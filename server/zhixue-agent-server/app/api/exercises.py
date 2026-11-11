from datetime import datetime, timezone
import uuid
import json
import hashlib
import threading
from pathlib import Path

from flask import Blueprint, current_app, jsonify, request

from app.api.identity import current_user_id, resolve_user_id
from app.api.plans import plan_belongs_to
from app.api.validation import (MAX_ID_CHARS, bounded_str, json_object, validate_answers)
from app.domain.evidence import Evidence, MasteryHistory
from app.domain.plan import LearningPlan
from app.domain.profile import LearnerProfile
from app.repositories.json_repository import JsonRepository
from app.repositories.staged_repository import StagedRepository
from app.tools.assessment_tools import grade_exercise, persist_mastery, mastery_scores
from app.agent import chat_llm, exercise_gen
from app.tools.exercise_tools import _CLIENT_FIELDS, select_exercises
from app.services.assessment_replan import replan_request, execute_assessment_replan
from app.services import review_jobs
from app.services import exercise_cache
from app.services import practice_rounds
from app.services import photo_practice
from app.services.image_inputs import inspect_image
from app.services.exercise_math import calculation_is_valid, calculation_explanation


exercises_api = Blueprint("exercises", __name__)
DEMO_EXERCISE_SET_ID = "set-demo-binary-tree-001"
EXERCISE_SET_IDS = {DEMO_EXERCISE_SET_ID, "set-demo-data-structures-001"}
_repository: JsonRepository | None = None

from app.tools.profile_merge import PROFILE_LOCK
_SUBMIT_LOCK = PROFILE_LOCK

_EXERCISE_BANK = [
	{"exerciseId": "exercise-preorder-001", "knowledgePointId": "binary-tree-postorder",
	 "knowledgePointName": "前序遍历", "difficulty": "easy", "stem": "以下哪项是给定二叉树的前序遍历结果？",
	 "options": ["A. 根-左-右", "B. 左-右-根", "C. 左-根-右", "D. 根-右-左"], "source": "demo"},
	{"exerciseId": "exercise-inorder-001", "knowledgePointId": "binary-tree-postorder",
	 "knowledgePointName": "中序遍历", "difficulty": "easy", "stem": "二叉树中序遍历访问节点的顺序是什么？",
	 "options": ["A. 根-左-右", "B. 左-根-右", "C. 左-右-根", "D. 根-右-左"], "source": "demo"},
	{"exerciseId": "exercise-postorder-001", "knowledgePointId": "binary-tree-postorder",
	 "knowledgePointName": "二叉树后序遍历", "difficulty": "medium", "stem": "二叉树后序遍历访问节点的顺序是什么？",
	 "options": ["A. 根-左-右", "B. 左-根-右", "C. 左-右-根", "D. 根-右-左"], "source": "demo"},
	{"exerciseId": "exercise-postorder-002", "knowledgePointId": "binary-tree-postorder",
	 "knowledgePointName": "二叉树后序遍历", "difficulty": "easy", "stem": "后序遍历中，根节点通常在什么时候被访问？",
	 "options": ["A. 最先", "B. 左子树之后、右子树之前", "C. 左右子树都访问后", "D. 任意时刻"], "source": "demo"},
	{"exerciseId": "exercise-postorder-003", "knowledgePointId": "binary-tree-postorder",
	 "knowledgePointName": "二叉树后序遍历", "difficulty": "medium", "stem": "表达式树用后序遍历得到的结果最接近哪种表达式？",
	 "options": ["A. 前缀表达式", "B. 中缀表达式", "C. 后缀表达式", "D. 自然语言"], "source": "demo"},
	{"exerciseId": "exercise-postorder-004", "knowledgePointId": "binary-tree-postorder",
	 "knowledgePointName": "二叉树后序遍历", "difficulty": "medium", "stem": "递归实现后序遍历时，输出当前节点应放在哪一步？",
	 "options": ["A. 递归左子树前", "B. 递归左右子树之间", "C. 递归左右子树后", "D. 只在叶节点执行"], "source": "demo"},
	*[
		{"exerciseId": f"exercise-bst-{number:03d}", "knowledgePointId": "binary-tree-search",
		 "knowledgePointName": "二叉搜索树", "difficulty": "medium" if number % 2 else "hard",
		 "stem": "二叉搜索树的中序遍历具有什么性质？", "options": ["A. 有序", "B. 逆序", "C. 随机", "D. 层序"], "source": "demo"}
		for number in range(1, 6)
	],
	*[
		{"exerciseId": f"exercise-graph-{number:03d}", "knowledgePointId": "graph-algorithm",
		 "knowledgePointName": "图算法", "difficulty": "easy" if number % 2 else "medium",
		 "stem": "BFS 通常使用哪种数据结构？", "options": ["A. 栈", "B. 队列", "C. 堆", "D. 集合"], "source": "demo"}
		for number in range(1, 6)
	],
	*[
		{"exerciseId": f"exercise-complexity-{number:03d}", "knowledgePointId": "algorithm-complexity",
		 "knowledgePointName": "算法复杂度先修", "difficulty": "easy" if number < 3 else "medium",
		 "stem": "二分查找的时间复杂度是？", "options": ["A. O(1)", "B. O(log n)", "C. O(n)", "D. O(n^2)"], "source": "demo"}
		for number in range(1, 6)
	],
	*[
		{"exerciseId": f"exercise-traversal-{number:03d}", "knowledgePointId": "binary-tree-traversal",
		 "knowledgePointName": "二叉树遍历基础", "difficulty": "easy" if number < 3 else "medium",
		 "stem": "层序遍历通常按什么方向访问节点？", "options": ["A. 逐层", "B. 只访问叶子", "C. 只访问根", "D. 随机"], "source": "demo"}
		for number in range(1, 6)
	],
	*[
		{"exerciseId": f"exercise-prerequisite-{number:03d}", "knowledgePointId": "recursion-basics", "knowledgePointName": "递归基础先修",
		 "difficulty": "easy" if number % 2 else "medium", "stem": "递归函数必须具备什么？",
		 "options": ["A. 终止条件", "B. 全局变量", "C. 图结构", "D. 排序"], "source": "demo"}
		for number in range(1, 8)
	],
]

_QUESTION_BANK_PATH = Path(__file__).resolve().parents[2] / "data" / "question_bank.json"
if _QUESTION_BANK_PATH.exists():
	with _QUESTION_BANK_PATH.open("r", encoding="utf-8") as stream:
		_question_bank = json.load(stream).get("exercises", [])
	if len(_question_bank) >= 30 and len({item.get("exerciseId") for item in _question_bank}) == len(_question_bank):
		_EXERCISE_BANK = _question_bank

_DEMO_EXERCISES = select_exercises(_EXERCISE_BANK, "binary-tree-postorder", count=3)

