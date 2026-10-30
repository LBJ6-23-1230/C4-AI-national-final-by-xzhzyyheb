"""Real PostgreSQL tests. Only an explicitly named disposable test database is used."""
from concurrent.futures import ProcessPoolExecutor, ThreadPoolExecutor
from copy import deepcopy
from datetime import timedelta
import base64
import json
import os
import subprocess
import sys
import time
from pathlib import Path
import uuid

import pytest

pytest.importorskip("sqlalchemy")
from sqlalchemy import text
from alembic import command
from alembic.config import Config
from app import create_app
from app.repositories.postgresql_repository import PostgreSQLRepository, make_engine
from app.repositories.pg_schema import tables
from app.services import job_queue


def test_chat_images_persist_and_are_deleted_by_worker(pg, monkeypatch):
    from app.agent import chat_llm
    from app.services.file_storage import storage
    monkeypatch.setattr(chat_llm, 'llm_ready', lambda: False)
    monkeypatch.setattr(chat_llm, 'detect_intent', lambda *args, **kwargs: ('analyze_wrong', False))
    app, repository = pg
    client = app.test_client()
    image = 'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAFklEQVR4nGO4o6FBEmIY1TCqYfhqAAAyBCwQhvh37QAAAABJRU5ErkJggg=='
    assert client.post('/api/agent/chat', json={'image': image, 'sessionId': 'pg-image'}).status_code == 200
    row = client.get('/api/agent/history').get_json()['history'][-1]
    original = repository.get('file_objects', row['image_file_id'])
    assert row['image_preview'].startswith('data:image/jpeg;base64,')
    assert storage().read(original) == base64.b64decode(image)
    assert client.get('/api/agent/images/' + row['image_file_id']).status_code == 200
    repository.close()
    assert client.get('/api/agent/history').get_json()['history'][-1]['image_file_id'] == row['image_file_id']
    assert client.delete('/api/agent/history').status_code == 200
    assert client.get('/api/agent/images/' + row['image_file_id']).status_code == 404
    assert job_queue.run_once(repository)
    assert repository.get('file_objects', row['image_file_id']) is None
    assert not storage()._path(original['objectKey']).exists()


@pytest.fixture
def pg(monkeypatch, tmp_path):
    url = os.getenv("ZHIXUE_TEST_DATABASE_URL")
    if not url:
        pytest.skip("set ZHIXUE_TEST_DATABASE_URL for PostgreSQL integration tests")
    from sqlalchemy.engine import make_url
    if not (make_url(url).database or "").startswith("zhixue_test"):
        pytest.fail("integration tests require a database whose name starts with zhixue_test")
    monkeypatch.setenv("DATABASE_URL", url)
    monkeypatch.delenv("MIGRATION_DATABASE_URL", raising=False)
    monkeypatch.setenv("APP_ENV", "development")
    monkeypatch.setenv("DEMO_ENABLED", "true")
    monkeypatch.setenv("FILE_STORAGE", "local")
    monkeypatch.setenv("FILE_STORAGE_DIR", str(tmp_path / "files"))
    monkeypatch.setenv("ZHIXUE_QUIET", "1")
    monkeypatch.setenv("DB_SCHEMA", "public")
    engine = make_engine(url)
    schema = "test_" + uuid.uuid4().hex
    with engine.begin() as connection:
        connection.execute(text(f'CREATE SCHEMA "{schema}"'))
    engine.dispose()
    monkeypatch.setenv("DB_SCHEMA", schema)
    command.upgrade(Config("alembic.ini"), "head")
    monkeypatch.setenv("ZHIXUE_DB", "postgresql")
    app = create_app(tmp_path / "unused.json")
    repository = app.extensions["repository"]
    yield app, repository
    repository.close()
    # Keep isolated schemas for failure inspection. The entire named disposable
    # database can be removed by the operator after reviewing the test report.


def _process_increment(count):
    repository = PostgreSQLRepository(os.environ["DATABASE_URL"])
    try:
        for _ in range(count):
            with repository.transaction("counter-owner"):
                value = repository.get("test_counters", "counter")
                repository.save("test_counters", "counter", {"value": value["value"] + 1})
    finally:
        repository.close()


def _process_submit(payload):
    app = create_app()
    try:
        with app.test_client() as client:
            response = client.post("/api/v1/exercises/set-demo-binary-tree-001/submit", json=payload)
            return response.status_code, response.get_json()
    finally:
        app.extensions["repository"].close()


def payload(key="same-key", answer="B"):
    return {"idempotencyKey": key, "answers": [{"exerciseId": "exercise-preorder-001", "answer": answer}]}


