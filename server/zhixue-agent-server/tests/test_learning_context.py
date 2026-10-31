"""Chat/workflow/practice share a durable, owner-scoped learning goal."""
import copy
from concurrent.futures import ThreadPoolExecutor

import pytest

from app import create_app
from app.agent import chat_llm
from app.api import workflows, exercises
from app.services import learning_context

SET = "/api/v1/exercises/set-demo-binary-tree-001/submit"


@pytest.fixture(params=["json", "sqlite"])
def setup(tmp_path, monkeypatch, request):
    monkeypatch.setenv("ZHIXUE_DB", request.param)
    client = create_app(tmp_path / "context.json").test_client()
    users = []
    for phone in ("13900007701", "13900007702"):
        body = client.post("/api/v1/auth/register", json={'password': 'test-pw-123456', 
            "phone": phone, "nickname": phone, "seedDemoData": True}).get_json()
        users.append((body["user"]["userId"], {"Authorization": "Bearer " + body["token"]}))
    monkeypatch.setattr(chat_llm, "chat", lambda **kwargs: {
        "reply": "根据已保存状态继续学习。", "intent": "get_suggestion", "card": None, "llmUsed": False})
    return client, workflows._repository, users


def chat(setup, chat_id="chat-a", identity=0):
    return setup[0].post("/api/agent/chat", headers=setup[2][identity][1], json={
        "message": "帮我按薄弱点安排复习并诊断", "sessionId": chat_id, "coordinateLearning": True})


def submit(setup, context, key="goal-submit", answer="A"):
    return setup[0].post(SET, headers=setup[2][0][1], json={
        "goalId": context["goalId"], "goalStateVersion": context["stateVersion"],
        "idempotencyKey": key, "answers": [{"exerciseId": "exercise-preorder-001", "answer": answer}]})


def test_chat_goal_submission_and_planning_are_one_chain(setup):
    client, repo, users = setup
    context = chat(setup).get_json()["learningContext"]
    assert context["knowledgePointId"] == "binary-tree-postorder"
    assert context["status"] == "waiting_for_answers"
    assert context["handoffs"][0]["receiver"] == "exercise"
    assert context["handoffs"][0]["toolCalls"] == ["select_exercises"]
    assert context["planId"] and context["planVersion"] == 1
    response = submit(setup, context, answer="B")
    assert response.status_code == 200, response.get_json()
    result = response.get_json()
    assert result["goalId"] == context["goalId"] and result["needReplan"]
    version = repo.get("profiles", users[0][0])["profileVersion"]
    # Lost client sync is repaired by resuming without a submission payload.
    resumed = client.post(f"/api/v1/workflows/{context['sessionId']}/run", json={}, headers=users[0][1]).get_json()
    current = resumed["learningContext"]
    assert current["status"] == "completed" and current["goalId"] == context["goalId"]
    assert current["assessmentTraceId"] == result["traceId"]
    assert [h["receiver"] for h in current["handoffs"]] == ["exercise", "assessment", "planner"]
    assert current["planVersion"] == result["plan"]["version"]
    assert submit(setup, context, answer="B").get_json() == result
    assert submit(setup, context).status_code == 409, "Changing answers must not silently reuse an acknowledged idempotency key"
    assert chat(setup).get_json()["learningContext"]["goalId"] == context["goalId"]
    assert repo.get("profiles", users[0][0])["profileVersion"] == version
    assert "answerKeys" not in str(resumed) and "answerKey" not in str(current)


def test_cold_account_waits_and_recovers_after_import(setup):
    client, repo, users = setup
    owner, headers = users[0]
    profile = repo.get("profiles", owner)
    repo.save("profiles", owner, dict(profile, mastery=[]))
    for plan in repo.list("plans"):
        if plan.get("userId") == owner:
            repo.delete("plans", plan["planId"])
    context = chat(setup).get_json()["learningContext"]
    assert context["waitingFor"] == "knowledge_points" and context["knowledgePointId"] == ""
    # 空账号的目标动作必须指向**可执行的导入入口**，而不是只读的学情画像页。
    assert context["action"]["targetPage"] == "pages/CourseImport"
    assert context["action"]["label"] == "补充课程与知识点"
    assert chat(setup).get_json()["learningContext"]["stateVersion"] == context["stateVersion"]
    assert client.get("/api/v1/plans/current", headers=headers).status_code == 404
    assert repo.get("profiles", owner)["mastery"] == []
    imported = client.post(f"/api/v1/profile/{owner}/knowledge-points", headers=headers,
                           json={"courses": ["数据结构"]})
    assert imported.status_code == 200
    resumed = chat(setup).get_json()["learningContext"]
    assert resumed["goalId"] == context["goalId"] and resumed["knowledgePointId"]
    assert resumed["waitingFor"] in ("answers", "exercise_generation")


