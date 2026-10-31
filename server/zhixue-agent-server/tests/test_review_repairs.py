"""Regression coverage for interrupted writes and competing user operations."""
import json
import os
from pathlib import Path
import runpy
import sqlite3
import subprocess
import sys
import time

from flask import Flask
import pytest

from app.api import partner_invite
from app import create_app
from app.repositories.json_repository import JsonRepository
from app.repositories.sqlite_repository import SQLiteRepository


def test_invitation_requires_real_sender_and_reaches_real_recipient(tmp_path):
    client = create_app(tmp_path / 'real-invitations.json').test_client()
    def register(phone):
        response = client.post('/api/v1/auth/register', json={'password': 'test-pw-123456', 'phone': phone, 'nickname': phone})
        assert response.status_code == 201
        data = response.get_json()
        return data['user']['userId'], {'Authorization': 'Bearer ' + data['token']}
    alice, auth_alice = register('13900008301')
    bob, auth_bob = register('13900008302')
    payload = {'toUserId': bob, 'message': 'study'}
    assert client.post('/api/v1/agent/partner-invitations', json=payload).status_code == 401
    assert partner_invite._repository.list('invitations') == []
    created = client.post('/api/v1/agent/partner-invitations', json=payload, headers=auth_alice)
    assert created.status_code == 201
    invitation = created.get_json()['invitation']
    assert invitation['fromUserId'] == alice
    url = '/api/v1/agent/partner-invitations/' + invitation['invitationId'] + '/accept'
    assert client.post(url, headers=auth_bob).status_code == 200
    for owner, headers, other in ((alice, auth_alice, bob), (bob, auth_bob, alice)):
        contacts = client.get('/api/v1/agent/partner-contacts', headers=headers).get_json()
        assert contacts['userId'] == owner
        assert contacts['contacts'][0]['partnerUserId'] == other


@pytest.mark.parametrize('operation', ['insert', 'replace', 'delete', 'clear'])
def test_json_failed_mutation_does_not_leak_into_later_writes(tmp_path, monkeypatch, operation):
    repo = JsonRepository(tmp_path / 'state.json')
    try:
        repo.save('items', 'existing', {'value': 'before'})
        original_disk = repo.path.read_bytes()
        original_flush = repo._flush
        def fail():
            raise OSError('injected disk failure')
        monkeypatch.setattr(repo, '_flush', fail)
        with pytest.raises(OSError):
            if operation in ('insert', 'replace'):
                repo.save('items', 'new' if operation == 'insert' else 'existing', {'value': 'after'})
            elif operation == 'delete':
                repo.delete('items', 'existing')
            else:
                repo.clear('items')
        assert repo.get('items', 'existing') == {'value': 'before'}
        assert repo.get('items', 'new') is None
        assert repo.path.read_bytes() == original_disk
        monkeypatch.setattr(repo, '_flush', original_flush)
        repo.save('other', 'unrelated', {'saved': True})
        assert json.loads(repo.path.read_text(encoding='utf-8'))['items'] == {'existing': {'value': 'before'}}
    finally:
        repo.close()


@pytest.mark.parametrize('backend', [JsonRepository, SQLiteRepository])
def test_accept_failure_rolls_back_and_same_action_retry_is_safe(tmp_path, monkeypatch, backend):
    repo = backend(tmp_path / 'invitations')
    monkeypatch.setattr(partner_invite, '_repository', repo)
    invitation = {'invitationId': 'inv', 'fromUserId': 'alice', 'toUserId': 'bob', 'status': 'pending'}
    repo.save('invitations', 'inv', invitation)
    app = Flask(__name__)
    try:
        # Fail the real commit after preparing both sides, not a mock endpoint.
        if backend is JsonRepository:
            original = repo._flush
            def fail():
                raise OSError('injected write failure')
            monkeypatch.setattr(repo, '_flush', fail)
        else:
            repo._connection.execute("""CREATE TRIGGER fail_contact BEFORE INSERT ON records
                WHEN NEW.collection = 'contacts' BEGIN SELECT RAISE(ABORT, 'injected'); END""")
            repo._connection.commit()
        with app.test_request_context():
            with pytest.raises(OSError if backend is JsonRepository else sqlite3.IntegrityError):
                partner_invite._respond('inv', 'bob', 'accepted')
        assert repo.get('invitations', 'inv') == invitation
        assert repo.list('contacts') == []
        if backend is JsonRepository:
            monkeypatch.setattr(repo, '_flush', original)
        else:
            repo._connection.execute('DROP TRIGGER fail_contact')
            repo._connection.commit()
        with app.test_request_context():
            first = partner_invite._respond('inv', 'bob', 'accepted').get_json()
            contacts = repo.list('contacts')
            assert len(contacts) == 2
            assert partner_invite._respond('inv', 'bob', 'accepted').get_json() == first
            assert repo.list('contacts') == contacts
            assert partner_invite._respond('inv', 'bob', 'declined')[1] == 409
            assert partner_invite._respond('inv', 'alice', 'accepted')[1] == 403
            # Recover a partial acceptance written by an older version.
            repo.delete('contacts', 'bob:alice')
            partner_invite._respond('inv', 'bob', 'accepted')
            assert len(repo.list('contacts')) == 2
    finally:
        repo.close()


