"""Bounded in-memory vectors and at most three concurrent embedding batches.

Only content hashes and immutable vectors are retained, never source text.
All results are validated before publishing to the cache; failures keep the
existing keyword fallback. Provider/key/model changes create a new namespace.
"""
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor
import hashlib
import threading
import time

_pool = ThreadPoolExecutor(max_workers=3, thread_name_prefix="embedding-batch")
_slots = threading.BoundedSemaphore(12)
_lock = threading.Lock()
_cache = OrderedDict()
MAX_ENTRIES = 2048
TTL_SECONDS = 900


def clear():
    with _lock:
        _cache.clear()


def cached_encode(texts, namespace, compute, deadline, batch_size):
    keys = [hashlib.sha256((namespace + "\0" + text).encode()).hexdigest() for text in texts]
    values = {}
    missing = {}
    with _lock:
        now = time.monotonic()
        for key in [k for k, (expiry, _) in _cache.items() if expiry <= now]:
            _cache.pop(key, None)
        for key, text in zip(keys, texts):
            if key in _cache:
                _cache.move_to_end(key)
                values[key] = _cache[key][1]
            else:
                missing[key] = text
    items = list(missing.items())
    batches = [items[i:i + batch_size] for i in range(0, len(items), batch_size)]
    # Sliding window bounds queue growth even for very large documents.
    pending = []
    fresh = {}
    try:
        for start in range(0, len(batches), 3):
            for batch in batches[start:start + 3]:
                if time.monotonic() >= deadline:
                    raise TimeoutError("embedding_budget")
                if not _slots.acquire(blocking=False):
                    raise RuntimeError("embedding_capacity")
                try:
                    future = _pool.submit(compute, [text for _, text in batch])
                except BaseException:
                    _slots.release()
                    raise
                future.add_done_callback(lambda _: _slots.release())
                pending.append((batch, future))
            for batch, future in pending:
                result = future.result(timeout=max(0, deadline - time.monotonic()))
                if len(result) != len(batch):
                    raise ValueError("embedding_count")
                fresh.update((key, tuple(vector)) for (key, _), vector in zip(batch, result))
            pending.clear()
        values.update(fresh)
        vectors = [values[key] for key in keys]
        if not vectors or any(len(v) != len(vectors[0]) for v in vectors):
            # A provider dimension change must not leave incompatible old vectors.
            with _lock:
                for key in keys:
                    _cache.pop(key, None)
            raise ValueError("embedding_dimensions")
        with _lock:
            for key, vector in fresh.items():
                _cache[key] = (time.monotonic() + TTL_SECONDS, vector)
                _cache.move_to_end(key)
            while len(_cache) > MAX_ENTRIES:
                _cache.popitem(last=False)
        return [list(vector) for vector in vectors]
    finally:
        for _, future in pending:
            future.cancel()