def test_same_chat_id_does_not_cross_accounts_and_restart_restores_goal(setup):
    client, repo, users = setup
    first = chat(setup).get_json()["learningContext"]
    second = chat(setup, identity=1).get_json()["learningContext"]
    assert first["goalId"] != second["goalId"]
    assert client.get(f"/api/v1/workflows/{first['goalId']}", headers=users[1][1]).status_code == 404
    assert client.post(f"/api/v1/workflows/{first['goalId']}/run", json={}, headers=users[1][1]).status_code == 404
    client = create_app(repo.path).test_client()
    restored = client.get("/api/v1/workflows/chat/chat-a", headers=users[0][1]).get_json()
    assert restored["goalId"] == first["goalId"] and restored["stateVersion"] == first["stateVersion"]
    assert client.get("/api/v1/workflows/chat/chat-a").status_code == 404


def test_goal_submission_cannot_be_attached_to_another_goal(setup):
    client, _, users = setup
    first = chat(setup).get_json()["learningContext"]
    second = chat(setup, "chat-b").get_json()["learningContext"]
    result = submit(setup, first).get_json()
    response = client.post(f"/api/v1/workflows/{second['sessionId']}/run", headers=users[0][1],
                           json={"submissionId": result["submissionId"]})
    assert response.status_code == 404
    assert submit(setup, second).status_code == 409


@pytest.mark.parametrize("change", ["version", "profile", "plan", "point", "owner"])
def test_rejects_stale_or_unrelated_goal_submission_before_grading(setup, monkeypatch, change):
    client, repo, users = setup
    context = chat(setup).get_json()["learningContext"]
    if change == "version":
        context["stateVersion"] -= 1
    elif change == "profile":
        profile = repo.get("profiles", users[0][0])
        repo.save("profiles", users[0][0], dict(profile, profileVersion=profile["profileVersion"] + 1))
    elif change == "plan":
        plan = repo.get("plans", context["planId"])
        repo.save("plans", context["planId"], dict(plan, version=plan["version"] + 1))
    elif change == "point":
        goal = repo.get("workflows", context["goalId"])
        state = copy.deepcopy(goal["state"])
        state["coordination"]["knowledgePointId"] = "graph-algorithm"
        repo.save("workflows", context["goalId"], dict(goal, state=state))
    else:
        context = chat(setup, identity=1).get_json()["learningContext"]
    calls = []
    monkeypatch.setattr(exercises.exercise_gen, "generate_review_explanations", lambda *a: calls.append(1))
    assert submit(setup, context).status_code in (404, 409)
    assert calls == []


def test_zero_time_wait_and_resume_uses_latest_plan(setup):
    client, repo, users = setup
    context = chat(setup).get_json()["learningContext"]
    url = "/api/v1/plans/current/availability"
    plan = repo.get("plans", context["planId"])
    response = client.post(url, headers=users[0][1], json={
        "availableMinutes": 0, "expectedPlanVersion": plan["version"], "idempotencyKey": "zero"})
    assert response.status_code == 200
    waiting = chat(setup).get_json()["learningContext"]
    assert waiting["waitingFor"] == "available_time"
    assert waiting["action"]["targetPage"] == "pages/StudyPlan"
    client.post(url, headers=users[0][1], json={"availableMinutes": 90,
        "expectedPlanVersion": response.get_json()["plan"]["version"], "idempotencyKey": "time-back"})
    resumed = chat(setup).get_json()["learningContext"]
    assert resumed["goalId"] == context["goalId"] and resumed["waitingFor"] == "answers"


