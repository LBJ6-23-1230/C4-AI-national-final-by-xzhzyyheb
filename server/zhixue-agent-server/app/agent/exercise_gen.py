# -*- coding: utf-8 -*-
"""按知识点**现场出题** —— 固定题库覆盖不到时的兜底。

## 为什么需要

`data/question_bank.json` 是固定题库（30 题 / **6 个知识点**）。
用户真正薄弱的知识点不可能只落在这 6 个里 —— 一旦落空，原行为是
"回落到演示那 3 道题"，也就是用户反馈的「**永远是那三个题目**」。

本模块让模型针对**任意知识点**出题，把覆盖面从"6 个知识点"扩到"任意"。

## ⚠️ 一条不能越的边界：模型只出题，**判分仍是确定性算式**

判分走 `app/tools/assessment_tools.grade_exercise`，按**存下来的 `answerKey`**
逐题比对，和模型没有任何关系。也就是说本题库与生成题的**判分口径完全一致**、
可复现、可断言。

这样"判断是算式，不是模型觉得"这条设计纪律**没有被打折**，
被放宽的只有一件小事：题从哪来。答辩时这正是最好讲的分层——
**"题库优先（可复现），覆盖不到时让模型出（并标注），判分始终是算式"**。

## 诚实边界（必须保留）

生成题的 `answerKey` 是模型给的，**存在出错的可能**。所以：
* 每题必须带 `explanation`（一句话说明为什么对），异常时它会被展示出来，可人工核对；
* 返回的题带 `source="llm"`，接口如实标注，前端据此提示"这组题由大模型生成"；
* 校验不过整批丢弃，宁可回落到题库默认题，**也不端出一批残缺的题**。
"""

from __future__ import annotations

import hashlib
import json
import logging
import re
import uuid
from contextvars import ContextVar
from typing import Any

from app.agent import chat_llm
from app.services.exercise_quality import is_subject_question
from app.services.exercise_math import normalize_calculation

MAX_GENERATE_COUNT = 6
avoid_questions = ContextVar('exercise_avoid_questions', default=())
generation_failure = ContextVar('exercise_generation_failure', default='')
logger = logging.getLogger('zhixue.exercise')


def _failure(reason):
	generation_failure.set(reason)
	logger.warning('exercise_generation_failed reason=%s', reason)
	return None


def failure_details():
	reason = generation_failure.get() or ('MODEL_NOT_CONFIGURED' if not generation_available() else 'GENERATION_FAILED')
	messages = {
		'MODEL_NOT_CONFIGURED': '出题服务尚未配置完成，请联系开发团队开通。',
		'MODEL_AUTH_FAILED': '出题服务连接异常，需要开发团队检查服务配置。',
		'MODEL_BUSY': '出题服务繁忙，请稍后重试。',
		'MODEL_TIMEOUT': '出题等待超时，请重新加载。',
		'MODEL_UNAVAILABLE': '暂时无法连接出题服务，请稍后重试。',
		'INVALID_QUESTION': '这次生成的题目未通过检查，请重新加载。',
		'INVALID_RESPONSE': '这次未能生成完整题目，请重新加载。',
	}
	return dict(failureReason=reason, message=messages.get(reason, '这次未能生成可用的新题，请重新加载或换个知识点。'))
_OPTION_LETTERS = ("A", "B", "C", "D")
_OPTION_RE = re.compile(r"^\s*([A-D])\s*[.、．:：]\s*(\S.*)$")


def generation_available() -> bool:
	"""是否具备出题能力（本质是"配没配 Key"）。"""
	return chat_llm.llm_ready()


def _slug(knowledge_point_name: str) -> str:
	"""把知识点名字压成可安全用作 id 片段的短串。

	中文知识点名不能直接进 id（长度、编码都不稳），所以取 sha1 前 10 位。
	这样同一知识点每次生成的 id 前缀相同，便于按知识点排查。
	"""
	digest = hashlib.sha1(knowledge_point_name.strip().encode("utf-8")).hexdigest()
	return digest[:10]


def _normalize_options(raw: Any) -> list[str] | None:
	"""校验并规范化选项：必须恰好 4 个，且形如 `A. xxx`。

	模型有时会把选项写成 `["根-左-右", ...]`（不带字母前缀），
	这里补上前缀；若有别的形状（个数不对、空串）一律判为不合格。
	"""
	if not isinstance(raw, list) or len(raw) != len(_OPTION_LETTERS):
		return None
	normalized: list[str] = []
	for index, item in enumerate(raw):
		text = str(item).strip()
		if not text:
			return None
		match = _OPTION_RE.match(text)
		body = match.group(2).strip() if match else text
		if not body:
			return None
		normalized.append(f"{_OPTION_LETTERS[index]}. {body}")
	return normalized