def test_real_cross_process_read_modify_write(pg):
    _, repository = pg
    repository.save("test_counters", "counter", {"value": 0})
    with ProcessPoolExecutor(max_workers=4) as pool:
        list(pool.map(_process_increment, [5] * 4))
    assert repository.get("test_counters", "counter") == {"value": 20}


def test_real_concurrent_submit_once_and_conflicting_retry(pg):
    app, repository = pg
    before = deepcopy(repository.get("profiles", "demo-user"))
    with ProcessPoolExecutor(max_workers=3) as pool:
        results = list(pool.map(_process_submit, [payload()] * 3))
    assert all(code == 200 for code, _ in results)
    assert all(result == results[0][1] for _, result in results)
    assert len(repository.list("submissions")) == 1
    changed = repository.get("profiles", "demo-user")
    assert changed["profileVersion"] == before["profileVersion"] + 1
    assert app.test_client().post("/api/v1/exercises/set-demo-binary-tree-001/submit",
                                  json=payload(answer="A")).status_code == 409


def test_batch_rollback_on_database_constraint_failure(pg):
    _, repository = pg
    with pytest.raises(Exception):
        with repository.transaction():
            repository.save("profiles", "rollback", {"userId": "rollback"})
            repository.save("users", "bad", {"userId": "bad", "version": -1})
    assert repository.get("profiles", "rollback") is None


def test_database_allows_shared_phone_and_rejects_cross_owner_document(pg):
    _, repository = pg
    repository.save("users", "one", {"userId": "one", "phone": "13900000001"})
    repository.save("users", "two", {"userId": "two", "phone": "13900000001"})
    assert repository.get('users', 'two')['phone'] == '13900000001'
    repository.save("knowledge_bases", "kb", {"kbId": "kb", "userId": "one"})
    with pytest.raises(Exception):
        repository.save("documents", "doc", {"documentId": "doc", "kbId": "kb", "userId": "two"})


def test_sessions_persist_as_digests_and_login_survives_new_connection(pg):
    app, repository = pg
    client = app.test_client()
    response = client.post("/api/v1/auth/register", json={"nickname": "甲", "phone": "13900000002", "password": "Testpass123!"})
    assert response.status_code == 201
    token = response.get_json()["token"]
    second = PostgreSQLRepository(os.environ["DATABASE_URL"])
    try:
        from app.auth.service import resolve_session
        assert resolve_session(second, token)["userId"] == response.get_json()["user"]["userId"]
        assert token not in json.dumps(second.list("sessions"))
        assert second.ids("sessions")[0].startswith("sha256:")
        assert resolve_session(second, second.ids("sessions")[0]) is None
    finally:
        second.close()


def test_chat_history_database_order_and_user_isolation(pg):
    app, repository = pg
    from app.agent import chat_llm
    with app.app_context():
        chat_llm.append_history("甲的输入", "回复", "one", "conversation")
        chat_llm.append_history("乙的输入", "回复", "two", "conversation")
        assert len(chat_llm.get_history("one")) == 1
        chat_llm.clear_history("one")
        assert chat_llm.get_history("one") == []
        assert chat_llm.get_history("two")[0]["user_input"] == "乙的输入"
    second = PostgreSQLRepository(os.environ["DATABASE_URL"])
    try:
        from app.services.chat_history import history
        assert len(history(second, "two")) == 1
    finally:
        second.close()


def test_expired_job_reclaimed_and_stale_lease_cannot_commit(pg):
    _, repository = pg
    with repository.transaction():
        job_queue.enqueue(repository, "review", "u", {}, "recover")
    first = job_queue.claim(repository)
    row = dict(first, lockedUntil=(job_queue.now() - timedelta(seconds=1)).isoformat())
    repository.save("jobs", first["jobId"], row)
    second = job_queue.claim(repository)
    assert second["attempts"] == 2 and second["leaseToken"] != first["leaseToken"]
    assert job_queue.finish(repository, first, ({}, set())) is False
    assert job_queue.heartbeat(repository, first) is False
    assert job_queue.fail(repository, second) is True
    assert repository.get("jobs", first["jobId"])["status"] == "queued"


def test_claim_skip_locked_is_exclusive_across_connections(pg):
    _, repository = pg
    with repository.transaction():
        for number in range(8):
            job_queue.enqueue(repository, "review", "u", {}, str(number))
    def claim(_):
        second = PostgreSQLRepository(os.environ["DATABASE_URL"])
        try:
            return job_queue.claim(second)["jobId"]
        finally:
            second.close()
    with ThreadPoolExecutor(max_workers=8) as pool:
        ids = list(pool.map(claim, range(8)))
    assert len(set(ids)) == 8


