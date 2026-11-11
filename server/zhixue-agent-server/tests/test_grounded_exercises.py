"""Material -> retrieval -> generation -> sources -> assessment regressions.

All model responses are deterministic substitutes, never live model evidence.
"""
import base64
import json

import pytest

from app import create_app
from app.agent import chat_llm, exercise_gen
from app.api import exercises
from app.services import grounded_exercises as grounding

SET = "/api/v1/exercises/set-demo-binary-tree-001"
TEXT = "# 后序遍历\n\n后序遍历的顺序是左子树、右子树、根节点，因此根节点最后访问。不要与中序遍历混淆。"


@pytest.fixture
def setup(tmp_path, monkeypatch):
    client = create_app(tmp_path / "grounding.json").test_client()
    users = []
    for phone in ("13900008801", "13900008802"):
        body = client.post("/api/v1/auth/register", json={'password': 'test-pw-123456', 
            "phone": phone, "nickname": phone, "seedDemoData": True}).get_json()
        users.append((body["user"]["userId"], {"Authorization": f"Bearer {body['token']}"}))
    owner, headers = users[0]
    kb = client.post("/api/v1/knowledge-bases", headers=headers, json={
        "courseName": "数据结构", "name": "本次讲义"}).get_json()["kbId"]
    doc = client.post(f"/api/v1/knowledge-bases/{kb}/documents", headers=headers,
                      json={"fileName": "复习.md", "contentBase64": base64.b64encode(TEXT.encode()).decode()}).get_json()["documentId"]
    document = client.get(f"/api/v1/documents/{doc}", headers=headers).get_json()
    assert client.put(f"/api/v1/documents/{doc}/knowledge-points", headers=headers,
        json={"expectedParsedAt": document["parsedAt"], "knowledgePoints": ["后序遍历"]}).status_code == 200
    calls = []

    def model(system, prompt, **kwargs):
        calls.append(prompt)
        sources = json.loads(prompt.split("资料JSON：", 1)[1])
        return json.dumps({"exercises": [row(sources[0])]})

    monkeypatch.setattr(exercise_gen, "generation_available", lambda: True)
    monkeypatch.setattr(chat_llm, "_call_llm", model)
    return client, exercises._repository, users, kb, doc, calls


def row(source):
    return {"stem": "按照讲义，后序遍历何时访问根节点？", "options": ["A. 最后", "B. 最先", "C. 左右之间", "D. 随机"],
            "answer": "A", "explanation": "讲义明确说明先访问左子树、再右子树，最后访问根节点。",
            "sourceIds": [source["sourceId"]], "supportingQuote": "后序遍历的顺序是左子树、右子树、根节点"}


def generate(setup, **changes):
    client, _, users, kb, doc, _ = setup
    args = {"sourceMode": "materials", "knowledgePointId": "后序遍历", "kbId": kb, "documentId": doc, "count": 1}
    args.update(changes)
    return client.get(SET, query_string=args, headers=users[0][1])


def test_material_options_are_read_only_and_scoped_to_owner_course_and_text(setup):
    client, repo, users, kb, doc, calls = setup
    owner, headers = users[0]
    profile = repo.get("profiles", owner)
    point = next(p for p in profile["mastery"] if p["knowledgePointId"] == "后序遍历")
    point["knowledgePointId"] = "custom-postorder-point"
    repo.save("profiles", owner, profile)
    url = "/api/v1/exercises/material-options"

    def options(query, auth=headers):
        response = client.get(url, query_string=query, headers=auth)
        assert response.status_code == 200
        return response.get_json()["options"]

    outline = dict(repo.get("documents", doc), documentId="outline", fileName="考纲.md")
    repo.save("documents", "outline", outline)
    repo.save("chunks", "outline-chunk", dict(chunkId="outline-chunk", userId=owner,
        kbId=kb, documentId="outline", text="后序遍历：熟悉，重点掌握", headingPath="后序遍历"))
    query = {"knowledgePointId": point["knowledgePointId"], "courseName": "数据结构"}
    expected = [{"kbId": kb, "documentId": doc, "fileName": "复习.md"}]
    assert options(query) == expected
    assert options({"knowledgePointId": point["knowledgePointId"]}) == expected
    assert options(dict(query, courseName="操作系统")) == []
    assert options(dict(query, knowledgePointId="后序遍历"), users[1][1]) == []
    assert options(dict(query, knowledgePointId="图的最短路径")) == []
    assert not calls
    assert not repo.list("exercises")

    response = generate(setup, **query)
    assert response.status_code == 200
    exercise = response.get_json()["exercises"][0]
    assert exercise["knowledgePointId"] == point["knowledgePointId"]
    assert exercise["knowledgePointName"] == "后序遍历"
    assert repo.get("exercises", exercise["exerciseId"])["courseName"] == "数据结构"
    assert generate(setup, **dict(query, courseName="操作系统")).status_code == 400


