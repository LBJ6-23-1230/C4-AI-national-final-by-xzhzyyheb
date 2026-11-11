from flask import Blueprint, jsonify, request
from datetime import datetime, timezone
import hashlib

from app.api.identity import resolve_user_id
from app.api.validation import json_object, bounded_str, MAX_ID_CHARS
from app.repositories.json_repository import JsonRepository


plans_api = Blueprint("plans", __name__)
_repository: JsonRepository | None = None


def configure_plans_repository(repository: JsonRepository) -> None:
	global _repository
	_repository = repository


@plans_api.post('/api/v1/plans/current/tasks/split')
def split_task():
	from app.tools.profile_merge import PROFILE_LOCK
	from copy import deepcopy
	data, guard = json_object()
	if guard is not None:
		return guard
	owner = resolve_user_id(data.get('userId'))
	steps = data.get('steps')
	if not isinstance(steps, list) or not 2 <= len(steps) <= 10 or any(not isinstance(s, dict) or
		not isinstance(s.get('title'), str) or not 1 <= len(s['title'].strip()) <= 200 or
		type(s.get('minutes')) is not int or not 1 <= s['minutes'] <= 1440 for s in steps):
		return jsonify(errorCode='BAD_REQUEST', message='请填写2至10个明确步骤和整数分钟'), 400
	with PROFILE_LOCK, _repository.transaction():
		plan = next((p for p in _repository.list('plans') if plan_belongs_to(p, owner)), None)
		if plan is None:
			return jsonify(errorCode='NOT_FOUND', message='计划不存在'), 404
		if type(data.get('expectedPlanVersion')) is not int or data['expectedPlanVersion'] != plan['version']:
			return jsonify(errorCode='CONFLICT', message='计划已有变化，请刷新后重试'), 409
		task = next((t for t in plan.get('tasks', []) + plan.get('unscheduledTasks', []) if t['taskId'] == data.get('taskId')), None)
		if task is None or task.get('status') in ('completed', 'running', 'in_progress') or task.get('parentTaskId'):
			return jsonify(errorCode='CONFLICT', message='该任务已变化或不支持继续拆分'), 409
		if sum(s['minutes'] for s in steps) != task['durationMinutes']:
			return jsonify(errorCode='BAD_REQUEST', message='步骤时长之和必须等于原任务预计时长'), 400
		children = [dict(task, taskId='step-' + hashlib.sha256((task['taskId'] + ':' + str(i)).encode()).hexdigest()[:24],
			parentTaskId=task['taskId'], source='ddl_step' if task.get('source') == 'ddl' else 'study_step',
			knowledgePointName=task['knowledgePointName'] + ' · ' + s['title'].strip(),
			durationMinutes=s['minutes'], status='pending', steps=[s['title'].strip()],
			deferredReason='已按你确认的步骤拆分，请确认每日时长后排期') for i, s in enumerate(steps)]
		for child in children:
			child.pop('scheduledDate', None)
		plan.setdefault('taskDecompositions', {})[task['taskId']] = dict(original=deepcopy(task), childIds=[t['taskId'] for t in children])
		plan['tasks'] = [t for t in plan.get('tasks', []) if t['taskId'] != task['taskId']]
		plan['unscheduledTasks'] = [t for t in plan.get('unscheduledTasks', []) if t['taskId'] != task['taskId']] + children
		plan['version'] += 1
		plan['reason'] = '已按确认的步骤拆分，原预计工作量保持不变；请在本周计划排期'
		_repository.save('plans', plan['planId'], plan)
	return jsonify(plan)


