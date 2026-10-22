"""Deterministic grading and mastery update rules."""

from collections.abc import Iterable, Mapping
from datetime import datetime, timezone
from typing import Any

from app.domain.assessment import AssessmentResult
from app.domain.evidence import Evidence, MasteryHistory
from app.domain.profile import KnowledgeMastery, LearnerProfile


def grade_exercise(
	answers: Iterable[Mapping[str, object]],
	answer_keys: Mapping[str, str],
	knowledge_points: Mapping[str, str] | None = None,
	old_mastery: int | float = 0,
	exercise_result_id: str | None = None,
	knowledge_point_names: Mapping[str, str] | None = None,
	old_mastery_by_point: Mapping[str, int | float] | None = None,
) -> AssessmentResult:
	"""Grade submitted answers without calling an LLM or mutating state."""
	knowledge_points = knowledge_points or {}
	submitted: dict[str, str] = {}
	for answer in answers:
		exercise_id = answer.get("exerciseId")
		if exercise_id is None:
			continue
		submitted[str(exercise_id)] = str(answer.get("answer", "")).strip().upper()

	valid_ids = [exercise_id for exercise_id in submitted if exercise_id in answer_keys]
	correct_ids = [exercise_id for exercise_id in valid_ids if submitted[exercise_id] == answer_keys[exercise_id]]
	score = round(len(correct_ids) / max(1, len(valid_ids)) * 100, 2)
	per_knowledge: dict[str, list[bool]] = {}
	for exercise_id in valid_ids:
		knowledge_point_id = knowledge_points.get(exercise_id, "unknown")
		per_knowledge.setdefault(knowledge_point_id, []).append(exercise_id in correct_ids)
	accuracy = {key: round(sum(values) / len(values), 4) for key, values in per_knowledge.items()}
	counts = {key: len(values) for key, values in per_knowledge.items()}
	# An explicit profile map uses zero for unseen points. The scalar remains
	# supported for existing single-point tool callers.
	old_scores = {point: (old_mastery_by_point.get(point, 0)
		if old_mastery_by_point is not None else old_mastery) for point in accuracy}
	new_scores = {point: update_mastery(old_scores[point], round(value * 100, 2))
		for point, value in accuracy.items()}
	primary = min(accuracy, key=lambda p: (-counts[p], p), default=None)
	wrong_names = list(dict.fromkeys((knowledge_point_names or {}).get(key, "知识点理解")
		for key in valid_ids if key not in correct_ids))
	error_types = [f"{name}·答错" for name in wrong_names]
	return AssessmentResult(
		score=score,
		per_knowledge_accuracy=accuracy,
		error_types=error_types,
		old_mastery=old_scores[primary] if primary else old_mastery,
		suggested_new_mastery=new_scores[primary] if primary else old_mastery,
		per_knowledge_mastery=new_scores,
		old_mastery_by_point=old_scores,
		question_counts=counts,
		correct_counts={key: sum(values) for key, values in per_knowledge.items()},
		exercise_result_id=exercise_result_id,
	)


def mastery_scores(profile: Mapping[str, Any]) -> dict[str, int | float]:
	"""Read authoritative point baselines for both submission entry points."""
	return {row["knowledgePointId"]: row.get("masteryScore", 0)
		for row in profile.get("mastery", []) if row.get("knowledgePointId")}


def update_mastery(old_score: int | float, assessment_score: float) -> int | float:
	"""Apply the transparent demo rule used by the assessment boundary."""
	if not 0 <= old_score <= 100:
		raise ValueError("old_score must be between 0 and 100")
	if not 0 <= assessment_score <= 100:
		raise ValueError("assessment_score must be between 0 and 100")
	if assessment_score == 100:
		delta = 29
	elif assessment_score >= 60:
		delta = 16
	elif assessment_score >= 40:
		delta = 4
	else:
		delta = -4
	return max(0, min(100, old_score + delta))


