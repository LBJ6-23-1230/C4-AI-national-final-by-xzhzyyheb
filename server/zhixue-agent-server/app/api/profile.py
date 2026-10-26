from flask import Blueprint, jsonify, request
from app.api.identity import can_read_user, resolve_user_id
from app.api.validation import json_object, bad_request
from app.agent.course_outline import derive_knowledge_points
from app.tools.profile_merge import PROFILE_LOCK, merge_points_into_profile

from app.repositories.json_repository import JsonRepository
from app.repositories.staged_repository import StagedRepository


profile_api = Blueprint("profile", __name__)
_repository: JsonRepository | None = None


def configure_profile_repository(repository: JsonRepository) -> None:
	global _repository
	_repository = repository


@profile_api.put("/api/v1/profile/<user_id>/preferences")
def update_learning_preferences(user_id):
	import re
	data, guard = json_object()
	if guard is not None:
		return guard
	user_id = resolve_user_id(user_id)
	from app.services.course_names import course_names
	raw_courses = data.get("targetCourses", data.get("targetCourse"))
	if not isinstance(raw_courses, (str, list)) or isinstance(raw_courses, list) and any(not isinstance(c, str) for c in raw_courses):
		return bad_request("请选择学习课程")
	courses = course_names(raw_courses)
	goal, slots = data.get("goal", ""), data.get("freeTimeSlots")
	if not courses or len(courses) > 12 or any(len(c) > 80 for c in courses) or not isinstance(goal, str) or len(goal.strip()) > 200:
		return bad_request("请选择1至12门课程，目标不超过200字")
	if not isinstance(slots, list) or len(slots) > 14 or any(not isinstance(s, str) or not re.fullmatch(r"(?:[01]\d|2[0-3]):[0-5]\d-(?:[01]\d|2[0-3]):[0-5]\d", s) or s[:5] >= s[6:] for s in slots):
		return bad_request("空闲时间请使用 HH:MM-HH:MM，结束时间应晚于开始时间")
	with PROFILE_LOCK, _repository.transaction():
		profile = _repository.get("profiles", user_id)
		if profile is None:
			return jsonify({"errorCode": "NOT_FOUND", "message": "画像不存在"}), 404
		profile.update(targetCourse=courses[0], targetCourses=courses, goal=goal.strip(),
			courseGoals={c: goal.strip() for c in courses}, freeTimeSlots=list(dict.fromkeys(slots)),
			profileVersion=profile.get("profileVersion", 1) + 1, preferencesConfirmed=True)
		_repository.save("profiles", user_id, profile)
	return jsonify({"profile": profile, "profileVersion": profile["profileVersion"],
		"mastery": profile.get("mastery", []), "history": profile.get("history", []), "evidence": profile.get("evidence", [])})


@profile_api.get("/api/v1/profile/<user_id>")
def get_profile(user_id: str):
	"""仅公开演示画像，真实画像按会话归属读取。"""
	if not can_read_user(user_id):
		return jsonify({"errorCode": "NOT_FOUND", "message": "profile not found", "details": None}), 404
	profile = _repository.get("profiles", user_id) if _repository else None
	if profile is None:
		return jsonify({"errorCode": "NOT_FOUND", "message": "profile not found", "details": {"userId": user_id}}), 404
	from app.services.course_names import profile_courses
	profile = dict(profile, targetCourses=profile_courses(profile))
	return jsonify({"profileVersion": profile.get("profileVersion", 1),
		"profile": profile, "mastery": profile.get("mastery", []),
		"history": profile.get("history", []), "evidence": profile.get("evidence", [])})


@profile_api.post("/api/v1/profile/<user_id>/knowledge-points")
def add_knowledge_points(user_id):
	data, guard = json_object()
	if guard is not None:
		return guard
	user_id = resolve_user_id(user_id)
	courses = data.get("courses")
	if not isinstance(courses, list) or not 1 <= len(courses) <= 60 or any(
		not isinstance(c, str) or not c.strip() or len(c.strip()) > 80 for c in courses):
		return bad_request("courses 必须为 1–60 个非空课程名，每个不超过 80 字")
	courses = list(dict.fromkeys(c.strip() for c in courses))
	if _repository is None:
		return jsonify({"errorCode": "SERVICE_UNAVAILABLE", "message": "repository unavailable"}), 503
	with PROFILE_LOCK:
		profile = _repository.get("profiles", user_id)
		if profile is None:
			return jsonify({"errorCode": "NOT_FOUND", "message": "profile not found"}), 404
		cached = profile.get("courseOutlines", {})
		missing = [c for c in courses if c not in cached]
	# Never hold the profile lock while waiting for a model.
	points = derive_knowledge_points(missing, course_details=data.get("courseDetails")) if missing else []
	with PROFILE_LOCK, _repository.transaction():
		staged = StagedRepository(_repository)
		profile = staged.get("profiles", user_id)
		if profile is None:
			return jsonify({"errorCode": "NOT_FOUND", "message": "profile not found"}), 404
		cached = profile.setdefault("courseOutlines", {})
		for course in missing:
			cached.setdefault(course, [p for p in points if p["sourceCourse"] == course])
		if missing:
			staged.save("profiles", user_id, profile)
		selected = [p for c in courses for p in cached[c]]
		profile = merge_points_into_profile(staged, user_id, selected)
		staged.commit()
		return jsonify({"profileVersion": profile.get("profileVersion", 1), "profile": profile,
			"mastery": profile.get("mastery", []), "history": profile.get("history", []),
			"evidence": profile.get("evidence", []),
			"source": "llm" if any(p.get("source") == "llm" for p in selected) else "rules"})
