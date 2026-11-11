import threading
import uuid
from contextlib import contextmanager
from pathlib import Path
from datetime import datetime, timezone

from flask import Blueprint, jsonify, request

from app.agents.assessment import AssessmentAgent
from app.agents.diagnosis import DiagnosisAgent
from app.agents.exercise import ExerciseAgent
from app.agents.planner import PlannerAgent
from app.agents.secretary import SecretaryAgent
from app.api.exercises import _ANSWER_KEYS, _EXERCISE_BANK
from app.api.identity import resolve_user_id
from app.api.validation import (MAX_ANSWERS, MAX_ANSWER_CHARS, MAX_ID_CHARS, MAX_TEXT_CHARS,
	bounded_str, json_object, validate_answers)
from app.domain.assessment import AssessmentResult
from app.domain.profile import KnowledgeMastery, LearnerProfile
from app.repositories.json_repository import JsonRepository
from app.repositories.file_lock import exclusive_file_lock
from app.model_adapters.qwen_adapter import QwenAdapter
from app.runtime.loop import run_workflow
from app.runtime.session import WorkflowSession
from app.tools.assessment_tools import persist_mastery, mastery_scores
from app.services.assessment_replan import replan_request, execute_assessment_replan
from app.tools.trace_tools import append_trace_event
from app.services import learning_context

workflows_api = Blueprint("workflows", __name__)
_repository: JsonRepository | None = None

from app.tools.profile_merge import PROFILE_LOCK
_WORKFLOW_RUN_LOCK = PROFILE_LOCK
_WORKFLOW_GUARD_STATE = threading.local()


@contextmanager
def _workflow_guard():
    with _WORKFLOW_RUN_LOCK:
        if getattr(_WORKFLOW_GUARD_STATE, 'active', False) or _repository is None:
            yield
            return
        path = Path(_repository.path)
        with exclusive_file_lock(path.with_name(path.name + '.workflow.process.lock')):
            _WORKFLOW_GUARD_STATE.active = True
            try:
                yield
            finally:
                _WORKFLOW_GUARD_STATE.active = False


class SubmissionNotFound(KeyError):
	"""`submissionId` 不存在或不属于该工作流。

	单独定义类型的原因：原实现把它与"会话不存在"共用 `except KeyError` 分支，
	于是对**存在的** session 传错/过期 submissionId 时会返回
	404 `{"message": "workflow not found"}` —— 语义与事实不符（workflow 确实存在），
	客户端会误判为会话失效并重建会话，掩盖真实错误。
	"""


class WorkflowConflict(ValueError):
	pass


def configure_workflows_repository(repository: JsonRepository) -> None:
	global _repository
	_repository = repository


def _error(code: str, message: str, details: dict | None = None, status: int = 400):
	return jsonify({"errorCode": code, "message": message, "details": details}), status


def _next_step(user_id: str) -> tuple[str, str]:
	if _repository is None or _repository.get("profiles", user_id) is None:
		return "diagnosis", "开始学情诊断"
	own_plans = [item for item in (_repository.list("plans") if _repository else [])
		if isinstance(item, dict) and item.get("userId", "demo-user") == user_id]
	if not own_plans:
		return "planner", "生成学习计划"
	return "exercise", "获取练习题并开始学习"


@workflows_api.post("/api/v1/workflows")
def create_workflow():
    with _workflow_guard():
        return _create_workflow()


