import os
from datetime import datetime, timezone

from flask import Blueprint, jsonify

from app.domain.plan import LearningPlan
from app.domain.profile import KnowledgeMastery, LearnerProfile
from app.repositories.json_repository import JsonRepository
from app.repositories.staged_repository import StagedRepository
from app.tools.profile_merge import PROFILE_LOCK
from app.api.exercises import configure_exercises_repository
from app.api.plans import configure_plans_repository
from app.api.profile import configure_profile_repository
from app.api.proactive import configure_proactive_repository
from app.api.traces import configure_traces_repository
from app.api.experiments import configure_experiments_repository


demo_api = Blueprint("demo", __name__)
_repository: JsonRepository | None = None


def configure_demo_repository(repository: JsonRepository) -> None:
	global _repository
	_repository = repository
	configure_exercises_repository(repository)
	configure_traces_repository(repository)
	configure_profile_repository(repository)
	configure_proactive_repository(repository)
	configure_plans_repository(repository)
	configure_experiments_repository(repository)


def ensure_demo_data() -> None:
	if _repository is None:
		return
	with PROFILE_LOCK, _repository.transaction():
		if _repository.get("profiles", "demo-user") is not None:
			return
		profile, plan, trace = _demo_state()
		_repository.apply_batch([], [
			("profiles", profile.user_id, profile.to_dict()),
			("plans", plan.plan_id, plan.to_dict()),
			("traces", trace["traceId"], trace),
		])


def _item_owner(item: dict[str, object]) -> str:
	"""尽力判断一条记录归属于哪个 userId；判不出返回空串。

	各集合的归属信息完整度不同（实测 `data/repository.json`）：
	  * `workflows`  —— 有顶层 `userId`，最好判
	  * `plans`      —— 有顶层 `userId`
	  * `traces` / `submissions` / `evidences` / `plan_histories`
	                —— **完全没有归属字段**，只能靠 id 关联推断
	判不出时返回空串，调用方按"保留"处理。
	"""
	if not isinstance(item, dict):
		return ""
	owner = item.get("userId")
	if isinstance(owner, str) and owner.strip():
		return owner.strip()
	state = item.get("state")
	if isinstance(state, dict):
		nested = state.get("userId")
		if isinstance(nested, str) and nested.strip():
			return nested.strip()
	return ""


def _purge_demo_owned(profile_user_id: str, repository=None) -> dict[str, int]:
	"""只删除**能证明属于演示身份**的记录，返回各集合删除条数。

	## 为什么不能整集合 clear（原实现的做法）

	`POST /api/v1/demo/reset` **无需任何凭据**即可调用。原先的实现是
	`_repository.clear(collection)` —— 那是清空**整个集合**，
	于是任何匿名请求都会把**所有注册用户**的 workflows / traces /
	submissions / evidences / plan_histories 一起删掉，而 profiles 仍保留，
	用户数据直接变成孤儿（自己的 workflow 由 200 变 404，且无法找回）。
	实测已复现。

	## 判定规则（保守优先）

	先算出"演示身份拥有哪些 workflow / plan"，再据此判定派生记录：
	  * workflows            —— 按 `userId` 直接判
	  * plans / plan_histories —— 按 `userId` / `planId` 判
	  * traces               —— `traceId` 命中被删 workflow 的 `traceId` 时删
	  * submissions / evidences —— 主键形态为 `<userId>:<setId>:<key>`，
	    或 id 命中被删 workflow 会话时删
	**其余一律保留**：拿不准归属就留着，宁可残留演示数据，也不误删他人记录。
	"""
	repo = repository if repository is not None else _repository
	if repo is None:
		return {}

	demo_workflow_ids: set[str] = set()
	demo_trace_ids: set[str] = set()
	for session_id in repo.ids("workflows"):
		item = repo.get("workflows", session_id)
		if item is None:
			continue
		if _item_owner(item) == profile_user_id:
			demo_workflow_ids.add(session_id)
			item_trace = item.get("traceId")
			if isinstance(item_trace, str) and item_trace:
				demo_trace_ids.add(item_trace)

	demo_plan_ids: set[str] = set()
	for plan_id in repo.ids("plans"):
		item = repo.get("plans", plan_id)
		if item is not None and _item_owner(item) == profile_user_id:
			demo_plan_ids.add(plan_id)

	removed: dict[str, int] = {}
	pending_deletes: list[tuple[str, str]] = []

	def _drop(collection: str, item_id: str) -> None:
		pending_deletes.append((collection, item_id))
		removed[collection] = removed.get(collection, 0) + 1

	for collection in ("focus_sessions", "learning_events", "plan_adjustments"):
		for item_id in repo.ids(collection):
			item = repo.get(collection, item_id)
			if item is not None and _item_owner(item) == profile_user_id:
				_drop(collection, item_id)

	for session_id in list(demo_workflow_ids):
		_drop("workflows", session_id)

	for plan_id in list(demo_plan_ids):
		_drop("plans", plan_id)

	for trace_id in repo.ids("traces"):
		if trace_id in demo_trace_ids:
			_drop("traces", trace_id)

	for result_id in repo.ids("submissions"):
		if result_id.startswith(f"{profile_user_id}:"):
			_drop("submissions", result_id)

	for history_id in repo.ids("plan_histories"):
		item = repo.get("plan_histories", history_id)
		if item is None:
			continue
		if item.get("planId") in demo_plan_ids or item.get("userId") == profile_user_id:
			_drop("plan_histories", history_id)

	for evidence_id in repo.ids("evidences"):
		item = repo.get("evidences", evidence_id)
		if item is None:
			continue
		source_id = item.get("sourceId")
		if isinstance(source_id, str) and source_id.startswith(f"{profile_user_id}:"):
			_drop("evidences", evidence_id)

	repo.apply_batch(pending_deletes, [])
	return removed


