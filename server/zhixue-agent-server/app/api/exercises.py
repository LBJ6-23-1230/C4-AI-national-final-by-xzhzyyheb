from datetime import datetime, timezone
import uuid
import json
import hashlib
import threading
from pathlib import Path

from flask import Blueprint, jsonify, request

from app.api.identity import resolve_user_id
# 计划归属判定与 `GET /plans/current` 共用同一口径，避免"读得到计划但练习不再重排"。
from app.api.plans import plan_belongs_to
from app.api.validation import (MAX_ID_CHARS, bounded_str, json_object, validate_answers)
from app.domain.evidence import Evidence, MasteryHistory
from app.domain.plan import LearningPlan
from app.domain.profile import LearnerProfile
from app.repositories.json_repository import JsonRepository
from app.repositories.staged_repository import StagedRepository
from app.tools.assessment_tools import grade_exercise, persist_mastery, mastery_scores
from app.agent import exercise_gen
from app.tools.exercise_tools import _CLIENT_FIELDS, select_exercises
from app.services.assessment_replan import replan_request, execute_assessment_replan
from app.services import review_jobs
from app.services import exercise_cache


exercises_api = Blueprint("exercises", __name__)
DEMO_EXERCISE_SET_ID = "set-demo-binary-tree-001"
EXERCISE_SET_IDS = {DEMO_EXERCISE_SET_ID, "set-demo-data-structures-001"}
_repository: JsonRepository | None = None

# 提交接口的"幂等检查 → 判分 → 掌握度回写 → 落盘"必须**整体原子**。
#
# 原实现是典型的 check-then-act：先读 `submissions` 判断幂等键是否已存在，
# 中间隔着判分与 `persist_mastery`（两者都在改画像），最后才写 `submissions`。
# 并发下多个请求会同时通过幂等检查，于是掌握度增量被叠加多次并**永久写错**。
# 实测：6 个并发同 idempotencyKey 提交同一份全对答案 →
#   响应体出现 2 种、mastery 被加到 100（正确值 71）、
#   profileVersion=3、history 2 条。
#
# 这里用一把进程内锁把整段串行化。同一进程内的提交本来就不需要并行
# （判分是纯计算，微秒级），串行化的吞吐代价可忽略，换来的是幂等语义真正成立。
from app.tools.profile_merge import PROFILE_LOCK
_SUBMIT_LOCK = PROFILE_LOCK

