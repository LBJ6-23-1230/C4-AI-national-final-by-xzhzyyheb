from copy import deepcopy

import pytest

from app import create_app
from app.api import plans
from app.tools.time_budget import fit_plan_to_budget

URL = "/api/v1/plans/current/availability"


def apply(client, minutes, version, key):
    return client.post(URL, json={"availableMinutes": minutes, "expectedPlanVersion": version,
                                  "idempotencyKey": key})


def test_time_change_defers_and_restores_tasks_without_losing_ids(tmp_path):
    client = create_app(tmp_path / "budget.json").test_client()
    original = plans._repository.get("plans", "plan-demo-001")
    first = apply(client, 60, original["version"], "sixty").get_json()
    reduced_response = apply(client, 30, first["plan"]["version"], "thirty")
    assert reduced_response.status_code == 200
    reduced = reduced_response.get_json()
    assert reduced["plan"]["budgetSummary"]["scheduledMinutes"] == 30
    assert len(reduced["plan"]["tasks"]) == len(reduced["plan"]["unscheduledTasks"]) == 1
    assert {t["taskId"] for t in reduced["plan"]["tasks"] + reduced["plan"]["unscheduledTasks"]} == {
        t["taskId"] for t in original["tasks"]}
    assert any(t.get("change") == "deferred" for t in reduced["planDiff"]["changedTasks"])
    assert apply(client, 30, first["plan"]["version"], "thirty").get_json() == reduced
    expanded = apply(client, 60, reduced["plan"]["version"], "again").get_json()
    assert expanded["plan"]["unscheduledTasks"] == []
    assert expanded["plan"]["tasks"] == original["tasks"]
    trace = client.get(f"/api/v1/traces/{expanded['traceId']}").get_json()
    assert trace["events"][0]["toolCalls"] == ["fit_plan_to_budget"]


@pytest.mark.parametrize("entry", ["submit", "workflow"])
def test_assessment_replanning_respects_saved_budget(tmp_path, entry):
    client = create_app(tmp_path / "assessment-budget.json").test_client()
    assert apply(client, 60, 1, "budget").status_code == 200
    answers = [{"exerciseId": "exercise-preorder-001", "answer": "WRONG"},
               {"exerciseId": "exercise-inorder-001", "answer": "WRONG"},
               {"exerciseId": "exercise-postorder-001", "answer": "WRONG"}]
    if entry == "submit":
        response = client.post("/api/v1/exercises/set-demo-binary-tree-001/submit",
                               json={"answers": answers, "idempotencyKey": "grade"})
    else:
        workflow = client.post("/api/v1/workflows", json={"goal": "有限时间复习"}).get_json()
        url = f"/api/v1/workflows/{workflow['sessionId']}/run"
        client.post(url, json={})
        response = client.post(url, json={"answers": answers})
    assert response.status_code == 200
    plan = plans._repository.get("plans", "plan-demo-001")
    assert sum(t["durationMinutes"] for t in plan["tasks"] if t["status"] != "completed") <= 60
    assert plan["budgetSummary"]["scheduledMinutes"] == 55
    assert plan["budgetSummary"]["unscheduledMinutes"] == 15
    assert len(plan["unscheduledTasks"]) == 1


def test_zero_budget_and_completed_tasks_are_retained(tmp_path):
    client = create_app(tmp_path / "zero.json").test_client()
    plan = plans._repository.get("plans", "plan-demo-001")
    plan["tasks"][0]["status"] = "completed"
    plans._repository.save("plans", plan["planId"], plan)
    response = apply(client, 0, 1, "none").get_json()
    assert response["plan"]["tasks"] == [plan["tasks"][0]]
    assert response["plan"]["budgetSummary"]["scheduledMinutes"] == 0
    assert len(response["plan"]["unscheduledTasks"]) == 1


def test_stale_version_and_conflicting_keys_do_not_overwrite_plan(tmp_path):
    client = create_app(tmp_path / "versions.json").test_client()
    response = apply(client, 30, 1, "change").get_json()
    before = deepcopy(plans._repository.get("plans", "plan-demo-001"))
    assert apply(client, 60, 1, "stale").status_code == 409
    assert apply(client, 60, 1, "change").status_code == 409
    assert plans._repository.get("plans", "plan-demo-001") == before
    unchanged = apply(client, 30, response["plan"]["version"], "same-budget").get_json()
    assert unchanged["changed"] is False
    assert unchanged["plan"]["version"] == before["version"]


@pytest.mark.parametrize("minutes", [-1, 1441, True, 1.5, "30", None])
def test_invalid_budget_is_rejected(tmp_path, minutes):
    client = create_app(tmp_path / "invalid.json").test_client()
    assert apply(client, minutes, 1, "invalid").status_code == 400
    assert plans._repository.get("plans", "plan-demo-001")["version"] == 1


def test_budget_failure_does_not_commit_constraint_or_drop_tasks(tmp_path, monkeypatch):
    client = create_app(tmp_path / "failure.json").test_client()
    before = deepcopy(plans._repository.get("plans", "plan-demo-001"))
    def fail():
        raise OSError("disk unavailable")
    monkeypatch.setattr(plans._repository, "_flush", fail)
    assert apply(client, 30, 1, "fail").status_code == 500
    assert plans._repository.get("plans", "plan-demo-001") == before
    assert plans._repository.list("plan_adjustments") == []


def test_same_budget_key_is_scoped_to_login_and_cannot_target_other_account(tmp_path):
    client = create_app(tmp_path / "owners.json").test_client()
    users = []
    for phone in ("13900007801", "13900007802"):
        result = client.post("/api/v1/auth/register", json={'password': 'test-pw-123456', "phone": phone, "nickname": phone,
            "seedDemoData": True}).get_json()
        users.append((result["user"]["userId"], {"Authorization": f"Bearer {result['token']}"}))
    owner_a, auth_a = users[0]
    owner_b, auth_b = users[1]
    payload = {"availableMinutes": 30, "expectedPlanVersion": 1, "idempotencyKey": "same", "userId": owner_b}
    assert client.post(URL, json=payload, headers=auth_a).get_json()["plan"]["userId"] == owner_a
    assert plans._repository.get("plans", f"plan-{owner_b}")["version"] == 1
    assert client.post(URL, json=payload, headers=auth_b).get_json()["plan"]["userId"] == owner_b
    assert len(plans._repository.list("plan_adjustments")) == 2


def test_focus_completion_of_deferred_task_preserves_progress_and_budget(tmp_path):
    from datetime import datetime, timezone
    client = create_app(tmp_path / "deferred-focus.json").test_client()
    reduced = apply(client, 0, 1, "zero").get_json()["plan"]
    task = reduced["unscheduledTasks"][0]
    response = client.post("/api/v1/focus-sessions", json={"taskId": "resumed-focus", "planTaskId": task["taskId"],
        "course": "数据结构", "task": task["knowledgePointName"], "plannedMinutes": 30, "actualMinutes": 30,
        "pauseCount": 0, "interruptionCount": 0, "completionRate": 100, "selfAssessment": "completed",
        "timerType": "countdown", "status": "completed", "endedAt": datetime.now(timezone.utc).isoformat()})
    assert response.status_code == 200
    assert response.get_json()["planTaskMatched"]
    plan = plans._repository.get("plans", "plan-demo-001")
    assert plan["tasks"][0]["status"] == "completed"
    assert all(t["taskId"] != task["taskId"] for t in plan["unscheduledTasks"])
    assert plan["budgetSummary"]["scheduledMinutes"] == 0