WORKER = r'''
import json, sys, time
from pathlib import Path
from flask import Flask
from app.api import focus, plans, partner_invite, workflows
from app.tools.profile_merge import merge_points_into_profile
from app.repositories.sqlite_repository import SQLiteRepository
database, action, directory, role = sys.argv[1:]
directory = Path(directory)
repo = SQLiteRepository(database)
focus.configure_focus_repository(repo)
plans.configure_plans_repository(repo)
partner_invite.configure_partner_invite_repository(repo)
workflows.configure_workflows_repository(repo)
app = Flask(__name__)
if role == 'first':
    def pause():
        (directory / 'read').write_text('ready')
        deadline = time.monotonic() + 10
        while not (directory / 'release').exists():
            if time.monotonic() > deadline:
                raise TimeoutError('parent did not release reader')
            time.sleep(.01)
    if action == 'accept':
        original = partner_invite._load
        def delayed(key):
            result = original(key)
            pause()
            return result
        partner_invite._load = delayed
    elif action == 'replan':
        original = repo.get
        def delayed(collection, key):
            result = original(collection, key)
            if collection == 'plans':
                pause()
            return result
        repo.get = delayed
    else:
        original = repo.ids if action == 'discover' else repo.list
        def delayed(collection):
            result = original(collection)
            if collection == 'plans':
                pause()
            return result
        if action == 'discover':
            repo.ids = delayed
        else:
            repo.list = delayed
else:
    (directory / 'attempt').write_text('ready')
payload = {'taskId': 'session-' + action, 'planTaskId': 'task-' + action,
    'course': 'audit', 'task': 'audit', 'endedAt': '2026-01-01T00:00:00Z',
    'plannedMinutes': 10, 'actualMinutes': 10, 'pauseCount': 0,
    'interruptionCount': 0, 'completionRate': 100,
    'selfAssessment': 'completed', 'timerType': 'countdown', 'status': 'completed'}
if action == 'budget':
    payload = {'availableMinutes': 10, 'expectedPlanVersion': 1, 'idempotencyKey': 'budget'}
try:
    with app.test_request_context(json=payload):
        if action in ('accept', 'decline'):
            result = partner_invite._respond('inv', 'bob', 'accepted' if action == 'accept' else 'declined')
        elif action == 'replan':
            workflows._agent_action('planner', {'userId': 'demo-user', 'plan': {'planId': 'plan'},
                'assessment': {'score': 0}, 'needReplan': True,
                'replanRequest': {'objective': 'audit', 'replanState': {'knowledgePointId': 'a',
                    'masteryScore': 0, 'assessmentScore': 0, 'repeatedError': True}}})
            result = app.response_class(status=200)
        elif action == 'discover':
            merge_points_into_profile(repo, 'demo-user', [{'name': 'new point', 'knowledgePointId': 'new-point'}])
            result = app.response_class(status=200)
        elif action == 'budget':
            result = plans.update_available_minutes()
        else:
            result = focus.submit_focus_session()
        status = result[1] if isinstance(result, tuple) else result.status_code
        (directory / (role + '.json')).write_text(json.dumps({'status': status}))
finally:
    repo.close()
'''


@pytest.mark.parametrize('first_action,second_action', [
    ('a', 'b'), ('budget', 'b'), ('discover', 'b'), ('replan', 'b'), ('accept', 'decline')])
