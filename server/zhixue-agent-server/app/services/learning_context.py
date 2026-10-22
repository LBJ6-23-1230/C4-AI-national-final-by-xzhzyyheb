"""One chat session -> one durable learning workflow, with public handoffs.

The workflow is the goal aggregate: goalId equals sessionId. This module stores
references and decisions, never another copy of mastery or plan business facts.
"""
import hashlib

from app.agents.secretary import SecretaryAgent


def chat_workflow_id(owner, chat_session_id):
    digest = hashlib.sha256(f"{owner}:{chat_session_id}".encode()).hexdigest()[:24]
    return f"goal-{digest}"


def prepare(repository, workflow, state):
    """Refresh authoritative inputs without changing the chosen goal point."""
    profile = state.get("profile") or {}
    points = [p for p in profile.get("mastery", []) if p.get("knowledgePointId")]
    coordination = dict(state["coordination"])
    target = coordination.get("knowledgePointId")
    if target and not any(p["knowledgePointId"] == target for p in points):
        same_name = next((p for p in points if p.get("knowledgePointName") == coordination.get("knowledgePointName")), None)
        if same_name:
            target = same_name["knowledgePointId"]
            coordination["knowledgePointId"] = target
    if not target and points:
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


def ensure_chat_context(repository, owner, chat_session_id, goal, point=""):
    # Called by chat only after the caller explicitly opts into coordination.
    from app.api.workflows import _run_saved_workflow
    from app.tools.profile_merge import PROFILE_LOCK
    session_id = chat_workflow_id(owner, chat_session_id)
    with PROFILE_LOCK:
        workflow = repository.get("workflows", session_id)
        if workflow is None:
            trace_id = f"trace-{session_id}"
            profile = repository.get("profiles", owner) or {}
            points = profile.get("mastery", [])
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
                        "status": "running", "currentStep": "secretary", "currentAgent": "secretary",
                        "stateVersion": 1, "maxSteps": 6, "finalAction": None,
                        "state": {"coordination": {"chatSessionId": chat_session_id,
                                                  "knowledgePointId": point,
                                                  "knowledgePointName": selected.get("knowledgePointName", point) if selected else point}}}
            repository.apply_batch([], [("workflows", session_id, workflow),
                                         ("traces", trace_id, {"traceId": trace_id, "userId": owner, "events": []})])
        _run_saved_workflow(session_id)
        return snapshot(repository, repository.get("workflows", session_id))