_EXERCISE_BANK = [
	{"exerciseId": "exercise-preorder-001", "knowledgePointId": "binary-tree-postorder",
	 # 展示名按**题干实际考什么**写：这题问的是前序遍历，原先被标成"后序遍历"，
	 # 于是练习页每道题都挂同一个错标签（实测反馈：「不能一味的写二叉树后序遍历，
	 # 要具体看题目」）。knowledgePointId 保持不动 —— 演示题集按它选取。
	 "knowledgePointName": "前序遍历", "difficulty": "easy", "stem": "以下哪项是给定二叉树的前序遍历结果？",
	 "options": ["A. 根-左-右", "B. 左-右-根", "C. 左-根-右", "D. 根-右-左"], "source": "demo"},
	{"exerciseId": "exercise-inorder-001", "knowledgePointId": "binary-tree-postorder",
	 # 同上：这题考的是中序遍历。
	 "knowledgePointName": "中序遍历", "difficulty": "easy", "stem": "二叉树中序遍历访问节点的顺序是什么？",
	 "options": ["A. 根-左-右", "B. 左-根-右", "C. 左-右-根", "D. 根-右-左"], "source": "demo"},
	{"exerciseId": "exercise-postorder-001", "knowledgePointId": "binary-tree-postorder",
	 "knowledgePointName": "二叉树后序遍历", "difficulty": "medium", "stem": "二叉树后序遍历访问节点的顺序是什么？",
	 "options": ["A. 根-左-右", "B. 左-根-右", "C. 左-右-根", "D. 根-右-左"], "source": "demo"},
	{"exerciseId": "exercise-postorder-002", "knowledgePointId": "binary-tree-postorder",
	 "knowledgePointName": "二叉树后序遍历", "difficulty": "easy", "stem": "后序遍历中，根节点通常在什么时候被访问？",
	 "options": ["A. 最先", "B. 左子树之后、右子树之前", "C. 左右子树都访问后", "D. 任意时刻"], "source": "demo"},
	{"exerciseId": "exercise-postorder-003", "knowledgePointId": "binary-tree-postorder",
	 "knowledgePointName": "二叉树后序遍历", "difficulty": "medium", "stem": "表达式树用后序遍历得到的结果最接近哪种表达式？",
	 "options": ["A. 前缀表达式", "B. 中缀表达式", "C. 后缀表达式", "D. 自然语言"], "source": "demo"},
	{"exerciseId": "exercise-postorder-004", "knowledgePointId": "binary-tree-postorder",
	 "knowledgePointName": "二叉树后序遍历", "difficulty": "medium", "stem": "递归实现后序遍历时，输出当前节点应放在哪一步？",
	 "options": ["A. 递归左子树前", "B. 递归左右子树之间", "C. 递归左右子树后", "D. 只在叶节点执行"], "source": "demo"},
	*[
		{"exerciseId": f"exercise-bst-{number:03d}", "knowledgePointId": "binary-tree-search",
		 "knowledgePointName": "二叉搜索树", "difficulty": "medium" if number % 2 else "hard",
		 "stem": "二叉搜索树的中序遍历具有什么性质？", "options": ["A. 有序", "B. 逆序", "C. 随机", "D. 层序"], "source": "demo"}
		for number in range(1, 6)
	],
	*[
		{"exerciseId": f"exercise-graph-{number:03d}", "knowledgePointId": "graph-algorithm",
		 "knowledgePointName": "图算法", "difficulty": "easy" if number % 2 else "medium",
		 "stem": "BFS 通常使用哪种数据结构？", "options": ["A. 栈", "B. 队列", "C. 堆", "D. 集合"], "source": "demo"}
		for number in range(1, 6)
	],
	*[
		{"exerciseId": f"exercise-complexity-{number:03d}", "knowledgePointId": "algorithm-complexity",
		 "knowledgePointName": "算法复杂度先修", "difficulty": "easy" if number < 3 else "medium",
		 "stem": "二分查找的时间复杂度是？", "options": ["A. O(1)", "B. O(log n)", "C. O(n)", "D. O(n^2)"], "source": "demo"}
		for number in range(1, 6)
	],
	*[
		{"exerciseId": f"exercise-traversal-{number:03d}", "knowledgePointId": "binary-tree-traversal",
		 "knowledgePointName": "二叉树遍历基础", "difficulty": "easy" if number < 3 else "medium",
		 "stem": "层序遍历通常按什么方向访问节点？", "options": ["A. 逐层", "B. 只访问叶子", "C. 只访问根", "D. 随机"], "source": "demo"}
		for number in range(1, 6)
	],
	*[
		{"exerciseId": f"exercise-prerequisite-{number:03d}", "knowledgePointId": "recursion-basics", "knowledgePointName": "递归基础先修",
		 "difficulty": "easy" if number % 2 else "medium", "stem": "递归函数必须具备什么？",
		 "options": ["A. 终止条件", "B. 全局变量", "C. 图结构", "D. 排序"], "source": "demo"}
		for number in range(1, 8)
	],
]

_QUESTION_BANK_PATH = Path(__file__).resolve().parents[2] / "data" / "question_bank.json"
if _QUESTION_BANK_PATH.exists():
	with _QUESTION_BANK_PATH.open("r", encoding="utf-8") as stream:
		_question_bank = json.load(stream).get("exercises", [])
	if len(_question_bank) >= 30 and len({item.get("exerciseId") for item in _question_bank}) == len(_question_bank):
		_EXERCISE_BANK = _question_bank

_DEMO_EXERCISES = select_exercises(_EXERCISE_BANK, "binary-tree-postorder", count=3)

_ANSWER_KEYS = {
	exercise["exerciseId"]: exercise["answerKey"]
	for exercise in _EXERCISE_BANK
	if exercise.get("answerKey")
}


