"""One chat session -> one durable learning workflow, with public handoffs.

The workflow is the goal aggregate: goalId equals sessionId. This module stores
references and decisions, never another copy of mastery or plan business facts.
"""
import hashlib
import re
import uuid
from datetime import datetime, timezone

from app.agents.secretary import SecretaryAgent


def is_learning_request(message):
    """Profile edits and requests to inspect data do not start practice."""
    if re.search(r"更新.*画像|修改.*画像|不(?:需要|想|要|再).{0,8}(?:学|复习|练)|功能|怎么使用|如何使用|是什么|介绍|说明书", message):
        return False
    return bool(re.search(
        r"(?:帮我|请)(?:按.{0,12})?(?:安排|制定|生成|规划).{0,25}(?:复习|练习|计划|学习)|"
        r"(?:我要|我想|请|帮我|开始|启动|确认)(?:开始|进行)?(?:学习|复习|练习)(?!目标|画像)|"
        r"(?:开始|启动|生成|制定).{0,8}(?:学习计划|复习计划|练习计划)", message))


def valid_point(point):
    from app.agent.knowledge import valid_knowledge_term
    return bool(point) and valid_knowledge_term(point)


def chat_workflow_id(owner, chat_session_id):
    digest = hashlib.sha256(f"{owner}:{chat_session_id}".encode()).hexdigest()[:24]
    return f"goal-{digest}"


def prepare(repository, workflow, state):
    """Refresh authoritative inputs without changing the chosen goal point."""
    profile = state.get("profile") or {}
    points = [p for p in profile.get("mastery", []) if p.get("knowledgePointId") and valid_point(p.get("knowledgePointName") or p["knowledgePointId"])]
    coordination = dict(state["coordination"])
    target = coordination.get("knowledgePointId")
    if target and not valid_point(coordination.get("knowledgePointName") or target):
        target = ""
        coordination.update(knowledgePointId="", knowledgePointName="")
    if target and not any(p["knowledgePointId"] == target for p in points):
        same_name = next((p for p in points if p.get("knowledgePointName") == coordination.get("knowledgePointName")), None)
        if same_name:
            target = same_name["knowledgePointId"]
            coordination["knowledgePointId"] = target
    if not target and points and coordination.get("allowProfileSelection") is True:
        point = min(points, key=lambda p: (p.get("masteryScore", 0), p["knowledgePointId"]))
        target = point["knowledgePointId"]
        coordination["knowledgePointId"] = target
        coordination["knowledgePointName"] = point.get("knowledgePointName", target)
    state["coordination"] = coordination
    state["knowledgePointId"] = target
    state["knowledgePoints"] = [dict(p, errorIntensity=max(0, 100-p.get("masteryScore", 0)), importance=50)
                                for p in points]
    plan = state.get("plan") or {}
    if plan.get("planId"):
        state["planId"] = plan["planId"]
    state["inputRefs"] = {"profileVersion": profile.get("profileVersion", 0),
                          "planId": plan.get("planId", ""), "planVersion": plan.get("version", 0)}
    block = ""
    if not target or not any(p["knowledgePointId"] == target for p in points):
        block = "knowledge_points"
    elif plan.get("constraints", {}).get("availableMinutes") == 0:
        block = "available_time"
    state["coordinationBlock"] = block if not state.get("assessment") else ""
    return state


def blocked_result(state):
    block = state["coordinationBlock"]
    message = ("还没有本目标可用的知识点，请先导入课程资料或在画像中添加知识点；尚未进行掌握度测评。"
               if block == "knowledge_points" else
               "当前可用时间为0分钟，请先调整专项计划的可用时间，再继续本目标。")
    return {"status": "waiting", "waitingFor": block, "toolCalls": [], "nextAction": message}


def action_for(state, status):
    waiting = state.get("waitingFor", "")
    if status == "completed":
        return {"label": "查看更新后的计划", "targetPage": "pages/StudyPlan"}
    if status == "error":
        return {"label": "重试本目标", "targetPage": ""}
    if waiting == "knowledge_points":
        # 必须落到**能真正补上知识点**的页面。旧实现指向 pages/StudyTags（只读的
        # 学情画像），空账号点进去仍然没有任何知识点可看，用户看到的就是
        # 「提示要补充 → 却无处可补 → 只能退回重试」。
        # 课程导入会经 `POST /api/v1/profile/<id>/knowledge-points` 写入 mastery
        # 并生成/更新计划（见 app/api/profile.py、app/tools/profile_merge.py），
        # 回来后 `prepare()` 会重新读到 profileVersion 变化，目标即可继续。
        return {"label": "补充课程与知识点", "targetPage": "pages/CourseImport"}
    if waiting == "available_time":
        return {"label": "调整可用时间", "targetPage": "pages/StudyPlan"}
    return {"label": "继续本目标练习", "targetPage": "pages/ExercisePractice"}


