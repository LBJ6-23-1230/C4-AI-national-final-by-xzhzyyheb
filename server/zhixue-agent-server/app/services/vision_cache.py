"""Small, owner-scoped, in-memory cache and single-flight for identical images.

Only complete, validated answers are retained. No images or credentials are
stored in keys, and no failed/partial result prevents a fresh recognition.
"""
from collections import OrderedDict
from concurrent.futures import Future
import threading
import time

_lock = threading.Lock()
_cache = OrderedDict()
_pending = {}
TTL_SECONDS = 300
MAX_ENTRIES = 32


def clear():
    with _lock:
        _cache.clear()


def resolve(key, compute, cacheable, timeout):
    with _lock:
        now = time.monotonic()
        for expired in [k for k, (deadline, _) in _cache.items() if deadline <= now]:
            _cache.pop(expired, None)
        if key in _cache:
            _cache.move_to_end(key)
            return _cache[key][1]
        future = _pending.get(key)
        leader = future is None
        if leader:
            # Bound bookkeeping as well as the model executor's own queue.
            if len(_pending) >= MAX_ENTRIES:
                raise RuntimeError("vision_capacity")
            future = _pending[key] = Future()
    if not leader:
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
        with _lock:
            _pending.pop(key, None)