_ANSWER_KEYS = {
	exercise["exerciseId"]: exercise["answerKey"]
	for exercise in _EXERCISE_BANK
	if exercise.get("answerKey")
}


def _merged_grading_tables(user_id: str | None = None) -> tuple[dict, dict]:
	"""判分用的两张表：`exerciseId → answerKey` 与 `exerciseId → knowledgePointId`。

	题库是常量；**模型现场出的题**存在 repository 的 `exercises` 集合里
	（判分发生在另一次请求，必须能把那批题找回来）。

	⚠️ 判分逻辑本身**一行没改** —— 仍然是 `grade_exercise` 按 `answerKey`
	逐题比对。这里只是让"被判分的题"多了"刚生成的那几道"，
	所以"判分是算式、不是模型觉得"这条纪律完好无损。
	"""
	answer_keys = dict(_ANSWER_KEYS)
	knowledge_points = {item["exerciseId"]: item["knowledgePointId"] for item in _EXERCISE_BANK}
	if _repository:
		for record in _repository.list("exercises"):
			if not isinstance(record, dict) or record.get("userId", "demo-user") != (user_id or resolve_user_id(None)):
				continue
			exercise_id = record.get("exerciseId")
			if not isinstance(exercise_id, str) or not exercise_id:
				continue
			if record.get("answerKey"):
				answer_keys[exercise_id] = record["answerKey"]
			knowledge_points[exercise_id] = record.get("knowledgePointId", "")
	return answer_keys, knowledge_points


def _generate_and_store(knowledge_point_name: str, count: int, excluded_ids=(), *,
		point_id: str | None = None, point_name: str | None = None, course: str = '', fresh: bool = False) -> list[dict]:
	"""让模型针对该知识点出题；**含答案**的版本存仓库，返回可下发的题面（不含答案）。"""
	owner = resolve_user_id(None)
	cache_key = exercise_cache.key(_repository, owner, knowledge_point_name, count,
		{"pointId": point_id, "course": course})
	with exercise_cache.guard(cache_key):
		exercise_gen.generation_failure.set('')
		items = None if fresh else exercise_cache.get(cache_key, _repository, excluded_ids)
		if items is None:
			items = exercise_gen.generate_exercises(knowledge_point_name, count)
			if not items:
				return []
			items = [dict(item, **({"knowledgePointId": point_id,
				"knowledgePointName": point_name or knowledge_point_name, "courseName": course}
				if point_id else {})) for item in items if item["exerciseId"] not in excluded_ids]
			if _repository:
				_repository.apply_batch([], [("exercises", item["exerciseId"], dict(item, userId=owner)) for item in items])
				exercise_cache.put(cache_key, items)
	return [{key: item[key] for key in _CLIENT_FIELDS if key in item} for item in items]


def _course_exercises(set_id, owner, course, raw_point, difficulty, count, excluded_ids):
	with exercise_cache.guard((str(_repository.path), owner, course, raw_point)):
		return _course_exercises_locked(set_id, owner, course, raw_point, difficulty, count, excluded_ids)


def _restore_round(previous, signature):
	if previous['signature'] != signature:
		return jsonify(errorCode='CONFLICT', message='本轮参数已变化，请重新开始练习'), 409
	for question in previous['response'].get('exercises', []):
		record = _repository.get('exercises', question['exerciseId']) or next(
			(item for item in _EXERCISE_BANK if item['exerciseId'] == question['exerciseId']), {})
		if not calculation_is_valid(dict(question, answerKey=record.get('answerKey'))):
			return jsonify(errorCode='CONFLICT', message='这组旧题的计算答案未通过校验，请返回重新生成练习题'), 409
	return jsonify(previous['response'])