def test_atomic_submission_binding_failure_rolls_back_mastery_and_plan(setup, monkeypatch):
    client, repo, users = setup
    context = chat(setup).get_json()["learningContext"]
    def snapshot():
        return {collection: {key: copy.deepcopy(repo.get(collection, key)) for key in repo.ids(collection)}
                for collection in ("profiles", "plans", "evidences", "wrong_book", "plan_histories", "learning_events", "traces", "submissions", "workflows")}
    before = snapshot()
    from app.repositories.staged_repository import StagedRepository
    original = StagedRepository.save
    def fail_binding(self, collection, key, value):
        if collection == "workflows":
            raise RuntimeError("binding unavailable")
        return original(self, collection, key, value)
    monkeypatch.setattr(StagedRepository, "save", fail_binding)
    assert submit(setup, context, answer="B").status_code == 500
    assert snapshot() == before


def test_goal_rejects_second_distinct_submission(setup):
    context = chat(setup).get_json()["learningContext"]
    assert submit(setup, context).status_code == 200
    assert submit(setup, context, key="second").status_code == 409


def test_concurrent_distinct_submissions_only_grade_goal_once(setup):
    client, repo, users = setup
    context = chat(setup).get_json()["learningContext"]
    before = repo.get("profiles", users[0][0])["profileVersion"]
    def send(index):
        with client.application.test_client() as concurrent_client:
            return concurrent_client.post(SET, headers=users[0][1], json={
                "goalId": context["goalId"], "goalStateVersion": context["stateVersion"],
                "idempotencyKey": f"concurrent-{index}",
                "answers": [{"exerciseId": "exercise-preorder-001", "answer": "A"}]}).status_code
    with ThreadPoolExecutor(max_workers=6) as pool:
        statuses = list(pool.map(send, range(6)))
    assert statuses.count(200) == 1 and statuses.count(409) == 5
    assert repo.get("profiles", users[0][0])["profileVersion"] == before + 1


def test_no_evidence_label_is_distinct_from_low_mastery(setup):
    client, repo, users = setup
    profile = repo.get("profiles", users[0][0])
    repo.save("profiles", users[0][0], dict(profile, history=[], evidence=[]))
    context = chat(setup).get_json()["learningContext"]
    assert context["assessmentStatus"] == "not_assessed" and context["assessedQuestionCount"] == 0
    assert submit(setup, context).status_code == 200
    after = client.get("/api/v1/workflows/chat/chat-a", headers=users[0][1]).get_json()
    assert after["assessmentStatus"] == "assessed" and after["assessedQuestionCount"] == 1


def test_coordinated_goal_uses_single_grading_entry_and_version_fences(setup):
    client, _, users = setup
    context = chat(setup).get_json()["learningContext"]
    path = f"/api/v1/workflows/{context['sessionId']}/run"
    assert client.post(path, headers=users[0][1], json={"answers": [{"exerciseId": "exercise-preorder-001", "answer": "A"}]}).status_code == 409
    assert client.post(path, headers=users[0][1], json={"expectedStateVersion": context["stateVersion"] + 1}).status_code == 409
    assert client.post(path, headers=users[0][1], json={"expectedStateVersion": True}).status_code == 400


def test_tool_failure_is_visible_and_can_retry_same_goal(setup, monkeypatch):
    original = workflows._agent_action
    monkeypatch.setattr(workflows, "_agent_action", lambda *args: (_ for _ in ()).throw(RuntimeError("private diagnostic")))
    context = chat(setup).get_json()["learningContext"]
    assert context["status"] == "tool_failed"
    assert "private diagnostic" not in str(context)
    monkeypatch.setattr(workflows, "_agent_action", original)
    recovered = chat(setup).get_json()["learningContext"]
    assert recovered["goalId"] == context["goalId"] and recovered["waitingFor"] == "answers"


def test_dispatch_model_never_receives_answer_keys(setup, monkeypatch):
    captured = []
    class Adapter:
        def safe_decide(self, state):
            captured.append(state)
            return None
    monkeypatch.setattr(workflows.QwenAdapter, "from_environment", lambda: Adapter())
    # Exercise the remaining ambiguous branch: single-action states now skip
    # dispatch entirely. Keep the privacy assertion non-vacuous with real secrets.
    original_state = workflows._workflow_state
    def ambiguous_state(workflow):
        return dict(original_state(workflow), profile=None, plan=None,
                    answerKeys={"q": "A"}, answers=["A"], exercises=[{"answer": "A"}])
    monkeypatch.setattr(workflows, "_workflow_state", ambiguous_state)
    client = setup[0]
    created = client.post("/api/v1/workflows", json={"goal": "旧入口安全调度"}).get_json()
    client.post(f"/api/v1/workflows/{created['sessionId']}/run", json={})
    assert captured and all(not {"answerKeys", "answers", "exercises"}.intersection(s) for s in captured)