def _create_workflow():
	data, guard = json_object()
	if guard is not None:
		return guard
	goal, guard = bounded_str(data.get("goal"), "goal", MAX_TEXT_CHARS)
	if guard is not None:
		return guard
	max_steps = data.get("maxSteps", 6)
	if isinstance(max_steps, bool) or not isinstance(max_steps, int) or not 1 <= max_steps <= 20:
		return _error("BAD_REQUEST", "maxSteps must be an integer between 1 and 20", {"field": "maxSteps"})

	raw_session = data.get("sessionId")
	session_id = f"session-{uuid.uuid4().hex[:12]}"
	if raw_session is not None:
		session_id, guard = bounded_str(raw_session, "sessionId", MAX_ID_CHARS)
		if guard is not None:
			return guard
	user_id = resolve_user_id(data.get("userId"))
	if _repository and data.get("sessionId"):
		existing = _repository.get("workflows", session_id)
		if existing is not None:
			if not _owns_record(existing, user_id):
				return _error("NOT_FOUND", "workflow not found", None, 404)
			return jsonify({key: existing.get(key) for key in
				("sessionId", "traceId", "status", "currentStep", "nextAction")})
	current_step, next_action = _next_step(user_id)
	if data.get("autoRun") is True and data.get("answers") is not None:
		_, guard = validate_answers(data.get("answers"))
		if guard is not None:
			return guard
	trace_id = f"trace-{session_id}"
	workflow = {"sessionId": session_id, "traceId": trace_id, "status": "running",
		"currentStep": current_step, "currentAgent": current_step, "nextAction": next_action,
		"stateVersion": 1, "finalAction": None, "goal": goal, "userId": user_id,
		"maxSteps": max_steps}
	if _repository:
		_repository.apply_batch([], [("workflows", session_id, workflow),
			("traces", trace_id, {"traceId": trace_id, "events": [], "userId": user_id})])
	if data.get("autoRun") is True:
		with _workflow_guard():
			if data.get("answers") is not None:
				checked, guard = validate_answers(data.get("answers"))
				if guard is not None:
					return guard
				return jsonify(_run_saved_workflow(session_id, checked))
			return run_workflow_api(session_id)
	return jsonify({key: workflow[key] for key in
		("sessionId", "traceId", "status", "currentStep", "nextAction")})


def _owns_record(record: dict | None, user_id: str) -> bool:
	"""记录是否属于该用户。

	⚠️ 缺失 `userId` 的老数据按 demo-user 归属 —— 与 `plans.py::get_current_plan`、
	`demo.py` 的清理逻辑同一口径，避免把既有演示数据误判成"别人的"而 404。

	返回 404 而不是 403：不向调用方泄漏"这个 sessionId 存在但不属于你"。
	"""
	if not isinstance(record, dict):
		return False
	return record.get("userId", "demo-user") == user_id


@workflows_api.get("/api/v1/workflows/<session_id>")
def get_workflow(session_id: str):
	workflow = _repository.get("workflows", session_id) if _repository else None
	if not _owns_record(workflow, resolve_user_id(request.args.get("userId"))):
		return _error("NOT_FOUND", "workflow not found", {"sessionId": session_id}, 404)
	response = {key: workflow.get(key) for key in ("status", "currentAgent", "stateVersion", "finalAction")}
	context = learning_context.snapshot(_repository, workflow)
	if context:
		response["learningContext"] = context
	return jsonify(response)


@workflows_api.get("/api/v1/workflows/chat/<chat_session_id>")
def get_chat_workflow(chat_session_id):
	owner = resolve_user_id(None)
	workflow = learning_context.current_chat_workflow(_repository, owner, chat_session_id) if _repository else None
	if not _owns_record(workflow, owner):
		return _error("NOT_FOUND", "learning goal not found", None, 404)
	context = learning_context.snapshot(_repository, workflow)
	if not context:
		return _error("NOT_FOUND", "learning goal not found", None, 404)
	return jsonify(context)


def _workflow_state(workflow: dict) -> dict:
	profile = _repository.get("profiles", workflow["userId"]) if _repository else None
	plan_id = workflow.get("state", {}).get("planId")
	plan = (_repository.get("plans", plan_id) if plan_id and _repository else None)
	if plan is not None and plan.get("userId", "demo-user") != workflow["userId"]:
		plan = None
	if plan is None and _repository:
		plan = next((item for item in _repository.list("plans")
			if item.get("userId", "demo-user") == workflow["userId"]), None)
	state = dict(workflow.get("state", {}))
	state["sessionId"] = workflow["sessionId"]
	state["userId"] = workflow["userId"]
	state["goal"] = workflow["goal"]
	if profile is not None:
		state["profile"] = profile
		state["oldMasteryByPoint"] = mastery_scores(profile)
	if plan is not None:
		state["plan"] = plan
	if "knowledgePoints" not in state:
		rows = profile.get("mastery", []) if isinstance(profile, dict) else []
		state["knowledgePoints"] = [{
			"knowledgePointId": str(item.get("knowledgePointId") or ""),
			"knowledgePointName": str(item.get("knowledgePointName") or
				item.get("knowledgePointId") or ""),
			"masteryScore": item.get("masteryScore", 0),
			"errorIntensity": max(0, 100 - int(item.get("masteryScore", 0))),
			"importance": 50,
		} for item in rows if isinstance(item, dict) and item.get("knowledgePointId")]
	state.setdefault("exercises", _EXERCISE_BANK)
	state.setdefault("answerKeys", _ANSWER_KEYS)
	state.setdefault("knowledgePointsByExercise", {
		item["exerciseId"]: item["knowledgePointId"] for item in _EXERCISE_BANK})
	if state.get("coordination"):
		learning_context.prepare(_repository, workflow, state)
	else:
		state.pop("coordinationBlock", None)
		if workflow["userId"] != "demo-user" and profile is not None and not profile.get("mastery") and not state.get("assessment"):
			state["coordinationBlock"] = "knowledge_points"
	return state


