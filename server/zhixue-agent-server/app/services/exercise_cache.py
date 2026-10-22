"""Short-lived, bounded question cache; all reuse checks are owner scoped."""
from collections import OrderedDict
from copy import deepcopy
import hashlib
import json
import threading
import time

_entries = OrderedDict()
_lock = threading.Lock()
_stripes = [threading.RLock() for _ in range(32)]
TTL_SECONDS = 300


def key(repository, owner, point, count, sources=None):
    # Store identity prevents app/test instances from sharing cached records.
    return (str(repository.path), owner, point.strip(), count,
            hashlib.sha256(json.dumps(sources or [], sort_keys=True, ensure_ascii=False).encode()).hexdigest())


def guard(cache_key):
    return _stripes[hash(cache_key) % len(_stripes)]


def get(cache_key, repository, excluded=()):
    with _lock:
        entry = _entries.get(cache_key)
        if not entry:
            return None
        expires, items = entry
        owner = cache_key[1]
        if expires <= time.monotonic() or any(
                q["exerciseId"] in excluded or
                repository.get("exercise_usage", f"{owner}:{q['exerciseId']}") or
                repository.get("exercises", q["exerciseId"]) != dict(q, userId=owner)
                for q in items):
            del _entries[cache_key]
            return None
        _entries.move_to_end(cache_key)
        return deepcopy(items)


def put(cache_key, items):
    with _lock:
        _entries[cache_key] = (time.monotonic() + TTL_SECONDS, deepcopy(items))
        _entries.move_to_end(cache_key)
        while len(_entries) > 256:
            _entries.popitem(last=False)


def clear():
    with _lock:
        _entries.clear()