def snapshot(repository, workflow):
    state = workflow.get("state", {})
    coordination = state.get("coordination")
    if not coordination:
        return None
    status = workflow.get("status", "running")
    waiting = state.get("waitingFor", "")
    public_status = ("completed" if status == "completed" else "tool_failed" if status == "error"
                     else "waiting_for_answers" if waiting == "answers"
                     else "waiting_for_input" if waiting else "ready")
    profile = repository.get("profiles", workflow["userId"]) or {}
    plan = repository.get("plans", state.get("planId", "")) or {}
    if plan.get("userId", "demo-user") != workflow["userId"]:
        plan = {}
    context = {"goalId": workflow["sessionId"], "sessionId": workflow["sessionId"],
               "traceId": workflow["traceId"], "goal": workflow["goal"],
               "stateVersion": workflow.get("stateVersion", 1), "status": public_status,
               "currentAgent": "secretary" if workflow.get("currentAgent") == "clarify" else workflow.get("currentAgent", "secretary"),
               "waitingFor": waiting, "nextAction": workflow.get("nextAction") or workflow.get("finalAction") or "继续本目标",
               "decisionSource": "rules", "action": action_for(state, status),
               "knowledgePointId": coordination.get("knowledgePointId", ""),
               "knowledgePointName": coordination.get("knowledgePointName", ""),
               "profileVersion": profile.get("profileVersion", 0), "planId": plan.get("planId", ""),
               "planVersion": plan.get("version", 0), "handoffs": state.get("handoffs", [])[-12:]}
    context["assessmentTraceId"] = state.get("assessmentTraceId", "")
    history = [h for h in profile.get("history", []) if h.get("source") == "assessment"
               and h.get("knowledgePointId") == context["knowledgePointId"]]
    context["assessmentStatus"] = "assessed" if history else "not_assessed"
    context["assessedQuestionCount"] = sum(h.get("questionCount", 0) for h in history)
    # Prefer materials only when a relevant owned course KB is unambiguous.
    point = context["knowledgePointName"] or context["knowledgePointId"]
    kbs = {c.get("kbId") for c in repository.list("chunks")
           if c.get("userId") == workflow["userId"] and point and point in (c.get("text", "") + c.get("headingPath", ""))}
    owned = [k for k in repository.list("knowledge_bases") if k.get("userId") == workflow["userId"] and k.get("kbId") in kbs]
    context["sourceMode"] = "materials" if len(owned) == 1 else "general"
    context["kbId"] = owned[0]["kbId"] if len(owned) == 1 else ""
    legacy_unconfirmed = bool(re.search(r"这道错题|这道题|这张图", workflow.get("goal", "")) and not coordination.get("diagnosisId"))
    if legacy_unconfirmed:
        context.update(needsConfirmation=True, knowledgePointId="", knowledgePointName="", status="waiting_for_input",
            nextAction="旧诊断目标尚未核对题干，请重新上传或输入题目后确认", action={"label": "补充题目", "targetPage": ""})
    if not valid_point(context["knowledgePointName"] or context["knowledgePointId"]):
        context.update(knowledgePointId="", knowledgePointName="", sourceMode="general", kbId="")
    if (coordination.get("knowledgePointId") and not valid_point(coordination.get("knowledgePointName") or coordination.get("knowledgePointId"))
            or not coordination.get("diagnosisId") and not is_learning_request(workflow.get("goal", ""))):
        context.update(needsConfirmation=True, knowledgePointId="", knowledgePointName="", status="waiting_for_input",
            nextAction="这个旧目标由资料标签或画像更新误触发。请重新选择具体知识点，历史记录已保留。",
            action={"label": "请重新选择知识点", "targetPage": ""})
    if workflow.get("userEnded"):
        context.update(status="ended", nextAction="此目标已由你结束，历史测评与完成记录仍保留", action={"label": "目标已结束", "targetPage": ""})
    return context