def persist_mastery(repository: Any, user_id: str, assessment: AssessmentResult,
					evidence_id: str, result_id: str,
					timestamp: datetime | None = None,
					additional_saves: list[tuple[str, str, dict[str, Any]]] | None = None) -> dict[str, Any] | None:
	"""Persist the assessment-owned mastery, evidence, and history updates."""
	profile = repository.get("profiles", user_id)
	if profile is None or not assessment.per_knowledge_accuracy:
		return None
	timestamp = timestamp or datetime.now(timezone.utc)
	profile_model = LearnerProfile.from_dict(profile)
	# Legacy results without per-point updates use the actual profile baseline.
	previous_scores = mastery_scores(profile)
	new_scores = {point: assessment.per_knowledge_mastery.get(point,
		update_mastery(previous_scores.get(point, 0), round(accuracy * 100, 2)))
		for point, accuracy in assessment.per_knowledge_accuracy.items() if point != "unknown"}
	if not new_scores:
		return None
	touched_points: list[str] = []
	for mastery in profile_model.mastery:
		if mastery.knowledge_point_id in new_scores:
			mastery.mastery_score = new_scores[mastery.knowledge_point_id]
			mastery.last_updated = timestamp
			touched_points.append(mastery.knowledge_point_id)
	# ⚠️ 画像里**没有记录**的知识点必须补建，否则"练了但没记上"。
	# 原实现只更新已存在的条目 —— 提交一个新知识点的题集时，
	# 掌握度变化在响应里可见、在画像里却查无此点，历史与事实不符。
	existing_points = {m.knowledge_point_id for m in profile_model.mastery}
	for point in assessment.per_knowledge_accuracy:
		if point in existing_points or point == "unknown":
			continue
		profile_model.mastery.append(KnowledgeMastery(
			knowledge_point_id=point,
			knowledge_point_name=point,
			mastery_score=new_scores[point],
			confidence=0.5,
			last_updated=timestamp,
		))
		touched_points.append(point)
	profile_model.advance_version()
	profile_dict = {**profile, **profile_model.to_dict()}
	previous_rows = {row["knowledgePointId"]: row for row in profile.get("mastery", [])}
	profile_dict["mastery"] = [{**previous_rows.get(row["knowledgePointId"], {}), **row}
		for row in profile_dict["mastery"]]
	profile_dict["history"] = profile.get("history", []) + [
		{**MasteryHistory(previous_scores.get(point, 0), new_scores[point],
			[evidence_id], "assessment", timestamp).to_dict(), "knowledgePointId": point,
			"questionCount": assessment.question_counts.get(point, 0)} for point in sorted(new_scores)]
	evidence = Evidence(evidence_id, "assessment", result_id,
		assessment.dominant_knowledge_point(), "accuracy",
		assessment.score / 100, timestamp, 1.0).to_dict()
	# ⚠️ 归属必须落盘。原来不写 `userId`，导致聚合侧无法按用户过滤 ——
	# `app/api/plans.py` 的「错误强度」只能把所有人的证据加在一起
	# （所以那边才要用 `sourceId` 前缀反查兜底）。这里补上，
	# 新数据就有了准确的归属；`Evidence` 域模型不加字段是为了不动它的
	# 序列化契约，与 `demo.py` 里 `plan_data["userId"] = ...` 是同一手法。
	evidence["userId"] = user_id
	# A legacy evidence ID now retains facts for every assessed point.
	evidence["perKnowledgeAccuracy"] = dict(assessment.per_knowledge_accuracy)
	evidence["masteryUpdates"] = [{"knowledgePointId": point,
		"oldScore": previous_scores.get(point, 0), "newScore": new_scores[point],
		"questionCount": assessment.question_counts.get(point, 0)} for point in sorted(new_scores)]
	profile_dict["evidence"] = profile.get("evidence", []) + [evidence]
	repository.apply_batch([], [("profiles", user_id, profile_dict),
		("evidences", evidence_id, evidence), *(additional_saves or [])])
	return profile_dict
