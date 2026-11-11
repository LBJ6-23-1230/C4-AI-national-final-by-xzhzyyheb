import base64
import json
from types import SimpleNamespace

import pymupdf
import pytest

from app import create_app
from app.services import photo_practice, vision_cache


PATH = "/api/v1/exercises/photo-practice"
GENERATE = f"{PATH}/generate"
CALC = f"{PATH}/range-sum-01/grade"
WRITTEN = f"{PATH}/bst-inorder-01/grade"


@pytest.fixture
def practice(tmp_path, monkeypatch):
    app = create_app(tmp_path / "photo.json")
    client = app.test_client()
    users = []
    for phone in ("13900007601", "13900007602"):
        result = client.post("/api/v1/auth/register", json={
            "phone": phone, "password": "Photo-test-1234", "nickname": phone,
        }).get_json()
        users.append((result["user"]["userId"], {"Authorization": f"Bearer {result['token']}"}))
    with pymupdf.open() as document:
        page = document.new_page(width=500, height=180)
        page.insert_text((30, 70), "1 + 4 + 1 + 5 = 10", fontsize=23)
        encoded = base64.b64encode(page.get_pixmap().tobytes("jpeg")).decode()
    monkeypatch.setenv("DASHSCOPE_API_KEY", "fixture-only")
    vision_cache.clear()
    yield app, client, users, {"image": encoded}
    vision_cache.clear()


def reply(content):
    return SimpleNamespace(choices=[SimpleNamespace(finish_reason="stop",
        message=SimpleNamespace(content=json.dumps(content, ensure_ascii=False)))])


def graded(criteria, answer="10"):
    return {"status": "graded", "transcript": "学生写出的式子和步骤", "finalAnswer": answer,
            "criteria": [{"id": item["id"], "points": item["maxPoints"], "feedback": "依据原作答"}
                         for item in criteria]}


def test_single_call_corrects_numeric_score_and_scopes_reuse(practice, monkeypatch):
    app, client, users, body = practice
    owner, headers = users[0]
    repository = app.extensions["repository"]
    profile = repository.get("profiles", owner)
    submissions = repository.ids("submissions")
    calls = []

    def model(kind, payload, *, budget):
        assert kind == "photo_grade" and payload["max_tokens"] == 1800 and budget <= 45
        request = json.loads(payload["messages"][1]["content"][1]["text"])
        calls.append(request["title"])
        return reply(graded(request["criteria"]))

    monkeypatch.setattr(photo_practice.llm_runtime, "request", model)
    available = client.get(PATH, headers=headers).get_json()["exercises"]
    assert {item["type"] for item in available} == {"calculation", "written"}
    assert all(set(item) == {"exerciseId", "title", "type", "stem"} for item in available)
    result = client.post(CALC, headers=headers, json=body).get_json()
    assert result["exerciseId"] == "range-sum-01" and result["score"] == 7
    assert result["maxScore"] == 10 and result["criteria"][-1]["points"] == 0
    assert "11" in result["explanation"]
    assert client.post(CALC, headers=headers, json=body).get_json() == result
    assert len(calls) == 1
    assert client.post(CALC, headers=users[1][1], json=body).status_code == 200
    other = client.post(WRITTEN, headers=headers, json=body).get_json()
    assert other["exerciseId"] == "bst-inorder-01" and other["score"] == 10
    assert len(calls) == 3 and len(set(calls)) == 2
    assert repository.get("profiles", owner) == profile and repository.ids("submissions") == submissions


