"""Fit whole pending tasks to an explicit total-minute budget, retaining overflow."""

from copy import deepcopy


def schedule_deferred_task(old_plan: dict, task_id: str) -> dict:
    """Commit only the chosen task, extending the budget just enough to fit it."""
    plan = deepcopy(old_plan)
    deferred = plan.get("unscheduledTasks", [])
    task = next((t for t in deferred if t["taskId"] == task_id), None)
    if task is None:
        raise LookupError("任务已不在待安排列表，请刷新计划")
    if task.get("status") == "completed":
        raise ValueError("该任务已完成，请刷新计划")
    pending = [t for t in plan.get("tasks", []) if t.get("status") != "completed"]
    if any(type(t.get("durationMinutes")) is not int or t["durationMinutes"] <= 0
           for t in [*pending, task]):
        raise ValueError("任务时长未明确，请先补充预计时长")
    scheduled_minutes = sum(t["durationMinutes"] for t in pending) + task["durationMinutes"]
    available = max(plan.get("constraints", {}).get("availableMinutes", 0), scheduled_minutes)
    if available > 1440:
        raise ValueError("加入后超过一天的可用时间，请先调整当前计划")
    task.pop("deferredReason", None)
    task["status"] = "pending"
    plan["tasks"] = [*plan.get("tasks", []), task]
    plan["unscheduledTasks"] = [t for t in deferred if t["taskId"] != task_id]
    for other in plan["unscheduledTasks"]:
        if type(other.get("durationMinutes")) is int and other["durationMinutes"] > 0:
            other["deferredReason"] = "本次未选择，任务保留，可单独加入本次计划"
    plan["constraints"] = {**plan.get("constraints", {}), "availableMinutes": available}
    plan["budgetSummary"] = {
        "availableMinutes": available,
        "scheduledMinutes": scheduled_minutes,
        "unallocatedMinutes": available - scheduled_minutes,
        "unscheduledMinutes": sum(t["durationMinutes"] for t in plan["unscheduledTasks"]
                                  if type(t.get("durationMinutes")) is int and t["durationMinutes"] > 0),
    }
    return plan


def fit_plan_to_budget(old_plan: dict, available_minutes: int, prioritize_point=None) -> dict:
    if isinstance(available_minutes, bool) or not isinstance(available_minutes, int) or not 0 <= available_minutes <= 1440:
        raise ValueError("available_minutes must be an integer between 0 and 1440")
    candidates = {}
    for task in [*old_plan.get("tasks", []), *old_plan.get("unscheduledTasks", [])]:
        candidates.setdefault(task["taskId"], deepcopy(task))
    tasks = list(candidates.values())
    completed = [t for t in tasks if t.get("status") == "completed"]
    pending = [t for t in tasks if t.get("status") != "completed"]
    pending.sort(key=lambda t: (0 if t.get('status') in ('running', 'in_progress') else
                               1 if t.get('source') == 'ddl' else 2,
                               t.get('dueAt') or t.get('dueDate') or '9999',
                               {'high': 0, 'medium': 1, 'low': 2}.get(t.get('priority'), 1),
                               t.get('masteryScore', 50),
                               bool(prioritize_point and t.get('knowledgePointId') != prioritize_point)))
    base_total = sum(t.get('baseDurationMinutes', t.get('durationMinutes', 0)) for t in pending if type(t.get('durationMinutes')) is int and t['durationMinutes'] > 0)
    for t in pending:
        if type(t.get('durationMinutes')) is int and t['durationMinutes'] > 0:
            t['durationMinutes'] = t.get('baseDurationMinutes', t['durationMinutes'])
    scheduled, deferred = [], []
    remaining = available_minutes
    for task in pending:
        task.pop("deferredReason", None)
        duration = task.get("durationMinutes", 0)
        if isinstance(duration, bool) or not isinstance(duration, int) or duration <= 0:
            task["deferredReason"] = "任务时长未明确，需补充后安排"
            deferred.append(task)
        elif task.get('status') in ('running', 'in_progress'):
            scheduled.append(task)
            remaining -= duration
        elif duration <= remaining:
            scheduled.append(task)
            remaining -= duration
        elif (task.get('source') != 'ddl' and task.get('status') == 'pending' and
              task.get('allowPartial') and remaining >= 5):
            # Only explicitly divisible learning tasks may be split. Keep the
            # unfinished minutes visible with their own stable task identifier.
            portion = remaining // 5 * 5
            rest = deepcopy(task)
            rest.pop('baseDurationMinutes', None)
            rest['durationMinutes'] = duration - portion
            rest['taskId'] = task['taskId'] + ':remaining'
            rest['parentTaskId'] = task['taskId']
            rest['allowPartial'] = False
            rest['deferredReason'] = f'预计需{duration - portion}分钟，当前剩余{remaining - portion}分钟，暂未安排'
            task['durationMinutes'] = portion
            task.pop('baseDurationMinutes', None)
            task['allowPartial'] = False
            scheduled.append(task)
            deferred.append(rest)
            remaining -= portion
        else:
            task["deferredReason"] = f"预计需{duration}分钟，当前剩余{remaining}分钟，暂未安排"
            deferred.append(task)
    mode = 'under_budget' if available_minutes < base_total else 'exact_budget'
    allocation_reason = ''
    if available_minutes > base_total and scheduled and not deferred:
        from app.tools.surplus_budget import allocate
        remaining, mode, allocation_reason = allocate(scheduled, remaining, old_plan.get('budgetSummary'))
    elif available_minutes > base_total:
        mode = 'surplus_fallback'
        allocation_reason = '没有可分配的有效任务，剩余时间保留未分配'
    if mode in ('under_budget', 'exact_budget'):
        for task in scheduled + deferred:
            task.pop('extraMinutes', None)
            task.pop('allocationReason', None)
    plan = dict(old_plan, tasks=completed + scheduled, unscheduledTasks=deferred,
                constraints={**old_plan.get("constraints", {}), "availableMinutes": available_minutes},
                budgetSummary={"baseTotalMinutes": base_total, "allocationMode": mode, "allocationReason": allocation_reason, "availableMinutes": available_minutes,
                    "scheduledMinutes": available_minutes - remaining,
                    "unallocatedMinutes": max(0, remaining),
                    "conflictMinutes": max(0, -remaining),
                    "unscheduledMinutes": sum(t.get("durationMinutes", 0) for t in deferred
                        if isinstance(t.get("durationMinutes"), int) and t["durationMinutes"] > 0)})
    changed = any(plan.get(k) != old_plan.get(k) for k in ("tasks", "unscheduledTasks", "constraints", "budgetSummary"))
    return {"plan": plan, "changed": changed}