def _merged_grading_tables(user_id: str | None = None) -> tuple[dict, dict]:
	"""判分用的两张表：`exerciseId → answerKey` 与 `exerciseId → knowledgePointId`。

	题库是常量；**模型现场出的题**存在 repository 的 `exercises` 集合里
	（判分发生在另一次请求，必须能把那批题找回来）。

	⚠️ 判分逻辑本身**一行没改** —— 仍然是 `grade_exercise` 按 `answerKey`
	逐题比对。这里只是让"被判分的题"多了"刚生成的那几道"，
	所以"判分是算式、不是模型觉得"这条纪律完好无损。
	"""
	answer_keys = dict(_ANSWER_KEYS)
	knowledge_points = {item["exerciseId"]: item["knowledgePointId"] for item in _EXERCISE_BANK}
	if _repository:
		for record in _repository.list("exercises"):
			if not isinstance(record, dict) or record.get("userId", "demo-user") != (user_id or resolve_user_id(None)):
				continue
			exercise_id = record.get("exerciseId")
			if not isinstance(exercise_id, str) or not exercise_id:
				continue
			if record.get("answerKey"):
				answer_keys[exercise_id] = record["answerKey"]
			knowledge_points[exercise_id] = record.get("knowledgePointId", "")
	return answer_keys, knowledge_points


def _generate_and_store(knowledge_point_name: str, count: int, excluded_ids=()) -> list[dict]:
	"""让模型针对该知识点出题；**含答案**的版本存仓库，返回可下发的题面（不含答案）。"""
	owner = resolve_user_id(None)
	cache_key = exercise_cache.key(_repository, owner, knowledge_point_name, count)
	with exercise_cache.guard(cache_key):
		items = exercise_cache.get(cache_key, _repository, excluded_ids)
		if items is None:
			items = exercise_gen.generate_exercises(knowledge_point_name, count)
			if not items:
				return []
			if _repository:
				_repository.apply_batch([], [("exercises", item["exerciseId"], dict(item, userId=owner)) for item in items])
				exercise_cache.put(cache_key, items)
	# 只下发题面字段：`answerKey` / `explanation` **绝不出后端**
	return [{key: item[key] for key in _CLIENT_FIELDS if key in item} for item in items]


def configure_exercises_repository(repository: JsonRepository) -> None:
	global _repository
	_repository = repository


def _resolve_knowledge_point_id(raw: str | None) -> str | None:
	"""把 `knowledgePointId` 参数**容错**成题库里真实存在的知识点 id。

	为什么需要：前端的错题诊断给出的是知识点**名字**（「图算法」「二叉树遍历」…），
	不是 id。若要求前端自己维护一份"名字 → id"的映射，就会有两处真源、必然漂移
	（题库改一个名字，前端就悄悄少出题）。题库就在本模块，在这里统一解析最稳。

	匹配顺序：精确 id → 精确名字 → 互相包含（「二叉树遍历」↔「二叉树遍历基础」）
	→ 共同二字前缀（「递归调用」↔「递归基础先修」）。
	**认不出就返回 None**（= 不加过滤）→ 走默认题集，
	而不是返回空列表把练习页整空 —— 宁可回落到默认题，也不要给一个打不开的页面。
	"""
	if raw is None:
		return None
	value = raw.strip()
	if not value:
		return None
	bank = list(_EXERCISE_BANK)
	for item in bank:
		if item.get("knowledgePointId") == value:
			return value
	for item in bank:
		if item.get("knowledgePointName") == value:
			return item.get("knowledgePointId")
	for item in bank:
		name = item.get("knowledgePointName") or ""
		if name and (value in name or name in value):
			return item.get("knowledgePointId")
	if len(value) >= 2:
		for item in bank:
			name = item.get("knowledgePointName") or ""
			if len(name) >= 2 and name[:2] == value[:2]:
				return item.get("knowledgePointId")
	return None


