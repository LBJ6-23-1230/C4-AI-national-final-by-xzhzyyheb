"""Regressions for the repository-wide backend and delivery-tool audit."""
import base64
import importlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import time

import pytest

from app import create_app
from app.api import knowledge as knowledge_api
from app.auth import service
from app.repositories.json_repository import JsonRepository
from app.repositories.sqlite_repository import SQLiteRepository

ROOT = Path(__file__).resolve().parents[3]


def tool(name):
    sys.path.insert(0, str(ROOT / 'tools'))
    try:
        return importlib.import_module(name)
    finally:
        sys.path.pop(0)


def test_proactive_uses_session_owner_and_rejects_guest_spoofing(tmp_path):
    client = create_app(tmp_path / 'identity.json').test_client()
    registered = client.post('/api/v1/auth/register', json={'nickname': 'audit', 'phone': '13900008401'}).get_json()
    owner = registered['user']['userId']
    headers = {'Authorization': 'Bearer ' + registered['token']}
    assert client.post('/api/v1/agent/proactive', json={'userId': owner}).status_code == 404
    own = client.post('/api/v1/agent/proactive', json={}, headers=headers)
    spoof = client.post('/api/v1/agent/proactive', json={'userId': 'demo-user'}, headers=headers)
    assert own.status_code == spoof.status_code == 200
    assert own.get_json() == spoof.get_json()


@pytest.mark.parametrize('backend', [JsonRepository, SQLiteRepository])
def test_account_session_and_profile_publish_together(tmp_path, monkeypatch, backend):
    repo = backend(tmp_path / 'account')
    original = service.provision_starter_profile
    def fail(*args, **kwargs):
        raise OSError('injected profile failure')
    try:
        monkeypatch.setattr(service, 'provision_starter_profile', fail)
        with pytest.raises(OSError):
            service.register_and_provision(repo, 'audit', phone='13900008402')
        for collection in ('users', 'sessions', 'profiles'):
            assert repo.list(collection) == []
        monkeypatch.setattr(service, 'provision_starter_profile', original)
        result = service.register_and_provision(repo, 'audit', phone='13900008402')
        assert repo.get('profiles', result['user']['userId'])
        assert service.resolve_session(repo, result['token'])
    finally:
        repo.close()


def test_upload_cannot_resurrect_library_deleted_during_parse(tmp_path, monkeypatch):
    client = create_app(tmp_path / 'upload.json').test_client()
    kb = client.post('/api/v1/knowledge-bases', json={'name': 'audit', 'courseName': 'audit'}).get_json()['kbId']
    original = knowledge_api.knowledge.process_document
    def parse(*args, **kwargs):
        result = original(*args, **kwargs)
        assert client.delete('/api/v1/knowledge-bases/' + kb).status_code == 200
        return result
    monkeypatch.setattr(knowledge_api.knowledge, 'process_document', parse)
    result = client.post(f'/api/v1/knowledge-bases/{kb}/documents', json={
        'fileName': 'audit.md', 'contentBase64': base64.b64encode('二叉树后序遍历'.encode()).decode()})
    assert result.status_code == 404
    assert knowledge_api._repository.list('documents') == []
    assert knowledge_api._repository.list('chunks') == []


def test_confirmation_profile_failure_rolls_back_document_and_summary(tmp_path, monkeypatch):
    from app.tools import profile_merge
    client = create_app(tmp_path / 'upload.json').test_client()
    kb = client.post('/api/v1/knowledge-bases', json={'name': 'audit', 'courseName': 'audit'}).get_json()['kbId']
    doc = client.post(f'/api/v1/knowledge-bases/{kb}/documents', json={
        'fileName': 'audit.md', 'contentBase64': base64.b64encode('二叉树后序遍历'.encode()).decode()}).get_json()
    before = knowledge_api._repository.get('documents', doc['documentId'])
    def fail(*args, **kwargs):
        raise OSError('injected merge failure')
    monkeypatch.setattr(profile_merge, 'merge_points_into_profile', fail)
    result = client.put(f"/api/v1/documents/{doc['documentId']}/knowledge-points", json={
        'knowledgePoints': ['后序遍历'], 'expectedParsedAt': doc['parsedAt']})
    assert result.status_code == 500
    assert knowledge_api._repository.get('documents', doc['documentId']) == before
    assert knowledge_api._repository.get('knowledge_bases', kb)['documentCount'] == 1


