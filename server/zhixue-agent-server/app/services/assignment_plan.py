"""Reconcile an account's local DDL snapshot without inventing study time."""
from copy import deepcopy
from datetime import date

from app.tools.time_budget import fit_plan_to_budget


def validate_assignments(rows):
    if not isinstance(rows, list) or len(rows) > 300:
        raise ValueError("assignments 必须是最多300项的作业列表")
    seen = set()
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError("作业格式错误")
        for field, limit in (("id", 128), ("title", 200), ("courseName", 80), ("dueDate", 10)):
            if not isinstance(row.get(field), str) or not row[field].strip() or len(row[field]) > limit:
                raise ValueError("作业ID、标题、课程和截止日期不能为空或超长")
        try:
            date.fromisoformat(row["dueDate"])
        except ValueError:
            raise ValueError("作业截止日期请使用YYYY-MM-DD") from None
        minutes = row.get("estimatedMinutes")
        if type(minutes) is not int or not 1 <= minutes <= 1440 or type(row.get("completed")) is not bool:
            raise ValueError("作业预计时长须为1至1440分钟，completed须为布尔值")
        if row["id"] in seen:
            raise ValueError("作业ID重复")
        seen.add(row["id"])


def reconcile(plan, rows, selected_id=None, *, authoritative=False):
    result = deepcopy(plan)
    existing = {t["taskId"]: t for t in plan.get("tasks", []) + plan.get("unscheduledTasks", [])}
    if not authoritative:
        # Old clients send device-local snapshots. Absence is never a deletion.
        present = {r['id'] for r in rows}
        rows = list(rows) + [dict(id=t['taskId'], title=t['knowledgePointName'],
            courseName=t.get('sourceCourse', ''), dueDate=t['dueDate'],
            estimatedMinutes=t['durationMinutes'], priority=t.get('priority', 'normal'),
            completed=t.get('status') == 'completed') for t in existing.values()
            if t.get('source') == 'ddl' and t['taskId'] not in present]
    scheduled_ids = {t["taskId"] for t in plan.get("tasks", [])}
    regular = deepcopy([t for t in plan.get("tasks", []) if t.get("source") != "ddl"])
    deferred = deepcopy([t for t in plan.get("unscheduledTasks", []) if t.get("source") != "ddl"])
    decomposed = plan.get('taskDecompositions', {})
    present = {r['id'] for r in rows}
    if authoritative and decomposed:
        removed = {child for parent, detail in decomposed.items() if detail.get('original', {}).get('source') == 'ddl' and parent not in present for child in detail['childIds']}
        regular = [t for t in regular if t['taskId'] not in removed]
        deferred = [t for t in deferred if t['taskId'] not in removed]
        result['taskDecompositions'] = {parent: detail for parent, detail in decomposed.items() if detail.get('original', {}).get('source') != 'ddl' or parent in present}
    for row in sorted(rows, key=lambda r: (r["dueDate"], r["id"])):
        if row['id'] in decomposed:
            for child in regular + deferred:
                if child.get('parentTaskId') == row['id']:
                    child.update(sourceCourse=row['courseName'], dueDate=row['dueDate'])
                    if row.get('completed'): child['status'] = 'completed'
            continue
        previous = existing.get(row["id"], {})
        task = dict(previous, taskId=row["id"], knowledgePointId=f"ddl:{row['id']}",
                    knowledgePointName=row["title"], source="ddl", sourceCourse=row["courseName"],
                    dueDate=row["dueDate"], durationMinutes=row["estimatedMinutes"],
                    priority="high" if row.get("priority") in ("高", "high") else "normal",
                    status="completed" if row["completed"] or previous.get("status") == "completed" else previous.get("status", "pending"))
        if task["status"] == "completed" or row["id"] in scheduled_ids or row["id"] == selected_id:
            task.pop("deferredReason", None)
            regular.append(task)
        else:
            task["deferredReason"] = previous.get("deferredReason") or "作业已同步，选择可用时间或点击加入计划后安排"
            deferred.append(task)
    result.update(tasks=regular, unscheduledTasks=deferred)
    # Ignore snapshot ordering when nothing about the actual assignments changed.
    # In particular a page refresh must preserve the user's explicit selection.
    current_ddls = {key: task for key, task in existing.items() if task.get("source") == "ddl"}
    next_ddls = {t["taskId"]: t for t in regular + deferred if t.get("source") == "ddl"}
    if not selected_id and current_ddls == next_ddls and result == plan:
        return deepcopy(plan)
    budget = plan.get("constraints", {}).get("availableMinutes")
    if selected_id:
        # Adding a specific assignment is an explicit commitment to its duration.
        budget = max(budget or 0, sum(t["durationMinutes"] for t in regular if t.get("status") != "completed"))
        if budget > 1440:
            raise ValueError("当前安排超过一天，请先调整计划时间")
    # Reading an unchanged DDL snapshot must not re-fit a deliberate task selection.
    if result != plan and plan.get('calendarDays'):
        from datetime import datetime
        from zoneinfo import ZoneInfo
        from app.services.calendar_plan import schedule
        today = datetime.now(ZoneInfo('Asia/Shanghai')).date().isoformat()
        days = [dict(date=d['date'], minutes=d['minutes']) for d in plan['calendarDays'] if d['date'] >= today]
        if days:
            result = schedule(result, days)
    elif budget is not None and result != plan:
        result = fit_plan_to_budget(result, budget)["plan"]
    if result != plan:
        result["version"] = plan["version"] + 1
        result["reason"] = "作业已按截止日期同步；已安排任务保留，未安排作业可选择时间加入计划。"
        result["factors"] = []
    return result
