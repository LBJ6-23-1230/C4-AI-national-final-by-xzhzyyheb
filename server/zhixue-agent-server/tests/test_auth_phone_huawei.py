# -*- coding: utf-8 -*-
"""手机号注册与华为账号登录回归测试。

对应两条产品要求：
1. **注册必须带手机号** —— 手机号是唯一身份标识，昵称不是
2. **华为账号一键登录** —— 鸿蒙全场景最对口的能力：免注册、免验证码
"""

from app import create_app

H = {"X-API-Contract-Version": "api-contract-v0.3"}

_SEQ = {"n": 0}


def _phone() -> str:
    _SEQ["n"] += 1
    return f"1360000{_SEQ['n']:04d}"


#: 测试账号统一用的密码 —— 见 `test_auth_login.py` 同名常量的说明：
#: `_verify_password()` 现在会**拒绝**用密码登录"从未设过密码"的账号
#: （此前会静默放行，等于任意密码都能登进去），所以这些"登回同一账号"的
#: 用例需要账号确实有密码。断言意图不变。
_TEST_PASSWORD = "test-pw-123456"


# --------------------------------------------------------------------- 手机号注册
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

    # 用干净格式应能登回
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


# --------------------------------------------------------------------- 手机号登录
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



# --------------------------------------------------------------------- 华为账号登录
def test_huawei_unverified_identity_cannot_issue_sessions(tmp_path):
    """客户端任填 OpenID/UnionID 不再能注册或登录真实身份。"""
    from app.repositories.json_repository import JsonRepository
    path = tmp_path / "huawei-unverified.json"
    client = create_app(path).test_client()
    for payload in ({}, {"openId": "victim"}, {"openId": "victim", "unionId": "victim"},
                    {"openId": "victim", "accessToken": "forged", "seedDemoData": True}):
        response = client.post("/api/v1/auth/login-with-huawei", json=payload, headers=H)
        assert response.status_code == 503
        assert response.get_json()["errorCode"] == "SERVICE_UNAVAILABLE"
        assert "token" not in response.get_json()
    repo = JsonRepository(path)
    assert not repo.list("users")
    assert not repo.list("sessions")