def _course_exercises_locked(set_id, owner, course, raw_point, difficulty, count, excluded_ids):
	"""Resolve an owned practice target and keep grading bound to it."""
	from app.services.subject_classification import normalized_mastery, subject
	from app.services.exercise_quality import is_subject_question
	profile = _repository.get("profiles", owner) if _repository else None
	rows = normalized_mastery(profile or {})
	fresh = request.args.get("forceGenerate", '').lower() in ("1", "true", "yes")
	point = next((p for p in rows if p.get("knowledgePointId") == raw_point
		and p.get("sourceCourse") == course), None)
	if point is None:
		book = next((q for q in (_repository.list("wrong_book") if _repository else [])
			if q.get("userId") == owner and q.get("knowledgePointId") == raw_point
			and (q.get("courseName") if q.get("courseConfirmed") else subject(q.get("courseName"),
				q.get("knowledgePointName"), q.get("stem"), profile)) == course), None)
		if book is None and _repository:
			target_key = hashlib.sha256((owner + '\0' + course + '\0' + raw_point).encode()).hexdigest()
			book = _repository.get("wrong_book_targets", target_key)
		if book is not None:
			conflict = any(p.get("knowledgePointId") == raw_point and p.get("sourceCourse") != course for p in rows)
			point = dict(knowledgePointId=('course-point-' + hashlib.sha256((course + '\0' + raw_point).encode()).hexdigest()[:20]
				if conflict else raw_point), knowledgePointName=book["knowledgePointName"], sourceCourse=course)
		elif fresh and raw_point:
			from app.services.outline_recommendations import recommend
			from_outline = next((p for p in recommend(_repository, owner, course)["points"]
				if p["knowledgePointId"] == raw_point), None)
			if from_outline is not None:
				point = dict(knowledgePointId=raw_point, knowledgePointName=from_outline["knowledgePointName"], sourceCourse=course)
		if point is None:
			return jsonify({"errorCode": "COURSE_POINT_MISMATCH", "message": "课程与知识点不匹配，请重新选择"}), 400
	target = point["knowledgePointId"]
	generate = fresh or request.args.get("generate", '').lower() in ("1", "true", "yes")
	round_id = request.args.get('roundId', '')
	if len(round_id) > 128:
		return jsonify(errorCode='BAD_REQUEST', message='roundId is too long'), 400
	round_key = practice_rounds.identity(owner, round_id)
	signature = practice_rounds.signature(course, target, difficulty, count, excluded_ids, fresh)
	previous = _repository.get('practice_rounds', round_key) if round_id else None
	if previous:
		return _restore_round(previous, signature)
	prior = practice_rounds.previous_questions(_repository, owner, _EXERCISE_BANK, bool(round_id))
	prior.extend(q for q in _EXERCISE_BANK + _repository.list('exercises') if q.get('exerciseId') in excluded_ids)
	seen = {practice_rounds.fingerprint(q) for q in prior}
	exercises = []
	if not fresh:
		from app.api.wrong_book import _course_for
		bank = [q for q in _EXERCISE_BANK if (q.get("knowledgePointId") == target
			or q.get("knowledgePointName") == point["knowledgePointName"])
			and _course_for(owner, q) == course]
		candidates = []
		for q in bank:
			if q["knowledgePointId"] != target:
				if q["exerciseId"] in excluded_ids:
					continue
				q = dict(q, exerciseId='bound-' + hashlib.sha256(
					(owner + '\0' + course + '\0' + target + '\0' + q["exerciseId"]).encode()).hexdigest()[:24],
					knowledgePointId=target, knowledgePointName=point["knowledgePointName"], courseName=course, userId=owner)
				_repository.save("exercises", q["exerciseId"], q)
			candidates.append(q)
		candidates.extend(q for q in (_repository.list("exercises") if _repository else [])
			if q.get("userId") == owner and q.get("knowledgePointId") == target and q.get("courseName") == course
			and q.get("source") != "materials"
			and q.get("answerKey") and q.get("options") and is_subject_question(q) and calculation_is_valid(q))
		available = []
		for q in candidates:
			fingerprint = practice_rounds.fingerprint(q)
			if q.get('exerciseId') in excluded_ids or fingerprint in seen:
				continue
			if difficulty and q.get('difficulty') != difficulty:
				continue
			available.append(q)
			seen.add(fingerprint)
		exercises = select_exercises(available, target, difficulty, count, ())
	if len(exercises) < count and generate:
		token = exercise_gen.avoid_questions.set(tuple(q['stem'] for q in prior + exercises if q.get('stem')))
		try:
			generated = _generate_and_store(course + '：' + point["knowledgePointName"], min(count - len(exercises), 6), excluded_ids,
				point_id=target, point_name=point["knowledgePointName"], course=course, fresh=fresh or bool(round_id))
		finally:
			exercise_gen.avoid_questions.reset(token)
		for q in generated:
			fingerprint = practice_rounds.fingerprint(q)
			if fingerprint not in seen:
				exercises.append(q)
				seen.add(fingerprint)
	if exercises and _repository:
		with PROFILE_LOCK, _repository.transaction():
			current = _repository.get("profiles", owner) or dict(userId=owner, goal='课程复习', mastery=[], evidence=[], history=[])
			if not any(p.get("knowledgePointId") == target for p in current.get("mastery", [])):
				current.setdefault("mastery", []).append(dict(point, masteryScore=0, confidence=0,
					source='practice', lastUpdated=datetime.now(timezone.utc).isoformat()))
				current["profileVersion"] = current.get("profileVersion", 0) + 1
				_repository.save("profiles", owner, current)
	message = '' if exercises else ('出题服务尚未配置，请联系服务管理员配置模型后重试。' if generate and not exercise_gen.generation_available()
		else '本次出题未成功，请重新加载或换一个知识点重试。' if generate else '本课程暂无可用题目，请启用现场出题。')
	response = {"setId": set_id, "exercises": exercises, "courseName": course,
		"knowledgePointId": target, "generationFailed": not bool(exercises), "message": message}
	if not exercises and generate:
		response.update(exercise_gen.failure_details())
	if round_id and exercises:
		with _repository.transaction():
			previous = _repository.get('practice_rounds', round_key)
			if previous:
				return _restore_round(previous, signature)
			issued = practice_rounds.previous_questions(_repository, owner, _EXERCISE_BANK, True)
			used = {practice_rounds.fingerprint(q) for q in issued}
			response['exercises'] = [q for q in exercises if practice_rounds.fingerprint(q) not in used]
			if not response['exercises']:
				response.update(generationFailed=True, message='本轮未获得新题，请重新加载。')
			else:
				_repository.save('practice_rounds', round_key, dict(userId=owner, signature=signature,
					response=response, createdAt=datetime.now(timezone.utc).isoformat()))
	return jsonify(response)


def configure_exercises_repository(repository: JsonRepository) -> None:
	global _repository
	_repository = repository


def _resolve_knowledge_point_id(raw: str | None) -> str | None:
	"""把 `knowledgePointId` 参数**容错**成题库里真实存在的知识点 id。

	为什么需要：前端的错题诊断给出的是知识点**名字**（「图算法」「二叉树遍历」…），
	不是 id。若要求前端自己维护一份"名字 → id"的映射，就会有两处真源、必然漂移
	（题库改一个名字，前端就悄悄少出题）。题库就在本模块，在这里统一解析最稳。

	匹配顺序：精确 id → 精确名字 → 互相包含（「二叉树遍历」↔「二叉树遍历基础」）
	→ 共同二字前缀（「递归调用」↔「递归基础先修」）。
	**认不出就返回 None**（= 不加过滤）→ 走默认题集，
	而不是返回空列表把练习页整空 —— 宁可回落到默认题，也不要给一个打不开的页面。
	"""
	if raw is None:
		return None
	value = raw.strip()
	if not value:
		return None
	bank = list(_EXERCISE_BANK)
	for item in bank:
		if item.get("knowledgePointId") == value:
			return value
	for item in bank:
		if item.get("knowledgePointName") == value:
			return item.get("knowledgePointId")
	for item in bank:
		name = item.get("knowledgePointName") or ""
		if name and (value in name or name in value):
			return item.get("knowledgePointId")
	if len(value) >= 2:
		for item in bank:
			name = item.get("knowledgePointName") or ""
			if len(name) >= 2 and name[:2] == value[:2]:
				return item.get("knowledgePointId")
	return None