def test_outline_guides_priority_but_cannot_be_used_as_question_evidence(setup, monkeypatch):
    client, repo, users, kb, doc, _ = setup
    owner, headers = users[0]
    outline_id = "outline-practice"
    excerpt_id = "outline-excerpt"
    name = "期末复习大纲.md"
    repo.save("documents", outline_id, dict(repo.get("documents", doc), documentId=outline_id, fileName=name))
    text = "堆排序：常考，重点掌握。\n后序遍历：必须掌握。\n红黑树：不要求掌握。"
    repo.save("chunks", excerpt_id, dict(chunkId=excerpt_id, userId=owner, kbId=kb, documentId=outline_id,
        text=text, headingPath="期末考试重点"))
    model_calls = []
    original_model = chat_llm._call_llm

    def model(system, prompt, **kwargs):
        if kwargs.get("request_type") != "outline_practice":
            return original_model(system, prompt, **kwargs)
        model_calls.append(prompt)
        return json.dumps({"points": [
            {"point": "堆排序", "id": excerpt_id, "quote": "堆排序：常考，重点掌握。"},
            {"point": "后序遍历", "id": excerpt_id, "quote": "后序遍历：必须掌握。"},
            {"point": "红黑树", "id": excerpt_id, "quote": "红黑树：不要求掌握。"},
            {"point": "图论", "id": excerpt_id, "quote": "图论：必考。"},
        ]})

    monkeypatch.setattr(chat_llm, "llm_ready", lambda: True)
    monkeypatch.setattr(chat_llm, "_call_llm", model)
    url = "/api/v1/exercises/outline-recommendations"
    query = {"courseName": "数据结构"}
    assert client.get(url, headers=users[1][1], query_string=query).get_json() == {"status": "no_outline", "points": []}
    assert client.get(url, headers=headers, query_string={"courseName": "操作系统"}).get_json()["points"] == []
    response = client.get(url, headers=headers, query_string=query).get_json()
    assert response["status"] == "ready"
    points = response["points"]
    assert [(p["knowledgePointName"], p["outlineFileName"]) for p in points] == [("后序遍历", name), ("堆排序", name)]
    assert client.get(url, headers=headers, query_string=query).get_json()["points"] == points
    assert len(model_calls) == 1 and text in model_calls[0].replace("\\n", "\n")
    assert not repo.list("exercises")
    assert client.get("/api/v1/exercises/material-options", headers=headers,
        query_string={**query, "knowledgePointId": "堆排序"}).get_json()["options"] == []
    requests = []

    def generate_fresh(point, count):
        requests.append((point, count))
        return [dict(exerciseId="outline-generated", source="llm", difficulty="medium",
                     stem="在堆排序中，取出堆顶后应先做什么？", options=["A. 调整堆", "B. 清空堆"], answerKey="A")]

    monkeypatch.setattr(exercise_gen, "generate_exercises", generate_fresh)
    query_for_practice = dict(query, knowledgePointId="堆排序", count=1, forceGenerate="1", roundId="outline-direct")
    assert client.get(SET, headers=users[1][1], query_string=query_for_practice).status_code == 400
    result = client.get(SET, headers=headers, query_string=query_for_practice).get_json()
    assert result["exercises"][0]["source"] == "llm"
    assert result["exercises"][0]["knowledgePointId"] == "堆排序"
    assert requests == [("数据结构：堆排序", 1)] and len(model_calls) == 1
    assert any(row["knowledgePointId"] == "堆排序" and row["sourceCourse"] == "数据结构"
               for row in repo.get("profiles", owner)["mastery"])
    question = generate(setup).get_json()["exercises"][0]
    assert all(source["documentId"] == doc for source in question["sources"])
    monkeypatch.setattr(chat_llm, "llm_ready", lambda: False)
    fallback = client.get(url, headers=headers, query_string=query).get_json()
    assert fallback["status"] == "outline_topics"
    assert [p["knowledgePointName"] for p in fallback["points"]] == ["后序遍历", "堆排序"]
    repo.save("chunks", excerpt_id, dict(repo.get("chunks", excerpt_id), text="第一章：方程求根"))
    assert client.get(url, headers=headers, query_string=query).get_json() == {"status": "no_priorities", "points": []}