@exercises_api.get("/api/v1/exercises/<set_id>")
def get_exercise_set(set_id: str):
	if set_id not in EXERCISE_SET_IDS:
		return jsonify({"errorCode": "NOT_FOUND", "message": "exercise set not found", "details": {"setId": set_id}}), 404
	raw_point = (request.args.get("knowledgePointId") or "").strip()
	knowledge_point_id = _resolve_knowledge_point_id(raw_point)
	difficulty = request.args.get("difficulty")
	excluded_ids = request.args.getlist("excludeExerciseId")
	# 记录调用方**是否显式传了 count**。
	# 原缺陷：`count` 只被"解析并校验"，但无过滤条件时直接返回整份 `_DEMO_EXERCISES`，
	# count 被**静默忽略** —— `?count=1` 照样返回 3 道题（实测）。
	# 这是"参数接受了但不生效"，比不声明该参数更糟：调用方以为筛选生效了。
	# 只有显式传入时才截断，默认行为（演示基线 3 题）保持不变。
	count_explicit = request.args.get("count") is not None
	try:
		count = int(request.args.get("count", 3))
		if count < 1:
			raise ValueError
	except ValueError:
		return jsonify({"errorCode": "BAD_REQUEST", "message": "count must be an integer", "details": None}), 400
	source_mode = request.args.get("sourceMode", "general")
	if source_mode not in ("general", "materials"):
		return jsonify({"errorCode": "BAD_REQUEST", "message": "sourceMode must be general or materials", "details": None}), 400
	if source_mode == "materials":
		return _material_set(set_id, raw_point, count)
	# `generate=1` 才允许现场出题 —— **默认行为一个字节都不变**，
	# 演示基线那条路径（不带参数）永远不会触发模型调用。
	generate_requested = (request.args.get("generate") or "").strip().lower() in ("1", "true", "yes")
	# ⚠️ 这里必须用 **raw_point** 判"调用方到底有没有给筛选条件"。
	# 用解析后的 `knowledge_point_id` 会踩坑：知识点解析不出来时它是 None，
	# 于是 `has_filter` 为假 → 直接走演示分支返回那 3 道题，
	# **后面的出题分支永远不可达**（实测过一次：0.0s 返回演示题，压根没调模型）。
	has_filter = bool(raw_point or difficulty or excluded_ids)
	if set_id == DEMO_EXERCISE_SET_ID and not has_filter:
		exercises = _DEMO_EXERCISES[:count] if count_explicit else _DEMO_EXERCISES
	else:
		exercises = []
		# 题库覆盖不到这个知识点（固定题库只有 6 个知识点）→ 允许时让模型现场出题。
		# 这正是"每个人薄弱的知识点不一样，要有针对性的题目"那个短板的解法：
		# 覆盖面从 6 个知识点扩到**任意**知识点。
		# 判定依据是 `knowledge_point_id is None`（解析不出 = 题库里没有），
		# 而不是"select 返回空" —— 后者在无过滤时会返回题库前 N 题，永远不为空。
		generation_attempted = bool(raw_point and knowledge_point_id is None and generate_requested)
		if generation_attempted:
			exercises = _generate_and_store(raw_point, count, excluded_ids)
		if not exercises:
			if generation_attempted:
				# ⚠️ 已经为这个知识点尝试过现场出题、但一道都没拿到时，**绝不能回落**到
				# `select_exercises(_EXERCISE_BANK, None, ...)`：不带知识点过滤的它
				# 返回的是**题库前 N 题**（正是二叉树那几道），等于把**另一个知识点**
				# 的题冒充成本次请求的题 —— 前端拿不到任何异常信号，用户看到的是
				# "换了个知识点，题却没变"。实测反馈的
				# 「第三次加载十几秒后依旧是第二次的题目和做题结果」就出在这条静默替换上
				# （模型出题失败 / 校验不过 → 被悄悄换成默认题）。
				# 如实返回空列表 + 明确标记，让前端提示"出题失败，请重试"，
				# 而不是给一份答非所问的题。
				return jsonify({
					"setId": set_id,
					"exercises": [],
					"generationFailed": True,
					"message": "针对该知识点现场出题失败，请重试。",
				})
			exercises = select_exercises(_EXERCISE_BANK, knowledge_point_id, difficulty, count, excluded_ids)
	response = {"setId": set_id, "exercises": exercises}
	if _repository and exercises and any(item.get("source") == "llm" for item in exercises):
		trace_id = f"trace-select-{uuid.uuid4().hex}"
		_repository.save("traces", trace_id, {"traceId": trace_id,
			"userId": resolve_user_id(request.args.get("userId")), "events": [{
				"agent": "exercise", "toolCalls": ["select_exercises"],
				"inputSummary": f"请求知识点 {raw_point}", "outputSummary": f"生成并入库 {len(exercises)} 道题",
				"evidenceIds": [], "stateVersion": 1, "timestamp": datetime.now(timezone.utc).isoformat(),
				"status": "completed", "stepId": "step-1", "inputStateVersion": 1, "outputStateVersion": 1}]})
		response["traceId"] = trace_id
	return jsonify(response)