@exercises_api.get("/api/v1/exercises/<set_id>")
def get_exercise_set(set_id: str):
	if set_id not in EXERCISE_SET_IDS:
		return jsonify({"errorCode": "NOT_FOUND", "message": "exercise set not found", "details": {"setId": set_id}}), 404
	raw_point = (request.args.get("knowledgePointId") or "").strip()
	knowledge_point_id = _resolve_knowledge_point_id(raw_point)
	difficulty = request.args.get("difficulty")
	excluded_ids = request.args.getlist("excludeExerciseId")
	count_explicit = request.args.get("count") is not None
	try:
		count = int(request.args.get("count", 3))
		if count < 1:
			raise ValueError
	except ValueError:
		return jsonify({"errorCode": "BAD_REQUEST", "message": "count must be an integer", "details": None}), 400
	source_mode = request.args.get("sourceMode", "general")
	if source_mode not in ("general", "materials", "document_bank"):
		return jsonify({"errorCode": "BAD_REQUEST", "message": "sourceMode must be general, materials or document_bank", "details": None}), 400
	if source_mode == "document_bank":
		return _document_bank_set(set_id, count, excluded_ids)
	if source_mode == "materials":
		return _material_set(set_id, raw_point, count)
	course = (request.args.get("courseName") or "").strip()
	if course:
		return _course_exercises(set_id, resolve_user_id(None), course, raw_point, difficulty, count, excluded_ids)
	generate_requested = (request.args.get("generate") or "").strip().lower() in ("1", "true", "yes")
	fresh = request.args.get("forceGenerate", '').lower() in ("1", "true", "yes")
	generate_requested = generate_requested or fresh
	has_filter = bool(raw_point or difficulty or excluded_ids)
	if set_id == DEMO_EXERCISE_SET_ID and not has_filter:
		exercises = _DEMO_EXERCISES[:count] if count_explicit else _DEMO_EXERCISES
	else:
		exercises = []
		generation_attempted = bool(raw_point and (knowledge_point_id is None or fresh) and generate_requested)
		if generation_attempted:
			point = None
			if fresh and _repository:
				profile = _repository.get("profiles", resolve_user_id(None)) or {}
				point = next((row for row in profile.get("mastery", []) if row.get("knowledgePointId") == raw_point), None)
			if point:
				name = point["knowledgePointName"]
				course = point.get("sourceCourse", "")
				exercises = _generate_and_store(f"{course}：{name}" if course else name, count, excluded_ids,
					point_id=raw_point, point_name=name, course=course, fresh=True)
			else:
				exercises = _generate_and_store(raw_point, count, excluded_ids, fresh=fresh)
		if not exercises:
			if generation_attempted:
				return jsonify({
					"setId": set_id,
					"exercises": [],
					"generationFailed": True,
					**exercise_gen.failure_details(),
				})
			exercises = select_exercises(_EXERCISE_BANK, knowledge_point_id, difficulty, count, excluded_ids)
	response = {"setId": set_id, "exercises": exercises}
	if _repository and exercises and any(item.get("source") == "llm" for item in exercises):
		trace_id = f"trace-select-{uuid.uuid4().hex}"
		_repository.save("traces", trace_id, {"traceId": trace_id,
			"userId": resolve_user_id(request.args.get("userId")), "events": [{
				"agent": "exercise", "toolCalls": ["select_exercises"],
				"inputSummary": f"请求知识点 {raw_point}", "outputSummary": f"生成并入库 {len(exercises)} 道题",
				"evidenceIds": [], "stateVersion": 1, "timestamp": datetime.now(timezone.utc).isoformat(),
				"status": "completed", "stepId": "step-1", "inputStateVersion": 1, "outputStateVersion": 1}]})
		response["traceId"] = trace_id
	return jsonify(response)


@exercises_api.get("/api/v1/exercises/photo-practice")
def get_photo_practice():
	return jsonify(exercises=[photo_practice.public_question(exercise_id, question)
		for exercise_id, question in photo_practice.QUESTIONS.items()])


@exercises_api.post("/api/v1/exercises/photo-practice/generate")
def generate_photo_practice():
	data, guard = json_object()
	if guard is not None:
		return guard
	point, guard = bounded_str(data.get("knowledgePointName"), "知识点", 120)
	if guard is not None:
		return guard
	course, guard = bounded_str(data.get("courseName"), "课程", 120, required=False, allow_empty=True)
	if guard is not None:
		return guard
	point_id, guard = bounded_str(data.get("knowledgePointId"), "知识点标识", MAX_ID_CHARS, required=False)
	if guard is not None:
		return guard
	previous_id, guard = bounded_str(data.get("previousExerciseId"), "上一题", MAX_ID_CHARS, required=False)
	if guard is not None:
		return guard
	question_type = data.get("type")
	if question_type not in ("calculation", "written"):
		return jsonify(errorCode="BAD_REQUEST", message="请选择计算题或解答题", details=None), 400
	if not chat_llm.llm_ready():
		return jsonify(errorCode="SERVICE_UNAVAILABLE", message="AI 出题暂不可用，请稍后重试", details=None), 503
	repository = current_app.extensions["repository"]
	owner = resolve_user_id(None)
	point_id, point, course = photo_practice.point_binding(repository.get("profiles", owner) or {}, point, course, point_id)
	previous_stem = ""
	if previous_id:
		previous = repository.get("photo_exercises", previous_id)
		if (previous and previous.get("userId") == owner and previous.get("type") == question_type and
			previous.get("knowledgePointName") == point and previous.get("courseName") == course):
			previous_stem = previous["stem"]
	try:
		question = photo_practice.generate_question(point, course, question_type, previous_stem)
	except TimeoutError:
		return jsonify(errorCode="PHOTO_GENERATION_TIMEOUT", message="出题超时，请重试", details=None), 504
	except Exception:
		return jsonify(errorCode="PHOTO_GENERATION_FAILED", message="暂未生成可用的新题，请重试", details=None), 502
	exercise_id = f"photo-{uuid.uuid4().hex}"
	repository.save("photo_exercises", exercise_id, dict(question, userId=owner, exerciseId=exercise_id,
		knowledgePointId=point_id, knowledgePointName=point, courseName=course, createdAt=datetime.now(timezone.utc).isoformat()))
	return jsonify(photo_practice.public_question(exercise_id, question))


@exercises_api.post("/api/v1/exercises/photo-practice/<exercise_id>/grade")
def submit_photo_practice(exercise_id):
	repository = current_app.extensions["repository"]
	owner = resolve_user_id(None)
	question = photo_practice.QUESTIONS.get(exercise_id)
	if question is None:
		question = repository.get("photo_exercises", exercise_id)
		if not question or question.get("userId") != owner:
			return jsonify(errorCode="NOT_FOUND", message="未找到对应的拍照练习题，请重新生成", details=None), 404
	data, guard = json_object()
	if guard is not None:
		return guard
	encoded = data.get("image")
	if not isinstance(encoded, str) or len(encoded) > 2 * 1024 * 1024 or not encoded.startswith("/9j/"):
		return jsonify(errorCode="BAD_REQUEST", message="请选择一张有效的作答照片", details=None), 400
	receipt = inspect_image(encoded)
	if receipt["status"] != "received":
		return jsonify(errorCode="BAD_REQUEST", message=receipt["message"], details=None), 400
	if not chat_llm.llm_ready():
		return jsonify(errorCode="SERVICE_UNAVAILABLE", message="拍照批改暂不可用，请稍后重试", details=None), 503
	try:
		grade = photo_practice.grade_photo(exercise_id, photo_practice.rubric(question), encoded,
			receipt["attachmentId"], current_user_id())
	except TimeoutError:
		return jsonify(errorCode="PHOTO_GRADE_TIMEOUT", message="批改超时，已保留本次照片，可以重试", details=None), 504
	except Exception:
		return jsonify(errorCode="PHOTO_GRADE_FAILED", message="暂未取得完整的批改结果，可以重试", details=None), 502
	if data.get("review") is True and "userId" in question and grade["status"] == "graded":
		attempt_id = f"photo-attempt-{uuid.uuid4().hex}"
		repository.save("photo_attempts", attempt_id, {"userId": owner, "exerciseId": exercise_id,
			"status": "draft", "result": grade})
		return jsonify(exerciseId=exercise_id, status="review", attemptId=attempt_id, transcript=grade["transcript"])
	return jsonify(grade)


