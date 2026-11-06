"""Shared focus acceptance: same clock, background recovery, CAS and one history."""
from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
import hashlib
import uuid

import pytest

from app.repositories.json_repository import JsonRepository
from app.repositories.sqlite_repository import SQLiteRepository
from app.services import device_collaboration as devices
from app.services import shared_focus as focus


@pytest.fixture(params=['json', 'sqlite'])
def repo(request, tmp_path):
    result = JsonRepository(tmp_path / 'shared.json') if request.param == 'json' else SQLiteRepository(tmp_path / 'shared.sqlite')
    yield result
    result.close()


def credentials(device):
    return dict(deviceId=device, deviceKey=hashlib.sha256(device.encode()).hexdigest())


def command(repo, device, action='heartbeat', owner='alice', now=1000000, **body):
    with repo.transaction(user_id=owner):
        return devices.execute(repo, owner, dict(credentials(device), action=action, **body), now / 1000)


def pair(repo):
    for name in ('phone', 'tablet'):
        command(repo, name, 'register', deviceLabel='测试' + name)
    invitation = command(repo, 'phone', 'invite', targetDeviceId='tablet')['links'][0]['invitationId']
    command(repo, 'tablet', 'accept', invitationId=invitation)
    return invitation


def task(**changes):
    return dict(course='数据结构', task='二叉树-唯一标识-测试', plannedMinutes=30,
                mode='normal', timerType='countdown', planTaskId='plan-task', **changes)


def action(repo, device, verb='heartbeat', owner='alice', now=1000000, **body):
    current = repo.get(focus.STATES, owner)
    defaults = dict(clientId=uuid.uuid4().hex, expectedRevision=current['revision'] if current else 0)
    if current:
        defaults['sessionId'] = current['sessionId']
    defaults.update(body)
    with repo.transaction(user_id=owner):
        return focus.execute(repo, owner, dict(credentials(device), action=verb, **defaults), now)


def read(repo, device, owner='alice', now=1000000):
    with repo.transaction(user_id=owner):
        return focus.read(repo, owner, credentials(device), now)


def start(repo):
    pair(repo)
    return action(repo, 'phone', 'start', task=task())['session']


def test_shared_clock_survives_handoff_pause_resume_and_background(repo):
    session = start(repo)
    assert session['elapsedMs'] == 0 and session['remainingMs'] == 1800000
    other = read(repo, 'tablet', now=1020000)['session']
    assert other['sessionId'] == session['sessionId'] and other['elapsedMs'] == 20000
    takeover = action(repo, 'tablet', 'handoff', now=1020000)['session']
    assert takeover['leaderDeviceId'] == 'tablet' and takeover['elapsedMs'] == 20000
    assert takeover['startedAt'] == session['startedAt']
    paused = action(repo, 'tablet', 'pause', now=1040000)['session']
    assert paused['state'] == 'paused' and paused['elapsedMs'] == 40000
    assert read(repo, 'phone', now=1100000)['session']['elapsedMs'] == 40000
    action(repo, 'phone', 'resume', now=1100000)
    command(repo, 'phone', 'background', now=1100000)
    snapshot = read(repo, 'tablet', now=1220000)['session']
    assert snapshot['state'] == 'running' and snapshot['elapsedMs'] == 160000
    assert snapshot['participants'][0]['background']
    command(repo, 'phone', now=1221000)
    assert command(repo, 'tablet', now=1221000)['links'][0]['state'] == 'connected'
    assert read(repo, 'phone', now=1221000)['session']['elapsedMs'] == snapshot['elapsedMs'] + 1000


def test_action_idempotency_and_concurrent_pause_only_increments_once(repo):
    start(repo)
    action(repo, 'tablet', 'join')
    revision = repo.get(focus.STATES, 'alice')['revision']
    def pause(index):
        return action(repo, 'phone' if index % 2 else 'tablet', 'pause', now=1030000,
                      expectedRevision=revision)['session']
    with ThreadPoolExecutor(max_workers=4) as pool:
        responses = list(pool.map(pause, range(8)))
    assert {r['revision'] for r in responses} == {revision + 1}
    assert {r['pauseCount'] for r in responses} == {1}
    body = dict(clientId='same-action', expectedRevision=revision + 1)
    first = action(repo, 'tablet', 'resume', now=1040000, **body)
    assert action(repo, 'tablet', 'resume', now=1060000, **body) == first
    with pytest.raises(focus.FocusSessionError) as error:
        action(repo, 'tablet', 'pause', now=1060000, **body)
    assert error.value.code == 'CLIENT_ID_CONFLICT'


