"""Assessment-to-planner handoff and one shared plan commit operation."""
from time import perf_counter

from app.agents.planner import PlannerAgent
from app.domain.assessment import AssessmentResult
from app.tools.plan_tools import create_plan_history, should_replan


def replan_request(assessment: AssessmentResult) -> dict:
    point = assessment.remediation_knowledge_point()
    score = round(assessment.per_knowledge_accuracy.get(point, 1) * 100, 2)
    state = {"knowledgePointId": point,
             "masteryScore": assessment.per_knowledge_mastery.get(point, assessment.suggested_new_mastery),
             "assessmentScore": score, "repeatedError": score < 80}
    decision = should_replan(state) if point != "unknown" else {"needReplan": False, "reasons": []}
    return {"fromAgent": "assessment", "toAgent": "planner", "objective": "根据逐知识点评估调整学习安排",
            "replanState": state, "decision": decision}


def execute_assessment_replan(repository, user_id: str, plan_id: str,
                              handoff: dict, evidence_ids: list[str], submission_id=None) -> dict:
    """Called under the shared profile lock. Execute the role before recording it."""
    plan = repository.get("plans", plan_id)
    started = perf_counter()
    profile_snapshot = repository.get('profiles', user_id) or {}
    handoff = dict(handoff, evidenceIds=list(evidence_ids), userId=user_id,
        planId=plan_id, inputVersion=(plan or {}).get('version', 0),
        profileVersion=profile_snapshot.get('profileVersion', 1),
        hardConstraints=(plan or {}).get('constraints', {}),
        knownFacts=[dict(taskId=t.get('taskId'), dueDate=t.get('dueDate'), dueAt=t.get('dueAt'),
            durationMinutes=t.get('durationMinutes'), status=t.get('status'))
            for t in (plan or {}).get('tasks', []) if t.get('source') == 'ddl'])
    def record_handoff(changed, output_version, tools):
        key = f"{user_id}:{submission_id or plan_id}:{handoff['inputVersion']}"
        repository.save('agent_handoffs', key, dict(handoff, changed=changed,
            outputVersion=output_version, processing='rules', modelCalls=0, tokens=None,
            toolCalls=tools, elapsedMs=round((perf_counter() - started) * 1000, 3)))
    def mark_handled():
        if submission_id:
            record = repository.get("submissions", submission_id)
            if record and record.get("response", {}).get("userId") == user_id:
                repository.save("submissions", submission_id, dict(record, replanHandled=True))
    if plan is None or plan.get("userId", "demo-user") != user_id:
        mark_handled()
        return {"changed": False, "toolCalls": [], "reason": "当前账号没有对应计划"}
    result = PlannerAgent().run({"plan": plan, "needReplan": True,
                                 "replanState": handoff["replanState"]})
    if not result.output.get("changedTasks"):
        record_handoff(False, plan['version'], list(result.tool_calls))
        mark_handled()
        return {"changed": False, "plan": plan, "toolCalls": list(result.tool_calls),
                "reason": "规划检查完成，当前计划无需变更或没有对应待调整任务"}
    profile = repository.get("profiles", user_id) or {}
    updated = dict(result.output["plan"], planId=plan_id, userId=user_id,
                   generatedFromProfileVersion=profile.get("profileVersion", 1))
    point = handoff["replanState"]["knowledgePointId"]
    name = next((r.get("knowledgePointName") for r in profile.get("mastery", []) if r.get("knowledgePointId") == point), None) or point
    reason = "按本次得分 %.2f 调整知识点 %s 的学习安排" % (
        handoff["replanState"]["assessmentScore"], name)
    history = create_plan_history(plan, updated, reason, evidence_ids)
    history.update({"planId": plan_id, "adjustmentReason": history["reason"],
                    "triggerEvidence": history["evidenceIds"]})
    event_id = f"plan:{plan_id}:v{updated['version']}"
    saves = [("plans", plan_id, updated),
             ("plan_histories", f"{plan_id}:v{updated['version']}", history),
             ("learning_events", event_id, {"eventId": event_id, "userId": user_id,
                "type": "PlanReplanned", "objectId": plan_id, "version": updated["version"],
                "occurredAt": history["timestamp"], "fromAgent": "assessment", "toAgent": "planner",
                "evidenceIds": evidence_ids, "status": "recorded"})]
    if submission_id:
        record = repository.get("submissions", submission_id)
        if record and record.get("response", {}).get("userId") == user_id:
            response = dict(record["response"], plan=updated, planDiff=history)
            saves.append(("submissions", submission_id, dict(record, response=response, replanHandled=True)))
    repository.apply_batch([], saves)
    record_handoff(True, updated['version'], list(result.tool_calls))
    from app.services.reminders import reconcile
    reconcile(repository, user_id)
    return {"changed": True, "plan": updated, "planDiff": history,
            "toolCalls": list(result.tool_calls), "reason": handoff["objective"]}