@exercises_api.post("/api/v1/exercises/photo-practice/<exercise_id>/complete")
def complete_photo_practice(exercise_id):
	repository = current_app.extensions["repository"]
	owner = resolve_user_id(None)
	question = repository.get("photo_exercises", exercise_id)
	if not question or question.get("userId") != owner:
		return jsonify(errorCode="NOT_FOUND", message="未找到对应的解答题", details=None), 404
	data, guard = json_object()
	if guard is not None:
		return guard
	unknown = data.get("outcome") == "unknown"
	if unknown:
		attempt_id = f"unknown-{exercise_id}"
		transcript = None
		result = {"exerciseId": exercise_id, "status": "unknown", "explanation": question["reference"]}
	else:
		attempt_id, guard = bounded_str(data.get("attemptId"), "作答标识", MAX_ID_CHARS)
		if guard is not None:
			return guard
		transcript, guard = bounded_str(data.get("transcript"), "作答内容", 1500)
		if guard is not None:
			return guard
		draft = repository.get("photo_attempts", attempt_id)
		if not draft or draft.get("userId") != owner or draft.get("exerciseId") != exercise_id:
			return jsonify(errorCode="NOT_FOUND", message="作答已失效，请重新提交照片", details=None), 404
		result = draft["result"]
		if draft["status"] == "draft" and transcript != result["transcript"]:
			if not chat_llm.llm_ready():
				return jsonify(errorCode="SERVICE_UNAVAILABLE", message="批改暂不可用，已保留修改内容", details=None), 503
			try:
				result = photo_practice.grade_text(exercise_id, photo_practice.rubric(question), transcript)
			except TimeoutError:
				return jsonify(errorCode="PHOTO_GRADE_TIMEOUT", message="重新批改超时，已保留修改内容", details=None), 504
			except Exception:
				return jsonify(errorCode="PHOTO_GRADE_FAILED", message="重新批改失败，已保留修改内容，可重试", details=None), 502
	with _SUBMIT_LOCK, repository.transaction():
		existing = repository.get("photo_attempts", attempt_id)
		if existing and existing["status"] == "completed":
			if existing["result"].get("transcript") != transcript:
				return jsonify(errorCode="CONFLICT", message="这次作答已提交，请重做本题后再修改", details=None), 409
			return jsonify(existing["result"])
		if repository.get("photo_exercises", exercise_id) != question:
			return jsonify(errorCode="NOT_FOUND", message="未找到对应的解答题", details=None), 404
		staged = StagedRepository(repository)
		response = photo_practice.finish_attempt(staged, owner, question, attempt_id, result)
		staged.commit()
	return jsonify(response)


@exercises_api.post("/api/v1/exercises/photo-practice/<exercise_id>/wrong-book")
def save_photo_wrong_book(exercise_id):
	from app.api.wrong_book import add_item
	repository = current_app.extensions["repository"]
	owner = resolve_user_id(None)
	data, guard = json_object()
	if guard is not None:
		return guard
	attempt_id, guard = bounded_str(data.get("attemptId"), "作答标识", MAX_ID_CHARS)
	if guard is not None:
		return guard
	with _SUBMIT_LOCK, repository.transaction():
		attempt = repository.get("photo_attempts", attempt_id)
		question = repository.get("photo_exercises", exercise_id)
		if (not attempt or not question or question.get("userId") != owner or attempt.get("userId") != owner or
			attempt.get("exerciseId") != exercise_id or attempt.get("status") != "completed"):
			return jsonify(errorCode="NOT_FOUND", message="请先完成这道解答题", details=None), 404
		result = attempt["result"]
		if result["status"] == "graded" and result["score"] >= result["maxScore"]:
			return jsonify(errorCode="BAD_REQUEST", message="这道题已得满分", details=None), 400
		add_item(repository, owner, dict(question, source="photo_practice", explanation=question["reference"],
			photoPracticeType=question["type"],
			knowledgePointId=result["knowledgePointId"], knowledgePointName=result["knowledgePointName"],
			courseName=result["courseName"]))
	return jsonify(exerciseId=exercise_id, added=True, removed=False)


@exercises_api.get("/api/v1/exercises/material-options")
def get_material_options():
	from app.agent.knowledge import valid_knowledge_term
	from app.services import grounded_exercises as grounding
	point = request.args.get("knowledgePointId", "").strip()
	course = request.args.get("courseName", "").strip()
	if not point or len(point) > 200 or len(course) > 120 or not valid_knowledge_term(point):
		return jsonify(errorCode="BAD_REQUEST", message="请提供有效的知识点和课程", details=None), 400
	owner = resolve_user_id(None)
	with _repository.transaction():
		options = grounding.material_options(_repository, owner, point, course)
	return jsonify(options=options)


@exercises_api.get("/api/v1/exercises/outline-recommendations")
def get_outline_recommendations():
	from app.services.outline_recommendations import recommend
	course = request.args.get("courseName", "").strip()
	if not course or len(course) > 120:
		return jsonify(errorCode="BAD_REQUEST", message="请提供有效的课程", details=None), 400
	return jsonify(recommend(_repository, resolve_user_id(None), course))


def _owned_bank_document(owner, document_id):
	doc = _repository.get('documents', document_id) or {}
	if doc.get('userId') != owner:
		return None, None
	kb = _repository.get('knowledge_bases', doc['kbId']) or {}
	return (doc, kb) if kb.get('userId') == owner else (None, None)


@exercises_api.get('/api/v1/exercises/document-banks')
def get_document_banks():
	from app.services import document_bank as bank
	owner = resolve_user_id(None)
	course = request.args.get('courseName', '').strip()
	document_id = request.args.get('documentId', '').strip()
	if len(course) > 120 or len(document_id) > 200:
		return jsonify(errorCode='BAD_REQUEST', message='课程或文件参数无效', details=None), 400
	if document_id:
		doc, _ = _owned_bank_document(owner, document_id)
		if not doc:
			return jsonify(errorCode='NOT_FOUND', message='文件不存在', details=None), 404
		documents = [doc]
	else:
		documents = bank.for_course(_repository, owner, course)
	used = bank.used_ids(_repository, owner) if documents else set()
	options = []
	for doc in documents:
		questions = bank.candidates(_repository, owner, doc)
		if questions:
			options.append(dict(kbId=doc['kbId'], documentId=doc['documentId'], fileName=doc['fileName'],
				count=len(questions), remaining=sum(q['exerciseId'] not in used for q in questions)))
	return jsonify(banks=options, maxCount=bank.MAX_ROUND)


