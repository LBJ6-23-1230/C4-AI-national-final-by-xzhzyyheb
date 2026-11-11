from copy import deepcopy

import pytest

from app import create_app
from app.agents.planner import PlannerAgent
from app.api import exercises, workflows
from app.runtime.orchestrator import decide_next_step
from app.services import assessment_replan


ANSWERS = [{"exerciseId": "exercise-preorder-001", "answer": "A"},
           {"exerciseId": "exercise-inorder-001", "answer": "B"},
           {"exerciseId": "exercise-postorder-001", "answer": "A"}]


@pytest.mark.parametrize("entry", ["submit", "workflow"])
def test_replan_executes_planner_role_and_commits_one_shared_plan(tmp_path, monkeypatch, entry):
    client = create_app(tmp_path / "handoff.json").test_client()
    calls = []
    run = PlannerAgent.run
    def spy(self, state):
        calls.append(deepcopy(state))
        return run(self, state)
    monkeypatch.setattr(PlannerAgent, "run", spy)
    if entry == "submit":
        response = client.post("/api/v1/exercises/set-demo-binary-tree-001/submit",
            json={"idempotencyKey": "handoff", "answers": ANSWERS}).get_json()
        trace_id = response["traceId"]
    else:
        created = client.post("/api/v1/workflows", json={"goal": "复习遍历"}).get_json()
        url = f"/api/v1/workflows/{created['sessionId']}/run"
        client.post(url, json={})
        response = client.post(url, json={"answers": ANSWERS}).get_json()
        trace_id = created["traceId"]
        assert response["status"] == "completed"
        assert response["state"]["replanRequest"]["fromAgent"] == "assessment"
        assert response["state"]["replanRequest"]["toAgent"] == "planner"
        assert response["state"]["replanHandled"] is True
    assert len(calls) == 1
    assert calls[0]["needReplan"] is True
    assert calls[0]["replanState"]["knowledgePointId"] == "binary-tree-postorder"
    plan = exercises._repository.get("plans", "plan-demo-001")
    assert plan["version"] == 2
    assert [t["durationMinutes"] for t in plan["tasks"]] == [45, 15]
    assert len(exercises._repository.list("plans")) == 1
    events = client.get(f"/api/v1/traces/{trace_id}").get_json()["events"]
    assert [e["agent"] for e in events] == (
        ["assessment", "planner"] if entry == "submit" else ["exercise", "assessment", "planner", "secretary"])
    recorded = [r for r in exercises._repository.list("learning_events") if r["type"] == "PlanReplanned"]
    assert len(recorded) == 1
    assert recorded[0]["evidenceIds"]


def test_model_cannot_finish_or_issue_new_exercises_before_pending_replan():
    state = {"profile": {}, "plan": {}, "assessment": {"score": 20}, "needReplan": True}
    for step in ("finish", "exercise"):
        assert decide_next_step(state, lambda _: {"step": step}).step == "planner"


def test_workflow_retry_after_planner_commit_does_not_grade_or_replan_twice(tmp_path, monkeypatch):
    client = create_app(tmp_path / "retry.json").test_client()
    created = client.post("/api/v1/workflows", json={"goal": "复习遍历"}).get_json()
    url = f"/api/v1/workflows/{created['sessionId']}/run"
    client.post(url, json={})
    execute = assessment_replan.execute_assessment_replan
    def fail_after_commit(*args, **kwargs):
        execute(*args, **kwargs)
        raise RuntimeError("simulated response interruption")
    monkeypatch.setattr(workflows, "execute_assessment_replan", fail_after_commit)
    assert client.post(url, json={"answers": ANSWERS}).status_code == 500
    profile = deepcopy(exercises._repository.get("profiles", "demo-user"))
    plan = deepcopy(exercises._repository.get("plans", "plan-demo-001"))
    monkeypatch.setattr(workflows, "execute_assessment_replan", execute)
    retried = client.post(url, json={"answers": ANSWERS})
    assert retried.status_code == 200
    assert retried.get_json()["status"] == "completed"
    assert retried.get_json()["state"]["assessment"]["oldMastery"] == 42
    assert exercises._repository.get("profiles", "demo-user") == profile
    assert exercises._repository.get("plans", "plan-demo-001") == plan
