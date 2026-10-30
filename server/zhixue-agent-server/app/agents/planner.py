"""Learning path planning agent."""

from collections.abc import Mapping
from typing import Any

from app.agents import AgentResult
from app.runtime.tool_registry import ToolRegistry, create_default_registry


class PlannerAgent:
	name = "planner"

	def __init__(self, registry: ToolRegistry | None = None) -> None:
		self.registry = registry or create_default_registry()

	def run(self, state: Mapping[str, Any]) -> AgentResult:
		if state.get("plan") is not None and "availableMinutes" in state:
			result = self.registry.execute("fit_plan_to_budget", self.name, {
				"old_plan": state["plan"], "available_minutes": state["availableMinutes"]})
			if result["changed"]:
				result["plan"]["version"] = state["plan"].get("version", 1) + 1
			return AgentResult(self.name, result, ("fit_plan_to_budget",))
		if state.get("plan") is not None and state.get("needReplan"):
			plan = state["plan"]
			budget = plan.get("constraints", {}).get("availableMinutes")
			if budget is not None:
				plan = dict(plan, tasks=[*plan.get("tasks", []), *plan.get("unscheduledTasks", [])], unscheduledTasks=[])
			result = self.registry.execute("replan_learning_path", self.name, {
				"old_plan": plan, "state": state.get("replanState", {})})
			if budget is not None:
				# DDL effort is a hard fact. Offer a short first segment of the
				# assessed practice only when the current plan has deadline work.
				if any(t.get('source') == 'ddl' for t in result['plan'].get('tasks', [])):
					for task in result['plan'].get('tasks', []):
						if task.get('knowledgePointId') == state.get('replanState', {}).get('knowledgePointId') and task.get('source') != 'ddl' and not task.get('parentTaskId'):
							task['allowPartial'] = True
				fitted = self.registry.execute("fit_plan_to_budget", self.name, {
					"old_plan": result["plan"], "available_minutes": budget,
					"prioritize_point": state.get("replanState", {}).get("knowledgePointId")})
				diff = self.registry.execute("build_plan_diff", self.name, {
					"old_plan": state["plan"], "new_plan": fitted["plan"]})
				result.update({"plan": fitted["plan"], "changedTasks": diff["changedTasks"]})
				if result["changedTasks"]:
					result["plan"]["version"] = state["plan"].get("version", 1) + 1
				return AgentResult(self.name, result, ("replan_learning_path", "fit_plan_to_budget", "build_plan_diff"))
			return AgentResult(self.name, result, ("replan_learning_path",))
		priorities = self.registry.execute("calculate_learning_priority", self.name, {
			"knowledge_points": list(state.get("knowledgePoints", [])),
			"context": dict(state.get("context", {})),
		})
		# ⚠️ 契约 `PlanTask.required` = [taskId, knowledgePointId, knowledgePointName,
		# durationMinutes, status] —— **五个都要给齐**。
		#
		# 原实现只给了 knowledgePointId / durationMinutes / status：走到 planner 的
		# 用户（例如计划已被重排过又新建工作流）会拿到 `tasks[0].taskId === undefined`，
		# 前端于是渲染出「知识点：undefined」，而 `ForEach` 的 key 用的是
		# `${task.taskId}-${task.status}` → **所有任务的 key 全都相同**，
		# 列表复用时会出现"改一条全变"的错乱。
		#
		# `taskId` 由知识点 id 派生（稳定、可复现），不用序号 —— 否则重排后
		# 同一任务会换 id，进度对不上。
		tasks = [{
			"taskId": f"task-{item['knowledgePointId']}",
			"knowledgePointId": item["knowledgePointId"],
			"knowledgePointName": str(
				item.get("knowledgePointName") or item["knowledgePointId"]),
			"durationMinutes": 30,
			"status": "pending",
		} for item in priorities]
		return AgentResult(self.name, {"plan": {"version": 1, "tasks": tasks},
			"priorities": priorities}, ("calculate_learning_priority",))
