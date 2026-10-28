"""Shared clients, bounded wall-clock budgets and privacy-safe model metrics."""
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FutureTimeout
from contextlib import contextmanager
import hashlib
import json
import logging
import math
import os
import threading
import time

logger = logging.getLogger("zhixue.llm")
_clients = OrderedDict()
_client_lock = threading.RLock()
_executor = ThreadPoolExecutor(max_workers=8, thread_name_prefix="llm")
_slots = threading.BoundedSemaphore(24)


def seconds(name, default, maximum=120):
    try:
        value = float(os.getenv(name, str(default)))
        return min(maximum, max(0.05, value)) if math.isfinite(value) else default
    except ValueError:
        return default


def configuration(api_key=None, base_url=None):
    return ((api_key if api_key is not None else os.getenv("DASHSCOPE_API_KEY", "")).strip(),
            (base_url or os.getenv("LLM_BASE_URL") or
             "https://dashscope.aliyuncs.com/compatible-mode/v1").rstrip("/"))


def fingerprint(api_key=None, base_url=None):
    key, base = configuration(api_key, base_url)
    return hashlib.sha256((base + "\0" + key).encode()).hexdigest()


@contextmanager
def client(api_key=None, base_url=None, timeout=30, retries=0):
    import openai
    key, base = configuration(api_key, base_url)
    cache_key = (base, hashlib.sha256(key.encode()).hexdigest(), timeout, retries)
    with _client_lock:
        entry = _clients.get(cache_key)
        if entry is None:
            entry = [openai.OpenAI(api_key=key, base_url=base, timeout=timeout, max_retries=retries), 0, False]
            _clients[cache_key] = entry
        _clients.move_to_end(cache_key)
        entry[1] += 1
        while len(_clients) > 8:
            _, old = _clients.popitem(last=False)
            old[2] = True
            if not old[1]:
                old[0].close()
    try:
        yield entry[0]
    finally:
        with _client_lock:
            entry[1] -= 1
            if entry[2] and not entry[1]:
                entry[0].close()


def clear_clients():
    """Tests/configuration maintenance: active clients close after release."""
    with _client_lock:
        for entry in _clients.values():
            entry[2] = True
            if not entry[1]:
                entry[0].close()
        _clients.clear()


def bounded(function, budget):
    if not _slots.acquire(blocking=False):
        raise RuntimeError("llm_capacity")
    try:
        future = _executor.submit(function)
    except BaseException:
        _slots.release()
        raise
    future.add_done_callback(lambda _: _slots.release())
    try:
        return future.result(timeout=budget)
    except FutureTimeout:
        future.cancel()
        raise TimeoutError("llm_budget") from None


def request(kind, payload, *, budget=None, api_key=None, base_url=None, operation="chat"):
    budget = budget if budget is not None else seconds("LLM_TIMEOUT_SECONDS", 30)
    started = time.monotonic()
    deadline = started + budget
    metrics = {"request_type": kind, "model": payload.get("model"), "http_status": None,
               "tokens": None, "finish_reason": None, "retries": 0, "fallback_reason": None,
               "queue_ms": None}

    def invoke():
        metrics["queue_ms"] = round((time.monotonic() - started) * 1000, 2)
        cache_timeout = seconds("LLM_EMBED_TIMEOUT_SECONDS", 30) if operation == "embeddings" else budget
        with client(api_key, base_url, timeout=cache_timeout, retries=0) as connection:
            for attempt in range(2):
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("llm_budget")
                try:
                    if operation == "embeddings":
                        response = connection.embeddings.create(**payload, timeout=remaining)
                    else:
                        response = connection.chat.completions.create(**payload, timeout=remaining)
                    metrics["http_status"] = 200
                    usage = getattr(response, "usage", None)
                    metrics["tokens"] = getattr(usage, "total_tokens", None)
                    choices = getattr(response, "choices", None)
                    metrics["finish_reason"] = getattr(choices[0], "finish_reason", None) if choices else None
                    return response
                except Exception as error:
                    status = getattr(error, "status_code", None)
                    metrics["http_status"] = status
                    if attempt or status not in (429, 500, 502, 503, 504):
                        metrics["fallback_reason"] = "http_error" if status else "transport_error"
                        raise
                    delay = 0.1
                    if deadline - time.monotonic() <= delay + 0.05:
                        raise TimeoutError("llm_budget") from None
                    metrics["retries"] = 1
                    time.sleep(delay)
    try:
        return bounded(invoke, budget)
    except TimeoutError:
        metrics["fallback_reason"] = "budget_exceeded"
        raise
    except Exception:
        metrics["fallback_reason"] = metrics["fallback_reason"] or "capacity_or_client_error"
        raise
    finally:
        # No exception messages, prompts, responses, user IDs or credentials.
        record = dict(metrics, elapsed_ms=round((time.monotonic() - started) * 1000, 2))
        logger.info(json.dumps(record, ensure_ascii=False))
