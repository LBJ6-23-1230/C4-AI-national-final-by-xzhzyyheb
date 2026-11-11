from flask import Blueprint, jsonify, request
from app.api.identity import can_read_user, resolve_user_id
from app.api.validation import json_object, bad_request
from app.agent.course_outline import derive_knowledge_points
from app.tools.profile_merge import PROFILE_LOCK, merge_points_into_profile

from app.repositories.json_repository import JsonRepository
from app.repositories.staged_repository import StagedRepository


profile_api = Blueprint("profile", __name__)
_repository: JsonRepository | None = None


@profile_api.put('/api/v1/profile/<user_id>/knowledge-points/classification')
def confirm_point_classification(user_id):
	"""Keep unresolved material, let its owner explicitly choose course and topic."""
	import hashlib
	data, guard = json_object()
	if guard is not None:
		return guard
	user_id = resolve_user_id(user_id)
	point_id, course = (data.get(k) for k in ('knowledgePointId', 'courseName'))
	topic = data.get('topicName', '')
	if any(not isinstance(v, str) or not v.strip() or len(v) > limit for v, limit in
		((point_id, 128), (course, 80))) or not isinstance(topic, str) or len(topic) > 100:
		return bad_request('请选择知识点与具体课程')
	if course.strip() in ('待确认科目', '待分类', '其他') or topic.strip() in ('其他知识点', '待分类', '其他'):
		return bad_request('请匹配具体课程和主题')
	course, topic = course.strip(), topic.strip()
	with PROFILE_LOCK, _repository.transaction():
		profile = _repository.get('profiles', user_id)
		if not profile:
			return jsonify(errorCode='NOT_FOUND', message='画像不存在'), 404
		if type(data.get('expectedProfileVersion')) is not int or data['expectedProfileVersion'] != profile.get('profileVersion', 1):
			return jsonify(errorCode='CONFLICT', message='资料已有更新，请刷新后重新匹配'), 409
		point = next((p for p in profile.get('mastery', []) if p.get('knowledgePointId') == point_id), None)
		if point is None:
			return jsonify(errorCode='NOT_FOUND', message='知识点不存在'), 404
		point['sourceCourse'] = course
		point['courseConfirmed'] = True
		point['classificationRequired'] = False
		profile['profileVersion'] = profile.get('profileVersion', 1) + 1
		_repository.save('profiles', user_id, profile)
		if topic:
			_repository.save('topic_memberships', user_id + ':' + point_id, dict(userId=user_id,
			knowledgePointId=point_id, sourceCourse=course, knowledgePointName=point['knowledgePointName'],
			topicGroupId='topic-' + hashlib.sha256((course + '\0' + topic).encode()).hexdigest()[:20],
			topicGroupName=topic, topicGroupConfidence=1.0, confirmed=True))
		for collection in ('exercises', 'wrong_book'):
			for record in _repository.list(collection):
				if record.get('userId') == user_id and record.get('knowledgePointId') == point_id:
					record['courseName'] = course
					record['courseConfirmed'] = True
					key = user_id + ':' + record['exerciseId'] if collection == 'wrong_book' else record['exerciseId']
					_repository.save(collection, key, record)
	return get_profile(user_id)


def configure_profile_repository(repository: JsonRepository) -> None:
	global _repository
	_repository = repository


@profile_api.post('/api/v1/profile/<user_id>/knowledge-points/manual')
def create_manual_knowledge_point(user_id):
	from datetime import datetime, timezone
	import hashlib
	from app.services.subject_classification import normalized_mastery
	from app.tools.profile_merge import canonical_name
	data, guard = json_object()
	if guard is not None:
		return guard
	user_id = resolve_user_id(user_id)
	course, name = (data.get(key) for key in ('courseName', 'knowledgePointName'))
	if any(not isinstance(value, str) or not value.strip() or len(value.strip()) > 80 for value in (course, name)):
		return bad_request('请填写课程和知识点名称，各不超过80字')
	course, name = course.strip(), name.strip()
	if course in ('待确认科目', '待确认课程', '待分类', '其他'):
		return bad_request('请选择具体课程后再新增知识点')
	if _repository is None:
		return jsonify(errorCode='SERVICE_UNAVAILABLE', message='暂时无法保存知识点，请稍后重试'), 503
	with PROFILE_LOCK, _repository.transaction():
		profile = _repository.get('profiles', user_id)
		if profile is None:
			return jsonify(errorCode='NOT_FOUND', message='画像不存在'), 404
		point = next((row for row in normalized_mastery(profile)
			if row.get('sourceCourse') == course and canonical_name(row.get('knowledgePointName', '')) == canonical_name(name)), None)
		if point is None:
			rows = profile.setdefault('mastery', [])
			if len(rows) >= 60:
				return bad_request('知识点已达60个上限，请先整理已有知识点')
			point = dict(knowledgePointId='manual-point-' + hashlib.sha256((course + '\0' + canonical_name(name)).encode()).hexdigest()[:24],
				knowledgePointName=name, sourceCourse=course, source='manual', courseConfirmed=True,
				classificationRequired=False, masteryScore=0, confidence=0, lastUpdated=datetime.now(timezone.utc).isoformat())
			rows.append(point)
			profile['profileVersion'] = profile.get('profileVersion', 1) + 1
			_repository.save('profiles', user_id, profile)
	response = get_profile(user_id)
	return jsonify(next(row for row in response.get_json()['mastery'] if row['knowledgePointId'] == point['knowledgePointId']))


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
		expected_version = data.get("expectedProfileVersion")
		if getattr(_repository, "durable_jobs", False) or expected_version is not None:
			if isinstance(expected_version, bool) or not isinstance(expected_version, int) or expected_version != profile.get("profileVersion", 1):
				return jsonify({"errorCode": "CONFLICT", "message": "学习画像已变化，请刷新后再保存", "details": {"profileVersion": profile.get("profileVersion", 1)}}), 409
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
	from app.services.subject_classification import normalized_mastery
	profile = dict(profile, targetCourses=profile_courses(profile), mastery=normalized_mastery(profile))
	from app.services.learning_effect import projected_mastery
	profile['mastery'] = projected_mastery(_repository, user_id, profile['mastery'])
	from app.services.topic_groups import aggregate
	profile['topicGroups'] = aggregate(profile['mastery'])
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
		from app.services.learning_effect import projected_mastery
		profile = dict(profile, mastery=projected_mastery(_repository, user_id, profile.get('mastery', [])))
		return jsonify({"profileVersion": profile.get("profileVersion", 1), "profile": profile,
			"mastery": profile.get("mastery", []), "history": profile.get("history", []),
			"evidence": profile.get("evidence", []),
			"source": "llm" if any(p.get("source") == "llm" for p in selected) else "rules"})