def _agent_action(step: str, state: dict):
	agents = {"secretary": SecretaryAgent(), "diagnosis": DiagnosisAgent(),
		"planner": PlannerAgent(), "exercise": ExerciseAgent(), "assessment": AssessmentAgent()}
	if step == "clarify" and state.get("coordinationBlock"):
		agents["secretary"].run(state)
		return learning_context.blocked_result(state)
	if step == "diagnosis":
		result = agents[step].run(state)
		if _repository and state.get("profile") is None:
			profile = LearnerProfile(
				state["userId"], state["goal"], None, [], 1,
				([KnowledgeMastery("binary-tree-postorder", 42, 0.7,
					datetime.now(timezone.utc), "二叉树后序遍历")] if state["userId"] == "demo-user" else []),
			).to_dict()
			_repository.save("profiles", state["userId"], profile)
			state["profile"] = profile
			if state["userId"] != "demo-user":
				return {**result.output, "profile": profile, "status": "waiting", "waitingFor": "knowledge_points",
					"toolCalls": list(result.tool_calls), "nextAction": "请先补充真实课程与知识点，尚未进行测评。"}
		return {**result.output, "profile": state.get("profile", {}), "toolCalls": list(result.tool_calls)}
	if step == "planner":
		if state.get("assessment") and state.get("needReplan"):
			handoff = state["replanRequest"]
			with _repository.transaction():
				result = execute_assessment_replan(_repository, state["userId"],
					state.get("plan", {}).get("planId", ""), handoff,
					state.get("evidenceIds", []), state.get("submissionId"))
			return {**result, "needReplan": False, "replanHandled": True,
				"nextAction": result["reason"]}
		result = agents[step].run(state)
		plan = dict(result.output["plan"], planId=f"plan-{state.get('sessionId', 'workflow')}" )
		if _repository:
			plan["generatedFromProfileVersion"] = state.get("profile", {}).get("profileVersion", 1)
			plan["userId"] = state["userId"]
			_repository.save("plans", plan["planId"], plan)
		return {**result.output, "plan": plan, "planId": plan["planId"],
			"toolCalls": list(result.tool_calls)}
	if step == "exercise":
		if state.get("coordination"):
			from app.api.exercises import _resolve_knowledge_point_id
			point = _resolve_knowledge_point_id(state.get("knowledgePointId"))
			state = dict(state, knowledgePointId=point or state.get("knowledgePointId"))
		result = agents[step].run(state)
		if state.get("coordination") and not result.output["exercises"]:
			return {"status": "waiting", "waitingFor": "exercise_generation", "toolCalls": list(result.tool_calls),
				"nextAction": "该知识点需要现场出题，请进入本目标练习；生成失败时会明确提示。"}
		return {"status": "waiting", "exercises": result.output["exercises"],
			"toolCalls": list(result.tool_calls), "nextAction": "提交答案后继续评估"}
	if step == "assessment":
		result = agents[step].run(state)
		persistence = _persist_workflow_assessment(state, result.output)
		return {**result.output, "assessment": result.output, "pendingSubmission": False,
			**persistence, "toolCalls": list(result.tool_calls)}
	return {"status": "error", "message": f"unsupported workflow step: {step}"}


