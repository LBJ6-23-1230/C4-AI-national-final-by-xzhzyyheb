"""Account display edits must persist, stay owner-scoped, and preserve learning data."""
import base64
import json

import pymupdf
import pytest

from app import create_app


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("ZHIXUE_CHAT_DIR", str(tmp_path / "chat"))
    return create_app(tmp_path / "profile-edit.json").test_client()


def register(client, phone="13800000001", nickname="原昵称"):
    response = client.post("/api/v1/auth/register", json={
        "nickname": nickname, "phone": phone, "password": "test123456"})
    assert response.status_code == 201
    return response.get_json()


def headers(account):
    return {"Authorization": "Bearer " + account["token"]}


def avatar(side=32):
    pixels = pymupdf.Pixmap(pymupdf.csRGB, (0, 0, side, side), False)
    pixels.clear_with(120)
    return "data:image/png;base64," + base64.b64encode(pixels.tobytes("png")).decode()


def test_edit_persists_and_preserves_account_and_learning_data(client, tmp_path):
    account = register(client)
    owner = account["user"]["userId"]
    learning = client.get(f"/api/v1/profile/{owner}", headers=headers(account)).get_json()
    picture = avatar()
    response = client.put("/api/v1/auth/me", headers=headers(account), json={
        "nickname": "  新昵称  ", "avatar": picture})
    assert response.status_code == 200
    updated = response.get_json()["user"]
    assert updated["nickname"] == "新昵称"
    assert updated["avatar"] == picture
    persisted = json.loads((tmp_path / "profile-edit.json").read_text(encoding="utf-8"))
    assert persisted["users"][owner]["nickname"] == "新昵称"
    assert persisted["users"][owner]["avatar"] == picture
    assert updated["userId"] == owner
    assert updated["phoneMasked"] == account["user"]["phoneMasked"]
    assert "token" not in updated and "passwordHash" not in updated
    assert client.get("/api/v1/auth/me", headers=headers(account)).get_json()["user"] == updated
    logged_in = client.post("/api/v1/auth/login", json={
        "phone": "13800000001", "password": "test123456"})
    assert logged_in.status_code == 200
    assert logged_in.get_json()["user"]["avatar"] == picture
    assert client.get(f"/api/v1/profile/{owner}", headers=headers(account)).get_json() == learning


@pytest.mark.parametrize("body", [
    {}, {"nickname": " "}, {"nickname": "x" * 17}, {"nickname": "a\nb"},
    {"avatar": "file://other-account/avatar.jpg"}, {"avatar": "https://example.com/avatar.jpg"},
    {"avatar": "data:image/png;base64,bm90IGFuIGltYWdl"},
    {"avatar": "data:image/png;base64," + base64.b64encode(
        b"\x89PNG\r\n\x1a\n" + b"\0" * 8 + b"\0\0\0\x20" * 2).decode()},
    {"avatar": "data:image/png;base64," + "a" * 180001},
    {"nickname": "新昵称", "avatar": None}, {"userId": "someone-else"},
])
def test_invalid_edit_does_not_partially_change_user(client, body):
    account = register(client)
    before = client.get("/api/v1/auth/me", headers=headers(account)).get_json()
    assert client.put("/api/v1/auth/me", json=body, headers=headers(account)).status_code == 400
    assert client.get("/api/v1/auth/me", headers=headers(account)).get_json() == before


def test_requires_session_and_cannot_edit_another_account(client):
    alice = register(client)
    bob = register(client, "13800000002", "另一账号")
    assert client.put("/api/v1/auth/me", json={"nickname": "改名"}).status_code == 401
    assert client.put("/api/v1/auth/me", headers={"Authorization": "Bearer invalid"},
                      json={"nickname": "改名"}).status_code == 401
    assert client.put("/api/v1/auth/me", headers=headers(alice), json={"nickname": "改名"}).status_code == 200
    assert client.get("/api/v1/auth/me", headers=headers(bob)).get_json()["user"]["nickname"] == "另一账号"


def test_avatar_can_be_removed_and_large_dimensions_rejected(client):
    account = register(client)
    assert client.put("/api/v1/auth/me", headers=headers(account), json={"avatar": avatar()}).status_code == 200
    assert client.put("/api/v1/auth/me", headers=headers(account), json={"avatar": avatar(513)}).status_code == 400
    response = client.put("/api/v1/auth/me", headers=headers(account), json={"avatar": ""})
    assert response.get_json()["user"]["avatar"] == ""


def test_client_jpeg_avatar_is_supported(client):
    account = register(client)
    pixels = pymupdf.Pixmap(pymupdf.csRGB, (0, 0, 256, 256), False)
    pixels.clear_with(160)
    picture = "data:image/jpeg;base64," + base64.b64encode(pixels.tobytes("jpeg")).decode()
    assert client.put("/api/v1/auth/me", headers=headers(account), json={"avatar": picture}).status_code == 200


def test_repeat_save_skips_image_decode_and_durable_rewrite(client, tmp_path, monkeypatch):
    from app.auth import service
    account = register(client)
    update = {"nickname": "新昵称", "avatar": avatar()}
    response = client.put("/api/v1/auth/me", headers=headers(account), json=update)
    assert response.status_code == 200
    before = (tmp_path / "profile-edit.json").stat().st_mtime_ns

    def must_not_decode(*args):
        raise AssertionError("unchanged avatar must not be decoded again")

    monkeypatch.setattr(service, "normalize_avatar", must_not_decode)
    repeated = client.put("/api/v1/auth/me", headers=headers(account), json=update)
    assert repeated.status_code == 200
    assert repeated.get_json() == response.get_json()
    assert (tmp_path / "profile-edit.json").stat().st_mtime_ns == before
    # Changing just the nickname also reuses the already validated avatar.
    update["nickname"] = "再改昵称"
    assert client.put("/api/v1/auth/me", headers=headers(account), json=update).status_code == 200


def test_sqlite_profile_persists_across_repository_reopen(tmp_path):
    from app.auth import service
    from app.repositories.sqlite_repository import SQLiteRepository
    path = tmp_path / "profiles.sqlite"
    repository = SQLiteRepository(path)
    account = service.register_user(repository, "原昵称", "大二", "13800000009", "test123456")
    owner = account["user"]["userId"]
    picture = avatar()
    service.update_account_profile(repository, owner, {"nickname": "新昵称", "avatar": picture})
    repository.close()
    reopened = SQLiteRepository(path)
    try:
        assert service.get_user(reopened, owner)["nickname"] == "新昵称"
        assert service.get_user(reopened, owner)["avatar"] == picture
    finally:
        reopened.close()


def test_existing_invitations_and_contacts_show_latest_nickname(client):
    alice = register(client)
    bob = register(client, "13800000002", "搭子")
    sent = client.post("/api/v1/agent/partner-invitations", headers=headers(alice),
                       json={"toUserId": bob["user"]["userId"]})
    assert sent.status_code in (200, 201)
    invitation_id = sent.get_json()["invitation"]["invitationId"]
    accepted = client.post(f"/api/v1/agent/partner-invitations/{invitation_id}/accept", headers=headers(bob))
    assert accepted.status_code == 200
    client.put("/api/v1/auth/me", headers=headers(alice), json={"nickname": "新昵称", "avatar": avatar()})
    contacts = client.get("/api/v1/agent/partner-contacts", headers=headers(bob)).get_json()["contacts"]
    assert contacts[0]["partnerName"] == "新昵称"
    outbox = client.get("/api/v1/agent/partner-invitations?box=outbox", headers=headers(alice)).get_json()
    assert outbox["invitations"][0]["fromName"] == "新昵称"