@plans_api.post('/api/v1/plans/current/recommendation')
def accept_assessment_action():
	from app.tools.profile_merge import PROFILE_LOCK
	from app.services.subject_classification import normalized_mastery
	data, guard = json_object()
	if guard is not None:
		return guard
	owner = resolve_user_id(data.get('userId'))
	point_id = data.get('knowledgePointId')
	if not isinstance(point_id, str) or not 1 <= len(point_id) <= 128:
		return jsonify(errorCode='BAD_REQUEST', message='请选择具体知识点'), 400
	with PROFILE_LOCK, _repository.transaction():
		profile = _repository.get('profiles', owner) or {}
		point = next((p for p in normalized_mastery(profile) if p.get('knowledgePointId') == point_id), None)
		if point is None:
			return jsonify(errorCode='NOT_FOUND', message='知识点不存在'), 404
		if not point.get('sourceCourse'):
			return jsonify(errorCode='CONFLICT', message='请先手动匹配课程'), 409
		plan = next((p for p in _repository.list('plans') if plan_belongs_to(p, owner)), None)
		plan = plan or dict(planId='plan-improve-' + owner, userId=owner, version=1,
			generatedFromProfileVersion=profile.get('profileVersion', 1), tasks=[], unscheduledTasks=[])
		from zoneinfo import ZoneInfo
		day = datetime.now(ZoneInfo('Asia/Shanghai')).date().isoformat()
		task_id = 'improve-' + hashlib.sha256((owner + '\0' + point_id + '\0' + day).encode()).hexdigest()[:24]
		if not any(t['taskId'] == task_id for t in plan.get('tasks', []) + plan.get('unscheduledTasks', [])):
			plan.setdefault('unscheduledTasks', []).append(dict(taskId=task_id, knowledgePointId=point_id,
				knowledgePointName='巩固' + point['knowledgePointName'], sourceCourse=point['sourceCourse'],
				source='assessment', durationMinutes=15, status='pending', priority='high',
				steps=['核对该知识点的错题解析，写出具体出错步骤', '完成相近难度新题并在学习报告查看结果'],
				deferredReason='已采纳测评改进动作，请在本周计划确认时间并排期'))
			plan['version'] += 1
			_repository.save('plans', plan['planId'], plan)
	return jsonify(plan)


@plans_api.post('/api/v1/plans/current/calendar')
def confirm_calendar():
	from app.services.calendar_plan import schedule
	from app.tools.profile_merge import PROFILE_LOCK
	from app.tools.plan_tools import create_plan_history
	data, guard = json_object()
	if guard is not None:
		return guard
	owner = resolve_user_id(data.get('userId'))
	with PROFILE_LOCK, _repository.transaction():
		plan = next((p for p in _repository.list('plans') if plan_belongs_to(p, owner)), None)
		if plan is None:
			return jsonify(errorCode='NOT_FOUND', message='请先建立学习任务'), 404
		if type(data.get('expectedPlanVersion')) is not int or data['expectedPlanVersion'] != plan['version']:
			return jsonify(errorCode='CONFLICT', message='计划已有变化，请刷新后重新排期'), 409
		try:
			updated = schedule(plan, data.get('days'), data.get('targetCourse'))
		except ValueError as error:
			return jsonify(errorCode='BAD_REQUEST', message=str(error)), 400
		updated['version'] = plan['version'] + 1
		history = create_plan_history(plan, updated, updated['reason'], [])
		history.update(planId=plan['planId'], adjustmentReason=updated['reason'], triggerEvidence=[])
		_repository.save('plans', plan['planId'], updated)
		_repository.save('plan_histories', f"{plan['planId']}:v{updated['version']}", history)
		from app.services.reminders import reconcile
		reconcile(_repository, owner)
	return jsonify(updated)


@plans_api.post("/api/v1/plans/current/assignments")
def sync_assignments():
	from app.services.assignment_plan import validate_assignments, reconcile
	from app.tools.profile_merge import PROFILE_LOCK
	from app.tools.plan_tools import create_plan_history
	data, guard = json_object()
	if guard is not None:
		return guard
	owner = resolve_user_id(data.get("userId"))
	rows, selected = data.get("assignments"), data.get("selectedId")
	if type(data.get('scheduleToday', False)) is not bool or (data.get('scheduleToday') and not selected):
		return jsonify(errorCode='BAD_REQUEST', message='加入本日计划需要选择具体任务'), 400
	from zoneinfo import ZoneInfo
	selected_date = datetime.now(ZoneInfo('Asia/Shanghai')).date().isoformat() if data.get('scheduleToday') else None
	with PROFILE_LOCK, _repository.transaction():
		if _repository.get('learning_sync_state', owner):
			from app.services.learning_data import snapshot
			rows = [dict(r, completed=r.get('completed', False)) for r in snapshot(_repository, owner)['homeworkDDLs']]
		try:
			validate_assignments(rows)
			if selected is not None and (not isinstance(selected, str) or not any(r["id"] == selected and not r["completed"] for r in rows)):
				raise ValueError("请选择一项待处理作业")
		except ValueError as error:
			return jsonify({"errorCode": "BAD_REQUEST", "message": str(error)}), 400
		previous = next((p for p in _repository.list("plans") if plan_belongs_to(p, owner)), None)
		if previous is None and not rows:
			return jsonify({"errorCode": "NOT_FOUND", "message": "current plan not found"}), 404
		profile = _repository.get("profiles", owner) or {}
		base = previous or {"planId": f"plan-ddl-{owner}", "userId": owner, "version": 0,
			"generatedFromProfileVersion": profile.get("profileVersion", 1), "tasks": [], "unscheduledTasks": []}
		try:
			plan = reconcile(base, rows, selected, selected_date=selected_date)
		except ValueError as error:
			return jsonify({"errorCode": "BAD_REQUEST", "message": str(error)}), 400
		if plan != previous:
			_repository.save("plans", plan["planId"], plan)
			if previous:
				history = create_plan_history(previous, plan, plan.get("reason", "作业同步"), [])
				history.update(planId=plan["planId"], adjustmentReason=plan.get("reason", "作业同步"), triggerEvidence=[])
				_repository.save("plan_histories", f"{plan['planId']}:v{plan['version']}", history)
		from app.services.reminders import reconcile as reconcile_reminders
		reconcile_reminders(_repository, owner)
	return jsonify(plan)


