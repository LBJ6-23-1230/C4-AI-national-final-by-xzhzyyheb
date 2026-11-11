# -*- coding: utf-8 -*-
"""手机号注册与华为账号登录回归测试。

对应两条产品要求：
1. **注册必须带手机号** —— 手机号是唯一身份标识，昵称不是
2. **华为账号一键登录** —— 鸿蒙全场景最对口的能力：免注册、免验证码
"""

import json
from io import BytesIO
from unittest.mock import Mock
from urllib.error import HTTPError
from urllib.parse import parse_qs
from urllib.response import addinfourl

import pytest

from app import create_app
from app.auth.service import create_session

H = {"X-API-Contract-Version": "api-contract-v0.3"}

_SEQ = {"n": 0}


def _phone() -> str:
    _SEQ["n"] += 1
    return f"1360000{_SEQ['n']:04d}"


_TEST_PASSWORD = "test-pw-123456"


def test_register_requires_phone(tmp_path):
    client = create_app(tmp_path / "req-phone.json").test_client()

    missing = client.post("/api/v1/auth/register", json={'password': 'test-pw-123456', "nickname": "无号同学"}, headers=H)
    assert missing.status_code == 400
    assert "手机号" in missing.get_json()["message"]


def test_register_rejects_malformed_phone(tmp_path):
    client = create_app(tmp_path / "bad-phone.json").test_client()

    for bad in ("12345", "23800000000", "1380000000", "abc", "12800000000"):
        response = client.post("/api/v1/auth/register",
                               json={'password': 'test-pw-123456', "nickname": "错号", "phone": bad}, headers=H)
        assert response.status_code == 400, f"phone={bad!r} → {response.status_code}"


def test_register_accepts_common_phone_formats(tmp_path):
    """`+86 138-0000-0000` 这类写法要能归一后存库。"""
    client = create_app(tmp_path / "fmt-phone.json").test_client()
    phone = _phone()
    formatted = f"+86 {phone[:3]}-{phone[3:7]}-{phone[7:]}"

    created = client.post("/api/v1/auth/register",
                          json={"nickname": "格式", "phone": formatted,
                                "password": _TEST_PASSWORD}, headers=H)
    assert created.status_code == 201

    logged = client.post("/api/v1/auth/login",
                         json={"phone": phone, "password": _TEST_PASSWORD}, headers=H)
    assert logged.status_code == 200
    assert logged.get_json()["user"]["userId"] == created.get_json()["user"]["userId"]


def test_register_rejects_duplicate_phone(tmp_path):
    client = create_app(tmp_path / 'unique.json').test_client()
    data = dict(phone='13900002222', password='password123', nickname='第一个')
    assert client.post('/api/v1/auth/register', json=data).status_code == 201
    data['nickname'] = '第二个'
    result = client.post('/api/v1/auth/register', json=data)
    assert result.status_code == 409
    assert result.get_json()['errorCode'] == 'PHONE_ALREADY_REGISTERED'


def test_phone_is_persisted_normalized_and_masked(tmp_path):
    """落库的是归一化号码；回传的是脱敏号码。"""
    client = create_app(tmp_path / "mask.json").test_client()
    phone = _phone()

    body = client.post("/api/v1/auth/register",
                       json={'password': 'test-pw-123456', "nickname": "脱敏", "phone": f"+86 {phone}"},
                       headers=H).get_json()

    user = body["user"]
    assert user["hasPhone"] is True
    assert user["phoneMasked"] == f"{phone[:3]}****{phone[-4:]}"
    assert phone not in str(body), "完整手机号不应出现在响应里"


def test_login_by_phone_returns_same_account(tmp_path):
    client = create_app(tmp_path / "login-phone.json").test_client()
    phone = _phone()
    created = client.post("/api/v1/auth/register",
                          json={"nickname": "手机登录", "phone": phone,
                                "password": _TEST_PASSWORD},
                          headers=H).get_json()

    logged = client.post("/api/v1/auth/login",
                         json={"phone": phone, "password": _TEST_PASSWORD}, headers=H)

    assert logged.status_code == 200
    assert logged.get_json()["user"]["userId"] == created["user"]["userId"]


def test_login_by_unknown_phone_is_401(tmp_path):
    client = create_app(tmp_path / "unknown.json").test_client()

    response = client.post("/api/v1/auth/login", json={"phone": "13700000099", "password": _TEST_PASSWORD}, headers=H)

    assert response.status_code == 401