def test_review_enqueue_atomic_and_result_does_not_regrade(pg, monkeypatch):
    app, repository = pg
    monkeypatch.setenv("DASHSCOPE_API_KEY", "test-key-not-real")
    client = app.test_client()
    response = client.post("/api/v1/exercises/set-demo-binary-tree-001/submit", json=payload())
    assert response.status_code == 200
    assert response.get_json()["reviewStatus"] == "pending"
    profile = deepcopy(repository.get("profiles", "demo-user"))
    job = job_queue.claim(repository)
    assert job["type"] == "review"
    assert job_queue.finish(repository, job, ({"exercise-preorder-001": "详细解析"}, {"exercise-preorder-001"}))
    assert repository.get("profiles", "demo-user") == profile
    assert repository.list("submissions")[0]["response"]["reviewStatus"] == "completed"
    assert not job_queue.finish(repository, job, ({}, set()))


def test_document_worker_parses_private_original_and_deletion_wins(pg):
    app, repository = pg
    client = app.test_client()
    kb = client.post("/api/v1/knowledge-bases", json={"name": "资料", "courseName": "数据结构"}).get_json()
    response = client.post(f"/api/v1/knowledge-bases/{kb['kbId']}/documents", json={
        "fileName": "notes.txt", "contentBase64": base64.b64encode(("二叉树的前序遍历先访问根节点。" * 20).encode()).decode()})
    assert response.status_code == 201
    document = response.get_json()
    assert document["status"] == "processing"
    assert job_queue.run_once(repository)
    ready = client.get(f"/api/v1/documents/{document['documentId']}").get_json()
    assert ready["status"] == "ready" and ready["chunkTotal"] > 0
    assert repository.list("chunks")[0]["sha256"] == document["sha256"]
    assert client.delete(f"/api/v1/documents/{document['documentId']}").status_code == 200
    assert job_queue.run_once(repository)
    assert not repository.list("file_objects")


def test_account_deletion_revokes_jobs_and_cleans_originals(pg):
    app, repository = pg
    from app.services.file_storage import storage
    from app.auth.service import deactivate_user
    repository.save("users", "u", {"userId": "u", "phone": "13900000003", "status": "active"})
    repository.save("profiles", "u", {"userId": "u"})
    original = storage().put("u", b"private", "private.txt")
    repository.save("file_objects", original["fileId"], original)
    with repository.transaction():
        job_queue.enqueue(repository, "review", "u", {}, "cancel-me")
    stale = job_queue.claim(repository)
    assert deactivate_user(repository, "u")
    assert repository.get("profiles", "u") is None
    assert repository.get("users", "u") == {"userId": "u", "status": "deactivated", "deactivatedAt": repository.get("users", "u")["deactivatedAt"]}
    assert job_queue.finish(repository, stale, ({}, set())) is False
    assert job_queue.run_once(repository)
    assert not storage()._path(original["objectKey"]).exists()


def test_additive_import_is_verified_and_never_overwrites(pg):
    _, repository = pg
    from tools.migrate_postgresql import prepare, import_and_verify
    source = {"users": {"imported": {"userId": "imported", "phone": "13900000004"}},
              "profiles": {"imported": {"userId": "imported", "profileVersion": 2}}}
    data, errors = prepare(source, {"imported": [{"user_input": "旧记录", "bot_response": "回复"}]})
    assert not errors
    assert import_and_verify(repository, data)["pending"] == 4
    assert repository.get("users", "imported") is None
    assert import_and_verify(repository, data, True)["ok"]
    assert import_and_verify(repository, data)["pending"] == 0
    changed = deepcopy(data)
    changed["profiles"]["imported"]["profileVersion"] = 3
    assert not import_and_verify(repository, changed, True)["ok"]
    assert repository.get("profiles", "imported")["profileVersion"] == 2


def test_no_demo_and_database_readiness(pg, monkeypatch):
    app, repository = pg
    monkeypatch.setenv("DEMO_ENABLED", "false")
    client = app.test_client()
    assert client.get("/health").status_code == 200
    assert client.get("/ready").status_code == 200
    assert client.get("/api/v1/plans/current").status_code == 401
    assert client.post("/api/v1/demo/reset").status_code == 404
    monkeypatch.setattr(repository, "check_ready", lambda: (_ for _ in ()).throw(RuntimeError()))
    assert client.get("/ready").status_code == 503
    assert client.get("/health").status_code == 200