def _document_bank_set(set_id, count, excluded_ids):
	from app.services import document_bank as bank
	owner = resolve_user_id(None)
	document_id = request.args.get('documentId', '').strip()
	kb_id = request.args.get('kbId', '').strip()
	if not document_id or not kb_id or max(len(document_id), len(kb_id)) > 200 or count > bank.MAX_ROUND:
		return jsonify(errorCode='BAD_REQUEST', message=f'请选择题库文件和 1 至 {bank.MAX_ROUND} 道题', details=None), 400
	doc, kb = _owned_bank_document(owner, document_id)
	if not doc or doc['kbId'] != kb_id:
		return jsonify(errorCode='NOT_FOUND', message='题库文件不存在', details=None), 404
	questions = bank.candidates(_repository, owner, doc)
	response = dict(setId=set_id, exercises=[], sourceMode=bank.MODE, kbId=kb_id, documentId=document_id)
	if len(questions) < count:
		return jsonify(dict(response, message=f'当前有 {len(questions)} 道可判分原题，请重新选择题数。'))
	with PROFILE_LOCK, _repository.transaction():
		current, _ = _owned_bank_document(owner, document_id)
		if current != doc:
			return jsonify(dict(response, message='题库文件已变更，请重新选择。'))
		used, excluded = bank.used_ids(_repository, owner), set(excluded_ids)
		questions.sort(key=lambda q: (q['exerciseId'] in used, q['exerciseId'] in excluded))
		items = questions[:count]
		_repository.apply_batch([], [('exercises', q['exerciseId'], dict(q, userId=owner,
			courseName=kb.get('courseName', ''), sourceDocumentId=document_id)) for q in items])
	response['exercises'] = [{key: q[key] for key in _CLIENT_FIELDS if key in q} for q in items]
	return jsonify(response)


def _material_set(set_id, point, count):
	from app.services import grounded_exercises as grounding
	from app.agent.knowledge import valid_knowledge_term
	owner = resolve_user_id(None)
	kb_id = request.args.get("kbId", "").strip()
	document_id = request.args.get("documentId", "").strip()
	if not point or not valid_knowledge_term(point) or not kb_id or len(point) > 200 or len(kb_id) > 200 or len(document_id) > 200 or count > 6:
		return jsonify({"errorCode": "BAD_REQUEST", "message": "资料题需指定知识点和资料库，题数为1至6", "details": None}), 400
	with PROFILE_LOCK, _repository.transaction():
		kb = _repository.get("knowledge_bases", kb_id) or {}
		if kb.get("userId") != owner:
			return jsonify(errorCode="NOT_FOUND", message="资料不存在", details=None), 404
		course = kb.get("courseName", "")
		requested_course = request.args.get("courseName", "").strip()
		if requested_course and requested_course.casefold() != course.strip().casefold():
			return jsonify(errorCode="BAD_REQUEST", message="资料与所选课程不匹配", details=None), 400
		target, name = grounding.material_target(_repository, owner, point, course)
		sources, failure = grounding.retrieve(_repository, owner, name, kb_id, document_id)
	if failure == "NOT_FOUND":
		return jsonify({"errorCode": "NOT_FOUND", "message": "资料不存在", "details": None}), 404
	response = {"setId": set_id, "exercises": [], "sourceMode": "materials",
		"kbId": kb_id, "documentId": document_id, "knowledgePointId": point}
	if not sources:
		return jsonify(dict(response, generationFailed=True, failureReason="INSUFFICIENT_MATERIALS",
			message="所选资料未检索到足够的相关原文，请补充资料或主动切换通用知识练习。"))
	cache_key = exercise_cache.key(_repository, owner, f"{course}\0{target}\0{name}", count, grounding.public_sources(sources))
	with exercise_cache.guard(cache_key):
		items = exercise_cache.get(cache_key, _repository, request.args.getlist("excludeExerciseId"))
		if items is None:
			items = [dict(item, knowledgePointId=target, knowledgePointName=name, courseName=course)
			         for item in grounding.generate(name, count, sources)]
	if not items:
		return jsonify(dict(response, generationFailed=True, failureReason="GENERATION_FAILED",
			message="本轮未能生成并核验所选数量的新题。可以减少题数、换资料，或从题库文件直接抽原题。"))
	with PROFILE_LOCK, _repository.transaction():
		if not grounding.sources_current(_repository, owner, sources):
			return jsonify(dict(response, generationFailed=True, failureReason="SOURCE_CHANGED",
				message="出题期间资料已删除或变更，请重新选择资料。"))
		trace_id = f"trace-materials-{uuid.uuid4().hex}"
		trace = {"traceId": trace_id, "userId": owner, "events": [{
			"agent": "exercise", "toolCalls": ["retrieve_materials", "generate_grounded_exercises"],
			"inputSummary": f"资料库 {kb_id}，知识点 {point}",
			"outputSummary": f"生成 {len(items)} 道资料题，来源链接及原文引用已核对；答案仍需学习者核验",
			"evidenceIds": [], "sourceChunkIds": [s["chunkId"] for s in sources],
			"stateVersion": 1, "timestamp": datetime.now(timezone.utc).isoformat(),
			"status": "completed", "stepId": "step-1", "inputStateVersion": 1, "outputStateVersion": 1}]}
		_repository.apply_batch([], [("exercises", item["exerciseId"], dict(item, userId=owner))
			for item in items] + [("traces", trace_id, trace)])
		exercise_cache.put(cache_key, items)
	response.update(exercises=[{k: item[k] for k in _CLIENT_FIELDS if k in item} for item in items], traceId=trace_id)
	return jsonify(response)


@exercises_api.get("/api/v1/exercises/<exercise_id>/sources")
def get_exercise_sources(exercise_id):
	from app.services import grounded_exercises as grounding
	owner = resolve_user_id(None)
	with PROFILE_LOCK, _repository.transaction():
		item = _repository.get("exercises", exercise_id) if _repository else None
		if not item or item.get("userId", "demo-user") != owner:
			return jsonify({"errorCode": "NOT_FOUND", "message": "题目不存在", "details": None}), 404
		sources = item.get("sources", [])
		if not grounding.sources_current(_repository, owner, sources):
			return jsonify({"errorCode": "SOURCE_UNAVAILABLE", "message": "原始资料已删除或变更，无法展示本题原文依据", "details": None}), 410
		return jsonify({"exerciseId": exercise_id, "sources": [dict(s,
			text=_repository.get("chunks", s["chunkId"])["text"]) for s in sources]})