def _demo_state() -> tuple[LearnerProfile, LearningPlan, dict[str, object]]:
	timestamp = datetime(2026, 9, 2, 9, 0, tzinfo=timezone.utc)
	profile = LearnerProfile(
		"demo-user",
		"数据结构考试80+",
		"2026-09-30",
		["20:00-22:00"],
		1,
		[
			KnowledgeMastery("binary-tree-postorder", 42, 0.7, timestamp, "二叉树后序遍历"),
			KnowledgeMastery("graph-algorithm", 55, 0.5, timestamp, "图算法"),
			KnowledgeMastery("哈希冲突", 63, 0.5, timestamp, "哈希冲突"),
			KnowledgeMastery("algorithm-complexity", 68, 0.6, timestamp, "算法复杂度先修"),
			KnowledgeMastery("recursion-basics", 74, 0.6, timestamp, "递归基础先修"),
		],
	)
	plan = LearningPlan(
		"plan-demo-001",
		1,
		[{"taskId": "task-postorder", "knowledgePointId": "binary-tree-postorder",
		  "knowledgePointName": "二叉树后序遍历", "durationMinutes": 30,
		  "status": "pending", "priority": "high"},
		 {"taskId": "task-graph", "knowledgePointId": "graph-algorithm",
		  "knowledgePointName": "图算法", "durationMinutes": 30,
		  "status": "pending", "priority": "medium"}],
		1,
		"巩固二叉树后序遍历",
		profile.user_id,
	)
	return profile, plan, {"traceId": "trace-demo-reset-001", "events": [], "userId": "demo-user"}


@demo_api.post("/api/v1/demo/reset")
def reset_demo():
	if os.getenv("ZHIXUE_ENABLE_DEV_TOOLS") != "1":
		return jsonify({"errorCode": "NOT_FOUND", "message": "resource not found", "details": None}), 404
	if _repository is None:
		return jsonify({"errorCode": "INTERNAL_ERROR", "message": "demo repository is not configured", "details": None}), 500

	profile, plan, trace = _demo_state()

	with PROFILE_LOCK, _repository.transaction():
		staged = StagedRepository(_repository)
		_purge_demo_owned(profile.user_id, staged)
		plan_data = plan.to_dict()
		staged.apply_batch([], [
			("profiles", profile.user_id, profile.to_dict()),
			("plans", plan.plan_id, plan_data),
			("traces", str(trace["traceId"]), trace),
		])
		staged.commit()
	return jsonify({"status": "reset", "userId": profile.user_id, "profile": profile.to_dict(),
					"plan": plan.to_dict(), "traceId": trace["traceId"]})
