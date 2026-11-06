"""Two independent installations: consent, receipts, leases and isolation."""
from copy import deepcopy
import hashlib
import pytest
from app.repositories.json_repository import JsonRepository
from app.repositories.sqlite_repository import SQLiteRepository
from app.services import device_collaboration as service


@pytest.fixture(params=['json', 'sqlite'])
def repo(request, tmp_path):
    repository = JsonRepository(tmp_path / 'devices.json') if request.param == 'json' else SQLiteRepository(tmp_path / 'devices.sqlite')
    yield repository
    repository.close()


def command(repo, device, action='heartbeat', owner='alice', now=1000, **body):
    data = dict(action=action, deviceId=device, deviceKey=hashlib.sha256(device.encode()).hexdigest(), **body)
    with repo.transaction():
        return service.execute(repo, owner, data, now)


def register(repo, device, owner='alice', now=1000):
    return command(repo, device, 'register', owner, now, deviceLabel='测试' + device)


def pair(repo):
    register(repo, 'phone'); register(repo, 'tablet')
    snapshot = command(repo, 'phone', 'invite', targetDeviceId='tablet')
    invitation = snapshot['links'][0]['invitationId']
    command(repo, 'tablet', 'accept', invitationId=invitation)
    return invitation


def task():
    return dict(course='操作系统', task='进程调度算法对比', plannedMinutes=90,
                mode='normal', timerType='countdown', source='manual', planTaskId='phone-only')


def test_explicit_consent_and_correct_recipient(repo):
    register(repo, 'phone'); register(repo, 'tablet')
    result = command(repo, 'phone', 'invite', targetDeviceId='tablet')
    link = result['links'][0]
    assert link['state'] == 'pending' and not link['incoming']
    assert command(repo, 'tablet')['links'][0]['incoming']
    with pytest.raises(service.CollaborationError, match='对方设备上确认'):
        command(repo, 'phone', 'accept', invitationId=link['invitationId'])
    with pytest.raises(service.CollaborationError, match='尚未连接'):
        command(repo, 'phone', 'publish', messageId='early', task=task())
    result = command(repo, 'tablet', 'accept', invitationId=link['invitationId'])
    assert result['links'][0]['state'] == 'connected'
    assert command(repo, 'tablet', 'accept', invitationId=link['invitationId'])['links'][0]['state'] == 'connected'
    assert command(repo, 'phone', 'invite', targetDeviceId='tablet')['links'][0]['invitationId'] == link['invitationId']


def test_delivery_requires_exact_receiver_ack_and_clear(repo):
    invitation = pair(repo)
    result = command(repo, 'phone', 'publish', messageId='message-1', task=task())
    assert result['links'][0]['acknowledgedAt'] == 0
    received = command(repo, 'tablet')['links'][0]['received']
    assert received['task']['task'] == task()['task'] and received['task']['source'] == 'collaborative'
    assert received['task']['planTaskId'] == 'phone-only' and received['ackedAt'] == 0
    with pytest.raises(service.CollaborationError):
        command(repo, 'phone', 'ack', invitationId=invitation, messageId='message-1')
    command(repo, 'tablet', 'ack', invitationId=invitation, messageId='message-1')
    assert command(repo, 'phone')['links'][0]['acknowledgedAt'] == 1000000
    # Retrying the same publish must preserve its receipt.
    assert command(repo, 'phone', 'publish', messageId='message-1', task=task())['links'][0]['acknowledgedAt'] == 1000000
    command(repo, 'phone', 'publish', messageId='message-2', task=task())
    with pytest.raises(service.CollaborationError):
        command(repo, 'tablet', 'ack', invitationId=invitation, messageId='message-1')
    assert command(repo, 'phone')['links'][0]['acknowledgedAt'] == 0
    command(repo, 'phone', 'clear', messageId='clear-1')
    assert command(repo, 'tablet')['links'][0]['received']['task'] is None


def test_multiple_devices_have_independent_receipts(repo):
    pair(repo); register(repo, 'pc')
    invitation = command(repo, 'phone', 'invite', targetDeviceId='pc')['links']
    pc_link = next(l for l in invitation if l['peerDeviceId'] == 'pc')
    command(repo, 'pc', 'accept', invitationId=pc_link['invitationId'])
    command(repo, 'phone', 'publish', messageId='broadcast', task=task())
    command(repo, 'pc', 'ack', invitationId=pc_link['invitationId'], messageId='broadcast')
    links = command(repo, 'phone')['links']
    assert len([l for l in links if l['state'] == 'connected']) == 2
    assert len([l for l in links if l['acknowledgedAt'] > 0]) == 1


def test_account_and_installation_isolation(repo):
    invitation = pair(repo)
    register(repo, 'other', owner='bob')
    assert command(repo, 'other', owner='bob')['devices'] == []
    for action, body in [('invite', dict(targetDeviceId='phone')), ('accept', dict(invitationId=invitation)),
                         ('ack', dict(invitationId=invitation, messageId='message'))]:
        with pytest.raises(service.CollaborationError):
            command(repo, 'other', action, owner='bob', **body)
    before = deepcopy(repo.list(service.DEVICES))
    with pytest.raises(service.CollaborationError, match='设备凭据无效'):
        service.execute(repo, 'alice', dict(action='heartbeat', deviceId='tablet', deviceKey='wrong' * 16), 1000)
    assert repo.list(service.DEVICES) == before
    snapshot = command(repo, 'phone')
    assert 'keyHash' not in str(snapshot) and 'deviceKey' not in str(snapshot)


