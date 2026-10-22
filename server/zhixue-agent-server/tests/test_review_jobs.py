from concurrent.futures import Future, ThreadPoolExecutor
from copy import deepcopy
import threading
import time

import pytest

from app import create_app
from app.api import exercises
from app.services import review_jobs
from app.repositories.json_repository import JsonRepository
from app.repositories.sqlite_repository import SQLiteRepository


@pytest.mark.parametrize("backend", ["json", "sqlite"])
def test_slow_review_backfills_replay_without_regrading(tmp_path, monkeypatch, backend):
    monkeypatch.setenv("ZHIXUE_DB", backend)
    monkeypatch.setenv("LLM_REVIEW_WAIT_SECONDS", "0.01")
    client = create_app(tmp_path / "review.json").test_client()
    repository = exercises._repository
    release = threading.Event()
    completed = threading.Event()
    pool = review_jobs.ReviewPool(1, 0)
    monkeypatch.setattr(review_jobs, "_pool", pool)

    def slow(questions, answers, keys):
        assert release.wait(5)
        return {q["exerciseId"]: "详细解析" * 20 for q in questions}, {q["exerciseId"] for q in questions}

    monkeypatch.setattr(exercises.exercise_gen, "generate_review_explanations", slow)
    original = review_jobs.attach
    def attach(future, *args):
        original(future, *args)
        future.add_done_callback(lambda _: completed.set())
    monkeypatch.setattr(review_jobs, "attach", attach)
    payload = {"idempotencyKey": "slow", "answers": [
        {"exerciseId": "exercise-preorder-001", "answer": "B"}]}
    try:
        started = time.monotonic()
        response = client.post("/api/v1/exercises/set-demo-binary-tree-001/submit", json=payload)
        assert time.monotonic() - started < 1
        assert response.status_code == 200
        first = response.get_json()
        assert first["review"][0]["explanationSource"] == "fallback"
        profile = deepcopy(repository.get("profiles", "demo-user"))
        release.set()
        assert completed.wait(3)
        replay = client.post("/api/v1/exercises/set-demo-binary-tree-001/submit", json=payload).get_json()
        assert replay["submissionId"] == first["submissionId"]
        assert replay["review"][0]["explanationSource"] == "llm"
        assert repository.get("wrong_book", "demo-user:exercise-preorder-001")["explanation"] == "详细解析" * 20
        assert repository.get("profiles", "demo-user") == profile
        assert len(repository.list("submissions")) == 1
    finally:
        release.set()
        pool.executor.shutdown(wait=True)


def test_fifty_jobs_have_bounded_workers_and_queue():
    pool = review_jobs.ReviewPool(4, 8)
    release = threading.Event()
    lock = threading.Lock()
    running = 0
    peak = 0
    def work():
        nonlocal running, peak
        with lock:
            running += 1
            peak = max(peak, running)
        release.wait(5)
        with lock:
            running -= 1
    try:
        with ThreadPoolExecutor(max_workers=50) as callers:
            futures = list(callers.map(lambda _: pool.submit(work), range(50)))
        assert sum(f is not None for f in futures) == 12
        assert peak <= 4
    finally:
        release.set()
        pool.executor.shutdown(wait=True)


def test_fifty_concurrent_submissions_return_with_bounded_model_work(tmp_path, monkeypatch):
    app = create_app(tmp_path / "pressure.json")
    repo = exercises._repository
    pool = review_jobs.ReviewPool(4, 8)
    monkeypatch.setattr(review_jobs, "_pool", pool)
    monkeypatch.setenv("LLM_REVIEW_WAIT_SECONDS", "0.01")
    release = threading.Event()
    lock = threading.Lock()
    running = 0
    peak = 0
    def slow(*args):
        nonlocal running, peak
        with lock:
            running += 1
            peak = max(peak, running)
        assert release.wait(15)
        with lock:
            running -= 1
        return {}, set()
    monkeypatch.setattr(exercises.exercise_gen, "generate_review_explanations", slow)
    def submit(number):
        with app.test_client() as client:
            started = time.monotonic()
            response = client.post("/api/v1/exercises/set-demo-binary-tree-001/submit", json={
                "idempotencyKey": f"pressure-{number}", "answers": [
                    {"exerciseId": "exercise-preorder-001", "answer": "A"}]})
            return response.status_code, time.monotonic() - started
    try:
        with ThreadPoolExecutor(max_workers=50) as callers:
            results = list(callers.map(submit, range(50)))
        assert all(status == 200 and duration < 5 for status, duration in results)
        assert len(repo.list("submissions")) == 50
        assert peak == 4
    finally:
        release.set()
        pool.executor.shutdown(wait=True)


