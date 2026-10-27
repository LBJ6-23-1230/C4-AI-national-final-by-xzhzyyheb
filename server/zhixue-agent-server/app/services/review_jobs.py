"""Bounded review work and conditional, score-neutral enrichment."""
from concurrent.futures import ThreadPoolExecutor, TimeoutError
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


def prepare(questions, answers, keys):
    fallback = {q["exerciseId"]: exercise_gen._fallback_review_explanation(
        q, answers[q["exerciseId"]], keys[q["exerciseId"]]) for q in questions}
    if not questions:
        return fallback, set(), None
    future = pool().submit(exercise_gen.generate_review_explanations,
                           deepcopy(questions), dict(answers), dict(keys))
    if future is None:
        logger.info("review_fallback reason=queue_full")
        return fallback, set(), None
    try:
        explanations, ids = future.result(timeout=_setting("LLM_REVIEW_WAIT_SECONDS", 2, 30))
        return explanations, ids, None
    except TimeoutError:
        logger.info("review_fallback reason=wait_budget")
        return fallback, set(), future
    except Exception:
        logger.warning("review_fallback reason=worker_failed")
        return fallback, set(), None


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
            updated = deepcopy(expected)
            owner = expected["response"]["userId"]
            changed = []
            for row in updated["response"]["review"]:
                key = row["exerciseId"]
                if row.get("explanationSource") == "fallback" and key in ids and explanations.get(key):
                    row.update(explanation=explanations[key], explanationSource="llm")
                    changed.append(key)
            updated["response"]["reviewStatus"] = "completed" if changed else "failed"
            # Compare the full snapshot so resets, edits and duplicate callbacks win.
            if not repository.compare_and_save("submissions", submission_id, expected, updated):
                return
            for key in changed:
                previous = wrong_snapshots.get(key)
                if previous and previous.get("userId") == owner:
                    replacement = dict(previous, explanation=explanations[key])
                    repository.compare_and_save("wrong_book", f"{owner}:{key}", previous, replacement)
            logger.info("review_backfill status=completed count=%s", len(changed))
        except Exception:
            failed = deepcopy(expected)
            failed["response"]["reviewStatus"] = "failed"
            repository.compare_and_save("submissions", submission_id, expected, failed)
            # Do not log exception text: provider errors may contain user content.
            logger.warning("review_backfill status=failed")

    future.add_done_callback(complete)
