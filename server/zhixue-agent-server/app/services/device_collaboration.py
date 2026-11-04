"""Explicit, account-scoped device pairing and acknowledged task delivery.

Presence means a foreground client contacted this server recently. A successful
publish only means queued; only the receiving installation can acknowledge it.
"""
from copy import deepcopy
import hashlib
import hmac
import json
import time
import uuid

PRESENCE_SECONDS = 25
INVITE_SECONDS = 60
DEVICES = 'collaboration_devices'
LINKS = 'collaboration_links'


class CollaborationError(ValueError):
    def __init__(self, message, status=409):
        super().__init__(message)
        self.status = status


def text(data, name, limit=128):
    value = data.get(name)
    if not isinstance(value, str) or not value.strip() or len(value) > limit:
        raise CollaborationError('设备请求格式不正确', 400)
    return value.strip()


def key(owner, identity):
    return hashlib.sha256(f'{owner}\0{identity}'.encode()).hexdigest()


def online(device, now):
    return bool(device and device['available'] and now - device['lastSeen'] < PRESENCE_SECONDS)


def task_value(raw):
    if not isinstance(raw, dict):
        raise CollaborationError('任务格式不正确', 400)
    minutes = raw.get('plannedMinutes')
    if type(minutes) is not int or not 0 <= minutes <= 180:
        raise CollaborationError('专注时长应为0至180分钟', 400)
    mode, timer = raw.get('mode'), raw.get('timerType', 'countdown')
    if mode not in ('normal', 'strict') or timer not in ('countdown', 'stopwatch') or (timer == 'countdown' and minutes == 0):
        raise CollaborationError('专注设置不正确', 400)
    if type(raw.get('allowBackgroundTiming', False)) is not bool:
        raise CollaborationError('专注设置不正确', 400)
    # Local plan identifiers and timing progress are not portable across devices.
    return dict(course=text(raw, 'course', 100), task=text(raw, 'task', 500),
                plannedMinutes=minutes, mode=mode, timerType=timer, source='collaborative',
                allowBackgroundTiming=raw.get('allowBackgroundTiming', False))