def test_review_handout_and_question_bank_link_without_priority_markers(setup):
    client, _, users, _, _, calls = setup
    _, headers = users[0]
    course = "计算机数值分析"
    kb = client.post("/api/v1/knowledge-bases", headers=headers, json={
        "courseName": course, "name": "数值分析资料"}).get_json()["kbId"]
    handout = "【串讲】计算机数值分析.txt"
    bank = "数值分析客观题汇总.txt"
    for name, text in (
        (handout, "CH2 数值积分问题的描述：为什么数值积分。\nCH3 常微分方程的差分方法：欧拉法。\n二分法不考。"),
        (bank, "数值积分用于近似计算定积分。常微分方程可用欧拉法近似求解。二分法需要检验区间端点符号。"),
    ):
        doc = client.post(f"/api/v1/knowledge-bases/{kb}/documents", headers=headers, json={
            "fileName": name, "contentBase64": base64.b64encode(text.encode()).decode()}).get_json()
        assert client.put(f"/api/v1/documents/{doc['documentId']}/knowledge-points", headers=headers,
                          json={"expectedParsedAt": doc["parsedAt"], "knowledgePoints": (
                              ["数值积分", "常微分方程", "二分法"] if name == bank else [])}).status_code == 200
    query = {"courseName": course}
    result = client.get("/api/v1/exercises/outline-recommendations", headers=headers, query_string=query).get_json()
    assert result["status"] == "outline_topics"
    assert [(p["knowledgePointName"], p["outlineFileName"]) for p in result["points"]] == [
        ("数值积分", handout), ("常微分方程", handout)]
    for point in result["points"]:
        options = client.get("/api/v1/exercises/material-options", headers=headers,
            query_string={**query, "knowledgePointId": point["knowledgePointName"]}).get_json()["options"]
        assert bank in [option["fileName"] for option in options]
    assert client.get("/api/v1/exercises/outline-recommendations", headers=users[1][1],
        query_string=query).get_json() == {"status": "no_outline", "points": []}
    assert not calls


