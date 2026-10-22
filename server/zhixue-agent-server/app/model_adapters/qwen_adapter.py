"""Provider-neutral Qwen-compatible adapter wrapper."""

from collections.abc import Callable, Mapping
import json
import os
from typing import Any

from app.model_adapters.llm import ModelAdapter, ModelAdapterError
from app.services import llm_runtime
import logging
logger = logging.getLogger("zhixue.decision")


class QwenAdapter(ModelAdapter):
	def __init__(self, completion: Callable[[Mapping[str, Any]], str] | None = None,
				 timeout_seconds: float | None = None, api_key: str | None = None,
				 base_url: str | None = None, model: str | None = None,
				 system_prompt: str | None = None) -> None:
		self.system_prompt = system_prompt
		self.completion = completion
		self.timeout_seconds = timeout_seconds if timeout_seconds is not None else min(
			llm_runtime.seconds("LLM_DECISION_TIMEOUT_SECONDS", 8), llm_runtime.seconds("LLM_TIMEOUT_SECONDS", 30))
		self.api_key = api_key if api_key is not None else os.getenv("DASHSCOPE_API_KEY", "")
		self.base_url = (base_url or os.getenv(
			"LLM_BASE_URL", "https://dashscope.aliyuncs.com/compatible-mode/v1")).rstrip("/")
		self.model = (
			(model or "").strip()
			or os.getenv("LLM_DECISION_MODEL", "").strip()
			or os.getenv("LLM_MODEL", "").strip()
			or "qwen3.8-flash"
		)

	@classmethod
	def from_environment(cls) -> "QwenAdapter | None":
		try:
			from dotenv import load_dotenv
			load_dotenv()
		except ImportError:
			pass
		if not os.getenv("DASHSCOPE_API_KEY", "").strip():
			return None
		return cls()

	def _thinking_disabled(self) -> bool:
		"""决策只输出一个 JSON，思维链纯属浪费延迟（且会占满超时预算）。

		默认关闭；`LLM_ENABLE_THINKING=1` 可打开。只有 DashScope 兼容端点接受
		`enable_thinking`，换成其它 OpenAI 兼容服务时不发这个字段，避免 400。
		"""
		if os.getenv("LLM_ENABLE_THINKING", "0").strip().lower() in (
				"1", "true", "yes", "on"):
			return False
		host = self.base_url.lower()
		return "dashscope" in host or "aliyuncs" in host

	def _http_completion(self, state: Mapping[str, Any]) -> str:
		if not self.api_key.strip():
			raise ModelAdapterError("model API key is not configured")
		payload = {
			"model": self.model,
			"messages": [
				{"role": "system", "content": self.system_prompt or (
					"你是学习工作流决策器。只返回 JSON，不要 markdown。"
					"JSON 必须包含 step，取值为 diagnosis、planner、exercise、assessment 或 finish。"
				)},
				{"role": "user", "content": json.dumps(dict(state), ensure_ascii=False)},
			],
			"temperature": 0,
			"response_format": {"type": "json_object"},
		}
		if self._thinking_disabled():
			payload["extra_body"] = {"enable_thinking": False}
		try:
			response = llm_runtime.request("decision", payload, budget=self.timeout_seconds,
				api_key=self.api_key, base_url=self.base_url)
			content = response.choices[0].message.content
		except Exception as error:
			raise ModelAdapterError("model request failed") from error
		if not isinstance(content, str) or not content.strip():
			raise ModelAdapterError("model response is empty")
		return content

	def complete(self, state: Mapping[str, Any]) -> str:
		try:
			response = (llm_runtime.bounded(lambda: self.completion(state), self.timeout_seconds)
				if self.completion else self._http_completion(state))
		except TimeoutError as error:
			raise ModelAdapterError("model request timed out") from error
		except ModelAdapterError:
			raise
		except Exception as error:
			raise ModelAdapterError("model request failed") from error
		if not isinstance(response, str) or not response.strip():
			raise ModelAdapterError("model response is empty")
		return response

	def safe_decide(self, state):
		try:
			decision = self.decide(state)
			logger.info('{"event":"decision","source":"model"}')
			return decision
		except ModelAdapterError:
			logger.info('{"event":"decision","source":"fallback","reason":"model_unavailable_or_invalid"}')
			return None
