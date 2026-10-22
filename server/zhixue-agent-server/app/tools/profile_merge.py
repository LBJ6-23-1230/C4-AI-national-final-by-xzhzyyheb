"""One atomic boundary for discovery and assessment profile writes."""
import threading
from datetime import datetime, timezone
import uuid

from app.repositories.staged_repository import StagedRepository

PROFILE_LOCK = threading.RLock()


def merge_points_into_profile(repository, user_id, points):
	from app.api.exercises import _EXERCISE_BANK
	from app.agents.planner import PlannerAgent
	from app.api.plans import plan_belongs_to
	from app.tools.plan_tools import create_plan_history
	bank = {row["knowledgePointName"]: row["knowledgePointId"] for row in _EXERCISE_BANK}
	with PROFILE_LOCK:
		repository = StagedRepository(repository)
		profile = repository.get("profiles", user_id)
		if profile is None:
			return None
		rows = profile.setdefault("mastery", [])
		ids = {row.get("knowledgePointId") for row in rows}
		names = {row.get("knowledgePointName") for row in rows}
		changed = False
		for point in points:
			point = {"name": point} if isinstance(point, str) else point
			name = str(point.get("name") or point.get("knowledgePointName") or "").strip()
			key = point.get("knowledgePointId") or bank.get(name, name)
			if not name or key in ids or name in names or len(rows) >= 60:
				continue
			rows.append({"knowledgePointId": key, "knowledgePointName": name,
				"masteryScore": 0, "confidence": 0, "lastUpdated": datetime.now(timezone.utc).isoformat(),
				"source": point.get("source", "document"), "sourceCourse": point.get("sourceCourse", ""),
				"importance": point.get("importance", 0.6)})
			ids.add(key)
			names.add(name)
			changed = True
		if changed:
			profile["profileVersion"] = profile.get("profileVersion", 1) + 1
			repository.save("profiles", user_id, profile)
		plans = [p for p in repository.list("plans") if plan_belongs_to(p, user_id)]
		if rows and (changed or not plans):
			state = {"knowledgePoints": [dict(row, importance=round(row.get("importance", 0.6) * 100),
				errorIntensity=0) for row in rows]}
			result = PlannerAgent().run(state)
			tools = list(result.tool_calls)
			previous = plans[0] if plans else None
			if previous is not None:
				# Preserve IDs, progress, durations and all deferred work; append only new points.
				tasks = [*previous.get("tasks", []), *previous.get("unscheduledTasks", [])]
				known = {t["knowledgePointId"] for t in tasks}
				for task in result.output["plan"]["tasks"]:
					if task["knowledgePointId"] not in known:
						tasks.append(task)
						known.add(task["knowledgePointId"])
				plan = dict(previous, tasks=tasks, unscheduledTasks=[])
				budget = previous.get("constraints", {}).get("availableMinutes")
				if budget is not None:
					fitted = PlannerAgent().run({"plan": plan, "availableMinutes": budget})
					plan = fitted.output["plan"]
					tools.extend(fitted.tool_calls)
				plan["version"] = previous.get("version", 1) + 1
			else:
				plan = dict(result.output["plan"], planId=f"plan-import-{user_id}")
			plan.update(userId=user_id, generatedFromProfileVersion=profile.get("profileVersion", 1),
				reason="根据新增课程或资料知识点更新专项计划；保留已有学习进度")
			repository.save("plans", plan["planId"], plan)
			event_id = f"input-{uuid.uuid4().hex}"
			trace_id = f"trace-{event_id}"
			now = datetime.now(timezone.utc).isoformat()
			repository.save("learning_events", event_id, {"eventId": event_id, "userId": user_id,
				"type": "KnowledgePointsDiscovered", "objectId": plan["planId"], "occurredAt": now,
				"profileVersion": profile["profileVersion"], "status": "recorded"})
			repository.save("traces", trace_id, {"traceId": trace_id, "userId": user_id, "events": [{
				"agent": "planner", "toolCalls": tools, "inputSummary": "新增课程或资料知识点",
				"outputSummary": plan["reason"], "evidenceIds": [], "timestamp": now,
				"status": "completed", "stateVersion": plan["version"],
				"inputStateVersion": previous.get("version", 1) if previous else 1,
				"outputStateVersion": plan["version"]}]})
			if previous is not None:
				history = create_plan_history(previous, plan, plan["reason"], [])
				history.update(planId=plan["planId"], adjustmentReason=plan["reason"], triggerEvidence=[])
				repository.save("plan_histories", f"{plan['planId']}:v{plan['version']}", history)
		repository.commit()
		return profile