def test_retake_invalid_score_and_timeout_can_retry(practice, monkeypatch):
    _, client, users, body = practice
    headers = users[0][1]
    assert client.post(f"{PATH}/missing/grade", headers=headers, json=body).status_code == 404
    assert client.post(CALC, headers=headers, json={"image": "/9j/not-a-photo"}).status_code == 400

    results = iter([
        {"status": "retake", "message": "最后两行模糊，请补拍。"},
        {"status": "graded", "transcript": "部分结果", "criteria": []},
        TimeoutError(),
        graded(photo_practice.QUESTIONS["range-sum-01"]["criteria"], "１１.０"),
    ])

    def model(*args, **kwargs):
        result = next(results)
        if isinstance(result, Exception):
            raise result
        return reply(result)

    monkeypatch.setattr(photo_practice.llm_runtime, "request", model)
    retake = client.post(CALC, headers=headers, json=body)
    assert retake.status_code == 200 and retake.get_json()["status"] == "retake"
    assert "score" not in retake.get_json()
    assert client.post(CALC, headers=headers, json=body).status_code == 502
    assert client.post(CALC, headers=headers, json=body).status_code == 504
    assert client.post(CALC, headers=headers, json=body).get_json()["score"] == 10


def test_generate_and_grade_saved_question_with_owner_and_unit(practice, monkeypatch):
    app, client, users, photo = practice
    owner, headers = users[0]
    query = {"type": "calculation", "knowledgePointName": "传输时延", "courseName": "计算机网络"}
    contexts = []

    def generate(system, prompt, **options):
        context = json.loads(prompt)
        contexts.append(context)
        size = 2 if context.get("previousStem") else 1
        return json.dumps({"title": "传输时延", "stem": f"发送 {size} Mb 数据，速率为 10 Mb/s。求发送时延（ms），写出过程。",
            "reference": f"数据量除以速率，再换算得到 {size * 100} ms。", "numericAnswer": str(size * 100), "unit": "ms",
            "criteria": [{"label": "写出公式", "maxPoints": 3, "rule": "时延等于数据量除以速率"},
                         {"label": "代入换算", "maxPoints": 4, "rule": "代入数据量和速率，再将秒换算为毫秒"}]})

    monkeypatch.setattr(photo_practice.chat_llm, "_call_llm", generate)
    question = client.post(GENERATE, headers=headers, json=query).get_json()
    exercise_id = question["exerciseId"]
    stored = app.extensions["repository"].get("photo_exercises", exercise_id)
    assert set(question) == {"exerciseId", "type", "title", "stem"}
    assert stored["userId"] == owner and stored["numericAnswer"] == "100"
    assert contexts[0] == {"knowledgePoint": "传输时延", "courseName": "计算机网络", "type": "calculation"}
    second = client.post(GENERATE, headers=headers, json=dict(query, previousExerciseId=exercise_id)).get_json()
    assert second["stem"] != question["stem"] and contexts[1]["previousStem"] == question["stem"]
    assert client.post(GENERATE, headers=users[1][1], json=dict(query, previousExerciseId=exercise_id)).status_code == 200
    assert "previousStem" not in contexts[-1]
    path = f"{PATH}/{exercise_id}/grade"
    assert client.post(path, headers=users[1][1], json=photo).status_code == 404

    final_unit = "s"

    def grade(kind, payload, *, budget):
        rubric = json.loads(payload["messages"][1]["content"][1]["text"])
        assert rubric["stem"] == question["stem"] and "userId" not in rubric
        return reply(dict(graded(rubric["criteria"], "100"), finalUnit=final_unit))

    monkeypatch.setattr(photo_practice.llm_runtime, "request", grade)
    result = client.post(path, headers=headers, json=photo).get_json()
    assert result["score"] == 7 and "100 ms" in result["criteria"][-1]["feedback"]
    vision_cache.clear()
    final_unit = "毫秒"
    assert client.post(path, headers=headers, json=photo).get_json()["score"] == 10