def test_reject_cancel_and_stale_invitation(repo):
    register(repo, 'phone'); register(repo, 'tablet')
    invitation = command(repo, 'phone', 'invite', targetDeviceId='tablet')['links'][0]['invitationId']
    assert command(repo, 'tablet', 'reject', invitationId=invitation)['links'][0]['state'] == 'rejected'
    new = command(repo, 'phone', 'invite', targetDeviceId='tablet')['links'][0]['invitationId']
    assert new != invitation
    with pytest.raises(service.CollaborationError):
        command(repo, 'tablet', 'accept', invitationId=invitation)
    command(repo, 'phone', 'disconnect', invitationId=new)
    with pytest.raises(service.CollaborationError):
        command(repo, 'tablet', 'accept', invitationId=new)


def test_presence_expiry_preserves_pairing_and_automatically_recovers(repo):
    pair(repo)
    result = command(repo, 'phone', now=1091)
    assert not result['devices'][0]['online'] and result['links'][0]['state'] == 'connected'
    assert command(repo, 'tablet', now=1092)['links'][0]['state'] == 'connected'
    assert command(repo, 'phone', 'invite', now=1093, targetDeviceId='tablet')['links'][0]['state'] == 'connected'


def test_background_and_offline_preserve_pairing_and_pending_task(repo):
    pair(repo)
    command(repo, 'phone', 'publish', messageId='message', task=task())
    command(repo, 'phone', 'background')
    result = command(repo, 'tablet', now=1120)
    assert not result['devices'][0]['online'] and result['devices'][0]['background']
    assert result['links'][0]['received']['messageId'] == 'message'
    assert result['links'][0]['state'] == 'connected'
    command(repo, 'phone', 'offline', now=1121)
    assert command(repo, 'tablet', now=1122)['links'][0]['received']['messageId'] == 'message'
    assert command(repo, 'phone', now=1123)['links'][0]['state'] == 'connected'


def test_exact_task_consumption_and_ttl(repo):
    invitation = pair(repo)
    command(repo, 'phone', 'publish', messageId='message', task=task())
    with pytest.raises(service.CollaborationError):
        command(repo, 'tablet', 'consume', invitationId=invitation, messageId='different')
    command(repo, 'tablet', 'consume', invitationId=invitation, messageId='message')
    assert command(repo, 'tablet')['links'][0]['received'] is None
    assert command(repo, 'phone')['links'][0]['acknowledgedAt'] > 0
    command(repo, 'phone', 'publish', messageId='next-message', task=task())
    assert command(repo, 'tablet', now=1000 + service.MESSAGE_SECONDS)['links'][0]['received'] is None


def test_heartbeat_writes_only_changed_device(repo, monkeypatch):
    pair(repo)
    writes = []
    original = repo.apply_batch
    def track(deletes, saves):
        writes.extend(saves)
        return original(deletes, saves)
    monkeypatch.setattr(repo, 'apply_batch', track)
    command(repo, 'phone', now=1001)
    assert len(writes) == 1 and writes[0][0] == service.DEVICES


def test_invitation_expiry_despite_live_heartbeats(repo):
    register(repo, 'phone'); register(repo, 'tablet')
    invitation = command(repo, 'phone', 'invite', targetDeviceId='tablet')['links'][0]['invitationId']
    for now in (1020, 1040, 1059):
        command(repo, 'phone', now=now); command(repo, 'tablet', now=now)
    assert command(repo, 'phone', now=1061)['links'][0]['state'] == 'expired'
    with pytest.raises(service.CollaborationError):
        command(repo, 'tablet', 'accept', now=1061, invitationId=invitation)


@pytest.mark.parametrize('update', [{'plannedMinutes': True}, {'plannedMinutes': 181}, {'task': ''},
                                    {'timerType': 'invalid'}, {'mode': 'unknown'}, {'allowBackgroundTiming': 'false'}])
def test_invalid_task_does_not_change_delivery(repo, update):
    pair(repo)
    before = repo.list(service.LINKS)
    with pytest.raises(service.CollaborationError):
        command(repo, 'phone', 'publish', messageId='invalid', task=dict(task(), **update))
    assert repo.list(service.LINKS) == before


def test_http_two_clients_and_anonymous_rejection(tmp_path):
    from app import create_app
    app = create_app(tmp_path / 'http-devices.json')
    a, b = app.test_client(), app.test_client()
    auth = a.post('/api/v1/auth/register', json=dict(nickname='设备连接测试', phone='13900008991', password='test-pw-123456')).get_json()
    headers = {'Authorization': 'Bearer ' + auth['token']}
    path = '/api/v1/device-collaboration'
    def post(client, device, action='heartbeat', **body):
        return client.post(path, headers=headers, json=dict(action=action, deviceId=device, deviceKey=device * 32, **body))
    assert a.post(path, json={}).status_code == 401
    assert post(a, 'a', 'register', deviceLabel='手机').status_code == 200
    assert post(b, 'b', 'register', deviceLabel='平板').status_code == 200
    result = post(a, 'a', 'invite', targetDeviceId='b').get_json()
    invitation = result['links'][0]['invitationId']
    assert post(b, 'b', 'accept', invitationId=invitation).status_code == 200
    assert post(a, 'a', 'publish', messageId='m', task=task()).get_json()['links'][0]['acknowledgedAt'] == 0
    assert post(b, 'b').get_json()['links'][0]['received']['task']['task'] == task()['task']
    assert post(b, 'b', 'ack', invitationId=invitation, messageId='m').status_code == 200
    assert post(a, 'a').get_json()['links'][0]['acknowledgedAt'] > 0
    assert post(a, 'a', 'disconnect', invitationId=invitation).status_code == 200
    assert post(b, 'b').get_json()['links'][0]['state'] == 'disconnected'
    assert a.post(path, headers=headers, json=['invalid']).status_code == 400
    app.extensions['repository'].close()