def _persist_workflow_assessment(state: dict, assessment_data: dict) -> dict:
	if _repository is None:
		return {"assessmentPersisted": False}
	with PROFILE_LOCK, _repository.transaction():
		return _persist_workflow_assessment_locked(state, assessment_data)


def _persist_workflow_assessment_locked(state: dict, assessment_data: dict) -> dict:
	"""Persist workflow grading through the same deterministic rules as submit."""
	if _repository is None or state.get("assessmentPersisted"):
		return {"assessmentPersisted": bool(state.get("assessmentPersisted"))}
	assessment = AssessmentResult.from_dict(assessment_data)
	evidence_id = f"evidence-{state['sessionId']}"
	result_id = assessment.exercise_result_id or f"workflow:{state['sessionId']}"
	previous = _repository.get("submissions", result_id)
	if previous and previous.get("response", {}).get("userId") == state["userId"]:
		saved = previous["response"]
		assessment = AssessmentResult.from_dict(saved["assessment"])
		handoff = replan_request(assessment)
		return {**saved["assessment"], "assessment": saved["assessment"],
			"assessmentPersisted": True, "submissionId": result_id,
			"evidenceIds": saved.get("evidenceIds", []),
			"needReplan": saved.get("needReplan", False) and not previous.get("replanHandled", False),
			"replanRequest": handoff, "replanState": handoff["replanState"],
			**{key: saved[key] for key in ("plan", "planDiff") if key in saved}}
	handoff = replan_request(assessment)
	decision = handoff["decision"]
	submission_response = {
		"userId": state.get("userId", "demo-user"),
		"submissionId": result_id,
		"assessment": assessment.to_dict(),
		"masteryUpdate": {
			"knowledgePointId": assessment.dominant_knowledge_point(),
			"oldScore": assessment.old_mastery,
			"newScore": assessment.suggested_new_mastery,
		},
		"needReplan": bool(decision["needReplan"]),
		"replanDecision": decision,
		"traceId": state.get("traceId", f"trace-{state['sessionId']}"),
		"evidenceIds": [evidence_id],
	}
	profile = persist_mastery(_repository, state["userId"], assessment, evidence_id, result_id,
		additional_saves=[("submissions", result_id, {"response": submission_response})])
	updates = {"assessmentPersisted": profile is not None, "evidenceIds": [evidence_id],
		"submissionId": result_id, "needReplan": profile is not None and bool(decision["needReplan"]),
		"replanRequest": handoff, "replanState": handoff["replanState"], "replanDecision": decision}
	if profile is not None:
		updates["profile"] = profile
	return updates


