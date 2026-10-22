from copy import deepcopy

import pytest

from app import create_app
from app.api import profile as profile_api
from app.tools.profile_merge import merge_points_into_profile


@pytest.mark.parametrize("budget", [None, 30])
def test_second_course_changes_existing_plan_preserving_ids_and_progress(tmp_path, budget):
    client = create_app(tmp_path / "incremental.json").test_client()
    auth = client.post("/api/v1/auth/register", json={"phone": "13900007901", "nickname": "课程测试",
                        "seedDemoData": False}).get_json()
    owner = auth["user"]["userId"]
    headers = {"Authorization": f"Bearer {auth['token']}"}
    url = f"/api/v1/profile/{owner}/knowledge-points"
    assert client.post(url, json={"courses": ["数据结构"]}, headers=headers).status_code == 200
    repo = profile_api._repository
    before = client.get("/api/v1/plans/current", headers=headers).get_json()
    saved = repo.get("plans", before["planId"])
    saved["tasks"][0]["status"] = "completed"
    done = deepcopy(saved["tasks"][0])
    repo.save("plans", before["planId"], saved)
    if budget is not None:
        result = client.post("/api/v1/plans/current/availability", json={"availableMinutes": budget,
            "expectedPlanVersion": saved["version"], "idempotencyKey": "budget"}, headers=headers)
        assert result.status_code == 200
        before = result.get_json()["plan"]
    response = client.post(url, json={"courses": ["数据结构", "操作系统"]}, headers=headers)
    assert response.status_code == 200
    after = client.get("/api/v1/plans/current", headers=headers).get_json()
    assert after["planId"] == before["planId"]
    assert after["version"] > before["version"]
    combined = after["tasks"] + after.get("unscheduledTasks", [])
    assert next(t for t in combined if t["taskId"] == done["taskId"]) == done
    new_points = {r["knowledgePointId"] for r in response.get_json()["mastery"] if r.get("sourceCourse") == "操作系统"}
    assert new_points
    assert new_points <= {t["knowledgePointId"] for t in combined}
    assert len({t["taskId"] for t in combined}) == len(combined)
    if budget is not None:
        assert sum(t["durationMinutes"] for t in after["tasks"] if t["status"] != "completed") <= budget
    history_count = len(repo.list("plan_histories"))
    assert client.post(url, json={"courses": ["数据结构", "操作系统"]}, headers=headers).status_code == 200
    assert client.get("/api/v1/plans/current", headers=headers).get_json()["version"] == after["version"]
    assert len(repo.list("plan_histories")) == history_count


def test_new_material_point_updates_plan_without_resetting_existing_score(tmp_path):
    create_app(tmp_path / "material.json")
    repo = profile_api._repository
    before = deepcopy(repo.get("profiles", "demo-user"))
    merge_points_into_profile(repo, "demo-user", [{"name": "进程调度", "source": "document"}])
    plan = repo.get("plans", "plan-demo-001")
    assert any(t["knowledgePointId"] == "进程调度" for t in plan["tasks"])
    after = repo.get("profiles", "demo-user")
    for row in before["mastery"]:
        assert next(r for r in after["mastery"] if r["knowledgePointId"] == row["knowledgePointId"]) == row


def test_discovery_plan_failure_does_not_partially_publish_profile(tmp_path, monkeypatch):
    from app.agents.planner import PlannerAgent
    create_app(tmp_path / "failure.json")
    repo = profile_api._repository
    profile = deepcopy(repo.get("profiles", "demo-user"))
    plan = deepcopy(repo.get("plans", "plan-demo-001"))
    def fail(*args):
        raise RuntimeError("planner unavailable")
    monkeypatch.setattr(PlannerAgent, "run", fail)
    with pytest.raises(RuntimeError):
        merge_points_into_profile(repo, "demo-user", ["新增知识点"])
    assert repo.get("profiles", "demo-user") == profile
    assert repo.get("plans", "plan-demo-001") == plan