def test_full_material_assessment_chain(setup):
    client, repo, users, _, _, calls = setup
    profile = repo.get("profiles", users[0][0])
    for mastery in profile["mastery"]:
        if mastery["knowledgePointId"] == "后序遍历":
            mastery["masteryScore"] = 42
    repo.save("profiles", users[0][0], profile)
    plan = client.get('/api/v1/plans/current', headers=users[0][1]).get_json()
    assert client.post('/api/v1/plans/current/availability', headers=users[0][1], json={
        'targetCourse': '数据结构', 'availableMinutes': 60, 'expectedPlanVersion': plan['version'],
        'idempotencyKey': 'material-course'}).status_code == 200
    body = generate(setup).get_json()
    assert len(calls) == 1
    question = body["exercises"][0]
    assert question["source"] == "materials" and question["sources"][0]["chunkIndex"] > 0
    assert not {"answerKey", "explanation", "supportingQuote"}.intersection(question)
    source_url = f"/api/v1/exercises/{question['exerciseId']}/sources"
    sources = client.get(source_url, headers=users[0][1]).get_json()
    assert "后序遍历" in sources["sources"][0]["text"]
    assert not {"answerKey", "explanation"}.intersection(sources)
    result = client.post(SET + "/submit", headers=users[0][1], json={
        "idempotencyKey": "material-submit", "answers": [{"exerciseId": question["exerciseId"], "answer": "B"}]}).get_json()
    assert result["assessment"]["score"] == 0
    assert result["masteryUpdate"]["oldScore"] == 42
    assert result["masteryUpdate"]["newScore"] == 38
    assert result["needReplan"] and result["planDiff"]["newVersion"] > result["planDiff"]["oldVersion"]
    assert result["review"][0]["explanationSource"] == "materials"
    assert result["review"][0]["sources"] == question["sources"]
    assert len(calls) == 1, "Review must retain source-backed explanation without another model call"
    assert next(m for m in repo.get("profiles", users[0][0])["mastery"] if m["knowledgePointId"] == "后序遍历")["masteryScore"] == 38
    from app.repositories.json_repository import JsonRepository
    restored = JsonRepository(repo.path)
    assert restored.get("exercises", question["exerciseId"])["sources"] == question["sources"]
    replay = client.post(SET + "/submit", headers=users[0][1], json={
        "idempotencyKey": "material-submit", "answers": [{"exerciseId": question["exerciseId"], "answer": "B"}]}).get_json()
    assert replay == result and len(calls) == 1
    wrong = client.get("/api/v1/wrong-book", headers=users[0][1]).get_json()["courses"]
    assert any(item["sources"] == question["sources"] for course in wrong for item in course["items"])
    trace = repo.get("traces", body["traceId"])["events"][0]
    assert trace["toolCalls"] == ["retrieve_materials", "generate_grounded_exercises"]


def test_material_cache_invalidates_on_document_version_usage_and_deletion(setup):
    client, repo, users, kb, doc, calls = setup
    first = generate(setup).get_json()["exercises"]
    assert generate(setup).get_json()["exercises"] == first
    assert len(calls) == 1
    document = repo.get("documents", doc)
    document["parsedAt"] = "2026-10-22T10:00:00Z"
    repo.save("documents", doc, document)
    second = generate(setup).get_json()["exercises"]
    assert second != first and len(calls) == 2
    assert client.post(SET + "/submit", headers=users[0][1], json={
        "idempotencyKey": "cache-used", "answers": [{"exerciseId": second[0]["exerciseId"], "answer": "A"}]}).status_code == 200
    third = generate(setup).get_json()["exercises"]
    assert third != second and len(calls) == 3
    repo.delete("documents", doc)
    assert generate(setup).status_code == 404
    assert len(calls) == 3


@pytest.mark.parametrize("identity", [1, None])
def test_other_identity_cannot_generate_read_or_submit(setup, identity):
    client, _, users, kb, doc, calls = setup
    question = generate(setup).get_json()["exercises"][0]
    headers = users[identity][1] if identity is not None else {}
    assert client.get(SET, headers=headers, query_string={"sourceMode": "materials", "kbId": kb,
        "documentId": doc, "knowledgePointId": "后序遍历"}).status_code == 404
    assert client.get(f"/api/v1/exercises/{question['exerciseId']}/sources", headers=headers).status_code == 404
    for ids in ([question["exerciseId"]], ["exercise-postorder-001", question["exerciseId"]]):
        response = client.post(SET + "/submit", headers=headers, json={"idempotencyKey": "private",
            "answers": [{"exerciseId": value, "answer": "A"} for value in ids]})
        assert response.status_code == 404 and "review" not in response.get_json()
    assert len(calls) == 1


def test_insufficient_materials_never_substitutes_bank(setup):
    body = generate(setup, knowledgePointId="binary-tree-postorder-unknown").get_json()
    assert body["failureReason"] == "INSUFFICIENT_MATERIALS" and body["exercises"] == []
    assert setup[-1] == []


