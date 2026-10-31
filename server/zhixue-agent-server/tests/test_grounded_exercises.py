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