def test_named_point_changes_the_selected_goal_input(setup):
    client, repo, users = setup
    profile = repo.get("profiles", users[0][0])
    profile["mastery"].append(dict(profile["mastery"][0], knowledgePointId="graph-algorithm", knowledgePointName="图算法", masteryScore=80))
    repo.save("profiles", users[0][0], profile)
    context = client.post("/api/agent/chat", headers=users[0][1], json={
        "message": "这次我要复习图算法", "sessionId": "explicit-topic", "coordinateLearning": True}).get_json()["learningContext"]
    assert context["knowledgePointId"] == "graph-algorithm"
    assert context["knowledgePointName"] == "图算法"


def test_named_missing_point_waits_instead_of_defaulting_to_trees(setup):
    client, repo, users = setup
    context = client.post("/api/agent/chat", headers=users[0][1], json={
        "message": "我想复习图算法", "sessionId": "missing-topic", "coordinateLearning": True}).get_json()["learningContext"]
    assert context["knowledgePointId"] == "graph-algorithm"
    assert context["waitingFor"] == "knowledge_points"
    assert not any(p["knowledgePointId"] == "graph-algorithm" for p in repo.get("profiles", users[0][0])["mastery"])


@pytest.mark.parametrize("value", [{}, [], True, 1, "", "x" * 513])
def test_workflow_submission_id_guard(setup, value):
    context = chat(setup).get_json()["learningContext"]
    response = setup[0].post(f"/api/v1/workflows/{context['sessionId']}/run", headers=setup[2][0][1], json={"submissionId": value})
    assert response.status_code == 400


def test_greeting_does_not_create_a_learning_goal(setup):
    response = setup[0].post("/api/agent/chat", headers=setup[2][0][1], json={
        "message": "你好", "sessionId": "greeting", "coordinateLearning": True}).get_json()
    assert "learningContext" not in response
    assert setup[0].get("/api/v1/workflows/chat/greeting", headers=setup[2][0][1]).status_code == 404


def test_named_course_selects_only_its_points(setup):
    client, repo, users = setup
    owner = users[0][0]
    profile = repo.get("profiles", owner)
    template = profile["mastery"][0]
    profile["mastery"] = [dict(template, knowledgePointId="tree", knowledgePointName="树", sourceCourse="数据结构", masteryScore=0),
                          dict(template, knowledgePointId="进程同步", knowledgePointName="进程同步", sourceCourse="操作系统", masteryScore=50)]
    repo.save("profiles", owner, profile)
    context = client.post("/api/agent/chat", headers=users[0][1], json={
        "message": "帮我复习操作系统", "sessionId": "explicit-course", "coordinateLearning": True}).get_json()["learningContext"]
    assert context["knowledgePointId"] == "进程同步"
    assert context["waitingFor"] == "exercise_generation"


def test_chat_goal_endpoint_reports_404_when_workflow_has_no_goal(setup):
    """会话存在但没有目标协调状态时，必须回 404 而不是 200 + `null`。

    旧实现直接 `jsonify(None)`：HTTP 200、正文 `null`，而契约声明 200 必须是
    LearningContext 对象。前端按契约校验后只能显示"数据结构与契约不一致"，
    既说不清"这个聊天没有目标"，也不会清掉上一次的目标卡。
    """
    client, repo, users = setup
    owner = users[0][0]
    session_id = learning_context.chat_workflow_id(owner, "chat-no-goal")
    repo.save("workflows", session_id, {"sessionId": session_id, "traceId": f"trace-{session_id}",
                                        "userId": owner, "goal": "没有目标协调状态的会话",
                                        "status": "running", "stateVersion": 1, "state": {}})
    response = client.get("/api/v1/workflows/chat/chat-no-goal", headers=users[0][1])
    assert response.status_code == 404
    assert response.get_json()["message"] == "learning goal not found"