def execute(repo, owner, data, now=None):
    now = time.time() if now is None else now
    if not isinstance(data, dict):
        raise CollaborationError('设备请求格式不正确', 400)
    action = text(data, 'action', 32)
    if action not in {'register', 'heartbeat', 'invite', 'accept', 'reject', 'disconnect', 'publish', 'clear', 'ack', 'offline'}:
        raise CollaborationError('不支持的设备操作', 400)
    device_id, secret = text(data, 'deviceId'), text(data, 'deviceKey')
    if len(secret) < 32:
        raise CollaborationError('设备凭据无效', 403)
    record_key = key(owner, device_id)
    device = repo.get(DEVICES, record_key)
    secret_hash = hashlib.sha256(secret.encode()).hexdigest()
    if device and not hmac.compare_digest(device['keyHash'], secret_hash):
        raise CollaborationError('设备凭据无效，请重新连接', 403)
    if action == 'register':
        label = text(data, 'deviceLabel', 80)
        if not device:
            if len(repo.query(DEVICES, {'userId': owner})) >= 20:
                raise CollaborationError('登记设备已达上限，请联系管理员清理旧设备')
            device = dict(userId=owner, deviceId=device_id, keyHash=secret_hash)
        device.update(deviceLabel=label, lastSeen=now, available=True)
    elif not device:
        raise CollaborationError('请先登记本机设备', 404)

    devices = {d['deviceId']: d for d in repo.query(DEVICES, {'userId': owner})}
    # Expire before refreshing this client's lease; reconnecting cannot revive an old link.
    links = repo.query(LINKS, {'userId': owner})
    for link in links:
        if link['state'] == 'pending' and now >= link['expiresAt']:
            link.update(state='expired', tasks={})
        if link['state'] in ('pending', 'connected') and not all(online(devices.get(d), now) for d in link['members']):
            link.update(state='disconnected', tasks={})

    device.update(lastSeen=now, available=action != 'offline')
    devices[device_id] = device
    selected = None
    if action == 'invite':
        target = text(data, 'targetDeviceId')
        if target == device_id or not online(devices.get(target), now):
            raise CollaborationError('对方设备不在线，请在另一台设备上打开连接设备页面')
        selected = next((l for l in links if set(l['members']) == {device_id, target}), None)
        # Repeated taps are idempotent; a crossed invite still requires its target's consent.
        if not selected or selected['state'] not in ('pending', 'connected'):
            replacement = dict(userId=owner, linkId=key(owner, json.dumps(sorted([device_id, target]))),
                               invitationId=uuid.uuid4().hex, members=[device_id, target],
                               requester=device_id, state='pending', expiresAt=now + INVITE_SECONDS, tasks={})
            if selected:
                links.remove(selected)
            selected = replacement
            links.append(selected)
    elif action in ('accept', 'reject', 'disconnect', 'ack'):
        selected = next((l for l in links if l['invitationId'] == text(data, 'invitationId') and device_id in l['members']), None)
        if not selected:
            raise CollaborationError('连接请求已失效，请刷新后重试', 404)
        if action in ('accept', 'reject'):
            if selected['requester'] == device_id:
                raise CollaborationError('需要在对方设备上确认连接', 403)
            if selected['state'] != 'pending':
                if action != 'accept' or selected['state'] != 'connected':
                    raise CollaborationError('连接请求已过期或已处理，请重新发起')
            else:
                selected['state'] = 'connected' if action == 'accept' else 'rejected'
        elif action == 'disconnect':
            selected.update(state='disconnected', tasks={})
        else:
            source = next(d for d in selected['members'] if d != device_id)
            message = selected['tasks'].get(source)
            if selected['state'] != 'connected' or not message or message['messageId'] != text(data, 'messageId'):
                raise CollaborationError('任务已更新，请刷新后重试')
            message['ackedAt'] = message['ackedAt'] or now
    elif action in ('publish', 'clear'):
        message_id = text(data, 'messageId')
        task = task_value(data.get('task')) if action == 'publish' else None
        connected = [l for l in links if device_id in l['members'] and l['state'] == 'connected']
        if not connected:
            raise CollaborationError('尚未连接其他设备，请先连接设备')
        for link in connected:
            previous = link['tasks'].get(device_id)
            if previous and previous['messageId'] == message_id:
                if previous['task'] != task:
                    raise CollaborationError('任务编号已被使用')
                continue
            link['tasks'][device_id] = dict(messageId=message_id, task=task, sentAt=now, ackedAt=0)
    if action == 'offline':
        for link in links:
            if device_id in link['members'] and link['state'] in ('pending', 'connected'):
                link.update(state='disconnected', tasks={})
    repo.apply_batch([], [(DEVICES, record_key, device)] + [(LINKS, l['linkId'], l) for l in links])
    peers = [dict(deviceId=d['deviceId'], deviceLabel=d['deviceLabel'], online=online(d, now),
                  lastSeen=int(d['lastSeen'] * 1000)) for d in devices.values() if d['deviceId'] != device_id]
    views = []
    for link in links:
        if device_id not in link['members']:
            continue
        peer_id = next(d for d in link['members'] if d != device_id)
        peer = devices.get(peer_id, {})
        incoming = deepcopy(link['tasks'].get(peer_id)) if link['state'] == 'connected' else None
        outgoing = link['tasks'].get(device_id) if link['state'] == 'connected' else None
        views.append(dict(invitationId=link['invitationId'], peerDeviceId=peer_id,
                          peerDeviceLabel=peer.get('deviceLabel', '另一台设备'),
                          state=link['state'], incoming=link['requester'] != device_id,
                          expiresAt=int(link['expiresAt'] * 1000),
                          received=incoming, sentMessageId=outgoing['messageId'] if outgoing else '',
                          acknowledgedAt=int(outgoing['ackedAt'] * 1000) if outgoing else 0))
    return dict(userId=owner, deviceId=device_id, serverTime=int(now * 1000), devices=peers, links=views)
