"""Reject a second JSON writer process; never silently allow lost updates."""
import os
from pathlib import Path
import threading
import weakref

_leases = {}
_guard = threading.Lock()


def _release(key):
    with _guard:
        entry = _leases.get(key)
        if entry is None:
            return
        entry[1] -= 1
        if entry[1] == 0:
            entry[0].close()
            del _leases[key]


def acquire(owner, path):
    key = str(Path(path).resolve()).casefold() if os.name == "nt" else str(Path(path).resolve())
    with _guard:
        if key in _leases:
            _leases[key][1] += 1
        else:
            lock_path = Path(str(path) + ".process.lock")
            lock_path.parent.mkdir(parents=True, exist_ok=True)
            stream = lock_path.open("a+b")
            stream.seek(0, 2)
            if stream.tell() == 0:
                stream.write(b"0")
                stream.flush()
            stream.seek(0)
            try:
                if os.name == "nt":
                    import msvcrt
                    msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
                else:
                    import fcntl
                    fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                stream.close()
                raise RuntimeError("JSON repository supports one process only; use ZHIXUE_DB=sqlite for multiple workers") from None
            _leases[key] = [stream, 1]
    return weakref.finalize(owner, _release, key)