@exercises_api.post("/api/v1/exercises/<set_id>/submit")
def submit_exercises(set_id: str):
	if set_id not in EXERCISE_SET_IDS:
		return jsonify({"errorCode": "NOT_FOUND", "message": "exercise set not found", "details": {"setId": set_id}}), 404
	data, guard = json_object()
	if guard is not None:
		return guard
	user_id = resolve_user_id(data.get("userId"))
	idempotency_key, guard = bounded_str(data.get("idempotencyKey"), "idempotencyKey",
										MAX_ID_CHARS)
	if guard is not None:
		return guard
	answers, guard = validate_answers(data.get("answers"))
	if guard is not None:
		return guard
	goal_id = data.get("goalId")
	goal = None
	if goal_id is not None:
		if not isinstance(goal_id, str) or not goal_id or len(goal_id) > MAX_ID_CHARS:
			return jsonify({"errorCode": "BAD_REQUEST", "message": "goalId格式无效", "details": None}), 400
		goal = _repository.get("workflows", goal_id) if _repository else None
		if not goal or goal.get("userId") != user_id or not goal.get("state", {}).get("coordination"):
			return jsonify({"errorCode": "NOT_FOUND", "message": "学习目标不存在", "details": None}), 404
		expected = data.get("goalStateVersion")
		if isinstance(expected, bool) or not isinstance(expected, int) or expected < 1:
			return jsonify({"errorCode": "BAD_REQUEST", "message": "目标交卷需要有效goalStateVersion", "details": None}), 400

	result_id = f"{user_id}:{set_id}:{idempotency_key}"
	request_fingerprint = hashlib.sha256(json.dumps({"answers":
		sorted((str(a["exerciseId"]), str(a.get("answer") or "").strip().upper()) for a in answers),
		"goalId": goal_id}, sort_keys=True).encode()).hexdigest()
	def replay(previous):
		if (previous.get("response", {}).get("goalId") != goal_id or
			previous.get("requestFingerprint", request_fingerprint) != request_fingerprint):
			return jsonify({"errorCode": "CONFLICT", "message": "该交卷标识已用于其他答案或目标", "details": None}), 409
		return jsonify(previous["response"])
	previous = _repository.get("submissions", result_id) if _repository else None
	if previous is not None:
		return replay(previous)
	def goal_conflict(repository):
		if not goal_id:
			return False
		current = repository.get("workflows", goal_id)
		refs = (current or {}).get("state", {}).get("inputRefs", {})
		profile = repository.get("profiles", user_id) or {}
		plan = repository.get("plans", refs.get("planId", "")) or {}
		return (not current or current.get("userEnded") or current.get("status") == "completed"
			or current.get("stateVersion") != data["goalStateVersion"]
			or refs.get("profileVersion", 0) != profile.get("profileVersion", 0)
			or refs.get("planVersion", 0) != plan.get("version", 0)
			or bool(current.get("state", {}).get("boundSubmissionId")))
	if goal_conflict(_repository):
		return jsonify({"errorCode": "CONFLICT", "message": "目标已变化或已交卷，请返回对话刷新目标", "details": None}), 409
	answer_keys, knowledge_points = _merged_grading_tables(user_id)
	question_records = list(_EXERCISE_BANK)
	if _repository:
		question_records.extend(item for item in _repository.list("exercises")
			if isinstance(item, dict) and item.get("userId", "demo-user") == user_id)
	questions_by_id = {str(item.get("exerciseId")): item for item in question_records
		if isinstance(item.get("exerciseId"), str)}
	submitted_answers = {str(item.get("exerciseId")): str(item.get("answer") or "").strip().upper()
		for item in answers}
	if any(key not in questions_by_id for key in submitted_answers):
		return jsonify({"errorCode": "NOT_FOUND", "message": "题目不存在或不属于当前账号", "details": None}), 404
	from app.services.exercise_quality import is_subject_question
	if any(not is_subject_question(questions_by_id[key]) for key in submitted_answers):
		return jsonify({"errorCode": "CONFLICT", "message": "这组旧题只考查考纲要求，不能用于测评，请返回重新生成知识练习题", "details": None}), 409
	if any(not calculation_is_valid(questions_by_id[key]) for key in submitted_answers):
		return jsonify({"errorCode": "CONFLICT", "message": "这组题的计算答案未通过校验，请返回重新生成练习题", "details": None}), 409
	if goal:
		target = goal["state"]["coordination"].get("knowledgePointId", "")
		allowed = {target, _resolve_knowledge_point_id(target)}
		if not target or any(questions_by_id[key].get("knowledgePointId") not in allowed for key in submitted_answers):
			return jsonify({"errorCode": "CONFLICT", "message": "题目与当前目标知识点不一致，请从目标入口重新进入练习", "details": None}), 409
	bank_round = all(questions_by_id[key].get('source') == 'document_bank' for key in submitted_answers)
	calculated_explanations = {key: calculation_explanation(questions_by_id[key]) for key in submitted_answers}
	document_sources = ('materials', 'document_bank')
	review_questions_for_job = [questions_by_id[key] for key in submitted_answers
		if questions_by_id[key].get("source") not in document_sources and not calculated_explanations[key]]
	review_available = bool(review_questions_for_job and exercise_gen.generation_available())
	durable_review = review_available and getattr(_repository, "durable_jobs", False)
	review_keys = {key: answer_keys[key] for key in submitted_answers}
	post_commit = []
	def _do_submit():
		repository = StagedRepository(_repository) if _repository else None
		if repository:
			previous = repository.get("submissions", result_id)
			if previous is not None:
				return replay(previous)
			if goal_conflict(repository):
				return jsonify({"errorCode": "CONFLICT", "message": "目标已变化或已交卷，请刷新目标", "details": None}), 409

		profile = repository.get("profiles", user_id) if repository else None
		if profile is None:
			return jsonify({"errorCode": "NOT_FOUND", "message": "profile not found", "details": {"userId": user_id}}), 404
		correct_ids = {exercise_id for exercise_id, answer in submitted_answers.items()
			if exercise_id in answer_keys and answer == answer_keys[exercise_id]}

		old_scores = mastery_scores(profile)
		names = {item["exerciseId"]: item.get("knowledgePointName", "知识点理解")
			for item in question_records}
		assessment = grade_exercise(answers, answer_keys, knowledge_points,
			exercise_result_id=result_id, knowledge_point_names=names,
			old_mastery_by_point=old_scores)
		score = assessment.score
		report_point = assessment.dominant_knowledge_point()
		report_old = old_scores.get(report_point, 0)
		report_new = assessment.per_knowledge_mastery.get(report_point, report_old)
		replan_point = assessment.remediation_knowledge_point()
		replan_mastery = assessment.per_knowledge_mastery.get(replan_point, 0)
		replan_score = round(assessment.per_knowledge_accuracy.get(replan_point, 1) * 100, 2)
		response = {
			"userId": user_id,
			"submissionId": result_id,
			"reviewStatus": "pending" if review_available else "unconfigured" if review_questions_for_job else "completed",
			"assessment": assessment.to_dict(),
			"masteryUpdate": None if bank_round else {"knowledgePointId": report_point, "oldScore": report_old,
				"newScore": report_new},
			"needReplan": False,
			"review": [{
				"exerciseId": exercise_id,
				"selectedAnswer": submitted_answers[exercise_id],
				"correctAnswer": answer_keys[exercise_id],
				"correct": exercise_id in correct_ids,
				"explanation": calculated_explanations[exercise_id] or (questions_by_id[exercise_id].get("explanation", "")
					if questions_by_id[exercise_id].get("source") in document_sources else ""),
				"explanationSource": "calculation" if calculated_explanations[exercise_id] else
					"materials" if questions_by_id[exercise_id].get("source") in document_sources else "fallback",
				"sources": questions_by_id.get(exercise_id, {}).get("sources", []),
			} for exercise_id in submitted_answers if exercise_id in answer_keys],
		}
		if goal_id:
			response["goalId"] = goal_id
		handoff = replan_request(assessment)
		response["replanDecision"] = handoff["decision"]
		response["needReplan"] = response["replanDecision"]["needReplan"]
		if repository:
			trace_id = f"trace-submit-{user_id}:{set_id}:{idempotency_key}"
			evidence_id = f"evidence-submit-{user_id}:{set_id}:{idempotency_key}"
			response["traceId"] = trace_id
			response["evidenceIds"] = [evidence_id]
			timestamp = datetime.now(timezone.utc)
			replanned: bool = False
			profile_model_dict = persist_mastery(repository, user_id, assessment,
				evidence_id, result_id, timestamp, point_details={
					item["knowledgePointId"]: {
						"knowledgePointName": item["knowledgePointName"],
						"sourceCourse": item["courseName"],
					} for item in question_records if item.get("source") == "materials" and item.get("courseName")
				})
			from app.api.wrong_book import record_submission
			record_submission(repository, user_id,
				[questions_by_id[key] for key in submitted_answers], submitted_answers, correct_ids)
			wrong_ids = {item.get("exerciseId") for item in repository.list("wrong_book")
				if isinstance(item, dict) and item.get("userId") == user_id}
			for item in response["review"]:
				item["inWrongBook"] = item["exerciseId"] in wrong_ids
			if profile_model_dict:
				if response["needReplan"]:
					plans = [item for item in repository.list("plans")
						if plan_belongs_to(item, user_id)]
					plan = next((item for item in plans if item.get("planId") == "plan-demo-001"), None)
					plan = plan or (plans[0] if plans else None)
					if plan is not None:
						outcome = execute_assessment_replan(repository, user_id, plan["planId"],
							handoff, [evidence_id])
						if outcome["changed"]:
							replanned = True
							response.update({"plan": outcome["plan"], "planDiff": outcome["planDiff"]})
			events: list[dict] = [{
				"agent": "assessment", "toolCalls": ["grade_exercise"] + (["update_mastery"] if profile_model_dict else []),
				"inputSummary": f"提交题集 {set_id}", "outputSummary": f"得分 {score}",
				"evidenceIds": [evidence_id], "stateVersion": 1, "timestamp": timestamp.isoformat(),
				"status": "completed", "sessionId": data.get("sessionId"), "stepId": "step-1",
				"inputStateVersion": 1, "outputStateVersion": 1}]
			if replanned:
				events.append({
					"agent": "planner", "toolCalls": ["replan_learning_path"],
					"inputSummary": f"知识点 {replan_point}，掌握度 {old_scores.get(replan_point, 0)} → {replan_mastery}，该点得分 {replan_score}",
					"outputSummary": f"计划重排为 V{response['plan'].get('version')}",
					"evidenceIds": [evidence_id], "stateVersion": 2,
					"timestamp": datetime.now(timezone.utc).isoformat(),
					"status": "completed", "sessionId": data.get("sessionId"), "stepId": "step-2",
					"inputStateVersion": 1, "outputStateVersion": 2})
			trace = {"traceId": trace_id, "userId": user_id, "events": events}
			response['planChangeSummary'] = ('本轮题库练习结果已保存。' if bank_round else '本轮结果已更新，已根据测评调整学习安排。'
				if replanned else '本轮结果已更新，当前计划无需调整。')
			repository.save("traces", trace_id, trace)
			if goal_id:
				from app.services.learning_context import bind_submission
				bind_submission(repository, repository.get("workflows", goal_id), response, events)
			submission_record = {"response": response, "userId": user_id,
				"idempotencyKey": f"{set_id}:{idempotency_key}", "answers": answers, "reviewToken": uuid.uuid4().hex,
				"requestFingerprint": request_fingerprint, "createdAt": timestamp.isoformat()}
			from app.services.learning_effect import question_facts
			submission_record['questionFacts'] = question_facts(
				[questions_by_id[k] for k in submitted_answers if questions_by_id[k].get('source') != 'document_bank'], correct_ids)
			repository.save("submissions", result_id, submission_record)
			if review_available:
				wrong_snapshots = {key: repository.get("wrong_book", f"{user_id}:{key}") for key in submitted_answers}
				if durable_review:
					from app.services.job_queue import enqueue
					enqueue(repository, "review", user_id, {"submissionId": result_id, "expected": submission_record,
						"wrongSnapshots": wrong_snapshots, "questions": review_questions_for_job,
						"answers": submitted_answers, "keys": review_keys}, result_id)
				else:
					post_commit.append((repository.repository, result_id, submission_record, wrong_snapshots))
			for exercise_id in submitted_answers:
				repository.save("exercise_usage", f"{user_id}:{exercise_id}", {
					"userId": user_id, "exerciseId": exercise_id, "submissionId": result_id,
					"createdAt": timestamp.isoformat()})
		http_response = jsonify(response)
		if repository is not None:
			from app.services.reminders import reconcile as reconcile_reminders
			reconcile_reminders(repository, user_id)
			repository.commit()
		return http_response

	with _SUBMIT_LOCK:
		with (_repository.transaction(user_id) if getattr(_repository, "durable_jobs", False) else _repository.transaction()):
			response = _do_submit()
	for job in post_commit:
		review_jobs.start(*job, review_questions_for_job, submitted_answers, review_keys)
	return response


@exercises_api.get("/api/v1/exercise-submissions/<path:submission_id>")
def get_submission_review(submission_id):
    owner = resolve_user_id(request.args.get("userId"))
    record = _repository.get("submissions", submission_id) if _repository else None
    if not record or record.get("response", {}).get("userId") != owner:
        return jsonify({"errorCode": "NOT_FOUND", "message": "交卷记录不存在"}), 404
    return jsonify(record["response"])