def _normalize_item(item: Any, knowledge_point_name: str, index: int,
					nonce: str) -> dict[str, Any] | None:
	"""把模型给出的一道题校验成题库同构的记录；不合格返回 None。"""
	if not isinstance(item, dict):
		return None
	stem = str(item.get("stem") or "").strip()
	if not stem or not is_subject_question(item):
		return None
	options = _normalize_options(item.get("options"))
	if options is None:
		return None
	answer = str(item.get("answer") or "").strip().upper()[:1]
	if answer not in _OPTION_LETTERS:
		return None
	explanation = str(item.get("explanation") or "").strip()
	return normalize_calculation({
		"exerciseId": f"llm-{_slug(knowledge_point_name)}-{nonce}-{index:02d}",
		"knowledgePointId": knowledge_point_name,
		"knowledgePointName": knowledge_point_name,
		"difficulty": "medium",
		"stem": stem,
		"options": options,
		"answerKey": answer,
		"explanation": explanation,
		"source": "llm",
	})


_SYSTEM_PROMPT = (
	"你是高校计算机课程的出题老师。只输出 JSON，不要任何解释性文字。"
)

_USER_PROMPT = """请针对知识点「{point}」出 {count} 道**单项选择题**，难度中等，考查概念理解与常见误区。

硬性要求：
1. 每题**恰好 4 个选项**，按 `A. xxx` 的格式书写；
2. `answer` 只能是 "A"/"B"/"C"/"D" 之一，且必须是**唯一的正确答案**；
3. 题干要具体、可判断，不要出现"以上都对""以上都不对"这类选项；
4. 禁止考资料要求“掌握/熟悉/了解”到何种程度，必须考实际概念、计算或应用。
5. `explanation` 用一句话说明为什么这个答案对，并点出最常见的错误理解。
6. 数值计算题先独立复算，确保四个选项中恰好有一个正确数值，answer 与解析一致。
   哈夫曼 WPL 题必须在题干明确列出全部叶子权值，并用逐次合并最小权值之和核对结果。

只输出如下 JSON（不要 markdown 代码块）：
{{"exercises":[{{"stem":"题干","options":["A. ...","B. ...","C. ...","D. ..."],"answer":"A","explanation":"..."}}]}}"""

_REVIEW_SYSTEM_PROMPT = (
	"你是严谨的高校课程助教。只输出 JSON；必须依据题干、全部选项与标准答案讲解，"
	"不得更改标准答案，不得省略错误选项分析。"
)

_REVIEW_USER_PROMPT = """请为下面这组已经判分的单项选择题生成详细解析。

每题解析必须包含：
1. 正确选项为什么正确，给出关键概念或推导过程；
2. 其余每个选项为什么不成立；
3. 结合用户选择指出容易混淆之处和一个可操作的记忆/检查方法。
结合题干的实际术语、数据或执行步骤展开；遇到顺序或计算题，列出关键中间结果。
避免通用模板、重复题干和猜测用户为何出错。每题建议 100—170 个汉字。

题目 JSON：
{questions}

只输出如下 JSON（不要 markdown 代码块）：
{{"reviews":[{{"exerciseId":"题目ID","explanation":"详细解析"}}]}}"""


def _fallback_review_explanation(question: dict[str, Any], selected_answer: str,
								 correct_answer: str) -> str:
	"""LLM 暂不可用时的可核对兜底；不再返回“请重新核对概念”式空话。"""
	options = [str(item).strip() for item in question.get("options", []) if str(item).strip()]
	correct_option = next((item for item in options if item[:1] == correct_answer), correct_answer)
	other_options = [item for item in options if item[:1] != correct_answer]
	selected_note = (f"你选择了 {selected_answer}，应重点比较它与 {correct_answer} 在定义、"
		"适用条件和执行顺序上的差别。" if selected_answer and selected_answer != correct_answer
		else "你的选择与标准答案一致，仍建议用定义逐项排除，避免只靠记忆字母。")
	return (f"标准答案是 {correct_option}。判断这道题时，应先锁定题干考查的核心定义，再把选项逐一代入；"
		f"其余选项（{'；'.join(other_options) or '无'}）至少有一处不符合题干限定，不能作为标准答案。"
		f"{selected_note}复习时请用“定义—条件—结论”三步重新验证，并说明每个错误选项错在哪里。")