def bind_submission(repository, workflow, result, events):
    """Join an already executed assessment to the goal in the caller's transaction."""
    import copy
    workflow = copy.deepcopy(workflow)
    state = workflow.setdefault("state", {})
    version = workflow.get("stateVersion", 1)
    tasks = list(state.get("handoffs", []))
    for event in events:
        task_id = f"{workflow['sessionId']}:step-{version}"
        tasks.append({"goalId": workflow["sessionId"], "agentTaskId": task_id,
                      "sender": "exercise" if event["agent"] == "assessment" else "assessment",
                      "receiver": event["agent"], "objective": workflow["goal"],
                      "dependsOn": [tasks[-1]["agentTaskId"]] if tasks else [],
                      "inputRefs": dict(state.get("inputRefs", {})),
                      "inputVersion": version, "outputVersion": version + 1,
                      "constraints": {}, "expectedArtifact": "assessment_evidence" if event["agent"] == "assessment" else "plan",
                      "status": "completed", "artifactRefs": {"submissionId": result["submissionId"], "traceId": result["traceId"]},
                      "evidenceIds": event.get("evidenceIds", []), "reason": event["outputSummary"],
                      "toolCalls": event["toolCalls"], "decisionSource": "rules"})
        version += 1
    state.update({"handoffs": tasks[-20:], "boundSubmissionId": result["submissionId"],
                  "assessmentTraceId": result["traceId"]})
    workflow["stateVersion"] = version
    workflow["updatedAt"] = datetime.now(timezone.utc).isoformat()
    if workflow.get("status") == "completed":
        workflow["completedAt"] = workflow["updatedAt"]
    repository.save("workflows", workflow["sessionId"], workflow)


def handoff(state, result, step, version):
    decision = SecretaryAgent().run(state)
    previous = state.get("handoffs", [])
    role = "secretary" if step == "clarify" else step
    refs = dict(state.get("inputRefs", {}))
    refs.update({"profileVersion": (state.get("profile") or {}).get("profileVersion", 0),
                 "planId": (state.get("plan") or {}).get("planId", ""),
                 "planVersion": (state.get("plan") or {}).get("version", 0)})
    output_plan = result.get("plan") or {}
    task = {"goalId": state["sessionId"], "agentTaskId": f"{state['sessionId']}:step-{version}",
            "sender": "secretary", "receiver": role, "objective": state["goal"],
            "dependsOn": [previous[-1]["agentTaskId"]] if previous else [],
            "inputRefs": refs, "inputVersion": version, "outputVersion": version + 1,
            "constraints": {"availableMinutes": (state.get("plan") or {}).get("constraints", {}).get("availableMinutes")},
            "expectedArtifact": {"planner": "plan", "exercise": "exercise_set", "assessment": "assessment_evidence",
                                 "diagnosis": "diagnosis", "clarify": "user_input"}.get(step, "result"),
            "status": "waiting_for_input" if result.get("status") == "waiting" else "tool_failed" if result.get("status") == "error" else "completed",
            "artifactRefs": {"planId": output_plan.get("planId", ""), "planVersion": output_plan.get("version", 0),
                             "submissionId": result.get("submissionId", ""),
                             "exerciseIds": [q["exerciseId"] for q in result.get("exercises", [])]},
            "evidenceIds": result.get("evidenceIds", []), "reason": decision.output["reason"],
            "toolCalls": result.get("toolCalls", []), "decisionSource": "rules"}
    return [*previous[-19:], task]


def current_chat_workflow(repository, owner, chat_session_id):
    base = chat_workflow_id(owner, chat_session_id)
    link = repository.get("chat_goal_links", base) or {}
    if link.get("ended"):
        return None
    workflow = repository.get("workflows", link.get("activeGoalId", base))
    if not workflow or workflow.get("userId") != owner:
        return None
    coordination = workflow.get("state", {}).get("coordination", {})
    # Old unconfirmed diagnosis goals (including HTTP fallback) are historical only.
    if re.search(r"这道错题|这道题|这张图", workflow.get("goal", "")) and not coordination.get("diagnosisId"):
        return None
    if (not coordination.get("diagnosisId") and not is_learning_request(workflow.get("goal", ""))
            or not valid_point(coordination.get("knowledgePointName") or coordination.get("knowledgePointId"))
            and coordination.get("knowledgePointId")):
        return None
    return workflow