def test_login_or_register_does_not_create_accounts(tmp_path):
    client = create_app(tmp_path / 'compat.json').test_client()
    data = dict(phone='13900002221', password='password123', nickname='原名')
    assert client.post('/api/v1/auth/login-or-register', json=data).status_code == 401
    original = client.post('/api/v1/auth/register', json=data).get_json()
    data['nickname'] = '新名'
    result = client.post('/api/v1/auth/login-or-register', json=data)
    assert result.status_code == 200
    assert result.get_json()['user']['userId'] == original['user']['userId']



_HUAWEI_AUTH_PATH = "/api/v1/auth/login-with-huawei"
_HUAWEI_TOKEN_URL = "https://oauth-login.cloud.huawei.com/oauth2/v3/token"
_HUAWEI_TOKEN_INFO_URL = (
    "https://oauth-api.cloud.huawei.com/rest.php?nsp_fmt=JSON&nsp_svc=huawei.oauth2.user.getTokenInfo"
)
_HUAWEI_TEST_CLIENT_ID = "1234567890"
_HUAWEI_TEST_CLIENT_SECRET = "test-client-secret"


def _huawei_response(url, body, headers=None):
    return addinfourl(BytesIO(json.dumps(body).encode("utf-8")), headers or {}, url, 200)


@pytest.fixture
def huawei_login(tmp_path, monkeypatch):
    monkeypatch.setenv("HUAWEI_ACCOUNT_CLIENT_ID", _HUAWEI_TEST_CLIENT_ID)
    monkeypatch.setenv("HUAWEI_ACCOUNT_CLIENT_SECRET", _HUAWEI_TEST_CLIENT_SECRET)
    transport = Mock(side_effect=AssertionError("Unexpected Huawei request"))
    monkeypatch.setattr("app.auth.huawei_account.urlopen", transport)
    app = create_app(tmp_path / "huawei.json")
    return app.test_client(), app.extensions["repository"], transport


def test_huawei_unverified_identity_cannot_issue_sessions(huawei_login):
    """客户端任填 OpenID/UnionID 不能注册或登录真实身份。"""
    client, repo, transport = huawei_login
    for payload in ({}, {"openId": "victim"}, {"openId": "victim", "unionId": "victim"},
                    {"openId": "victim", "accessToken": "forged", "seedDemoData": True},
                    {"openId": "victim", "authorizationCode": "test-code"},
                    {"authorizationCode": " "}, {"authorizationCode": 123}):
        response = client.post(_HUAWEI_AUTH_PATH, json=payload, headers=H)
        assert response.status_code == 400
        assert "token" not in response.get_json()
    transport.assert_not_called()
    assert not repo.list("users")
    assert not repo.list("sessions")


def test_huawei_verified_codes_log_into_same_account(huawei_login):
    client, repo, transport = huawei_login
    identity = {
        "client_id": _HUAWEI_TEST_CLIENT_ID,
        "expire_in": 1123,
        "open_id": "provider-verified-open-id",
        "union_id": "provider-verified-union-id",
        "type": 0,
    }
    transport.side_effect = [
        _huawei_response(_HUAWEI_TOKEN_URL, {"access_token": "first-access-token"}),
        _huawei_response(_HUAWEI_TOKEN_INFO_URL, identity),
        _huawei_response(_HUAWEI_TOKEN_URL, {"access_token": "second-access-token"}),
        _huawei_response(_HUAWEI_TOKEN_INFO_URL, identity),
        HTTPError(_HUAWEI_TOKEN_URL, 400, "Bad Request", {}, BytesIO(b'{"error":1101,"sub_error":20156}')),
    ]

    first = client.post(_HUAWEI_AUTH_PATH, json={"authorizationCode": "first-code"}, headers=H)
    again = client.post(_HUAWEI_AUTH_PATH, json={"authorizationCode": "second-code"}, headers=H)
    replay = client.post(_HUAWEI_AUTH_PATH, json={"authorizationCode": "first-code"}, headers=H)

    assert first.status_code == 201
    assert again.status_code == 200
    assert replay.status_code == 401
    assert "token" not in replay.get_json()
    created, existing = first.get_json(), again.get_json()
    user_id = created["user"]["userId"]
    assert existing["user"]["userId"] == user_id
    assert created["created"] is True
    assert existing["created"] is False
    assert created["needsPasswordSetup"] is False
    assert existing["needsPasswordSetup"] is False
    assert len(repo.list("users")) == 1
    assert len(repo.list("sessions")) == 2
    assert repo.get("users", user_id)["authSubject"] == identity["open_id"]
    assert identity["open_id"] not in first.get_data(as_text=True)
    assert created["token"] != existing["token"]
    assert existing["token"] != "second-access-token"
    session_headers = {**H, "Authorization": f"Bearer {existing['token']}"}
    me = client.get("/api/v1/auth/me", headers=session_headers)
    assert me.status_code == 200
    assert me.get_json()["user"]["userId"] == user_id
    assert me.get_json()["user"]["needsPasswordSetup"] is False
    assert client.get(f"/api/v1/profile/{user_id}", headers=session_headers).status_code == 200

    exchange, token_info, *_ = [call.args[0] for call in transport.call_args_list]
    assert exchange.full_url == _HUAWEI_TOKEN_URL
    assert token_info.full_url == _HUAWEI_TOKEN_INFO_URL
    for request in (exchange, token_info):
        assert request.get_method() == "POST"
        assert request.get_header("Content-type") == "application/x-www-form-urlencoded"
    assert parse_qs(exchange.data.decode()) == {
        "grant_type": ["authorization_code"],
        "code": ["first-code"],
        "client_id": [_HUAWEI_TEST_CLIENT_ID],
        "client_secret": [_HUAWEI_TEST_CLIENT_SECRET],
    }
    assert parse_qs(token_info.data.decode()) == {
        "access_token": ["first-access-token"],
        "open_id": ["OPENID"],
    }