def test_stale_profile_preferences_conflict_without_overwriting(pg):
    app, repository = pg
    client = app.test_client()
    version = repository.get("profiles", "demo-user")["profileVersion"]
    request = {"targetCourse": "数据结构", "goal": "复习", "freeTimeSlots": ["20:00-21:00"],
               "expectedProfileVersion": version}
    assert client.put("/api/v1/profile/demo-user/preferences", json=request).status_code == 200
    assert client.put("/api/v1/profile/demo-user/preferences", json=request).status_code == 409
    assert repository.get("profiles", "demo-user")["profileVersion"] == version + 1


def test_worker_crash_on_last_attempt_stops_showing_review_pending(pg, monkeypatch):
    app, repository = pg
    monkeypatch.setenv("DASHSCOPE_API_KEY", "test-key-not-real")
    result = app.test_client().post("/api/v1/exercises/set-demo-binary-tree-001/submit", json=payload()).get_json()
    job = job_queue.claim(repository)
    repository.save("jobs", job["jobId"], dict(job, attempts=4,
        lockedUntil=(job_queue.now() - timedelta(seconds=1)).isoformat()))
    assert job_queue.run_once(repository)
    assert repository.get("jobs", job["jobId"])["status"] == "failed"
    assert repository.get("submissions", result["submissionId"])["response"]["reviewStatus"] == "failed"


def test_separate_worker_process_recovers_after_claiming_process_dies(pg):
    _, repository = pg
    from app.services.file_storage import storage
    original = storage().put("restart-user", b"temporary recovery fixture", "recovery.txt")
    repository.save("file_objects", original["fileId"], original)
    with repository.transaction():
        key = job_queue.enqueue(repository, "delete_file", "restart-user", {"file": original}, "restart")
    script = ("import os; from app.repositories.postgresql_repository import PostgreSQLRepository; "
              "from app.services.job_queue import claim; "
              "r=PostgreSQLRepository(os.environ['DATABASE_URL']); "
              "assert claim(r,lease_seconds=1); os._exit(17)")
    crashed = subprocess.run([sys.executable, "-c", script], capture_output=True, timeout=20)
    assert crashed.returncode == 17
    assert repository.get("jobs", key)["status"] == "running"
    time.sleep(1.1)
    resumed = subprocess.run([sys.executable, "worker.py", "--once"], capture_output=True, timeout=30)
    assert resumed.returncode == 0, resumed.stderr.decode(errors="replace")[-1000:]
    row = repository.get("jobs", key)
    assert row["status"] == "succeeded" and row["attempts"] == 2
    assert not storage()._path(original["objectKey"]).exists()


def test_exhausted_job_can_recover_if_finalizing_worker_dies(pg, monkeypatch):
    app, repository = pg
    monkeypatch.setenv("DASHSCOPE_API_KEY", "test-key-not-real")
    result = app.test_client().post("/api/v1/exercises/set-demo-binary-tree-001/submit",
                                   json=payload("finalization-crash")).get_json()
    job = job_queue.claim(repository)
    repository.save("jobs", job["jobId"], dict(job, attempts=4,
        lockedUntil=(job_queue.now() - timedelta(seconds=1)).isoformat()))
    # A worker claims the exhausted lease, then dies before applying terminal state.
    finalizing = job_queue.claim(repository)
    assert finalizing["status"] == "running"
    repository.save("jobs", job["jobId"], dict(finalizing,
        lockedUntil=(job_queue.now() - timedelta(seconds=1)).isoformat()))
    assert job_queue.run_once(repository)
    assert repository.get("jobs", job["jobId"])["status"] == "failed"
    assert repository.get("submissions", result["submissionId"])["response"]["reviewStatus"] == "failed"


def test_late_chat_completion_cannot_restore_deleted_account_history(pg):
    _, repository = pg
    from app.auth.service import deactivate_user
    from app.services.chat_history import append, history
    repository.save("users", "late-chat", {"userId": "late-chat", "status": "active"})
    assert deactivate_user(repository, "late-chat")
    append(repository, "late-chat", {"session_id": "private", "user_input": "deleted"})
    assert history(repository, "late-chat") == []
    assert repository.get("chat_sessions", "late-chat") is None


def test_logged_in_app_requests_over_real_http(pg):
    app, _ = pg
    import threading
    from werkzeug.serving import make_server
    server = make_server("127.0.0.1", 0, app, threaded=True)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        probe = Path(__file__).resolve().parents[3] / "tools/check_logged_in_flows.py"
        result = subprocess.run([sys.executable, str(probe), "--port", str(server.server_port)],
                                capture_output=True, text=True, encoding="utf-8", timeout=90)
        print(result.stdout)
        assert result.returncode == 0, result.stdout + result.stderr
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