def test_start_race_and_stale_revision_return_authoritative_snapshot(repo):
    pair(repo)
    def attempt(device):
        try:
            return action(repo, device, 'start', expectedRevision=0, task=task())
        except focus.FocusSessionError as error:
            return error
    with ThreadPoolExecutor(max_workers=2) as pool:
        responses = list(pool.map(attempt, ('phone', 'tablet')))
    assert sum(isinstance(r, dict) for r in responses) == 1
    conflict = next(r for r in responses if isinstance(r, focus.FocusSessionError))
    assert conflict.code == 'ACTIVE_SESSION' and conflict.snapshot['session']['state'] == 'running'
    current = repo.get(focus.STATES, 'alice')
    leader = current['leaderDeviceId']
    action(repo, leader, 'pause', now=1010000)
    with pytest.raises(focus.FocusSessionError) as error:
        action(repo, leader, 'resume', now=1020000, expectedRevision=current['revision'])
    assert error.value.status == 409 and error.value.snapshot['session']['state'] == 'paused'


def test_offline_action_times_replay_without_counting_paused_gap(repo):
    start(repo)
    action(repo, 'phone', 'pause', now=1100000, occurredAt=1020000)
    result = action(repo, 'phone', 'resume', now=1101000, occurredAt=1060000)['session']
    assert result['elapsedMs'] == 61000
    result = action(repo, 'phone', 'complete', now=1120000, occurredAt=1100000)['session']
    assert result['elapsedMs'] == 60000 and result['record']['actualMinutes'] == 1


def test_complete_records_once_and_reuses_plan_and_partner_progress(repo):
    start(repo)
    action(repo, 'tablet', 'join')
    repo.save('plans', 'plan', dict(planId='plan', userId='alice', tasks=[dict(taskId='plan-task', status='pending')]))
    repo.save('study_tasks', 'plan-task', dict(userId='alice', status='pending'))
    repo.save('shared_study_tasks', 'plan-task', dict(status='accepted', members=['alice', 'bob'],
                                                     progress={'alice': 'pending', 'bob': 'pending'}))
    revision = repo.get(focus.STATES, 'alice')['revision']
    def finish(device):
        return action(repo, device, 'complete', now=1060000, expectedRevision=revision)['session']
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(finish, ('phone', 'tablet')))
    assert results[0]['record'] == results[1]['record']
    assert len(repo.list('focus_sessions')) == len(repo.list('learning_events')) == 1
    assert repo.list('focus_sessions')[0]['session']['taskId'] == results[0]['sessionId']
    assert repo.get('plans', 'plan')['tasks'][0]['status'] == 'completed'
    assert repo.get('study_tasks', 'plan-task')['status'] == 'completed'
    assert repo.get('shared_study_tasks', 'plan-task')['progress'] == {'alice': 'completed', 'bob': 'pending'}


def test_no_cross_account_unpaired_or_revoked_access(repo):
    invitation = pair(repo)
    action(repo, 'phone', 'start', task=task())
    command(repo, 'stranger', 'register', deviceLabel='未配对设备')
    assert read(repo, 'stranger')['session'] is None
    with pytest.raises(focus.FocusSessionError) as error:
        action(repo, 'stranger', 'handoff')
    assert error.value.status == 403
    command(repo, 'phone', 'register', owner='bob', deviceLabel='其他账号')
    assert read(repo, 'phone', owner='bob')['session'] is None
    action(repo, 'tablet', 'handoff')
    command(repo, 'phone', 'disconnect', invitationId=invitation)
    assert read(repo, 'tablet')['session'] is None
    with pytest.raises(focus.FocusSessionError):
        action(repo, 'tablet', 'pause')
    with pytest.raises(focus.FocusSessionError):
        focus.read(repo, 'alice', dict(deviceId='phone', deviceKey='invalid' * 10))


