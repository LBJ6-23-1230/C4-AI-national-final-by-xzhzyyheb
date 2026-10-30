"""Protect latency shortcuts without bypassing evidence or mutation boundaries."""
from app.agent import chat_llm


def test_profile_shortcut_keeps_evidence_and_uses_one_model_call(monkeypatch):
    monkeypatch.setenv("DASHSCOPE_API_KEY", "test-key")
    calls = []

    def complete(system, prompt, **kwargs):
        calls.append((prompt, kwargs))
        return "当前递归掌握度为42，需要加强。"

    monkeypatch.setattr(chat_llm, "_call_llm", complete)
    result = chat_llm.chat("帮我看看我的薄弱知识点", user_id="latency-user",
                           user_context={"userId": "latency-user", "mastery": [
                               {"knowledgePointName": "递归", "masteryScore": 42}]})
    assert len(calls) == 1
    assert calls[0][1]["request_type"] == "weakness"
    assert "递归" in calls[0][0] and "42" in calls[0][0]
    assert result["llmUsed"] is True
    assert result["intent"] == "analyze_weakness"


def test_modified_shortcut_still_uses_classifier(monkeypatch):
    monkeypatch.setenv("DASHSCOPE_API_KEY", "test-key")
    calls = []

    def complete(*args, **kwargs):
        calls.append(kwargs)
        return '{"intent":"query_tasks"}'

    monkeypatch.setattr(chat_llm, "_call_llm", complete)
    assert chat_llm.detect_intent("不要帮我看看我的薄弱知识点，只看任务") == ("query_tasks", True)
    assert len(calls) == 1


def test_shortcut_failure_preserves_honest_fallback(monkeypatch):
    monkeypatch.setenv("DASHSCOPE_API_KEY", "test-key")

    def fail(*args, **kwargs):
        raise TimeoutError()

    monkeypatch.setattr(chat_llm, "_call_llm", fail)
    result = chat_llm.chat("帮我看看我的薄弱知识点", user_id="latency-empty",
                           user_context={"userId": "latency-empty"})
    assert result["llmUsed"] is False
    assert "没有足够的掌握度或有效错题证据" in result["reply"]
    assert "降级" not in result["reply"]


def test_pending_cancel_skips_classifier_and_preserves_session_scope(monkeypatch):
    monkeypatch.setenv("DASHSCOPE_API_KEY", "test-key")
    key = ("latency-user", "latency-session")
    chat_llm._PENDING_PROFILE_UPDATES[key] = {"user": {"examDate": "2027-01-01"}}

    def unexpected(*args, **kwargs):
        raise AssertionError("confirmation must not call intent model")

    monkeypatch.setattr(chat_llm, "detect_intent", unexpected)
    try:
        result = chat_llm.chat("取消更新", user_id=key[0], session_id=key[1])
        assert result["intent"] == "update_profile"
        assert not result["profileUpdates"]
        assert key not in chat_llm._PENDING_PROFILE_UPDATES
    finally:
        chat_llm._PENDING_PROFILE_UPDATES.pop(key, None)
