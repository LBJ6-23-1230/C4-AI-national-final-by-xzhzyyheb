from contextlib import contextmanager
from types import SimpleNamespace as NS
import json
import threading
import time

import pytest

from app import create_app
from app.agent import semantic
from app.api import exercises
from app.services import llm_runtime as runtime, llm_health, exercise_cache
from app.model_adapters.qwen_adapter import QwenAdapter


def response(text="OK"):
    return NS(choices=[NS(message=NS(content=text), finish_reason="stop")], usage=NS(total_tokens=7))


@pytest.mark.parametrize("status,success,calls", [(429, True, 2), (503, True, 2), (401, False, 1),
    (400, False, 1), (429, False, 2), (500, False, 2)])
def test_retry_only_transient_once_with_private_metrics(monkeypatch, caplog, status, success, calls):
    attempts = []
    class Failed(Exception):
        status_code = status
    class Client:
        def with_options(self, **kwargs):
            assert kwargs["max_retries"] == 0
            return self
        @property
        def chat(self):
            return NS(completions=self)
        def create(self, **kwargs):
            attempts.append(kwargs)
            if success and len(attempts) > 1:
                return response()
            raise Failed("sk-secret private question")
    @contextmanager
    def connection(*a, **kw):
        yield Client()
    monkeypatch.setattr(runtime, "client", connection)
    started = time.monotonic()
    with caplog.at_level("INFO", logger="zhixue.llm"):
        if success:
            assert runtime.request("test", {"model": "model", "messages": "private question"}, budget=0.5)
        else:
            with pytest.raises(Failed):
                runtime.request("test", {"model": "model", "messages": "private question"}, budget=0.5)
    assert time.monotonic() - started < 0.7
    assert len(attempts) == calls
    assert "sk-secret" not in caplog.text and "private question" not in caplog.text
    record = json.loads([r.message for r in caplog.records if r.name == "zhixue.llm"][-1])
    assert record["retries"] == calls - 1
    if success:
        assert record["tokens"] == 7 and record["finish_reason"] == "stop"


def test_budget_includes_slow_transport(monkeypatch):
    release = threading.Event()
    class Client:
        @property
        def chat(self):
            return NS(completions=NS(create=self.create))
        def create(self, **kw):
            release.wait(2)
            return response()
    @contextmanager
    def connection(*a, **kw):
        yield Client()
    monkeypatch.setattr(runtime, "client", connection)
    started = time.monotonic()
    try:
        with pytest.raises(TimeoutError):
            runtime.request("test", {"model": "m"}, budget=0.05)
        assert time.monotonic() - started < 0.3
    finally:
        release.set()


def test_clients_reused_and_config_changes_rebuild(monkeypatch):
    import openai
    runtime.clear_clients()
    built = []
    class Client:
        def __init__(self, **kwargs):
            built.append(kwargs)
        @property
        def chat(self):
            return NS(completions=NS(create=lambda **kw: response()))
        def close(self):
            pass
    monkeypatch.setattr(openai, "OpenAI", Client)
    try:
        with runtime.client("first", "https://example.test", 2) as first:
            pass
        with runtime.client("first", "https://example.test", 2) as again:
            assert first is again
        with runtime.client("second", "https://example.test", 2) as changed:
            assert changed is not first
        with runtime.client("second", "https://example.test", 3):
            pass
        for _ in range(2):
            runtime.request("test", {"model": "m"}, api_key="first", base_url="https://example.test", budget=2)
        assert len(built) == 3
        assert all(settings["max_retries"] == 0 for settings in built)
        assert all("first" not in str(k) and "second" not in str(k) for k in runtime._clients)
    finally:
        runtime.clear_clients()


def test_decision_budget_is_configurable_and_logs_fallback(monkeypatch, caplog):
    monkeypatch.setenv("LLM_DECISION_TIMEOUT_SECONDS", "0.05")
    monkeypatch.setenv("LLM_TIMEOUT_SECONDS", "30")
    release = threading.Event()
    adapter = QwenAdapter(completion=lambda _: release.wait(1))
    assert adapter.timeout_seconds == 0.05
    try:
        with caplog.at_level("INFO"):
            assert adapter.safe_decide({}) is None
        assert '"source":"fallback"' in caplog.text
    finally:
        release.set()