def _material_set(set_id, point, count):
	from app.services import grounded_exercises as grounding
	owner = resolve_user_id(None)
	kb_id = request.args.get("kbId", "").strip()
	document_id = request.args.get("documentId", "").strip()
	if not point or not kb_id or len(point) > 200 or len(kb_id) > 200 or len(document_id) > 200 or count > 6:
		return jsonify({"errorCode": "BAD_REQUEST", "message": "资料题需指定知识点和资料库，题数为1至6", "details": None}), 400
	with PROFILE_LOCK, _repository.transaction():
		sources, failure = grounding.retrieve(_repository, owner, point, kb_id, document_id)
	if failure == "NOT_FOUND":
		return jsonify({"errorCode": "NOT_FOUND", "message": "资料不存在", "details": None}), 404
	response = {"setId": set_id, "exercises": [], "sourceMode": "materials",
		"kbId": kb_id, "documentId": document_id, "knowledgePointId": point}
	if not sources:
		return jsonify(dict(response, generationFailed=True, failureReason="INSUFFICIENT_MATERIALS",
			message="所选资料未检索到足够的相关原文，请补充资料或主动切换通用知识练习。"))
	cache_key = exercise_cache.key(_repository, owner, point, count, grounding.public_sources(sources))
	with exercise_cache.guard(cache_key):
		items = exercise_cache.get(cache_key, _repository, request.args.getlist("excludeExerciseId"))
		if items is None:
			items = grounding.generate(point, count, sources)
	if not items:
		return jsonify(dict(response, generationFailed=True, failureReason="GENERATION_FAILED",
			message="资料题生成失败或来源校验未通过，请重试；也可以主动切换通用知识练习。"))
	with PROFILE_LOCK, _repository.transaction():
		if not grounding.sources_current(_repository, owner, sources):
			return jsonify(dict(response, generationFailed=True, failureReason="SOURCE_CHANGED",
				message="出题期间资料已删除或变更，请重新选择资料。"))
		trace_id = f"trace-materials-{uuid.uuid4().hex}"
		trace = {"traceId": trace_id, "userId": owner, "events": [{
			"agent": "exercise", "toolCalls": ["retrieve_materials", "generate_grounded_exercises"],
			"inputSummary": f"资料库 {kb_id}，知识点 {point}",
			"outputSummary": f"生成 {len(items)} 道资料题，来源链接及原文引用已核对；答案仍需学习者核验",
			"evidenceIds": [], "sourceChunkIds": [s["chunkId"] for s in sources],
			"stateVersion": 1, "timestamp": datetime.now(timezone.utc).isoformat(),
			"status": "completed", "stepId": "step-1", "inputStateVersion": 1, "outputStateVersion": 1}]}
		_repository.apply_batch([], [("exercises", item["exerciseId"], dict(item, userId=owner))
			for item in items] + [("traces", trace_id, trace)])
		exercise_cache.put(cache_key, items)
	response.update(exercises=[{k: item[k] for k in _CLIENT_FIELDS if k in item} for item in items], traceId=trace_id)
	return jsonify(response)


@exercises_api.get("/api/v1/exercises/<exercise_id>/sources")
def get_exercise_sources(exercise_id):
	from app.services import grounded_exercises as grounding
	owner = resolve_user_id(None)
	with PROFILE_LOCK, _repository.transaction():
		item = _repository.get("exercises", exercise_id) if _repository else None
		if not item or item.get("userId", "demo-user") != owner:
			return jsonify({"errorCode": "NOT_FOUND", "message": "题目不存在", "details": None}), 404
		sources = item.get("sources", [])
		if not grounding.sources_current(_repository, owner, sources):
			return jsonify({"errorCode": "SOURCE_UNAVAILABLE", "message": "原始资料已删除或变更，无法展示本题原文依据", "details": None}), 410
		return jsonify({"exerciseId": exercise_id, "sources": [dict(s,
			text=_repository.get("chunks", s["chunkId"])["text"]) for s in sources]})


