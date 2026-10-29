from copy import deepcopy
from datetime import datetime, timezone

import pytest

from app import create_app
from app.api import plans


URL = "/api/v1/plans/current/tasks/schedule"


def task(key, minutes, **kwargs):
    return dict(taskId=key, knowledgePointId=key, knowledgePointName=key,
                durationMinutes=minutes, status="pending", **kwargs)


def seed(client, available=60):
    plan = plans._repository.get("plans", "plan-demo-001")
    plan.update(tasks=[task("completed", 30), task("current", 60)],
                unscheduledTasks=[task("first", 45), task("chosen", 90), task("last", 75)],
                constraints={"availableMinutes": available}, candidatePool=[{"knowledgePointId": "candidate"}])
    plan["tasks"][0]["status"] = "completed"
    plans._repository.save("plans", plan["planId"], plan)
    return plan


def schedule(client, key="add-chosen", **changes):
    return client.post(URL, json=dict(taskId="chosen", expectedPlanVersion=1, idempotencyKey=key, **changes))


@pytest.mark.parametrize("backend", ["json", "sqlite"])
@pytest.mark.parametrize("available,expected", [(60, 150), (300, 300)])
def test_only_selected_task_is_added_and_refresh_preserves_selection(tmp_path, monkeypatch, backend, available, expected):
    monkeypatch.setenv("ZHIXUE_DB", backend)
    client = create_app(tmp_path / "schedule.json").test_client()
    before = seed(client, available)
    response = schedule(client)
    assert response.status_code == 200
    result = response.get_json()
    plan = result["plan"]
    assert plan["tasks"][:2] == before["tasks"]
    assert [t["taskId"] for t in plan["tasks"]] == ["completed", "current", "chosen"]
    assert [t["taskId"] for t in plan["unscheduledTasks"]] == ["first", "last"]
    assert plan["candidatePool"] == before["candidatePool"]
    assert plan["budgetSummary"] == dict(availableMinutes=expected, scheduledMinutes=150,
                                          unallocatedMinutes=expected - 150, unscheduledMinutes=120)
    assert plan["version"] == 2
    assert any(t["taskId"] == "chosen" and t.get("change") == "scheduled" for t in result["planDiff"]["changedTasks"])
    assert schedule(client).get_json() == result
    synced = client.post("/api/v1/plans/current/assignments", json={"assignments": []}).get_json()
    assert synced == plan
    assert len(plans._repository.list("plan_adjustments")) == 1
    trace = client.get(f"/api/v1/traces/{result['traceId']}").get_json()
    assert trace["events"][0]["toolCalls"] == ["schedule_deferred_task"]


def test_assignment_refresh_preserves_order_and_does_not_fill_other_tasks(tmp_path):
    client = create_app(tmp_path / "ddl-schedule.json").test_client()
    rows = [dict(id=key, title=key, courseName="数据结构", dueDate=due,
                 estimatedMinutes=minutes, priority="高", completed=False)
            for key, due, minutes in [("first", "2026-10-30", 45), ("chosen", "2026-10-29", 90)]]
    client.post("/api/v1/plans/current/assignments", json={"assignments": rows})
    plan = plans._repository.get("plans", "plan-demo-001")
    # All existing tasks completed: plenty of spare budget, yet choose only one DDL.
    for t in plan["tasks"]:
        t["status"] = "completed"
    plan["constraints"] = {"availableMinutes": 300}
    plans._repository.save("plans", plan["planId"], plan)
    added = client.post(URL, json=dict(taskId="chosen", expectedPlanVersion=plan["version"],
                                       idempotencyKey="ddl")).get_json()["plan"]
    refreshed = client.post("/api/v1/plans/current/assignments", json={"assignments": list(reversed(rows))}).get_json()
    assert refreshed == added
    assert [t["taskId"] for t in refreshed["unscheduledTasks"]] == ["first"]
    session = dict(taskId="chosen-focus", planTaskId="chosen", course="数据结构", task="chosen",
                   plannedMinutes=90, actualMinutes=90, pauseCount=0, interruptionCount=0,
                   completionRate=100, selfAssessment="completed", timerType="countdown", status="completed",
                   endedAt=datetime.now(timezone.utc).isoformat())
    completed = client.post("/api/v1/focus-sessions", json=session)
    assert completed.status_code == 200 and completed.get_json()["planTaskMatched"]
    assert next(t for t in plans._repository.get("plans", plan["planId"])["tasks"] if t["taskId"] == "chosen")["status"] == "completed"


@pytest.mark.parametrize("changes,status", [
    ({"taskId": "missing"}, 404), ({"taskId": "current"}, 404),
    ({"taskId": ""}, 400), ({"taskId": []}, 400),
    ({"expectedPlanVersion": True}, 400), ({"expectedPlanVersion": 0}, 400),
    ({"expectedPlanVersion": 99}, 409), ({"idempotencyKey": ""}, 400),
])
def test_invalid_requests_do_not_change_plan(tmp_path, changes, status):
    client = create_app(tmp_path / "invalid.json").test_client()
    before = deepcopy(seed(client))
    payload = dict(taskId="chosen", expectedPlanVersion=1, idempotencyKey="invalid")
    payload.update(changes)
    assert client.post(URL, json=payload).status_code == status
    assert plans._repository.get("plans", before["planId"]) == before
    assert not plans._repository.list("plan_adjustments")


@pytest.mark.parametrize("duration", [0, -1, True, "90", 1441])
def test_invalid_duration_and_day_limit_are_rejected(tmp_path, duration):
    client = create_app(tmp_path / "duration.json").test_client()
    before = seed(client)
    before["unscheduledTasks"][1]["durationMinutes"] = duration
    plans._repository.save("plans", before["planId"], before)
    assert schedule(client).status_code == 400
    assert plans._repository.get("plans", before["planId"]) == before


def test_conflicting_retry_and_stale_actions_cannot_duplicate_tasks(tmp_path):
    client = create_app(tmp_path / "conflicts.json").test_client()
    seed(client)
    added = schedule(client).get_json()["plan"]
    for key, version, task_id in [("add-chosen", 1, "last"), ("stale", 1, "last"), ("again", 2, "chosen")]:
        response = client.post(URL, json=dict(taskId=task_id, expectedPlanVersion=version, idempotencyKey=key))
        assert response.status_code in (404, 409)
    assert plans._repository.get("plans", added["planId"]) == added


def test_failed_save_rolls_back_plan_history_and_retry_record(tmp_path, monkeypatch):
    client = create_app(tmp_path / "rollback.json").test_client()
    before = deepcopy(seed(client))
    def fail():
        raise OSError("disk unavailable")
    monkeypatch.setattr(plans._repository, "_flush", fail)
    assert schedule(client).status_code == 500
    assert plans._repository.get("plans", before["planId"]) == before
    assert not plans._repository.list("plan_adjustments")
    assert not plans._repository.list("plan_histories")


def test_schedule_is_scoped_to_authenticated_account(tmp_path):
    client = create_app(tmp_path / "owners.json").test_client()
    seed(client)
    auth = client.post("/api/v1/auth/register", json=dict(phone="13900008712", nickname="任务安排测试",
                                                        seedDemoData=False)).get_json()
    headers = {"Authorization": "Bearer " + auth["token"]}
    payload = dict(taskId="chosen", expectedPlanVersion=1, idempotencyKey="owner", userId="demo-user")
    assert client.post(URL, json=payload, headers=headers).status_code == 404
    assert plans._repository.get("plans", "plan-demo-001")["version"] == 1
    assert schedule(client, key="owner").status_code == 200