def test_invalid_rubric_and_repeated_question_do_not_return_a_sample(practice, monkeypatch):
    app, client, users, _ = practice
    headers = users[0][1]
    query = {"type": "written", "knowledgePointName": "中序遍历"}
    assert client.post(GENERATE, headers=headers, json=dict(query, type="choice")).status_code == 400
    generated = {"title": "中序遍历", "stem": "解释二叉搜索树的中序遍历为何有序。", "reference": "按左、根、右访问。",
        "criteria": [{"label": "子树", "maxPoints": 4, "rule": "说明子树内有序"},
                     {"label": "拼接", "maxPoints": 5, "rule": "说明按左、根、右拼接后有序"}]}
    monkeypatch.setattr(photo_practice.chat_llm, "_call_llm", lambda *args, **kwargs: json.dumps(generated))
    assert client.post(GENERATE, headers=headers, json=query).status_code == 502
    generated["criteria"][1]["maxPoints"] = 6
    exercise_id = client.post(GENERATE, headers=headers, json=query).get_json()["exerciseId"]
    assert client.post(GENERATE, headers=headers, json=dict(query, previousExerciseId=exercise_id)).status_code == 502
    assert app.extensions["repository"].ids("photo_exercises") == [exercise_id]


@pytest.mark.parametrize("failure", ["duplicate", "invalid_json"])
def test_next_question_retries_unusable_model_output_in_one_request(practice, monkeypatch, failure):
    app, client, users, _ = practice
    owner, headers = users[0]
    repo = app.extensions["repository"]
    previous = "有 50 个节点的单链表，无尾指针，求尾插一次需要移动指针的次数。"
    repo.save("photo_exercises", "photo-previous", {
        "exerciseId": "photo-previous", "userId": owner, "type": "calculation", "stem": previous,
        "knowledgePointName": "线性表与链表", "courseName": "数据结构",
    })
    question = {"title": "遍历单链表", "stem": "从首节点开始，沿 next 指针访问长度为 8 的单链表的最后一个节点，需要前进几次？写出过程。",
        "reference": "首节点已访问，再前进 8 - 1 = 7 次。", "numericAnswer": "7", "unit": "次",
        "criteria": [{"label": "确定起点", "rule": "从第一个节点开始计数"},
                     {"label": "列式计算", "rule": "写出 8 - 1"}]}
    bad = json.dumps(dict(question, stem=previous)) if failure == "duplicate" else '{"stem":'
    responses = iter([bad, json.dumps(question)])
    calls = []
    clock = iter([100.0, 104.0])
    monkeypatch.setattr(photo_practice, "monotonic", lambda: next(clock))
    monkeypatch.setattr(photo_practice.chat_llm, "llm_timeout_seconds", lambda: 30)

    def generate(system, prompt, **options):
        calls.append((system, json.loads(prompt), options["budget"]))
        return next(responses)

    monkeypatch.setattr(photo_practice.chat_llm, "_call_llm", generate)
    response = client.post(GENERATE, headers=headers, json={"type": "calculation",
        "knowledgePointName": "线性表与链表", "courseName": "数据结构", "previousExerciseId": "photo-previous"})
    assert response.status_code == 200
    assert response.get_json()["stem"] == question["stem"]
    assert len(calls) == 2 and calls[0][1] == calls[1][1]
    assert calls[1][1]["previousStem"] == previous and "重新生成整道题" in calls[1][0]
    assert [call[2] for call in calls] == [30, 26]
    assert len(repo.ids("photo_exercises")) == 2