@plans_api.post("/api/v1/plans/current/tasks/schedule")
def schedule_task():
	from app.tools.time_budget import schedule_deferred_task
	from app.tools.plan_tools import create_plan_history
	from app.tools.profile_merge import PROFILE_LOCK
	data, guard = json_object()
	if guard is not None:
		return guard
	owner = resolve_user_id(data.get("userId"))
	key, guard = bounded_str(data.get("idempotencyKey"), "idempotencyKey", MAX_ID_CHARS)
	if guard is not None:
		return guard
	task_id, guard = bounded_str(data.get("taskId"), "taskId", MAX_ID_CHARS)
	if guard is not None:
		return guard
	version = data.get("expectedPlanVersion")
	if type(version) is not int or version < 1:
		return jsonify({"errorCode": "BAD_REQUEST", "message": "expectedPlanVersion must be a positive integer"}), 400
	operation_id = hashlib.sha256(f"schedule\0{owner}\0{key}".encode()).hexdigest()
	facts = {"taskId": task_id, "expectedPlanVersion": version}
	with PROFILE_LOCK, _repository.transaction():
		previous = _repository.get("plan_adjustments", operation_id)
		if previous:
			if previous["request"] != facts:
				return jsonify({"errorCode": "CONFLICT", "message": "该请求已用于其他操作，请刷新计划"}), 409
			return jsonify(previous["response"])
		plan = next((p for p in _repository.list("plans") if plan_belongs_to(p, owner)), None)
		if plan is None:
			return jsonify({"errorCode": "NOT_FOUND", "message": "当前学习计划不存在"}), 404
		if plan["version"] != version:
			return jsonify({"errorCode": "CONFLICT", "message": "计划已有更新，请刷新后重新加入任务"}), 409
		try:
			updated = schedule_deferred_task(plan, task_id)
		except LookupError as error:
			return jsonify({"errorCode": "NOT_FOUND", "message": str(error)}), 404
		except ValueError as error:
			return jsonify({"errorCode": "BAD_REQUEST", "message": str(error)}), 400
		updated.update(version=version + 1, userId=owner)
		task = updated["tasks"][-1]
		minutes = updated["budgetSummary"]["availableMinutes"]
		reason = f"已将「{task['knowledgePointName']}」加入本次计划，可用时间为{minutes}分钟；其他待安排任务保留"
		updated["reason"] = reason
		history = create_plan_history(plan, updated, reason, [])
		for change in history["changedTasks"]:
			if change.get("taskId") == task_id:
				change["change"] = "scheduled"
		history.update(planId=plan["planId"], adjustmentReason=reason, triggerEvidence=[])
		event_id, trace_id = f"schedule-{operation_id}", f"trace-schedule-{operation_id}"
		now = datetime.now(timezone.utc).isoformat()
		response = {"plan": updated, "planDiff": history, "changed": True, "traceId": trace_id, "eventId": event_id}
		_repository.apply_batch([], [
			("plans", plan["planId"], updated),
			("plan_histories", f"{plan['planId']}:v{updated['version']}", history),
			("plan_adjustments", operation_id, {"userId": owner, "request": facts, "response": response}),
			("learning_events", event_id, {"eventId": event_id, "userId": owner, "type": "PlanTaskScheduled",
				"objectId": task_id, "occurredAt": now, "availableMinutes": minutes, "status": "recorded"}),
			("traces", trace_id, {"traceId": trace_id, "userId": owner, "events": [{
				"agent": "planner", "toolCalls": ["schedule_deferred_task"], "inputSummary": f"加入任务{task_id}",
				"outputSummary": reason, "evidenceIds": [], "timestamp": now, "status": "completed",
				"stateVersion": updated["version"], "inputStateVersion": version, "outputStateVersion": updated["version"]}]}),
		])
		return jsonify(response)


