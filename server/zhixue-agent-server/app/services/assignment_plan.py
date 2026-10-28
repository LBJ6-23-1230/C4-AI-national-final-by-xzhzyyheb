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


def reconcile(plan, rows, selected_id=None):
    result = deepcopy(plan)
    existing = {t["taskId"]: t for t in plan.get("tasks", []) + plan.get("unscheduledTasks", [])}
    scheduled_ids = {t["taskId"] for t in plan.get("tasks", [])}
    regular = [t for t in plan.get("tasks", []) if t.get("source") != "ddl"]
    deferred = [t for t in plan.get("unscheduledTasks", []) if t.get("source") != "ddl"]
    for row in sorted(rows, key=lambda r: (r["dueDate"], r["id"])):
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
            task["deferredReason"] = "作业已同步，选择可用时间或点击加入计划后安排"
            deferred.append(task)
    result.update(tasks=regular, unscheduledTasks=deferred)
    budget = plan.get("constraints", {}).get("availableMinutes")
    if selected_id:
        # Adding a specific assignment is an explicit commitment to its duration.
        budget = max(budget or 0, sum(t["durationMinutes"] for t in regular if t.get("status") != "completed"))
        if budget > 1440:
            raise ValueError("当前安排超过一天，请先调整计划时间")
    if budget is not None:
        result = fit_plan_to_budget(result, budget)["plan"]
    if result != plan:
        result["version"] = plan["version"] + 1
        result["reason"] = "作业已按截止日期同步；已安排任务保留，未安排作业可选择时间加入计划。"
        result["factors"] = []
    return result