def test_oversize_http_body_is_rejected_before_json_decode(tmp_path):
    client = create_app(tmp_path / 'body.json').test_client()
    result = client.post('/api/v1/agent/proactive', data=b' ' * (16 * 1024 * 1024 + 1), content_type='application/json')
    assert result.status_code == 413
    assert result.is_json


def test_chat_history_cross_process_writes_preserve_all_users(tmp_path):
    script = '''
import sys, time
from pathlib import Path
from app.agent import chat_llm
directory, role = Path(sys.argv[1]), sys.argv[2]
original = chat_llm._load_history_store
first = True
def controlled_read():
    global first
    value = original()
    if role == 'first' and first:
        first = False
        (directory / 'read').write_text('ready')
        deadline = time.monotonic() + 10
        while not (directory / 'release').exists():
            if time.monotonic() > deadline: raise TimeoutError('release')
            time.sleep(.01)
    return value
chat_llm._load_history_store = controlled_read
(directory / (role + '.started')).write_text('ready')
chat_llm.append_history(role, 'response', user_id=role)
'''
    env = dict(os.environ, ZHIXUE_CHAT_DIR=str(tmp_path), DASHSCOPE_API_KEY='')
    processes = []
    def start(role):
        proc = subprocess.Popen([sys.executable, '-c', script, str(tmp_path), role], env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        processes.append(proc)
        return proc
    def wait(name, proc):
        deadline = time.monotonic() + 10
        while not (tmp_path / name).exists():
            assert proc.poll() is None
            assert time.monotonic() < deadline
            time.sleep(.01)
    try:
        first = start('first')
        wait('read', first)
        second = start('second')
        wait('second.started', second)
        time.sleep(.2)
        (tmp_path / 'release').write_text('go')
        for proc in processes:
            _, errors = proc.communicate(timeout=15)
            assert proc.returncode == 0, errors.decode(errors='replace')
        store = json.loads((tmp_path / 'history.json').read_text(encoding='utf-8'))
        assert set(store) == {'first', 'second'}
    finally:
        for proc in processes:
            if proc.poll() is None:
                proc.kill()
                proc.communicate()


def test_package_policy_strips_signing_without_touching_source(tmp_path):
    policy = tool('packaging_policy')
    path = tmp_path / 'build-profile.json5'
    text = '''{"app":{"signingConfigs":[{"material":{"storePassword":"secret]value","keyPassword":"private"}}],"products":[{"name":"default","signingConfig":"default"}]}}'''
    path.write_text(text, encoding='utf-8')
    sanitized = policy.sanitized_bytes(path)
    assert b'secret' not in sanitized and b'private' not in sanitized
    parsed = json.loads(sanitized)
    assert parsed['app']['signingConfigs'] == []
    assert 'signingConfig' not in parsed['app']['products'][0]
    assert path.read_text(encoding='utf-8') == text


@pytest.mark.parametrize('name', ['.env', '.env.production', 'repository.sqlite-wal', 'history.json',
                                  'repository.json', 'sign.p12', 'local.properties'])
def test_package_policy_excludes_runtime_and_signing_material(name):
    assert tool('packaging_policy').should_skip(Path(name))


def test_package_template_is_kept_and_placeholder_does_not_hide_real_key():
    policy = tool('packaging_policy')
    assert not policy.should_skip(Path('server/.env.example'))
    assert policy.should_skip(Path('server/data/repository.json.bak-20261025'))
    assert not tool('verify_packages').is_forbidden('server/.env.example')
    with pytest.raises(ValueError):
        policy.assert_safe_content(('sk-xxxxxxxx ' + 'sk-' + 'A' * 32).encode(), 'fixture')


def test_migration_refuses_existing_target_and_overwrite_replaces_rows(tmp_path):
    migration = tool('migrate_repository')
    source, target = tmp_path / 'source.json', tmp_path / 'target.sqlite'
    source.write_text(json.dumps({'items': {'new': {'value': 2}}}), encoding='utf-8')
    repo = SQLiteRepository(target)
    repo.save('items', 'old', {'value': 1})
    repo.close()
    with pytest.raises(FileExistsError):
        migration.migrate(source, target, False)
    migration.migrate(source, target, False, overwrite=True)
    assert migration.verify(source, target)
    repo = SQLiteRepository(target)
    try:
        assert repo.ids('items') == ['new']
    finally:
        repo.close()


def test_migration_verification_does_not_create_missing_database(tmp_path):
    migration = tool('migrate_repository')
    source, target = tmp_path / 'source.json', tmp_path / 'missing.sqlite'
    source.write_text('{}', encoding='utf-8')
    with pytest.raises(sqlite3.OperationalError):
        migration.verify(source, target)
    assert not target.exists()


def test_configuration_check_does_not_create_runtime_database(tmp_path):
    path = tmp_path / 'must-not-exist.json'
    env = dict(os.environ, ZHIXUE_REPOSITORY=str(path), ZHIXUE_QUIET='1', DASHSCOPE_API_KEY='')
    result = subprocess.run([sys.executable, 'run.py', '--check'], env=env, capture_output=True, timeout=15)
    assert result.returncode == 0, result.stderr.decode(errors='replace')
    assert not path.exists()


@pytest.mark.parametrize('action,expected', [('register', [201, 409]), ('code', [200, 429])])
def test_auth_workers_serialize_uniqueness_and_code_cooldown(tmp_path, action, expected):
    database = tmp_path / 'auth.sqlite'
    SQLiteRepository(database).close()
    script = '''
import sys, time
from pathlib import Path
from app.auth import service
from app.repositories.sqlite_repository import SQLiteRepository
directory, role, action = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
repo = SQLiteRepository(directory / 'auth.sqlite')
first = True
original_list, original_get = repo.list, repo.get
def pause(collection, result):
    global first
    if role == 'first' and first and collection == ('users' if action == 'register' else 'verification_codes'):
        first = False
        (directory / 'read').write_text('ready')
        deadline = time.monotonic() + 10
        while not (directory / 'release').exists():
            if time.monotonic() > deadline: raise TimeoutError('release')
            time.sleep(.01)
    return result
repo.list = lambda collection: pause(collection, original_list(collection))
repo.get = lambda collection, key: pause(collection, original_get(collection, key))
(directory / (role + '.started')).write_text('ready')
try:
    if action == 'register':
        service.register_and_provision(repo, 'audit', phone='13900008403')
        status = 201
    else:
        service.send_verification_code(repo, '13900008403')
        status = 200
except service.AuthError as error:
    status = error.status
finally:
    repo.close()
(directory / (role + '.status')).write_text(str(status))
'''
    processes = []
    def start(role):
        proc = subprocess.Popen([sys.executable, '-c', script, str(tmp_path), role, action],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        processes.append(proc)
        return proc
    def wait(name, proc):
        deadline = time.monotonic() + 10
        while not (tmp_path / name).exists():
            assert proc.poll() is None
            assert time.monotonic() < deadline
            time.sleep(.01)
    try:
        first = start('first')
        wait('read', first)
        second = start('second')
        wait('second.started', second)
        time.sleep(.2)
        (tmp_path / 'release').write_text('go')
        for proc in processes:
            _, errors = proc.communicate(timeout=15)
            assert proc.returncode == 0, errors.decode(errors='replace')
        assert [int((tmp_path / (role + '.status')).read_text()) for role in ('first', 'second')] == expected
    finally:
        for proc in processes:
            if proc.poll() is None:
                proc.kill()
                proc.communicate()


def test_sqlite_wrong_code_attempt_is_committed_despite_auth_error(tmp_path):
    repo = SQLiteRepository(tmp_path / 'code.sqlite')
    try:
        sent = service.send_verification_code(repo, '13900008404')
        wrong = '000000' if sent['devCode'] != '000000' else '111111'
        with pytest.raises(service.AuthError):
            service.verify_verification_code(repo, '13900008404', wrong)
        assert repo.list('verification_codes')[0]['failedAttempts'] == 1
    finally:
        repo.close()


@pytest.mark.parametrize('operation', ['workflow', 'trace'])
def test_workers_serialize_workflow_and_trace_operations(tmp_path, monkeypatch, operation):
    database = tmp_path / 'shared.sqlite'
    monkeypatch.setenv('ZHIXUE_DB', 'sqlite:' + str(database))
    app = create_app(tmp_path / 'unused.json')
    created = app.test_client().post('/api/v1/workflows', json={'goal': 'audit', 'sessionId': 'shared', 'autoRun': False})
    assert created.status_code == 200
    script = '''
import sys, time
from pathlib import Path
from flask import Flask
from app.api import workflows
from app.repositories.sqlite_repository import SQLiteRepository
from app.tools.trace_tools import append_trace_event
directory, role, operation = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
repo = SQLiteRepository(directory / 'shared.sqlite')
def pause():
    (directory / 'read').write_text('ready')
    deadline = time.monotonic() + 10
    while not (directory / 'release').exists():
        if time.monotonic() > deadline: raise TimeoutError('release')
        time.sleep(.01)
if operation == 'workflow':
    workflows.configure_workflows_repository(repo)
    app = Flask(__name__)
    app.register_blueprint(workflows.workflows_api)
    original = workflows._run_saved_workflow
    def controlled(*args, **kwargs):
        if role == 'first': pause()
        return original(*args, **kwargs)
    workflows._run_saved_workflow = controlled
else:
    original = repo.get
    def controlled(collection, key):
        value = original(collection, key)
        if role == 'first' and collection == 'traces': pause()
        return value
    repo.get = controlled
(directory / (role + '.started')).write_text('ready')
try:
    if operation == 'workflow':
        response = app.test_client().post('/api/v1/workflows/shared/run', json={'expectedStateVersion': 1})
        status = response.status_code
    else:
        append_trace_event(repo, 'shared-trace', agent=role, tool_calls=[], input_summary='audit',
                           output_summary='audit', evidence_ids=[], state_version=1, status='completed')
        status = 200
    (directory / (role + '.status')).write_text(str(status))
finally:
    repo.close()
'''
    processes = []
    def start(role):
        proc = subprocess.Popen([sys.executable, '-c', script, str(tmp_path), role, operation],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        processes.append(proc)
        return proc
    def wait(name, proc):
        deadline = time.monotonic() + 10
        while not (tmp_path / name).exists():
            assert proc.poll() is None, proc.communicate()[1].decode(errors='replace')
            assert time.monotonic() < deadline
            time.sleep(.01)
    try:
        first = start('first')
        wait('read', first)
        second = start('second')
        wait('second.started', second)
        time.sleep(.2)
        (tmp_path / 'release').write_text('go')
        for proc in processes:
            _, errors = proc.communicate(timeout=15)
            assert proc.returncode == 0, errors.decode(errors='replace')
        assert [int((tmp_path / (role + '.status')).read_text()) for role in ('first', 'second')] == (
            [200, 409] if operation == 'workflow' else [200, 200])
        if operation == 'trace':
            repo = SQLiteRepository(database)
            try:
                assert len(repo.get('traces', 'shared-trace')['events']) == 2
            finally:
                repo.close()
    finally:
        for proc in processes:
            if proc.poll() is None:
                proc.kill()
                proc.communicate()


def test_llm_preflight_checks_defaults_and_embedding_failure_without_raw_error():
    script = '''
import os, runpy, sys
from types import SimpleNamespace
calls = []
def completion(**kwargs):
    calls.append(kwargs['model'])
    return SimpleNamespace(usage=SimpleNamespace(total_tokens=1))
def embedding(**kwargs):
    raise RuntimeError('PRIVATE_UPSTREAM_RESPONSE')
def client(**kwargs):
    assert kwargs['max_retries'] == 0
    return SimpleNamespace(chat=SimpleNamespace(completions=SimpleNamespace(create=completion)),
                           embeddings=SimpleNamespace(create=embedding))
sys.modules['openai'] = SimpleNamespace(OpenAI=client)
sys.modules['dotenv'] = SimpleNamespace(load_dotenv=lambda *args, **kwargs: None)
try:
    runpy.run_path(sys.argv[1], run_name='__main__')
except SystemExit as result:
    assert result.code == 1
assert calls == ['qwen3.8-flash', 'qwen3-vl-plus', 'qwen3.8-flash', 'qwen3-vl-plus']
'''
    env = dict(os.environ, DASHSCOPE_API_KEY='audit-placeholder', PYTHONIOENCODING='utf-8')
    for name in ('LLM_MODEL', 'LLM_VL_MODEL', 'LLM_DECISION_MODEL'):
        env.pop(name, None)
    result = subprocess.run([sys.executable, '-c', script, str(ROOT / 'tools/check_llm_ready.py')],
                            env=env, capture_output=True, timeout=15)
    assert result.returncode == 0, result.stderr.decode(errors='replace')
    assert b'PRIVATE_UPSTREAM_RESPONSE' not in result.stdout


def test_export_filters_mutated_seed_without_touching_local_user_records(tmp_path):
    import json
    policy = tool('packaging_policy')
    path = tmp_path / 'mock_wrong_questions.json'
    rows = [{'userId': 'demo-user', 'createdAt': '2026-09-20', 'questionId': 'seed'},
            {'userId': 'demo-user', 'createdAt': '2026-10-25', 'questionId': 'runtime'},
            {'userId': 'private-user', 'createdAt': '2026-09-01', 'questionId': 'private'}]
    original = json.dumps(rows).encode()
    path.write_bytes(original)
    assert json.loads(policy.sanitized_bytes(path)) == [rows[0]]
    assert path.read_bytes() == original