@pytest.mark.parametrize("mutation", [
    {"sourceIds": ["fabricated"]}, {"supportingQuote": "不存在于任何上传资料中的引用内容"},
    {"explanation": ""}, {"answer": "A incorrect"},
    {"options": ["A. 相同", "B. 相同", "C. 不同", "D. 其他"]},
    {"sourceIds": []}, {"stem": ""},
    {"options": [1, 2, 3, 4]},
])
def test_invalid_grounding_is_rejected_without_fallback(setup, monkeypatch, mutation):
    def model(system, prompt, **kwargs):
        source = json.loads(prompt.split("资料JSON：")[1])[0]
        return json.dumps({"exercises": [dict(row(source), **mutation)]})
    monkeypatch.setattr(chat_llm, "_call_llm", model)
    body = generate(setup).get_json()
    assert body["exercises"] == [] and body["failureReason"] == "GENERATION_FAILED"
    assert setup[1].list("exercises") == []


def test_model_unavailable_is_explicit(setup, monkeypatch):
    monkeypatch.setattr(exercise_gen, "generation_available", lambda: False)
    assert generate(setup).get_json()["failureReason"] == "GENERATION_FAILED"
    assert setup[-1] == []


@pytest.mark.parametrize("response", ["invalid json", '{"exercises":[]}', '{"exercises":[null]}'])
def test_model_invalid_response_is_explicit(setup, monkeypatch, response):
    monkeypatch.setattr(chat_llm, "_call_llm", lambda *a, **k: response)
    assert generate(setup).get_json()["failureReason"] == "GENERATION_FAILED"


def test_source_delete_during_generation_does_not_publish(setup, monkeypatch):
    client, repo, users, _, doc, _ = setup
    original = chat_llm._call_llm
    def delete_then_generate(*args, **kwargs):
        assert client.delete(f"/api/v1/documents/{doc}", headers=users[0][1]).status_code == 200
        return original(*args, **kwargs)
    monkeypatch.setattr(chat_llm, "_call_llm", delete_then_generate)
    body = generate(setup).get_json()
    assert body["failureReason"] == "SOURCE_CHANGED" and repo.list("exercises") == []


@pytest.mark.parametrize("change", ["delete", "text", "version"])
def test_sources_fail_honestly_after_material_changed(setup, change):
    client, repo, users, _, doc, _ = setup
    item = generate(setup).get_json()["exercises"][0]
    source = item["sources"][0]
    if change == "delete":
        client.delete(f"/api/v1/documents/{doc}", headers=users[0][1])
    elif change == "text":
        chunk = repo.get("chunks", source["chunkId"])
        repo.save("chunks", source["chunkId"], dict(chunk, text="资料已改变"))
    else:
        record = repo.get("documents", doc)
        repo.save("documents", doc, dict(record, parsedAt="later"))
    result = client.get(f"/api/v1/exercises/{item['exerciseId']}/sources", headers=users[0][1])
    assert result.status_code == 410 and result.get_json()["errorCode"] == "SOURCE_UNAVAILABLE"


def test_non_computer_course_supported(setup, monkeypatch):
    client, repo, users, _, _, _ = setup
    headers = users[0][1]
    kb = client.post("/api/v1/knowledge-bases", headers=headers, json={"courseName": "生物学", "name": "生物讲义"}).get_json()["kbId"]
    doc = client.post(f"/api/v1/knowledge-bases/{kb}/documents", headers=headers, json={
        "fileName": "biology.txt", "contentBase64": base64.b64encode("光合作用利用光能，将二氧化碳和水合成为有机物，并释放氧气。".encode()).decode()}).get_json()["documentId"]
    sources, error = grounding.retrieve(repo, users[0][0], "光合作用", kb, doc)
    assert not error and len(sources) == 1 and sources[0]["documentId"] == doc
    assert grounding.retrieve(repo, users[0][0], "后序遍历", kb, doc)[1] == "INSUFFICIENT_MATERIALS"


@pytest.mark.parametrize("changes", [{"kbId": ""}, {"knowledgePointId": ""}, {"count": 7}, {"sourceMode": "typo"}])
def test_material_request_guards(setup, changes):
    assert generate(setup, **changes).status_code == 400
