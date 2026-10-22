"""Fit whole pending tasks to an explicit total-minute budget, retaining overflow."""

from copy import deepcopy


def fit_plan_to_budget(old_plan: dict, available_minutes: int, prioritize_point=None) -> dict:
    if isinstance(available_minutes, bool) or not isinstance(available_minutes, int) or not 0 <= available_minutes <= 1440:
        raise ValueError("available_minutes must be an integer between 0 and 1440")
    candidates = {}
    for task in [*old_plan.get("tasks", []), *old_plan.get("unscheduledTasks", [])]:
        candidates.setdefault(task["taskId"], deepcopy(task))
    tasks = list(candidates.values())
    completed = [t for t in tasks if t.get("status") == "completed"]
    pending = [t for t in tasks if t.get("status") != "completed"]
    if prioritize_point:
        pending.sort(key=lambda t: t.get("knowledgePointId") != prioritize_point)
    scheduled, deferred = [], []
    remaining = available_minutes
    for task in pending:
        task.pop("deferredReason", None)
        duration = task.get("durationMinutes", 0)
        if isinstance(duration, bool) or not isinstance(duration, int) or duration <= 0:
            task["deferredReason"] = "任务时长未明确，需补充后安排"
            deferred.append(task)
        elif duration <= remaining:
            scheduled.append(task)
            remaining -= duration
        else:
            task["deferredReason"] = f"预计需{duration}分钟，当前剩余{remaining}分钟，暂未安排"
            deferred.append(task)
    plan = dict(old_plan, tasks=completed + scheduled, unscheduledTasks=deferred,
                constraints={**old_plan.get("constraints", {}), "availableMinutes": available_minutes},
                budgetSummary={"availableMinutes": available_minutes,
                    "scheduledMinutes": available_minutes - remaining,
                    "unallocatedMinutes": remaining,
                    "unscheduledMinutes": sum(t.get("durationMinutes", 0) for t in deferred
                        if isinstance(t.get("durationMinutes"), int) and t["durationMinutes"] > 0)})
    changed = any(plan.get(k) != old_plan.get(k) for k in ("tasks", "unscheduledTasks", "constraints", "budgetSummary"))
    return {"plan": plan, "changed": changed}
