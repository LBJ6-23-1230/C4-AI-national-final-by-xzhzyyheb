"""决赛评估中的甲/乙/游客/失效凭据访问矩阵。"""
import base64

import pytest

from app import create_app
from app.repositories.json_repository import JsonRepository


@pytest.fixture
def accounts(tmp_path):
    path = tmp_path / "access.json"
    client = create_app(path).test_client()
    users = []
    for phone in ("13900009001", "13900009002"):
        response = client.post("/api/v1/auth/register", json={'password': 'test-pw-123456', 
            "phone": phone, "nickname": phone, "seedDemoData": True})
        assert response.status_code == 201
        body = response.get_json()
        users.append((body["user"]["userId"], {"Authorization": f"Bearer {body['token']}"}))
    return client, JsonRepository(path), users


@pytest.mark.parametrize("identity,status", [(0, 404), (1, 200), (None, 404), ("invalid", 401)])
def test_private_resource_matrix(accounts, identity, status):
    client, repo, users = accounts
    owner, owner_headers = users[1]
    headers = ({"Authorization": "Bearer invalid"} if identity == "invalid" else
               users[identity][1] if identity is not None else {})
    kb = client.post("/api/v1/knowledge-bases", json={"name": "乙的资料", "courseName": "数据结构"},
                     headers=owner_headers).get_json()["kbId"]
    document = client.post(f"/api/v1/knowledge-bases/{kb}/documents", json={
        "fileName": "private.txt",
        "contentBase64": base64.b64encode("私有讲义".encode()).decode()},
        headers=owner_headers).get_json()["documentId"]
    workflow = client.post("/api/v1/workflows", json={"goal": "乙的任务"},
                           headers=owner_headers).get_json()
    for url in (f"/api/v1/profile/{owner}", f"/api/v1/plans/plan-{owner}/diff",
                f"/api/v1/knowledge-bases/{kb}", f"/api/v1/documents/{document}",
                f"/api/v1/workflows/{workflow['sessionId']}",
                f"/api/v1/traces/{workflow['traceId']}"):
        assert client.get(url, headers=headers).status_code == status, url
    # 创建接口的同 ID 重试也必须校验所有权。
    assert client.post("/api/v1/workflows", json={"goal": "重试", "sessionId": workflow["sessionId"]},
                       headers=headers).status_code == status
    assert client.post(f"/api/v1/workflows/{workflow['sessionId']}/run", json={},
                       headers=headers).status_code == status


@pytest.mark.parametrize("url", ["/api/v1/plans/current", "/api/v1/knowledge-bases",
                                "/api/v1/wrong-book", "/api/agent/history", "/api/agent/user-data"])
def test_guest_cannot_select_registered_identity(accounts, url):
    client, _, users = accounts
    assert client.get(f"{url}?userId={users[1][0]}").status_code == 404


@pytest.mark.parametrize("authorization", ["", "Basic abc", "Bearer", "Bearer garbage"])
def test_malformed_credentials_never_fall_back_to_demo(accounts, authorization):
    client, _, _ = accounts
    assert client.get("/api/v1/profile/demo-user", headers={"Authorization": authorization}).status_code == 401


def test_expired_credentials_are_rejected(accounts):
    client, repo, users = accounts
    from app.api import auth
    repository = auth._repository
    for key in repository.ids("sessions"):
        session = repository.get("sessions", key)
        session["expiresAt"] = "2000-01-01T00:00:00+00:00"
        repository.save("sessions", key, session)
    assert client.get("/api/v1/profile/demo-user", headers=users[0][1]).status_code == 401


def test_logged_out_credentials_are_rejected(accounts):
    client, _, users = accounts
    assert client.post("/api/v1/auth/logout", headers=users[0][1]).status_code == 200
    assert client.get("/api/v1/profile/demo-user", headers=users[0][1]).status_code == 401


@pytest.mark.parametrize("identity,status", [(0, 200), (1, 200), (None, 200), ("invalid", 401)])
def test_demo_profile_is_public_with_valid_or_no_credentials(accounts, identity, status):
    client, _, users = accounts
    headers = ({"Authorization": "Bearer invalid"} if identity == "invalid" else
               users[identity][1] if identity is not None else {})
    assert client.get("/api/v1/profile/demo-user", headers=headers).status_code == status


def test_concurrent_session_creation_preserves_first_owner(accounts):
    from concurrent.futures import ThreadPoolExecutor
    client, _, users = accounts

    def create(user):
        with client.application.test_client() as concurrent_client:
            return concurrent_client.post("/api/v1/workflows", json={
                "goal": "同时创建", "sessionId": "shared-id"}, headers=user[1]).status_code

    with ThreadPoolExecutor(max_workers=2) as pool:
        statuses = list(pool.map(create, users))
    assert sorted(statuses) == [200, 404]
    for user, creation_status in zip(users, statuses):
        assert client.get("/api/v1/workflows/shared-id", headers=user[1]).status_code == creation_status


def test_guest_cannot_write_real_profile(accounts):
    client, _, users = accounts
    owner, headers = users[1]
    before = client.get(f"/api/v1/profile/{owner}", headers=headers).get_json()
    assert client.post(f"/api/v1/profile/{owner}/knowledge-points",
                       json={"courses": ["操作系统"]}).status_code == 404
    assert client.post("/api/v1/workflows", json={"goal": "冒用", "userId": owner}).status_code == 404
    assert client.post("/api/v1/exercises/set-demo-binary-tree-001/submit", json={
        "userId": owner, "idempotencyKey": "forged", "answers": []}).status_code == 404
    assert client.get(f"/api/v1/profile/{owner}", headers=headers).get_json() == before


def test_tools_are_closed_by_default(accounts, monkeypatch):
    client, _, users = accounts
    monkeypatch.delenv("ZHIXUE_ENABLE_DEV_TOOLS", raising=False)
    for headers in ({}, users[0][1]):
        assert client.post("/api/v1/demo/reset", headers=headers).status_code == 404
        assert client.get("/api/v1/experiments/snapshot", headers=headers).status_code == 404


def test_unknown_trace_owner_is_not_public(accounts):
    client, _, users = accounts
    from app.api import traces
    traces._repository.save("traces", "unowned", {"traceId": "unowned", "events": []})
    for headers in ({}, users[0][1]):
        assert client.get("/api/v1/traces/unowned", headers=headers).status_code == 404


def test_cross_account_submission_keys_do_not_overwrite_trace(accounts):
    client, _, users = accounts
    results = []
    for _, headers in users:
        result = client.post("/api/v1/exercises/set-demo-binary-tree-001/submit", json={
            "idempotencyKey": "same-key", "answers": [{"exerciseId": "exercise-preorder-001", "answer": "A"}]},
            headers=headers)
        assert result.status_code == 200
        results.append(result.get_json())
    assert results[0]["traceId"] != results[1]["traceId"]
    assert results[0]["evidenceIds"] != results[1]["evidenceIds"]
    assert client.get(f"/api/v1/traces/{results[0]['traceId']}", headers=users[0][1]).status_code == 200
    assert client.get(f"/api/v1/traces/{results[0]['traceId']}", headers=users[1][1]).status_code == 404
