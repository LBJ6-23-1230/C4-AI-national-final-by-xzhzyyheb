"""Failures in the normal submission path must not publish partial learning state."""

import time
from copy import deepcopy

import pytest

from app import create_app
from app.api import exercises, wrong_book
from app.repositories.json_repository import JsonRepository
from app.repositories.sqlite_repository import SQLiteRepository


ANSWERS = [{"exerciseId": "exercise-preorder-001", "answer": "A"},
           {"exerciseId": "exercise-inorder-001", "answer": "B"},
           {"exerciseId": "exercise-postorder-001", "answer": "A"}]
COLLECTIONS = ("profiles", "plans", "evidences", "wrong_book", "plan_histories",
               "learning_events", "traces", "submissions")


def snapshot(repo):
    return {c: {key: deepcopy(repo.get(c, key)) for key in repo.ids(c)} for c in COLLECTIONS}


@pytest.mark.parametrize("backend", ["json", "sqlite"])
@pytest.mark.parametrize("failure", ["wrong_book", "planner", "commit"])
def test_failed_submission_leaves_no_partial_results_and_retries_once(tmp_path, monkeypatch, backend, failure):
    monkeypatch.setenv("ZHIXUE_DB", backend)
    client = create_app(tmp_path / "atomic.json").test_client()
    repo = exercises._repository
    before = snapshot(repo)
    payload = {"idempotencyKey": "atomic", "answers": ANSWERS}
    def fail(*args, **kwargs):
        raise RuntimeError("simulated interruption")
    with monkeypatch.context() as patch:
        if failure == "wrong_book":
            original = wrong_book.record_submission
            def write_then_fail(*args, **kwargs):
                original(*args, **kwargs)
                fail()
            patch.setattr(wrong_book, "record_submission", write_then_fail)
        elif failure == "planner":
            original = exercises.execute_assessment_replan
            def plan_then_fail(*args, **kwargs):
                original(*args, **kwargs)
                fail()
            patch.setattr(exercises, "execute_assessment_replan", plan_then_fail)
        else:
            patch.setattr(repo, "apply_batch", fail)
        assert client.post("/api/v1/exercises/set-demo-binary-tree-001/submit", json=payload).status_code == 500
    assert snapshot(repo) == before
    persisted = JsonRepository(repo.path) if backend == "json" else SQLiteRepository(repo.path)
    try:
        assert snapshot(persisted) == before
    finally:
        if backend == "sqlite":
            persisted.close()
    first = client.post("/api/v1/exercises/set-demo-binary-tree-001/submit", json=payload)
    assert first.status_code == 200
    assert first.get_json()["masteryUpdate"]["oldScore"] == 42
    assert first.get_json()["masteryUpdate"]["newScore"] == 58
    after = snapshot(repo)
    assert client.post("/api/v1/exercises/set-demo-binary-tree-001/submit", json=payload).get_json() == first.get_json()
    assert snapshot(repo) == after
    assert len(after["submissions"]) == 1
    assert repo.get("plans", "plan-demo-001")["version"] == 2


def test_response_interruption_after_commit_is_replayable_without_model_or_updates(tmp_path, monkeypatch):
    client = create_app(tmp_path / "response.json").test_client()
    repo = exercises._repository
    commit = repo.apply_batch
    def commit_then_fail(*args, **kwargs):
        commit(*args, **kwargs)
        raise RuntimeError("lost response after atomic commit")
    payload = {"idempotencyKey": "lost-response", "answers": ANSWERS}
    with monkeypatch.context() as patch:
        patch.setattr(repo, "apply_batch", commit_then_fail)
        assert client.post("/api/v1/exercises/set-demo-binary-tree-001/submit", json=payload).status_code == 500
    before = snapshot(repo)
    def no_model(*args):
        raise AssertionError("an acknowledged submission must be replayed before model calls")
    monkeypatch.setattr(exercises.exercise_gen, "generate_review_explanations", no_model)
    assert client.post("/api/v1/exercises/set-demo-binary-tree-001/submit", json=payload).status_code == 200
    assert snapshot(repo) == before


def test_slow_review_model_cannot_block_submission(tmp_path, monkeypatch):
    """逐题解析是增强项：模型比预算慢时必须先交卷，不能拖到客户端读超时。"""
    client = create_app(tmp_path / "slow-review.json").test_client()
    monkeypatch.setenv("LLM_REVIEW_WAIT_SECONDS", "0.3")

    def slow_review(*args, **kwargs):
        time.sleep(2.0)
        return {}, set()

    monkeypatch.setattr(exercises.exercise_gen, "generate_review_explanations", slow_review)
    started = time.perf_counter()
    response = client.post("/api/v1/exercises/set-demo-binary-tree-001/submit",
                           json={"idempotencyKey": "slow-review", "answers": ANSWERS})
    elapsed = time.perf_counter() - started

    assert response.status_code == 200
    body = response.get_json()
    assert body["assessment"]["score"] == 66.67
    assert elapsed < 1.5, f"交卷被解析拖住了：{elapsed:.2f}s"
    assert [item["explanationSource"] for item in body["review"]] == ["fallback", "fallback", "fallback"]