def chat_goal_history(repository, owner, chat_session_id):
    rows = [w for w in repository.list("workflows") if w.get("userId") == owner and
            w.get("state", {}).get("coordination", {}).get("chatSessionId") == chat_session_id]
    rows.sort(key=lambda w: (w.get("createdAt", ""), w["sessionId"]))
    return [snapshot(repository, w) for w in rows[-20:][::-1] if w.get("state", {}).get("coordination")]


def ensure_chat_context(repository, owner, chat_session_id, goal, point="", new_goal=False, diagnosis_id=""):
    # Called by chat only after the caller explicitly opts into coordination.
    from app.api.workflows import _run_saved_workflow, _workflow_guard
    from app.tools.profile_merge import PROFILE_LOCK
    base = chat_workflow_id(owner, chat_session_id)
    with _workflow_guard(), PROFILE_LOCK:
        workflow = current_chat_workflow(repository, owner, chat_session_id)
        if workflow and not point:
            named_now = [r for r in (repository.get("profiles", owner) or {}).get("mastery", [])
                         if r.get("knowledgePointName") and r["knowledgePointName"] in goal]
            if named_now:
                selected_now = max(named_now, key=lambda r: len(r["knowledgePointName"]))
                if selected_now["knowledgePointId"] != workflow.get("state", {}).get("coordination", {}).get("knowledgePointId"):
                    point = selected_now["knowledgePointId"]
                    new_goal = True
        if new_goal or workflow and workflow.get("userEnded"):
            workflow = None
        session_id = workflow["sessionId"] if workflow else (f"{base}-{uuid.uuid4().hex[:10]}" if repository.get("workflows", base) or new_goal else base)
        if diagnosis_id:
            session_id = base + "-" + hashlib.sha256(diagnosis_id.encode()).hexdigest()[:10]
            saved_diagnosis_goal = repository.get("workflows", session_id)
            if saved_diagnosis_goal:
                workflow = saved_diagnosis_goal
        if workflow is None:
            trace_id = f"trace-{session_id}"
            profile = repository.get("profiles", owner) or {}
            points = [p for p in profile.get("mastery", []) if valid_point(p.get("knowledgePointName") or p.get("knowledgePointId"))]
            # Prefer explicitly named points/courses in the user's real input.
            named = [p for p in points if any(name and name in goal for name in
                     (p.get("knowledgePointName", ""), p.get("knowledgePointId", "")))]
            course_points = [p for p in points if p.get("sourceCourse") and p["sourceCourse"] in goal]
            selected = None
            if not point and named:
                selected = max(named, key=lambda p: len(p.get("knowledgePointName", "")))
            elif not point and course_points:
                selected = min(course_points, key=lambda p: (p.get("masteryScore", 0), p["knowledgePointId"]))
            elif not point:
                from app.api.exercises import _EXERCISE_BANK
                mentioned = [q for q in _EXERCISE_BANK if q.get("knowledgePointName") and q["knowledgePointName"] in goal]
                if mentioned:
                    selected = max(mentioned, key=lambda q: len(q["knowledgePointName"]))
            if selected:
                point = selected["knowledgePointId"]
            workflow = {"sessionId": session_id, "traceId": trace_id, "userId": owner, "goal": goal[:1000],
                        "createdAt": datetime.now(timezone.utc).isoformat(),
                        "status": "running", "currentStep": "secretary", "currentAgent": "secretary",
                        "stateVersion": 1, "maxSteps": 6, "finalAction": None,
                        "state": {"coordination": {"chatSessionId": chat_session_id,
                                                  "knowledgePointId": point,
                                                  "diagnosisId": diagnosis_id,
                                                  "allowProfileSelection": bool(re.search(r"薄弱|短板|查漏补缺", goal)),
                                                  "knowledgePointName": selected.get("knowledgePointName", point) if selected else point}}}
            repository.apply_batch([], [("workflows", session_id, workflow),
                                         ("traces", trace_id, {"traceId": trace_id, "userId": owner, "events": []})])
        repository.save("chat_goal_links", base, {"userId": owner, "chatSessionId": chat_session_id,
            "activeGoalId": session_id, "ended": False})
        _run_saved_workflow(session_id)
        return snapshot(repository, repository.get("workflows", session_id))
