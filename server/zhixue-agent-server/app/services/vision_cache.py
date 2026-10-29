"""Small, owner-scoped, in-memory cache and single-flight for identical images.

Only complete, validated answers are retained. No images or credentials are
stored in keys, and no failed/partial result prevents a fresh recognition.
"""
from collections import OrderedDict
from concurrent.futures import Future
import threading
import time
import logging

_lock = threading.Lock()
_cache = OrderedDict()
_pending = {}
TTL_SECONDS = 300
MAX_ENTRIES = 32


def clear():
    with _lock:
        _cache.clear()


def resolve(key, compute, cacheable, timeout):
    started = time.monotonic()
    from app.services.chat_progress import emit
    with _lock:
        now = time.monotonic()
        for expired in [k for k, (deadline, _) in _cache.items() if deadline <= now]:
            _cache.pop(expired, None)
        if key in _cache:
            _cache.move_to_end(key)
            emit("vision_reused", "已找到本次图片的完整识别结果，正在整理")
            logging.getLogger("zhixue.llm").info("vision_cache outcome=hit elapsed_ms=%.1f", (time.monotonic() - started) * 1000)
            return _cache[key][1]
        future = _pending.get(key)
        leader = future is None
        if leader:
            # Bound bookkeeping as well as the model executor's own queue.
            if len(_pending) >= MAX_ENTRIES:
                raise RuntimeError("vision_capacity")
            future = _pending[key] = Future()
    if not leader:
        emit("vision_wait", "相同图片正在识别，正在等待结果，无需重复上传")
        return future.result(timeout=timeout)
    try:
        value = compute()
        if cacheable(value):
            with _lock:
                _cache[key] = (time.monotonic() + TTL_SECONDS, value)
                while len(_cache) > MAX_ENTRIES:
                    _cache.popitem(last=False)
        future.set_result(value)
        return value
    except BaseException as error:
        future.set_exception(error)
        raise
    finally:
        logging.getLogger("zhixue.llm").info("vision_cache outcome=computed elapsed_ms=%.1f", (time.monotonic() - started) * 1000)
        with _lock:
            _pending.pop(key, None)
