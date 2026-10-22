from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
from datetime import datetime, timezone

import pytest

from app import create_app
from app.api import focus
from app.repositories.json_repository import JsonRepository


def session(**changes):
    return {"taskId": "focus-one", "planTaskId": "task-postorder", "course": "数据结构",
            "task": "完成遍历练习", "plannedMinutes": 30, "actualMinutes": 25,
            "pauseCount": 1, "interruptionCount": 0, "completionRate": 100,
            "selfAssessment": "completed", "timerType": "countdown", "status": "completed",
            "endedAt": datetime.now(timezone.utc).isoformat(), **changes}


def login(client, phone):
    body = client.post("/api/v1/auth/register", json={"phone": phone, "password": "Password123",
        "nickname": "同学", "seedDemoData": False}).get_json()
    return {"Authorization": f"Bearer {body['token']}"}, body['user']['userId']


def test_focus_retry_is_atomic_durable_and_does_not_change_mastery(tmp_path):
    path = tmp_path / "focus.json"
    client = create_app(path).test_client()
    before = deepcopy(focus._repository.get("profiles", "demo-user"))
    payload = session()
    first = client.post("/api/v1/focus-sessions", json=payload)
    assert first.status_code == 200
    assert first.get_json()["planTaskMatched"]
    assert client.post("/api/v1/focus-sessions", json=payload).get_json() == first.get_json()
    stored = JsonRepository(path)
    assert len(stored.list("focus_sessions")) == len(stored.list("learning_events")) == 1
    assert stored.get("profiles", "demo-user") == before
    task = next(t for t in stored.get("plans", "plan-demo-001")["tasks"] if t["taskId"] == "task-postorder")
    assert task["status"] == "completed"
    restarted = create_app(path).test_client()
    history = restarted.get("/api/v1/focus-sessions").get_json()
    assert len(history["sessions"]) == 1
    assert history["taskStatuses"] == {"task-postorder": "completed"}
    assert restarted.post("/api/v1/focus-sessions", json=dict(payload, actualMinutes=10)).status_code == 409


def test_accounts_cannot_read_or_update_each_others_focus_and_plan(tmp_path):
    client = create_app(tmp_path / "accounts.json").test_client()
    a, owner_a = login(client, "13900007701")
    b, owner_b = login(client, "13900007702")
    focus._repository.save("plans", "private", {"planId": "private", "userId": owner_b,
        "tasks": [{"taskId": "private-task", "status": "pending"}]})
    payload = session(planTaskId="private-task")
    result = client.post("/api/v1/focus-sessions", json=dict(payload, userId=owner_b), headers=a)
    assert result.status_code == 200
    assert result.get_json()["userId"] == owner_a
    assert not result.get_json()["planTaskMatched"]
    assert focus._repository.get("plans", "private")["tasks"][0]["status"] == "pending"
    assert client.get("/api/v1/focus-sessions", headers=b).get_json()["sessions"] == []
    assert client.get(f"/api/v1/focus-sessions?userId={owner_a}").status_code == 404
    assert client.get("/api/v1/focus-sessions", headers={"Authorization": "Bearer invalid"}).status_code == 401
    assert client.post("/api/v1/focus-sessions", json=payload, headers=b).status_code == 200
    assert len(focus._repository.list("focus_sessions")) == 2


@pytest.mark.parametrize("changes", [
    {"actualMinutes": -1}, {"pauseCount": True}, {"pauseCount": 1.5},
    {"completionRate": 101}, {"selfAssessment": []}, {"endedAt": "yesterday"},
    {"endedAt": "2026-01-01T00:00:00"}, {"taskId": ""}, {"timerType": "unknown"},
])
def test_bad_focus_facts_are_rejected_without_writes(tmp_path, changes):
    client = create_app(tmp_path / "invalid.json").test_client()
    assert client.post("/api/v1/focus-sessions", json=session(**changes)).status_code == 400
    assert focus._repository.list("focus_sessions") == []
    assert focus._repository.list("learning_events") == []


def test_concurrent_focus_retry_records_once(tmp_path):
    app = create_app(tmp_path / "concurrent.json")
    payload = session()
    def submit(_):
        with app.test_client() as client:
            return client.post("/api/v1/focus-sessions", json=payload).get_json()
    with ThreadPoolExecutor(max_workers=4) as pool:
        responses = list(pool.map(submit, range(8)))
    assert all(r == responses[0] for r in responses)
    assert len(focus._repository.list("focus_sessions")) == 1


def test_completed_task_is_not_demoted_by_later_partial_focus(tmp_path):
    client = create_app(tmp_path / "partial.json").test_client()
    assert client.post("/api/v1/focus-sessions", json=session()).status_code == 200
    assert client.post("/api/v1/focus-sessions", json=session(taskId="another",
        selfAssessment="partial", status="not_completed", completionRate=50)).status_code == 200
    history = client.get("/api/v1/focus-sessions").get_json()
    assert len(history["sessions"]) == 2
    assert history["taskStatuses"]["task-postorder"] == "completed"
    assert next(t for t in focus._repository.get("plans", "plan-demo-001")["tasks"]
                if t["taskId"] == "task-postorder")["status"] == "completed"


def test_failed_batch_rolls_back_memory_and_can_be_retried(tmp_path, monkeypatch):
    client = create_app(tmp_path / "failure.json").test_client()
    repo = focus._repository
    before_plan = deepcopy(repo.get("plans", "plan-demo-001"))
    payload = session()
    flush = repo._flush
    def fail():
        raise OSError("simulated storage failure")
    monkeypatch.setattr(repo, "_flush", fail)
    assert client.post("/api/v1/focus-sessions", json=payload).status_code == 500
    assert repo.list("focus_sessions") == []
    assert repo.list("learning_events") == []
    assert repo.get("plans", "plan-demo-001") == before_plan
    monkeypatch.setattr(repo, "_flush", flush)
    assert client.post("/api/v1/focus-sessions", json=payload).status_code == 200