def _run_saved_workflow(session_id: str, answers: list[dict] | None = None,
					submission_id: str | None = None) -> dict:
	workflow = _repository.get("workflows", session_id) if _repository else None
	if workflow is None:
		raise KeyError(session_id)
	coordinated = bool(workflow.get("state", {}).get("coordination"))
	if coordinated and answers is None and submission_id is None:
		submission_id = workflow.get("state", {}).get("boundSubmissionId")
	if coordinated and workflow.get("status") == "completed":
		if answers is not None or (submission_id and submission_id != workflow.get("state", {}).get("submissionId")):
			raise WorkflowConflict("目标已完成，请开启新对话建立下一轮目标")
		return _workflow_response(workflow)
	has_new_input = isinstance(answers, list) or submission_id is not None
	state = _workflow_state(workflow)
	if coordinated and workflow.get("status") == "error":
		workflow = dict(workflow, status="running")
	if workflow.get("state", {}).get("awaitingAnswers") and not has_new_input:
		if not coordinated or workflow["state"].get("inputRefs") == state.get("inputRefs"):
			return _workflow_response(workflow)
		state.update({"awaitingAnswers": False, "waitingFor": ""})
	if coordinated and not has_new_input and workflow.get("state", {}).get("waitingFor") and (
		workflow["state"].get("inputRefs") == state.get("inputRefs")):
		return _workflow_response(workflow)
	trace_id = workflow.get("traceId", f"trace-{session_id}")
	if submission_id:
		submission = _repository.get("submissions", submission_id) if _repository else None
		if submission is None or submission.get("response", {}).get("userId") != workflow.get("userId"):
			raise SubmissionNotFound(submission_id)
		result = submission["response"]
		if coordinated and result.get("goalId") != session_id:
			raise SubmissionNotFound(submission_id)
		state.update({"assessment": result["assessment"], "needReplan": False,
			"pendingSubmission": False, "assessmentPersisted": True,
			"submissionId": submission_id, "evidenceIds": result.get("evidenceIds", []),
			"awaitingAnswers": False, "waitingFor": ""})
		answers = None
	if isinstance(answers, list):
		if coordinated:
			raise WorkflowConflict("请通过本目标练习页交卷，再用submissionId继续，避免重复评估入口")
		state.update({"answers": answers, "pendingSubmission": True,
			"exerciseResultId": f"workflow:{session_id}", "awaitingAnswers": False})
	session = WorkflowSession.from_dict({**workflow, "state": state})
	model_adapter = None if coordinated else QwenAdapter.from_environment()
	def act(step, observed):
		try:
			output = _agent_action(step, observed)
		except Exception:
			if not coordinated:
				raise
			output = {"status": "error", "message": "本次工具执行失败，已保留目标；可点击继续重试。", "toolCalls": []}
		if coordinated:
			output["handoffs"] = learning_context.handoff(observed, output, step, session.state_version)
		return output
	def model_decider(observed):
		return model_adapter.safe_decide({key: value for key, value in observed.items()
			if key not in ("answerKeys", "answers", "exercises", "knowledgePointsByExercise")})
	result = run_workflow(session, lambda: session.state, act,
		model_decider=model_decider if model_adapter else None,
		trace_recorder=lambda **event: append_trace_event(_repository, trace_id, **event))
	updated = result.to_dict()
	if workflow.get("createdAt"):
		updated["createdAt"] = workflow["createdAt"]
	updated["traceId"] = trace_id
	updated["nextAction"] = updated.get("finalAction")
	if coordinated:
		updated["state"]["inputRefs"] = _workflow_state(updated)["inputRefs"]
	for transient in ("profile", "exercises", "answers", "answerKeys"):
		updated["state"].pop(transient, None)
	if _repository:
		from datetime import datetime, timezone
		updated["updatedAt"] = datetime.now(timezone.utc).isoformat()
		if updated.get("status") == "completed":
			updated["completedAt"] = updated["updatedAt"]
		_repository.save("workflows", session_id, updated)
	return _workflow_response(updated)


def _workflow_response(workflow):
	response = {key: workflow.get(key) for key in ("sessionId", "traceId", "status", "currentStep", "currentAgent", "stateVersion",
		"finalAction", "nextAction", "state")}
	context = learning_context.snapshot(_repository, workflow)
	if context:
		response["learningContext"] = context
	return response


@workflows_api.post("/api/v1/workflows/<session_id>/run")
def run_workflow_api(session_id: str):
	data, guard = json_object()
	if guard is not None:
		return guard

	existing_workflow = _repository.get("workflows", session_id) if _repository else None
	if existing_workflow is not None and not _owns_record(
			existing_workflow, resolve_user_id(data.get("userId"))):
		return _error("NOT_FOUND", "workflow not found", {"sessionId": session_id}, 404)

	if existing_workflow and existing_workflow.get("userEnded"):
		return _error("CONFLICT", "目标已结束，请建立新目标", None, 409)

	answers = None
	if data.get("answers") is not None:
		answers, guard = validate_answers(data.get("answers"))
		if guard is not None:
			return guard
	submission_id = None
	if data.get("submissionId") is not None:
		submission_id, guard = bounded_str(data["submissionId"], "submissionId", 3 * MAX_ID_CHARS)
		if guard is not None:
			return guard

	try:
		with _workflow_guard():
			current = _repository.get("workflows", session_id) if _repository else None
			if data.get("expectedStateVersion") is not None:
				expected = data["expectedStateVersion"]
				if isinstance(expected, bool) or not isinstance(expected, int) or expected < 1:
					return _error("BAD_REQUEST", "expectedStateVersion must be a positive integer")
				if current and current.get("stateVersion", 1) != expected:
					return _error("CONFLICT", "目标状态已变化，请刷新后继续", None, 409)
			return jsonify(_run_saved_workflow(session_id, answers, submission_id))
	except WorkflowConflict as error:
		return _error("CONFLICT", str(error), None, 409)
	except SubmissionNotFound:
		return _error("NOT_FOUND", "submission not found",
					  {"sessionId": session_id, "submissionId": data.get("submissionId")}, 404)
	except KeyError:
		return _error("NOT_FOUND", "workflow not found", {"sessionId": session_id}, 404)