@pytest.mark.parametrize(("client_id", "provider_headers"), [
    ("another-client", {}),
    (_HUAWEI_TEST_CLIENT_ID, {"NSP_STATUS": "102"}),
])
def test_huawei_rejects_unverified_token_info(huawei_login, client_id, provider_headers):
    client, repo, transport = huawei_login
    transport.side_effect = [
        _huawei_response(_HUAWEI_TOKEN_URL, {"access_token": "test-access-token"}),
        _huawei_response(_HUAWEI_TOKEN_INFO_URL, {
            "client_id": client_id, "expire_in": 1123, "open_id": "victim", "type": 0,
        }, provider_headers),
    ]
    response = client.post(_HUAWEI_AUTH_PATH, json={"authorizationCode": "test-code"}, headers=H)
    assert response.status_code == 401
    assert "token" not in response.get_json()
    assert not repo.list("users")
    assert not repo.list("sessions")


def test_verified_huawei_login_revokes_legacy_unverified_session(huawei_login):
    client, repo, transport = huawei_login
    user_id = "legacy-huawei-user"
    open_id = "provider-verified-open-id"
    repo.save("users", user_id, {
        "userId": user_id,
        "status": "active",
        "authProvider": "agc_phone",
        "authSubject": open_id,
    })
    legacy_session = create_session(repo, user_id)
    transport.side_effect = [
        _huawei_response(_HUAWEI_TOKEN_URL, {"access_token": "test-access-token"}),
        _huawei_response(_HUAWEI_TOKEN_INFO_URL, {
            "client_id": _HUAWEI_TEST_CLIENT_ID, "expire_in": 1123, "open_id": open_id, "type": 0,
        }),
    ]

    verified = client.post(_HUAWEI_AUTH_PATH, json={"authorizationCode": "fresh-code"}, headers=H)
    assert verified.status_code == 200
    assert verified.get_json()["user"]["userId"] == user_id
    assert verified.get_json()["user"]["needsPasswordSetup"] is False
    revoked = client.get("/api/v1/auth/me", headers={**H, "Authorization": f"Bearer {legacy_session['token']}"})
    assert revoked.status_code == 401
    assert len(repo.list("users")) == 1
    assert len(repo.list("sessions")) == 1


def test_huawei_unavailable_never_issues_sessions(huawei_login, monkeypatch):
    client, repo, transport = huawei_login
    payload = {"authorizationCode": "test-code"}
    with monkeypatch.context() as config:
        config.delenv("HUAWEI_ACCOUNT_CLIENT_SECRET")
        missing = client.post(_HUAWEI_AUTH_PATH, json=payload, headers=H)
    transport.assert_not_called()

    transport.side_effect = TimeoutError("Upstream timeout")
    failed = client.post(_HUAWEI_AUTH_PATH, json=payload, headers=H)
    for response in (missing, failed):
        assert response.status_code == 503
        assert response.get_json()["errorCode"] == "SERVICE_UNAVAILABLE"
        assert "token" not in response.get_json()
    assert not repo.list("users")
    assert not repo.list("sessions")