@exercises_api.post("/api/v1/exercises/<set_id>/submit")
def submit_exercises(set_id: str):
	if set_id not in EXERCISE_SET_IDS:
		return jsonify({"errorCode": "NOT_FOUND", "message": "exercise set not found", "details": {"setId": set_id}}), 404
	data, guard = json_object()
	if guard is not None:
		return guard
	# 身份解析：已登录用登录身份（忽略请求体里的 userId，防冒用）；
	# 未登录时才用请求体/演示身份。修复"登录后掌握度仍写进 demo-user"的缺陷。
	user_id = resolve_user_id(data.get("userId"))
	idempotency_key, guard = bounded_str(data.get("idempotencyKey"), "idempotencyKey",
										MAX_ID_CHARS)
	if guard is not None:
		return guard
	# answers 必须逐项校验：缺了"元素必须是对象"这条时，传 ["a"] / [1] / [None]
	# 会一路深入到判分逻辑才炸成 500。
	answers, guard = validate_answers(data.get("answers"))
	if guard is not None:
		return guard
	goal_id = data.get("goalId")
	goal = None
	if goal_id is not None:
		if not isinstance(goal_id, str) or not goal_id or len(goal_id) > MAX_ID_CHARS:
			return jsonify({"errorCode": "BAD_REQUEST", "message": "goalId格式无效", "details": None}), 400
		goal = _repository.get("workflows", goal_id) if _repository else None
		if not goal or goal.get("userId") != user_id or not goal.get("state", {}).get("coordination"):
			return jsonify({"errorCode": "NOT_FOUND", "message": "学习目标不存在", "details": None}), 404
		expected = data.get("goalStateVersion")
		if isinstance(expected, bool) or not isinstance(expected, int) or expected < 1:
			return jsonify({"errorCode": "BAD_REQUEST", "message": "目标交卷需要有效goalStateVersion", "details": None}), 400

	result_id = f"{user_id}:{set_id}:{idempotency_key}"
	request_fingerprint = hashlib.sha256(json.dumps({"answers":
		sorted((str(a["exerciseId"]), str(a.get("answer") or "").strip().upper()) for a in answers),
		"goalId": goal_id}, sort_keys=True).encode()).hexdigest()
	def replay(previous):
		if (previous.get("response", {}).get("goalId") != goal_id or
			previous.get("requestFingerprint", request_fingerprint) != request_fingerprint):
			return jsonify({"errorCode": "CONFLICT", "message": "该交卷标识已用于其他答案或目标", "details": None}), 409
		return jsonify(previous["response"])
	# 逐题解析必须真正经过 LLM。先做一次无锁幂等快查，避免用户重复点击时重复耗费模型调用；
	# 真正写入前仍会在 `_SUBMIT_LOCK` 内再次检查，幂等与掌握度更新语义不变。
	previous = _repository.get("submissions", result_id) if _repository else None
	if previous is not None:
		return replay(previous)
	def goal_conflict(repository):
		if not goal_id:
			return False
		current = repository.get("workflows", goal_id)
		refs = (current or {}).get("state", {}).get("inputRefs", {})
		profile = repository.get("profiles", user_id) or {}
		plan = repository.get("plans", refs.get("planId", "")) or {}
		return (not current or current.get("status") == "completed"
			or current.get("stateVersion") != data["goalStateVersion"]
			or refs.get("profileVersion", 0) != profile.get("profileVersion", 0)
			or refs.get("planVersion", 0) != plan.get("version", 0)
			or bool(current.get("state", {}).get("boundSubmissionId")))
	if goal_conflict(_repository):
		return jsonify({"errorCode": "CONFLICT", "message": "目标已变化或已交卷，请返回对话刷新目标", "details": None}), 409
	answer_keys, knowledge_points = _merged_grading_tables(user_id)
	question_records = list(_EXERCISE_BANK)
	if _repository:
		question_records.extend(item for item in _repository.list("exercises")
			if isinstance(item, dict) and item.get("userId", "demo-user") == user_id)
	questions_by_id = {str(item.get("exerciseId")): item for item in question_records
		if isinstance(item.get("exerciseId"), str)}
	submitted_answers = {str(item.get("exerciseId")): str(item.get("answer") or "").strip().upper()
		for item in answers}
	# Unknown/private generated IDs must never expose answers via the review path.
	if any(key not in questions_by_id for key in submitted_answers):
		return jsonify({"errorCode": "NOT_FOUND", "message": "题目不存在或不属于当前账号", "details": None}), 404
	if goal:
		target = goal["state"]["coordination"].get("knowledgePointId", "")
		allowed = {target, _resolve_knowledge_point_id(target)}
		if not target or any(questions_by_id[key].get("knowledgePointId") not in allowed for key in submitted_answers):
			return jsonify({"errorCode": "CONFLICT", "message": "题目与当前目标知识点不一致，请从目标入口重新进入练习", "details": None}), 409
	review_explanations, llm_review_ids, pending_review = review_jobs.prepare(
		[questions_by_id[key] for key in submitted_answers if questions_by_id[key].get("source") != "materials"],
		submitted_answers, answer_keys)
	for key in submitted_answers:
		if questions_by_id[key].get("source") == "materials":
			review_explanations[key] = questions_by_id[key]["explanation"]
	# ⚠️ 整段"幂等检查 → 判分 → 掌握度回写 → 落盘"必须持锁串行执行。
	# 详见 `_SUBMIT_LOCK` 的注释：不加锁时并发重复提交会让掌握度增量叠加多次。
	# 把原逻辑收进内部函数再持锁调用（而不是整段缩进一层），
	# 是为了让这次改动的 diff 只落在两行上，便于复核。
	post_commit = []
	def _do_submit():
		repository = StagedRepository(_repository) if _repository else None
		if repository:
			previous = repository.get("submissions", result_id)
			if previous is not None:
				return replay(previous)
			if goal_conflict(repository):
				return jsonify({"errorCode": "CONFLICT", "message": "目标已变化或已交卷，请刷新目标", "details": None}), 409

		profile = repository.get("profiles", user_id) if repository else None
		if profile is None:
			return jsonify({"errorCode": "NOT_FOUND", "message": "profile not found", "details": {"userId": user_id}}), 404
		# 判分表、题目与 LLM 解析已在锁外准备；锁内只做确定性判分与持久化。
		correct_ids = {exercise_id for exercise_id, answer in submitted_answers.items()
			if exercise_id in answer_keys and answer == answer_keys[exercise_id]}

		old_scores = mastery_scores(profile)
		names = {item["exerciseId"]: item.get("knowledgePointName", "知识点理解")
			for item in question_records}
		assessment = grade_exercise(answers, answer_keys, knowledge_points,
			exercise_result_id=result_id, knowledge_point_names=names,
			old_mastery_by_point=old_scores)
		score = assessment.score
		# Keep the legacy primary-point response, while replanning explicitly
		# targets the weakest assessed point rather than the best answered one.
		report_point = assessment.dominant_knowledge_point()
		report_old = old_scores.get(report_point, 0)
		report_new = assessment.per_knowledge_mastery.get(report_point, report_old)
		replan_point = assessment.remediation_knowledge_point()
		replan_mastery = assessment.per_knowledge_mastery.get(replan_point, 0)
		replan_score = round(assessment.per_knowledge_accuracy.get(replan_point, 1) * 100, 2)
		response = {
			"userId": user_id,
			"submissionId": result_id,
			"assessment": assessment.to_dict(),
			"masteryUpdate": {"knowledgePointId": report_point, "oldScore": report_old,
				"newScore": report_new},
			"needReplan": False,
			"review": [{
				"exerciseId": exercise_id,
				"selectedAnswer": submitted_answers[exercise_id],
				"correctAnswer": answer_keys[exercise_id],
				"correct": exercise_id in correct_ids,
				"explanation": review_explanations.get(exercise_id)
					or questions_by_id.get(exercise_id, {}).get("explanation")
					or f"正确答案是 {answer_keys[exercise_id]}。",
				"explanationSource": "materials" if questions_by_id.get(exercise_id, {}).get("source") == "materials"
					else ("llm" if exercise_id in llm_review_ids else "fallback"),
				"sources": questions_by_id.get(exercise_id, {}).get("sources", []),
			} for exercise_id in submitted_answers if exercise_id in answer_keys],
		}
		if goal_id:
			response["goalId"] = goal_id
		handoff = replan_request(assessment)
		response["replanDecision"] = handoff["decision"]
		response["needReplan"] = response["replanDecision"]["needReplan"]
		if repository:
			trace_id = f"trace-submit-{user_id}:{set_id}:{idempotency_key}"
			evidence_id = f"evidence-submit-{user_id}:{set_id}:{idempotency_key}"
			response["traceId"] = trace_id
			response["evidenceIds"] = [evidence_id]
			timestamp = datetime.now(timezone.utc)
			#: 本次提交是否**真的**重排了计划（供 trace 补记 planner 事件）。
			replanned: bool = False
			profile_model_dict = persist_mastery(repository, user_id, assessment,
					evidence_id, result_id, timestamp)
			from app.api.wrong_book import record_submission
			review_questions = []
			for key in submitted_answers:
				if key in questions_by_id:
					question = dict(questions_by_id[key])
					question["explanation"] = review_explanations.get(key, question.get("explanation", ""))
					review_questions.append(question)
			record_submission(repository, user_id,
				review_questions,
				submitted_answers, correct_ids)
			wrong_ids = {item.get("exerciseId") for item in repository.list("wrong_book")
				if isinstance(item, dict) and item.get("userId") == user_id}
			for item in response["review"]:
				item["inWrongBook"] = item["exerciseId"] in wrong_ids
			if profile_model_dict:
				if response["needReplan"]:
					plans = [item for item in repository.list("plans")
						if plan_belongs_to(item, user_id)]
					plan = next((item for item in plans if item.get("planId") == "plan-demo-001"), None)
					plan = plan or (plans[0] if plans else None)
					if plan is not None:
						outcome = execute_assessment_replan(repository, user_id, plan["planId"],
							handoff, [evidence_id])
						if outcome["changed"]:
							replanned = True
							response.update({"plan": outcome["plan"], "planDiff": outcome["planDiff"]})
			events: list[dict] = [{
				"agent": "assessment", "toolCalls": ["grade_exercise"] + (["update_mastery"] if profile_model_dict else []),
				"inputSummary": f"提交题集 {set_id}", "outputSummary": f"得分 {score}",
				"evidenceIds": [evidence_id], "stateVersion": 1, "timestamp": timestamp.isoformat(),
				"status": "completed", "sessionId": data.get("sessionId"), "stepId": "step-1",
				"inputStateVersion": 1, "outputStateVersion": 1}]
			if replanned:
				# ★ 计划确实被重排了，就必须在 trace 里留痕。
				#
				# 原实现只写 assessment 一条事件 —— 于是"计划 V1→V2、时长
				# [30,30]→[45,15]"这件事在决策轨迹里**完全看不到**，
				# 而 trace 正是本项目"可复核的 Agent 决策链"这个卖点的落点。
				# 实测：提交后 trace 里只有 assessment/grade_exercise，
				# 找不到任何 planner 痕迹。
				events.append({
					"agent": "planner", "toolCalls": ["replan_learning_path"],
					"inputSummary": f"知识点 {replan_point}，掌握度 {old_scores.get(replan_point, 0)} → {replan_mastery}，该点得分 {replan_score}",
					"outputSummary": f"计划重排为 V{response['plan'].get('version')}",
					"evidenceIds": [evidence_id], "stateVersion": 2,
					"timestamp": datetime.now(timezone.utc).isoformat(),
					"status": "completed", "sessionId": data.get("sessionId"), "stepId": "step-2",
					"inputStateVersion": 1, "outputStateVersion": 2})
			trace = {"traceId": trace_id, "userId": user_id, "events": events}
			repository.save("traces", trace_id, trace)
			if goal_id:
				from app.services.learning_context import bind_submission
				bind_submission(repository, repository.get("workflows", goal_id), response, events)
			submission_record = {"response": response, "reviewToken": uuid.uuid4().hex,
				"requestFingerprint": request_fingerprint, "createdAt": timestamp.isoformat()}
			repository.save("submissions", result_id, submission_record)
			for exercise_id in submitted_answers:
				repository.save("exercise_usage", f"{user_id}:{exercise_id}", {
					"userId": user_id, "exerciseId": exercise_id, "submissionId": result_id,
					"createdAt": timestamp.isoformat()})
		http_response = jsonify(response)
		if repository is not None:
			repository.commit()
			if pending_review is not None:
				wrong_snapshots = {key: repository.get("wrong_book", f"{user_id}:{key}")
					for key in submitted_answers}
				post_commit.append((pending_review, repository.repository, result_id,
					submission_record, wrong_snapshots))
		return http_response

	with _SUBMIT_LOCK:
		with _repository.transaction():
			response = _do_submit()
		for job in post_commit:
			review_jobs.attach(*job)
		return response