@pytest.mark.parametrize("backend", [JsonRepository, SQLiteRepository])
@pytest.mark.parametrize("change", ["none", "edit", "delete", "owner", "reset"])
def test_callback_preserves_edits_deletions_ownership_and_is_idempotent(tmp_path, backend, change):
    repo = backend(tmp_path / "data")
    row = {"exerciseId": "q", "explanationSource": "fallback", "explanation": "old"}
    original = {"reviewToken": "v1", "response": {"userId": "u", "review": [row]}}
    wrong = {"userId": "u", "explanation": "old", "wrongCount": 1}
    repo.save("submissions", "s", original)
    repo.save("wrong_book", "u:q", wrong)
    future = Future()
    review_jobs.attach(future, repo, "s", original, {"q": wrong})
    if change == "edit":
        repo.save("wrong_book", "u:q", dict(wrong, explanation="manual"))
    elif change == "delete":
        repo.delete("wrong_book", "u:q")
    elif change == "owner":
        replaced = deepcopy(original)
        replaced["response"]["userId"] = "other"
        repo.save("submissions", "s", replaced)
    elif change == "reset":
        repo.save("submissions", "s", dict(original, reviewToken="v2"))
    future.set_result(({"q": "new"}, {"q"}))
    snapshot = deepcopy(repo.get("submissions", "s"))
    review_jobs.attach(future, repo, "s", original, {"q": wrong})
    assert repo.get("submissions", "s") == snapshot
    if change in ("owner", "reset"):
        assert snapshot["response"]["review"][0]["explanation"] == "old"
        assert repo.get("wrong_book", "u:q") == wrong
    else:
        assert snapshot["response"]["review"][0]["explanationSource"] == "llm"
        expected = None if change == "delete" else dict(wrong, explanation="manual" if change == "edit" else "new")
        assert repo.get("wrong_book", "u:q") == expected
    if backend is SQLiteRepository:
        repo.close()


def test_worker_failure_and_queue_full_fall_back(monkeypatch, caplog):
    pool = review_jobs.ReviewPool(1, 0)
    monkeypatch.setattr(review_jobs, "_pool", pool)
    monkeypatch.setenv("LLM_REVIEW_WAIT_SECONDS", "0")
    release = threading.Event()
    future = pool.submit(lambda: release.wait(5))
    q = {"exerciseId": "q", "options": ["A. a", "B. b"]}
    try:
        with caplog.at_level("INFO"):
            fallback, ids, pending = review_jobs.prepare([q], {"q": "B"}, {"q": "A"})
        assert fallback["q"] and not ids and pending is None
        assert "reason=queue_full" in caplog.text
    finally:
        release.set()
        future.result(2)
        pool.executor.shutdown(wait=True)


def test_sqlite_conditional_update_serializes_independent_connections(tmp_path):
    first = SQLiteRepository(tmp_path / "shared.sqlite")
    second = SQLiteRepository(tmp_path / "shared.sqlite")
    original = {"response": "fallback"}
    first.save("submissions", "s", original)
    barrier = threading.Barrier(2)
    def update(repo, value):
        barrier.wait(3)
        return repo.compare_and_save("submissions", "s", original, {"response": value})
    try:
        with ThreadPoolExecutor(max_workers=2) as callers:
            futures = [callers.submit(update, repo, value)
                       for repo, value in [(first, "one"), (second, "two")]]
            assert sorted(f.result(5) for f in futures) == [False, True]
        assert first.get("submissions", "s") == second.get("submissions", "s")
    finally:
        first.close()
        second.close()


def test_worker_failure_does_not_expose_private_errors(monkeypatch, caplog):
    q = {"exerciseId": "q", "options": ["A. a", "B. b"]}
    pool = review_jobs.ReviewPool(1, 0)
    monkeypatch.setattr(review_jobs, "_pool", pool)
    monkeypatch.setenv("LLM_REVIEW_WAIT_SECONDS", "1")
    def fail(*args):
        raise ValueError("private content must not be logged")
    monkeypatch.setattr(exercises.exercise_gen, "generate_review_explanations", fail)
    try:
        fallback, ids, pending = review_jobs.prepare([q], {"q": "B"}, {"q": "A"})
        assert fallback["q"] and not ids and pending is None
        assert "private content" not in caplog.text
    finally:
        pool.executor.shutdown(wait=True)
