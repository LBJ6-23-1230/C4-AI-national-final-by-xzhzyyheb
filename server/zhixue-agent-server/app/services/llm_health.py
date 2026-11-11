"""Passive health reads; explicitly requested, authenticated probes are throttled."""
from datetime import datetime, timezone
import threading
import time

from app.agent import chat_llm
from app.services import llm_runtime

_lock = threading.Lock()
_state = {}
_last_probe = 0.0
_inflight = False


def status():
    configured = chat_llm.llm_ready()
    config = (llm_runtime.fingerprint(), chat_llm.llm_model())
    with _lock:
        state = dict(_state) if _state.get("config") == config else {}
        fresh = bool(state and time.monotonic() - state.get("at", 0) < 300)
        return {"configured": configured, "verified": state.get("verified") if configured and fresh else None,
                "checkedAt": state.get("checkedAt") if fresh else None,
                "verificationReason": state.get("reason") if fresh else "not_verified"}


def verify():
    global _last_probe, _inflight, _state
    if not chat_llm.llm_ready():
        return status(), 200
    with _lock:
        now = time.monotonic()
        limited = _inflight or (_last_probe and now - _last_probe < 60)
        if not limited:
            _last_probe, _inflight = now, True
    if limited:
        return dict(status(), verificationReason="rate_limited"), 429
    config = (llm_runtime.fingerprint(), chat_llm.llm_model())
    verified, reason = False, "probe_failed"
    try:
        response = llm_runtime.request("health_probe", {"model": config[1], "messages": [
            {"role": "user", "content": "Reply OK"}], "max_tokens": 4, "temperature": 0,
            **chat_llm._thinking_kwargs()}, budget=5)
        verified = bool(response.choices and response.choices[0].message.content)
        reason = "ok" if verified else "empty_response"
    except Exception:
        pass
    finally:
        with _lock:
            _state = {"config": config, "at": time.monotonic(), "verified": verified,
                      "checkedAt": datetime.now(timezone.utc).isoformat(), "reason": reason}
            _inflight = False
    return status(), 200