@workflows_api.get("/api/v1/workflows/chat/<chat_session_id>/goals")
def list_chat_goals(chat_session_id):
    owner = resolve_user_id(None)
    return jsonify({"goals": learning_context.chat_goal_history(_repository, owner, chat_session_id)})


@workflows_api.post("/api/v1/workflows/chat/<chat_session_id>/goals")
def manage_chat_goals(chat_session_id):
    from app.tools.profile_merge import PROFILE_LOCK, merge_points_into_profile
    data, guard = json_object()
    if guard is not None:
        return guard
    owner = resolve_user_id(None)
    action = data.get("action")
    if action not in ("start", "select", "end"):
        return _error("BAD_REQUEST", "请选择建立、切换或结束目标", None, 400)
    with _workflow_guard(), PROFILE_LOCK:
        base = learning_context.chat_workflow_id(owner, chat_session_id)
        current = learning_context.current_chat_workflow(_repository, owner, chat_session_id)
        if action in ("end", "select"):
            with _repository.transaction():
                goal_id = data.get("goalId")
                goal = _repository.get("workflows", goal_id) if isinstance(goal_id, str) else None
                if not _owns_record(goal, owner) or goal.get("state", {}).get("coordination", {}).get("chatSessionId") != chat_session_id:
                    return _error("NOT_FOUND", "目标不存在", None, 404)
                if action == "end" and (current["sessionId"] if current else (_repository.get("chat_goal_links", base) or {}).get("activeGoalId", base)) != goal_id:
                    return _error("CONFLICT", "当前目标已变化，请刷新", None, 409)
                if action == "end":
                    from datetime import datetime, timezone
                    goal = dict(goal, userEnded=True, stateVersion=goal.get("stateVersion", 1) + 1,
                                updatedAt=datetime.now(timezone.utc).isoformat())
                    _repository.save("workflows", goal_id, goal)
                _repository.save("chat_goal_links", base, {"userId": owner, "chatSessionId": chat_session_id,
                    "activeGoalId": goal_id, "ended": action == "end"})
                return jsonify({"status": "ended" if action == "end" else "selected",
                    "learningContext": None if action == "end" else learning_context.snapshot(_repository, goal)})
        diagnosis_id = data.get("diagnosisId")
        diagnosis = _repository.get("chat_diagnoses", diagnosis_id) if isinstance(diagnosis_id, str) else None
        if not diagnosis or diagnosis.get("userId") != owner or diagnosis.get("chatSessionId") != chat_session_id:
            return _error("NOT_FOUND", "请先上传并识别本会话的题目", None, 404)
        point, guard = bounded_str(data.get("knowledgePoint", diagnosis["knowledgePoint"]), "knowledgePoint", 60)
        if guard is not None:
            return guard
        from app.agent.knowledge import valid_knowledge_term
        if not valid_knowledge_term(point):
            return _error("BAD_REQUEST", "请选择具体知识点，不能使用掌握、熟悉等考纲要求作为知识点", None, 400)
        if diagnosis.get("goalId"):
            saved = _repository.get("workflows", diagnosis["goalId"])
            if diagnosis.get("confirmedPoint") != point:
                return _error("CONFLICT", "该题目已建立目标，请重新识别后修改", None, 409)
            return jsonify({"status": "created", "learningContext": learning_context.snapshot(_repository, saved)})
        merge_points_into_profile(_repository, owner, [{"name": point, "source": "diagnosis"}])
        context = learning_context.ensure_chat_context(_repository, owner, chat_session_id,
            "针对" + point + "完成练习与测评", point, new_goal=True, diagnosis_id=diagnosis_id)
        _repository.save("chat_diagnoses", diagnosis_id, dict(diagnosis, goalId=context["goalId"], confirmedPoint=point))
        return jsonify({"status": "created", "learningContext": context})
