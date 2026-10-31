import json
import threading
import time
from types import SimpleNamespace as NS

import pytest

from app import create_app
from app.agent import chat_llm, semantic
from app.runtime.orchestrator import decide_next_step
from app.services import embedding_cache, llm_runtime, chat_progress


@pytest.fixture(autouse=True)
def clear_cache():
    embedding_cache.clear()
    yield
    embedding_cache.clear()


def test_forced_steps_skip_model_but_ambiguous_states_keep_it():
    calls = []
    def model(state):
        calls.append(state)
        return {"step": "diagnosis"}
    for state, step in [({"profile": {}}, "planner"),
                        ({"profile": {}, "plan": {}}, "exercise"),
                        ({"profile": {}, "plan": {}, "pendingSubmission": True}, "assessment")]:
        assert decide_next_step(state, model).step == step
    assert calls == []
    assert decide_next_step({}, model).step == "diagnosis"
    assert len(calls) == 1


def test_embedding_batches_overlap_and_preserve_order(monkeypatch):
    monkeypatch.setenv("DASHSCOPE_API_KEY", "test-parallel")
    rendezvous = threading.Barrier(3)
    calls = []
    def request(kind, payload, **kwargs):
        batch = payload["input"]
        calls.append(list(batch))
        rendezvous.wait(timeout=3)  # A sequential implementation cannot pass.
        return NS(data=[NS(index=i, embedding=[float(batch[i]), 1]) for i in reversed(range(len(batch)))])
    monkeypatch.setattr(llm_runtime, "request", request)
    texts = [str(i) for i in range(30)]
    vectors = semantic.encode(texts + ["0"])
    assert [v[0] for v in vectors] == list(range(30)) + [0]
    assert len(calls) == 3
    vectors[0][0] = -100
    assert semantic.encode(["0", "1"]) == [[0, 1], [1, 1]]
    assert len(calls) == 3


def test_embedding_invalidation_and_failure_retry(monkeypatch):
    monkeypatch.setenv("DASHSCOPE_API_KEY", "cache-key")
    calls = []
    def request(kind, payload, **kwargs):
        calls.append(payload["input"])
        return NS(data=[NS(index=i, embedding=[float(len(t)), 1]) for i, t in enumerate(payload["input"])])
    monkeypatch.setattr(llm_runtime, "request", request)
    assert semantic.encode(["first"])
    assert semantic.encode(["first", "new"])
    assert calls == [["first"], ["new"]]
    monkeypatch.setenv("EMBED_MODEL", "changed-model")
    assert semantic.encode(["first"])
    assert len(calls) == 3
    monkeypatch.setenv("DASHSCOPE_API_KEY", "changed-key")
    assert semantic.encode(["first"])
    assert len(calls) == 4
    monkeypatch.setattr(llm_runtime, "request", lambda *a, **k: NS(data=[NS(index=0, embedding=[float('nan')])]))
    assert semantic.encode(["invalid"]) is None
    monkeypatch.setattr(llm_runtime, "request", request)
    assert semantic.encode(["invalid"])


def events(response):
    return [(frame.split('\n')[0][7:], json.loads(frame.split('data: ', 1)[1]))
            for frame in response.get_data(as_text=True).split('\n\n') if 'data: ' in frame]


def test_stream_feedback_precedes_blocked_model_and_saves_once(tmp_path, monkeypatch):
    application = create_app(tmp_path / "stream.json")
    monkeypatch.setenv("DASHSCOPE_API_KEY", "stream-test")
    release = threading.Event()
    entered = threading.Event()
    def complete(*args, **kwargs):
        entered.set()
        assert release.wait(5)
        return "目前证据不足，请先完成练习。"
    monkeypatch.setattr(chat_llm, "_call_llm", complete)
    client = application.test_client()
    response = client.post('/api/agent/chat', headers={"Accept": "text/event-stream"},
                           json={"message": "帮我看看我的薄弱知识点", "sessionId": "stream-s"}, buffered=False)
    try:
        assert response.mimetype == 'text/event-stream'
        iterator = iter(response.response)
        assert b'accepted' in next(iterator)
        assert entered.wait(3)
        assert b'context' in next(iterator)
        assert b'analysis' in next(iterator)
    finally:
        release.set()
    remaining = b''.join(iterator).decode()
    assert 'event: result' in remaining
    rows = chat_llm.get_history()
    assert len([r for r in rows if r.get('session_id') == 'stream-s']) == 1


def test_stream_identity_errors_and_legacy_contract(tmp_path):
    client = create_app(tmp_path / "identity.json").test_client()
    demo_before = chat_llm.get_history('demo-user')
    account = client.post('/api/v1/auth/register', json={'password': 'test-pw-123456', "phone": "13900007891", "nickname": "测试"}).get_json()
    headers = {"Accept": "text/event-stream", "Authorization": "Bearer " + account['token']}
    result = events(client.post('/api/agent/chat', headers=headers,
        json={"message": "帮我看看我的薄弱知识点", "sessionId": "owned", "userId": "demo-user"}))
    assert result[-1][0] == 'result'
    assert len(chat_llm.get_history(account['user']['userId'])) == 1
    assert chat_llm.get_history('demo-user') == demo_before
    failure = events(client.post('/api/agent/chat', headers={"Accept": "text/event-stream"},
                                json={"message": "hello", "userId": account['user']['userId']}))
    assert failure[-1][0] == 'error' and failure[-1][1]['status'] == 404
    legacy = client.post('/api/agent/chat', json={"message": "今天我应该先学什么？"})
    assert legacy.is_json and legacy.get_json()['reply']


def test_stream_capacity_rejects_without_executing(tmp_path, monkeypatch):
    monkeypatch.setattr(chat_progress, '_slots', threading.BoundedSemaphore(0))
    client = create_app(tmp_path / 'capacity.json').test_client()
    before = chat_llm.get_history()
    response = client.post('/api/agent/chat', headers={"Accept": "text/event-stream"}, json={"message": "hello"})
    assert response.status_code == 503
    assert chat_llm.get_history() == before
