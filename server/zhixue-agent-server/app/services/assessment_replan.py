"""Assessment-to-planner handoff and one shared plan commit operation."""

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
        mark_handled()
        return {"changed": False, "plan": plan, "toolCalls": list(result.tool_calls),
                "reason": "规划检查完成，当前计划无需变更或没有对应待调整任务"}
    profile = repository.get("profiles", user_id) or {}
    updated = dict(result.output["plan"], planId=plan_id, userId=user_id,
                   generatedFromProfileVersion=profile.get("profileVersion", 1))
    reason = "按本次得分 %.2f 调整知识点 %s 的学习安排" % (
        handoff["replanState"]["assessmentScore"], handoff["replanState"]["knowledgePointId"])
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
    return {"changed": True, "plan": updated, "planDiff": history,
            "toolCalls": list(result.tool_calls), "reason": handoff["objective"]}