def test_confirm_corrected_answer_and_record_without_mastery_change(practice, monkeypatch):
    app, client, users, photo = practice
    owner, headers = users[0]
    other = users[1][1]
    repo = app.extensions["repository"]
    point = {"knowledgePointId": "numerics-bisection", "knowledgePointName": "二分法",
        "sourceCourse": "计算机数值分析", "masteryScore": 42, "confidence": 0.5,
        "lastUpdated": "2026-11-08T00:00:00+00:00"}
    profile = dict(repo.get("profiles", owner), mastery=[point])
    repo.save("profiles", owner, profile)
    question = dict(photo_practice.QUESTIONS["range-sum-01"], userId=owner, exerciseId="photo-example",
        knowledgePointId=point["knowledgePointId"], knowledgePointName="二分法", courseName="计算机数值分析")
    repo.save("photo_exercises", question["exerciseId"], question)
    path = f"{PATH}/{question['exerciseId']}"
    monkeypatch.setattr(photo_practice.llm_runtime, "request", lambda *args, **kwargs: reply(graded(question["criteria"], "11")))

    draft = client.post(f"{path}/grade", headers=headers, json=dict(photo, review=True)).get_json()
    assert set(draft) == {"status", "exerciseId", "attemptId", "transcript"} and draft["status"] == "review"
    assert not photo_practice.point_feedback(repo, owner)
    completion = {"attemptId": draft["attemptId"], "transcript": "改正识别稿：1 + 4 + 1 + 5 = 10"}
    assert client.post(f"{path}/complete", headers=other, json=completion).status_code == 404
    assert client.post(f"{path}/wrong-book", headers=headers, json=completion).status_code == 404

    model_calls = []

    def regrade(system, prompt, **options):
        data = json.loads(prompt)
        model_calls.append(data["studentAnswer"])
        assert data["question"]["numericAnswer"] == "11"
        return json.dumps(graded(data["question"]["criteria"], "10"))

    monkeypatch.setattr(photo_practice.chat_llm, "_call_llm", regrade)
    result = client.post(f"{path}/complete", headers=headers, json=completion).get_json()
    assert result["score"] == 7 and result["transcript"] == completion["transcript"]
    assert result["knowledgePointId"] == point["knowledgePointId"]
    assert client.post(f"{path}/complete", headers=headers, json=completion).get_json() == result
    assert model_calls == [completion["transcript"]]
    assert repo.get("profiles", owner) == profile
    row = client.get(f"/api/v1/profile/{owner}", headers=headers).get_json()["mastery"][0]
    assert row["photoPracticeCount"] == 1 and row["photoPracticeScore"] == 7 and row["masteryScore"] == 42

    for _ in range(2):
        assert client.post(f"{path}/wrong-book", headers=headers, json=completion).get_json()["added"] is True
    book = client.get("/api/v1/wrong-book", headers=headers).get_json()
    item = book["courses"][0]["items"][0]
    assert book["total"] == 1 and item["knowledgePointId"] == point["knowledgePointId"]
    assert item["courseName"] == point["sourceCourse"] and item["photoPracticeType"] == "calculation"
    assert item["canAutoGrade"] is False and item["explanation"] == question["reference"]

    unchanged = client.post(f"{path}/grade", headers=headers, json=dict(photo, review=True)).get_json()
    result = client.post(f"{path}/complete", headers=headers,
        json={"attemptId": unchanged["attemptId"], "transcript": unchanged["transcript"]}).get_json()
    assert result["score"] == 10 and len(model_calls) == 1
    assert photo_practice.point_feedback(repo, owner)[point["knowledgePointId"]]["photoPracticeCount"] == 1


def test_explicit_unknown_links_new_point_without_a_grade(practice):
    app, client, users, _ = practice
    owner, headers = users[0]
    repo = app.extensions["repository"]
    question = dict(photo_practice.QUESTIONS["bst-inorder-01"], userId=owner, exerciseId="photo-new-point",
        knowledgePointName="二叉搜索树中序遍历", courseName="数据结构")
    repo.save("photo_exercises", question["exerciseId"], question)
    assert not photo_practice.point_feedback(repo, owner)
    path = f"{PATH}/{question['exerciseId']}"
    result = client.post(f"{path}/complete", headers=headers, json={"outcome": "unknown"}).get_json()
    assert result["status"] == "unknown" and "score" not in result and result["explanation"]
    assert client.post(f"{path}/complete", headers=headers, json={"outcome": "unknown"}).get_json() == result
    row = next(point for point in client.get(f"/api/v1/profile/{owner}", headers=headers).get_json()["mastery"]
        if point["knowledgePointId"] == result["knowledgePointId"])
    assert row["photoPracticeStatus"] == "unknown" and row["effectiveQuestionCount"] == 0
    assert client.get("/api/v1/wrong-book", headers=headers).get_json()["total"] == 0
    assert client.post(f"{path}/wrong-book", headers=headers, json={"attemptId": result["attemptId"]}).status_code == 200
