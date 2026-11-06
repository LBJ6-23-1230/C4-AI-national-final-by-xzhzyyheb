"""Bounded background review work and score-neutral updates."""
from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
import logging
import math
import os
import threading

from app.agent import exercise_gen

logger = logging.getLogger("zhixue.review")


class ReviewPool:
    def __init__(self, workers=4, queue_size=8):
        self.executor = ThreadPoolExecutor(max_workers=workers, thread_name_prefix="review")
        self.slots = threading.BoundedSemaphore(workers + queue_size)

    def submit(self, function, *args):
        if not self.slots.acquire(blocking=False):
            return None
        try:
            future = self.executor.submit(function, *args)
        except BaseException:
            self.slots.release()
            raise
        future.add_done_callback(lambda _: self.slots.release())
        return future


def _setting(name, default, maximum):
    try:
        value = float(os.getenv(name, str(default)))
        return min(maximum, max(0, value)) if math.isfinite(value) else default
    except ValueError:
        return default


_pool = None
_pool_lock = threading.Lock()


def pool():
    global _pool
    with _pool_lock:
        if _pool is None:
            _pool = ReviewPool(max(1, int(_setting("LLM_REVIEW_WORKERS", 4, 32))),
                               int(_setting("LLM_REVIEW_QUEUE_SIZE", 8, 128)))
        return _pool


def start(repository, submission_id, expected, wrong_snapshots, questions, answers, keys):
    future = pool().submit(exercise_gen.generate_review_explanations, questions, answers, keys)
    if future is None:
        logger.info("review_job status=failed reason=queue_full")
        apply_result(repository, submission_id, expected, wrong_snapshots, {}, set())
    else:
        attach(future, repository, submission_id, expected, wrong_snapshots)


def apply_result(repository, submission_id, expected, wrong_snapshots, explanations, ids):
    """Conditional enrichment only; never repeats scoring or revives deleted rows."""
    updated = deepcopy(expected)
    owner = expected["response"]["userId"]
    changed = []
    for row in updated["response"]["review"]:
        key = row["exerciseId"]
        if row.get("explanationSource") == "fallback" and key in ids and explanations.get(key):
            row.update(explanation=explanations[key], explanationSource="llm")
            changed.append(key)
    updated["response"]["reviewStatus"] = "completed" if changed else "failed"
    if not repository.compare_and_save("submissions", submission_id, expected, updated):
        return False
    for key in changed:
        previous = wrong_snapshots.get(key)
        if previous and previous.get("userId") == owner:
            repository.compare_and_save("wrong_book", f"{owner}:{key}", previous,
                                        dict(previous, explanation=explanations[key]))
    return True


def attach(future, repository, submission_id, expected, wrong_snapshots):
    """Register only after commit. Never access Flask globals in a callback."""
    expected = deepcopy(expected)
    wrong_snapshots = deepcopy(wrong_snapshots)

    def complete(done):
        try:
            explanations, ids = done.result()
        except Exception:
            # Provider errors can contain user content.
            logger.warning("review_job status=failed reason=worker_error")
            explanations, ids = {}, set()
        apply_result(repository, submission_id, expected, wrong_snapshots, explanations, ids)

    future.add_done_callback(complete)