def test_201_embeddings_batched_at_ten_and_sorted(monkeypatch):
    monkeypatch.setenv("DASHSCOPE_API_KEY", "test")
    batches = []
    def request(kind, payload, **kwargs):
        batches.append(len(payload["input"]))
        return NS(data=[NS(index=i, embedding=[float(payload["input"][i]), 1.0])
                        for i in reversed(range(len(payload["input"])))])
    monkeypatch.setattr(runtime, "request", request)
    result = semantic.encode([str(i) for i in range(201)])
    assert [v[0] for v in result] == list(range(201))
    assert batches == [10] * 20 + [1]
    chunks = [{"chunkId": str(i), "text": str(i)} for i in range(200)]
    _, mode = semantic.rerank(chunks, "0", {str(i): 0 for i in range(200)})
    assert mode == "hybrid:semantic+keyword+tag"


def test_health_is_passive_cached_throttled_and_config_scoped(tmp_path, monkeypatch):
    monkeypatch.setenv("DASHSCOPE_API_KEY", "test")
    monkeypatch.setattr(llm_health, "_state", {})
    monkeypatch.setattr(llm_health, "_last_probe", 0)
    monkeypatch.setattr(llm_health, "_inflight", False)
    calls = []
    monkeypatch.setattr(runtime, "request", lambda *a, **k: calls.append(1) or response())
    client = create_app(tmp_path / "health.json").test_client()
    for _ in range(5):
        state = client.get("/api/agent/health").get_json()
        assert state["configured"] is True and state["verified"] is None
    assert calls == []
    assert client.post("/api/agent/health").status_code == 401
    registration = client.post("/api/v1/auth/register", json={"phone": "13900009821", "nickname": "health"}).get_json()
    headers = {"Authorization": f"Bearer {registration['token']}"}
    assert client.post("/api/agent/health", headers=headers).get_json()["verified"] is True
    assert client.post("/api/agent/health", headers=headers).status_code == 429
    assert len(calls) == 1
    assert client.get("/api/agent/health").get_json()["verified"] is True
    monkeypatch.setenv("DASHSCOPE_API_KEY", "changed")
    assert client.get("/api/agent/health").get_json()["verified"] is None


def test_generated_cache_owner_usage_expiry_and_exclusions(tmp_path, monkeypatch):
    client = create_app(tmp_path / "cache.json").test_client()
    exercise_cache.clear()
    calls = []
    def generate(point, count):
        calls.append(point)
        return [{"exerciseId": f"q-{len(calls)}", "knowledgePointId": point,
                 "knowledgePointName": point, "difficulty": "medium", "stem": "question",
                 "options": ["A. a", "B. b", "C. c", "D. d"], "answerKey": "A",
                 "explanation": "explanation", "source": "llm"}]
    monkeypatch.setattr(exercises.exercise_gen, "generate_exercises", generate)
    url = "/api/v1/exercises/set-demo-binary-tree-001?knowledgePointId=uncatalogued&generate=1&count=1"
    first = client.get(url).get_json()["exercises"]
    started = time.monotonic()
    assert client.get(url).get_json()["exercises"] == first
    assert time.monotonic() - started < 1
    assert len(calls) == 1
    repo = exercises._repository
    foreign_key = exercise_cache.key(repo, "another-user", "uncatalogued", 1)
    assert exercise_cache.get(foreign_key, repo) is None
    payload = {"idempotencyKey": "used", "answers": [{"exerciseId": "q-1", "answer": "A"}]}
    assert client.post("/api/v1/exercises/set-demo-binary-tree-001/submit", json=payload).status_code == 200
    assert client.get(url).get_json()["exercises"] != first
    assert len(calls) == 2
    assert client.get(url + "&excludeExerciseId=q-2").get_json()["exercises"][0]["exerciseId"] == "q-3"
    monkeypatch.setattr(exercise_cache, "TTL_SECONDS", -1)
    exercise_cache.clear()
    client.get(url)
    client.get(url)
    assert len(calls) == 5