def generate_review_explanations(questions: list[dict[str, Any]],
								 submitted_answers: dict[str, str],
								 answer_keys: dict[str, str]) -> tuple[dict[str, str], set[str]]:
	"""一次 LLM 调用批量生成逐题详解，失败时返回信息完整、且不冒充 AI 的兜底解析。"""
	requested: list[dict[str, Any]] = []
	by_id: dict[str, dict[str, Any]] = {}
	for question in questions:
		exercise_id = str(question.get("exerciseId") or "")
		if exercise_id not in submitted_answers or exercise_id not in answer_keys:
			continue
		by_id[exercise_id] = question
		requested.append({
			"exerciseId": exercise_id,
			"stem": question.get("stem", ""),
			"options": question.get("options", []),
			"selectedAnswer": submitted_answers[exercise_id],
			"correctAnswer": answer_keys[exercise_id],
		})

	result: dict[str, str] = {}
	llm_ids: set[str] = set()
	if requested and generation_available():
		try:
			content = chat_llm._call_llm(
				_REVIEW_SYSTEM_PROMPT,
				_REVIEW_USER_PROMPT.format(
					questions=json.dumps(requested, ensure_ascii=False, separators=(",", ":"))),
				temperature=0.2,
				max_tokens=min(3600, 350 + len(requested) * 420),
				response_json=True,
				request_type="review",
			)
			parsed = chat_llm.extract_json(content)
			rows = parsed.get("reviews") if isinstance(parsed, dict) else None
			if isinstance(rows, list):
				for row in rows:
					if not isinstance(row, dict):
						continue
					exercise_id = str(row.get("exerciseId") or "")
					explanation = str(row.get("explanation") or "").strip()
					if exercise_id in by_id and len(explanation) >= 40:
						result[exercise_id] = explanation
						llm_ids.add(exercise_id)
		except Exception:  # noqa: BLE001 -- 解析失败不能让确定性判分与交卷失败
			pass

	for exercise_id, question in by_id.items():
		if exercise_id not in result:
			result[exercise_id] = _fallback_review_explanation(
				question, submitted_answers[exercise_id], answer_keys[exercise_id])
	return result, llm_ids


def generate_exercises(knowledge_point_name: str, count: int) -> list[dict[str, Any]] | None:
	"""让模型针对该知识点出题。

	返回题库同构的记录列表；**任何一步不达标都返回 None**（调用方回落到题库默认题）。
	不抛异常：出题失败不该把练习页打挂。
	"""
	point = (knowledge_point_name or "").strip()
	generation_failure.set('')
	from app.agent.knowledge import valid_knowledge_term
	if not point or not valid_knowledge_term(point) or count < 1:
		return _failure('INVALID_QUESTION')
	wanted = min(count, MAX_GENERATE_COUNT)
	if not generation_available():
		return _failure('MODEL_NOT_CONFIGURED')

	try:
		content = chat_llm._call_llm(
			_SYSTEM_PROMPT,
			_USER_PROMPT.format(point=point, count=wanted) +
			'\n本轮编号：' + uuid.uuid4().hex + '\n请更换情境和考查角度，禁止重复以下已发题干：\n' +
			json.dumps(list(avoid_questions.get())[-40:], ensure_ascii=False),
			temperature=0.6,
			max_tokens=min(4000, 900 + wanted * 500),
			response_json=True,
			request_type="exercise",
		)
	except Exception as error:
		status = getattr(error, 'status_code', None)
		reason = ('MODEL_AUTH_FAILED' if status in (401, 403) else 'MODEL_BUSY' if status == 429
			else 'MODEL_TIMEOUT' if isinstance(error, TimeoutError) or type(error).__name__ == 'APITimeoutError'
			else 'MODEL_UNAVAILABLE')
		return _failure(reason)

	parsed = chat_llm.extract_json(content)
	if not isinstance(parsed, dict):
		return _failure('INVALID_RESPONSE')
	raw_items = parsed.get("exercises")
	if not isinstance(raw_items, list):
		return _failure('INVALID_RESPONSE')

	items: list[dict[str, Any]] = []
	seen_stems: set[str] = set()
	nonce = uuid.uuid4().hex[:6]
	for raw in raw_items:
		item = _normalize_item(raw, point, len(items) + 1, nonce)
		if item is None:
			continue
		key = item["stem"]
		if key in seen_stems:
			continue
		seen_stems.add(key)
		items.append(item)
		if len(items) >= wanted:
			break

	return items if items else _failure('INVALID_QUESTION')