def test_heartbeat_does_not_rewrite_or_increment_shared_state(repo, monkeypatch):
    start(repo)
    before = deepcopy(repo.get(focus.STATES, 'alice'))
    writes = []
    original = repo.apply_batch
    def capture(deletes, saves):
        writes.extend(saves)
        return original(deletes, saves)
    monkeypatch.setattr(repo, 'apply_batch', capture)
    result = action(repo, 'phone', now=1005000)['session']
    assert result['elapsedMs'] == 5000 and not writes
    assert repo.get(focus.STATES, 'alice') == before


def test_new_device_can_start_after_old_unpaired_session_has_ended(repo):
    start(repo)
    command(repo, 'new-phone', 'register', deviceLabel='新手机')
    with pytest.raises(focus.FocusSessionError) as error:
        action(repo, 'new-phone', 'start', task=task())
    assert error.value.code == 'PAIRING_REQUIRED'
    action(repo, 'phone', 'complete', now=1060000)
    old_id = repo.get(focus.STATES, 'alice')['sessionId']
    fresh = action(repo, 'new-phone', 'start', now=1061000, task=task())['session']
    assert fresh['sessionId'] != old_id and fresh['leaderDeviceId'] == 'new-phone'
    assert fresh['elapsedMs'] == 0 and len(repo.list('focus_sessions')) == 1


def test_complete_storage_failure_cannot_publish_partial_history(repo, monkeypatch):
    start(repo)
    before = deepcopy(repo.get(focus.STATES, 'alice'))
    apply = repo.apply_batch
    def fail(*args):
        raise OSError('simulated storage failure')
    monkeypatch.setattr(repo, 'apply_batch', fail)
    with pytest.raises(OSError):
        action(repo, 'phone', 'complete', now=1060000)
    assert repo.list('focus_sessions') == [] and repo.list('learning_events') == []
    assert repo.get(focus.STATES, 'alice') == before
    monkeypatch.setattr(repo, 'apply_batch', apply)
    action(repo, 'phone', 'complete', now=1060000)
    assert len(repo.list('focus_sessions')) == 1


def test_http_auth_header_credentials_conflict_and_history(tmp_path):
    from app import create_app
    app = create_app(tmp_path / 'http-shared.json')
    client = app.test_client()
    auth = client.post('/api/v1/auth/register', json=dict(nickname='共享测试', phone='13900008992',
                                                        password='test-pw-123456', seedDemoData=False)).get_json()
    headers = {'Authorization': 'Bearer ' + auth['token']}
    for device in ('phone', 'tablet'):
        assert client.post('/api/v1/device-collaboration', headers=headers,
                           json=dict(credentials(device), action='register', deviceLabel=device)).status_code == 200
    invite = client.post('/api/v1/device-collaboration', headers=headers,
                         json=dict(credentials('phone'), action='invite', targetDeviceId='tablet')).get_json()['links'][0]
    client.post('/api/v1/device-collaboration', headers=headers,
                json=dict(credentials('tablet'), action='accept', invitationId=invite['invitationId']))
    path = '/api/v1/focus-session'
    assert client.get(path).status_code == 401
    assert client.get(path, headers=headers).status_code == 400
    assert client.post(path + '/actions', headers=headers, json=['bad']).status_code == 400
    device_headers = dict(headers, **{'X-Device-Id': 'tablet', 'X-Device-Key': credentials('tablet')['deviceKey']})
    assert client.get(path, headers=device_headers).get_json()['session'] is None
    started = client.post(path + '/actions', headers=headers, json=dict(credentials('phone'), action='start',
        expectedRevision=0, clientId='start', task=task())).get_json()['session']
    assert client.get(path, headers=device_headers).get_json()['session']['sessionId'] == started['sessionId']
    conflict = client.post(path + '/actions', headers=headers, json=dict(credentials('tablet'), action='start',
        expectedRevision=0, clientId='second-start', task=task()))
    assert conflict.status_code == 409 and conflict.get_json()['snapshot']['session']['sessionId'] == started['sessionId']
    completed = client.post(path + '/actions', headers=headers, json=dict(credentials('phone'), action='complete',
        sessionId=started['sessionId'], expectedRevision=started['revision'], clientId='complete')).get_json()['session']
    history = client.get('/api/v1/focus-sessions', headers=headers).get_json()['sessions']
    assert history == [completed['record']]
    assert client.post('/api/v1/focus-sessions', headers=headers, json=completed['record']).status_code == 200
    app.extensions['repository'].close()