def test_sqlite_workers_serialize_read_modify_write(tmp_path, first_action, second_action):
    database = tmp_path / 'shared.sqlite'
    repo = SQLiteRepository(database)
    repo.save('plans', 'plan', {'planId': 'plan', 'userId': 'demo-user', 'version': 1,
        'tasks': [{'taskId': 'task-' + name, 'knowledgePointId': name,
                   'knowledgePointName': name, 'durationMinutes': 10, 'status': 'pending'} for name in ('a', 'b')]})
    repo.save('invitations', 'inv', {'invitationId': 'inv', 'fromUserId': 'alice',
                                   'toUserId': 'bob', 'status': 'pending'})
    repo.save('profiles', 'demo-user', {'userId': 'demo-user', 'profileVersion': 1, 'mastery': []})
    worker = tmp_path / 'worker.py'
    worker.write_text(WORKER, encoding='utf-8')
    env = dict(os.environ, PYTHONPATH=str(Path(__file__).resolve().parents[1]))
    processes = []
    def start(action, role):
        process = subprocess.Popen([sys.executable, str(worker), str(database), action, str(tmp_path), role],
                                   env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        processes.append(process)
        return process
    def wait_for(name, process):
        deadline = time.monotonic() + 10
        while not (tmp_path / name).exists():
            assert process.poll() is None, process.communicate()[1].decode(errors='replace')
            assert time.monotonic() < deadline, f'timed out waiting for {name}'
            time.sleep(.01)
    try:
        first = start(first_action, 'first')
        wait_for('read', first)
        second = start(second_action, 'second')
        wait_for('attempt', second)
        # With no encompassing transaction, the second worker can commit here.
        time.sleep(.2)
        (tmp_path / 'release').write_text('go')
        for process in processes:
            _, errors = process.communicate(timeout=15)
            assert process.returncode == 0, errors.decode(errors='replace')
        statuses = [json.loads((tmp_path / (role + '.json')).read_text())['status'] for role in ('first', 'second')]
        if first_action == 'accept':
            assert statuses == [200, 409]
            assert repo.get('invitations', 'inv')['status'] == 'accepted'
            assert len(repo.list('contacts')) == 2
        else:
            assert statuses == [200, 200]
            plan = repo.get('plans', 'plan')
            tasks = {t['taskId']: t for t in plan['tasks'] + plan.get('unscheduledTasks', [])}
            assert tasks['task-b']['status'] == 'completed'
            if first_action == 'a':
                assert tasks['task-a']['status'] == 'completed'
                assert len(repo.list('focus_sessions')) == 2
            elif first_action == 'budget':
                assert plan['constraints']['availableMinutes'] == 10
                assert plan['budgetSummary']['scheduledMinutes'] == 10
            elif first_action == 'discover':
                assert any(t['knowledgePointId'] == 'new-point' for t in plan['candidatePool'])
            else:
                assert plan['version'] == 2
    finally:
        for process in processes:
            if process.poll() is None:
                process.kill()
                process.communicate()
        repo.close()


def test_validator_audit_covers_shared_routes_templates_and_missing_routes():
    root = Path(__file__).resolve().parents[3]
    audit = runpy.run_path(str(root / 'tools' / 'check_frontend_validator_coverage.py'))
    exact, prefix = audit['parse_validator_routes']("""
        if (route === '/api/v1/focus-sessions') { return true; }
        if (method === 'GET' && route.indexOf('/api/v1/documents/') === 0) { return true; }
    """)
    for method in ('GET', 'POST'):
        assert audit['matches']((method, '/api/v1/focus-sessions'), exact, prefix)
    assert audit['matches'](('GET', '/api/v1/documents/{param}'), exact, prefix)
    assert not audit['matches'](('POST', '/api/v1/missing'), exact, prefix)
    source = (root / 'app/entry/src/main/ets/api/AgentApiClient.ets').read_text(encoding='utf-8')
    calls = audit['parse_client_calls'](source)
    assert ('GET', '/api/v1/knowledge-bases') in calls
    assert ('GET', '/api/v1/exercises/{param}') in calls
    assert ('POST', '/api/v1/exercises/{param}/submit') in calls
    contract = json.loads((root / 'contracts/openapi.json').read_bytes())
    operations = {(method, audit['normalize'](route)) for method, route in audit['contract_operations'](contract)}
    assert not {(method, audit['normalize'](route)) for method, route in calls} - operations