@plans_api.post("/api/v1/plans/current/availability")
def update_available_minutes():
	from app.agents.planner import PlannerAgent
	from app.tools.plan_tools import create_plan_history
	from app.tools.profile_merge import PROFILE_LOCK
	data, guard = json_object()
	if guard is not None:
		return guard
	owner = resolve_user_id(data.get("userId"))
	key, guard = bounded_str(data.get("idempotencyKey"), "idempotencyKey", MAX_ID_CHARS)
	if guard is not None:
		return guard
	minutes, version = data.get("availableMinutes"), data.get("expectedPlanVersion")
	if isinstance(minutes, bool) or not isinstance(minutes, int) or not 0 <= minutes <= 1440:
		return jsonify({"errorCode": "BAD_REQUEST", "message": "availableMinutes must be an integer from 0 to 1440"}), 400
	if isinstance(version, bool) or not isinstance(version, int) or version < 1:
		return jsonify({"errorCode": "BAD_REQUEST", "message": "expectedPlanVersion must be a positive integer"}), 400
	operation_id = hashlib.sha256(f"{owner}\0{key}".encode()).hexdigest()
	course = data.get("targetCourse", "")
	if not isinstance(course, str) or len(course) > 80:
		return jsonify({"errorCode": "BAD_REQUEST", "message": "请选择主攻课程"}), 400
	course = course.strip()
	facts = {"availableMinutes": minutes, "expectedPlanVersion": version, "targetCourse": course}
	with PROFILE_LOCK, _repository.transaction():
		previous = _repository.get("plan_adjustments", operation_id)
		if previous:
			if previous["request"] != facts:
				return jsonify({"errorCode": "CONFLICT", "message": "idempotency key already used for different constraints"}), 409
			return jsonify(previous["response"])
		plan = next((p for p in _repository.list("plans") if plan_belongs_to(p, owner)), None)
		if plan is None:
			return jsonify({"errorCode": "NOT_FOUND", "message": "current plan not found"}), 404
		if plan["version"] != version:
			return jsonify({"errorCode": "CONFLICT", "message": "plan changed; refresh before applying new constraints"}), 409
		if course:
			profile = _repository.get("profiles", owner) or {}
			pool = [r for r in profile.get("mastery", []) if r.get("sourceCourse") == course]
			assignments = [t for t in plan.get("tasks", []) + plan.get("unscheduledTasks", []) if t.get("source") in ("ddl", "manual", "partner", "exam_review", "today") and t.get("status") != "completed"]
			if not pool and not any(t.get("sourceCourse") == course for t in assignments):
				return jsonify({"errorCode": "BAD_REQUEST", "message": "该课程暂无候选知识点，请先导入课程或资料"}), 400
			completed = [t for t in plan.get("tasks", []) + plan.get("unscheduledTasks", []) if t.get("status") == "completed"]
			done = {t["knowledgePointId"] for t in completed}
			pool = sorted([r for r in pool if r["knowledgePointId"] not in done], key=lambda r: (r.get("masteryScore", 0), r["knowledgePointId"]))
			count = min(3, max(1, minutes // 15)) if minutes else 0
			selected = pool[:count]
			old_tasks = {t["knowledgePointId"]: t for t in plan.get("tasks", []) + plan.get("unscheduledTasks", [])}
			tasks = [dict(old_tasks.get(r["knowledgePointId"], {}), taskId=old_tasks.get(r["knowledgePointId"], {}).get("taskId", f"task-{r['knowledgePointId']}"),
				knowledgePointId=r["knowledgePointId"], knowledgePointName=r["knowledgePointName"], sourceCourse=course,
				durationMinutes=min(30, minutes // max(1, len(selected))), status="pending") for r in selected]
			assignments.sort(key=lambda t: (t.get("sourceCourse") != course, t.get("dueDate", ""), t["taskId"]))
			plan_for_budget = dict(plan, tasks=completed + assignments + tasks, unscheduledTasks=[], targetCourse=course,
				candidatePool=[r for r in profile.get("mastery", []) if r["knowledgePointId"] not in done | {x["knowledgePointId"] for x in selected}])
		elif "candidatePool" in plan and not any(t.get("source") == "ddl" for t in plan.get("tasks", []) + plan.get("unscheduledTasks", [])):
			return jsonify({"errorCode": "BAD_REQUEST", "message": "请先选择本次主攻课程，再安排学习时长"}), 400
		else:
			plan_for_budget = plan
		result = PlannerAgent().run({"plan": plan_for_budget, "availableMinutes": minutes})
		if plan_for_budget != plan:
			result.output["changed"] = True
			result.output["plan"]["version"] = version + 1
		updated = dict(result.output["plan"], userId=owner)
		reason = f"本次专项计划可用{minutes}分钟，已安排{updated['budgetSummary']['scheduledMinutes']}分钟；暂未安排的任务保留待后续选择"
		updated["reason"] = reason
		history = create_plan_history(plan, updated, reason, []) if result.output["changed"] else {
			"oldVersion": version, "newVersion": version, "changedTasks": [], "reason": reason, "evidenceIds": []}
		history.update({"planId": plan["planId"], "adjustmentReason": reason, "triggerEvidence": []})
		event_id, trace_id = f"availability-{operation_id}", f"trace-availability-{operation_id}"
		now = datetime.now(timezone.utc).isoformat()
		response = {"plan": updated, "planDiff": history, "changed": result.output["changed"],
			"traceId": trace_id, "eventId": event_id}
		saves = [("plan_adjustments", operation_id, {"userId": owner, "request": facts, "response": response}),
			("learning_events", event_id, {"eventId": event_id, "userId": owner,
				"type": "AvailabilityChanged" if result.output["changed"] else "AvailabilityConfirmed",
				"objectId": plan["planId"], "occurredAt": now, "availableMinutes": minutes, "status": "recorded"}),
			("traces", trace_id, {"traceId": trace_id, "userId": owner, "events": [{
				"agent": "planner", "toolCalls": list(result.tool_calls), "inputSummary": f"可用时间调整为{minutes}分钟",
				"outputSummary": reason, "evidenceIds": [], "timestamp": now, "status": "completed",
				"stateVersion": updated["version"], "inputStateVersion": version, "outputStateVersion": updated["version"]}]})]
		if result.output["changed"]:
			saves.extend([("plans", plan["planId"], updated),
				("plan_histories", f"{plan['planId']}:v{updated['version']}", history)])
		_repository.apply_batch([], saves)
		from app.services.reminders import reconcile as reconcile_reminders
		reconcile_reminders(_repository, owner)
		return jsonify(response)


def _evidence_belongs_to(evidence: dict, user_id: str) -> bool:
	"""判断一条 evidence 是否属于该用户。

	历史数据里没有 `userId` 字段（写入侧是后补的，见 `assessment_tools.py`），
	所以回退用 `sourceId` 前缀判断 —— 它形如 `<userId>:<setId>:<...>`，
	与 `app/api/demo.py` 里清理 evidences 的口径完全一致。
	"""
	owner = evidence.get("userId")
	if isinstance(owner, str) and owner:
		return owner == user_id
	source_id = evidence.get("sourceId")
	return isinstance(source_id, str) and source_id.startswith(f"{user_id}:")


def plan_belongs_to(plan: dict, user_id: str) -> bool:
	"""计划记录是否属于该用户。

	主口径：记录里的 `userId`；**键缺失时按 demo-user**（与 `demo.py` 的清理
	逻辑、以及历史数据口径一致）。

	⚠️ 兜底 `planId`：`LearningPlan.to_dict()` 曾长期不返回 `userId`，而计划重排是
	**整条覆盖**写回，于是做过练习的账号，记录里的 `userId` 键会被抹掉 ——
	读侧默认值一生效，真实账号就再也读不到自己的计划（`GET /plans/current` → 404，
	已实测复现）。计划 id 的构造口径是 `plan-<userId>`（见 `auth/service.py`
	与 `workflows.py`），可直接反推归属，让既有脏记录自愈，不必等用户再练一次。

	注意这个兜底是**纯增量**的：只在"能反推出归属且匹配"时返回 True，
	其余情况一律回落到原口径，绝不影响演示基线（`plan-demo-001` 的 id 反推结果是
	`demo-001`，仍靠"键缺失 == demo-user"这条老规则命中）。
	"""
	owner = plan.get("userId")
	if isinstance(owner, str) and owner:
		return owner == user_id
	plan_id = plan.get("planId")
	if isinstance(plan_id, str) and plan_id.startswith("plan-"):
		if plan_id[len("plan-"):] == user_id:
			return True
	return user_id == "demo-user"


@plans_api.get("/api/v1/plans/current")
def get_current_plan():
	user_id = resolve_user_id(request.args.get("userId"))
	plans = [plan for plan in (_repository.list("plans") if _repository else [])
		if plan_belongs_to(plan, user_id)]
	if not plans:
		return jsonify({"errorCode": "NOT_FOUND", "message": "current plan not found", "details": {"userId": user_id}}), 404
	plan = dict(plans[0])
	from app.api.study_tasks import merge_owned_tasks
	from app.tools.profile_merge import PROFILE_LOCK
	with PROFILE_LOCK, _repository.transaction():
		plan = _repository.get('plans', plan['planId'])
		updated = merge_owned_tasks(_repository, plan, user_id)
		if updated != plan:
			updated['version'] = plan['version'] + 1
			updated.pop('budgetSummary', None)
			_repository.save('plans', updated['planId'], updated)
		plan = updated
	if plan.get("tasks") and plan["tasks"][0].get("source") == "ddl":
		plan["factors"] = []
		return jsonify(plan)
	if user_id != "demo-user" and "candidatePool" not in plan and (
		str(plan.get("planId", "")).startswith("plan-import-") or
		str(plan.get("reason", "")).startswith("根据新增课程或资料知识点")):
		from app.tools.profile_merge import PROFILE_LOCK
		with PROFILE_LOCK, _repository.transaction():
			plan = _repository.get("plans", plan["planId"])
			if "candidatePool" not in plan:
				before = dict(plan)
				profile = _repository.get("profiles", user_id) or {}
				completed = [t for t in plan.get("tasks", []) + plan.get("unscheduledTasks", []) if t.get("status") == "completed"]
				done = {t["knowledgePointId"] for t in completed}
				ddl_tasks = [t for t in plan.get("tasks", []) if t.get("source") in ("ddl", "manual", "partner", "exam_review", "today") and t.get("status") != "completed"]
				ddl_deferred = [t for t in plan.get("unscheduledTasks", []) if t.get("source") in ("ddl", "manual", "partner", "exam_review", "today") and t.get("status") != "completed"]
				plan.update(tasks=completed + ddl_tasks, unscheduledTasks=ddl_deferred, candidatePool=[r for r in profile.get("mastery", []) if r.get("knowledgePointId") not in done],
					version=plan.get("version", 1) + 1, reason="历史自动积压任务已转为候选知识点；请选择本次课程与时长，完成记录已保留")
				plan.pop("budgetSummary", None)
				from app.tools.plan_tools import create_plan_history
				history = create_plan_history(before, plan, plan["reason"], [])
				history.update(planId=plan["planId"], adjustmentReason=plan["reason"], triggerEvidence=[])
				_repository.apply_batch([], [("plans", plan["planId"], plan),
					("plan_histories", f"{plan['planId']}:v{plan['version']}", history)])
	if plan.get("tasks"):
		profile = _repository.get("profiles", user_id) if _repository else None
		mastery_by_point: dict[str, float] = {}
		if isinstance(profile, dict):
			for item in (profile.get("mastery") or []):
				if isinstance(item, dict):
					point = item.get("knowledgePointId")
					if isinstance(point, str):
						mastery_by_point[point] = float(item.get("masteryScore", 0) or 0)

		error_intensity_by_point: dict[str, float] = {}
		evidence_count_by_point: dict[str, int] = {}
		for evidence in (_repository.list("evidences") if _repository else []):
			if not isinstance(evidence, dict):
				continue
			if not _evidence_belongs_to(evidence, user_id):
				continue
			point = evidence.get("knowledgePointId")
			if not isinstance(point, str):
				continue
			evidence_count_by_point[point] = evidence_count_by_point.get(point, 0) + 1

		for point, count in evidence_count_by_point.items():
			error_intensity_by_point[point] = min(100.0, 40.0 + 20.0 * count)

		days_left = 5
		for task in plan["tasks"]:
			raw_days = task.get("daysLeft")
			if isinstance(raw_days, int) and raw_days >= 0:
				days_left = raw_days
				break

		knowledge_points = [
			{
				"knowledgePointId": task.get("knowledgePointId", "binary-tree-postorder"),
				"masteryScore": mastery_by_point.get(
					task.get("knowledgePointId", ""), 0.0),
				"errorIntensity": error_intensity_by_point.get(
					task.get("knowledgePointId", ""), 0.0),
				"importance": 90 if task.get("source") == "agent" else 60,
				"prerequisiteImpact": 20 if task.get("canCollaborate") else 10,
			}
			for task in plan["tasks"]
		]
		top_priority = __import__("app.decision.priority", fromlist=["calculate_learning_priority"]).calculate_learning_priority(
			knowledge_points, {"daysLeft": days_left}
		)
		if top_priority:
			lead_point = plan["tasks"][0].get("knowledgePointId", "")
			lead = next(
				(row for row in top_priority if row.get("knowledgePointId") == lead_point),
				top_priority[0],
			)
			plan["factors"] = _factor_rows(lead.get("factors", {}))
			plan["reason"] = lead.get("reason", plan.get("reason", ""))
	return jsonify(plan)


def _factor_rows(factors: object) -> list[dict]:
	"""把优先级因子从 `{name: {value, weight, contribution}}` 摊平成数组。

	为什么必须转：前端 `LearningPlan.factors` 声明为 `DecisionFactor[]`，
	`StudySuggestion.ets` 用 `factors().length > 0` 判断是否渲染五因子卡，
	`ApiResponseValidator` 也按数组校验（`hasArray(data,'factors')`）。

	而 `calculate_learning_priority` 返回的是**字典**。直接透传会导致：
	  * 联机模式：`.length` 为 undefined → 「为什么是它」因子卡**永不显示**
	  * 离线 Fixture：`FixtureApiTransport.factors()` 返回数组 → 正常显示
	于是表现为"离线好看、联机消失"的假象，极难定位。

	数组元素结构与 `/api/v1/agent/proactive` 的 factors 保持一致
	（name / value / weight / contribution），前端同一个 `DecisionFactor` 即可消费。
	"""
	if not isinstance(factors, dict):
		return []
	rows: list[dict] = []
	for name, values in factors.items():
		if not isinstance(values, dict):
			continue
		rows.append({
			"name": str(name),
			"value": values.get("value", 0),
			"weight": values.get("weight", 0),
			"contribution": values.get("contribution", 0),
		})
	rows.sort(key=lambda row: row.get("contribution", 0), reverse=True)
	return rows


@plans_api.get("/api/v1/plans/<plan_id>/diff")
def get_plan_diff(plan_id: str):
	plan = _repository.get("plans", plan_id) if _repository else None
	if plan is None or not plan_belongs_to(plan, resolve_user_id(request.args.get("userId"))):
		return jsonify({"errorCode": "NOT_FOUND", "message": "plan not found", "details": {"planId": plan_id}}), 404
	history = _latest_plan_history(plan_id)
	if history is None:
		return jsonify({"planId": plan_id, "oldVersion": plan["version"], "newVersion": plan["version"],
			"changedTasks": [], "adjustmentReason": "no changes", "triggerEvidence": []})
	return jsonify({"planId": plan_id, "oldVersion": history.get("oldVersion"),
		"newVersion": history.get("newVersion"), "changedTasks": history.get("changedTasks", []),
		"adjustmentReason": history.get("adjustmentReason", history.get("reason", "")),
		"triggerEvidence": history.get("triggerEvidence", history.get("evidenceIds", []))})


def _latest_plan_history(plan_id: str) -> dict | None:
	"""Return the newest retained replan event for a plan.

	Plan histories are event records, so a plan can have one entry per
	replanned version. The old single-key representation is still accepted
	for data written before this change.
	"""
	if _repository is None:
		return None
	histories = [
		item for item in _repository.list("plan_histories")
		if item.get("planId") == plan_id
	]
	if not histories:
		legacy = _repository.get("plan_histories", plan_id)
		return legacy

	def version(item: dict) -> int:
		try:
			return int(item.get("newVersion", 0))
		except (TypeError, ValueError):
			return 0

	return max(histories, key=lambda item: (
		version(item), str(item.get("timestamp", ""))))
