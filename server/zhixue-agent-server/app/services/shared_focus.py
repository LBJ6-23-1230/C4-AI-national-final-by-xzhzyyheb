"""One account, one server-timed focus session, with consent and CAS actions."""
from copy import deepcopy
from datetime import datetime, timezone
import hashlib
import hmac
import json
import math
import time
import uuid

from app.services.device_collaboration import DEVICES, LINKS, key, online, background, text, task_value

STATES = 'focus_session_state'
COMMANDS = 'focus_session_commands'
ACTIVE = {'running', 'paused'}


class FocusSessionError(ValueError):
    def __init__(self, message, status=400, code='BAD_REQUEST', snapshot=None):
        super().__init__(message)
        self.status, self.code, self.snapshot = status, code, snapshot


def authenticate(repo, owner, data):
    device_id, secret = text(data, 'deviceId'), text(data, 'deviceKey')
    device = repo.get(DEVICES, key(owner, device_id))
    if not device or len(secret) < 32 or not hmac.compare_digest(
            device['keyHash'], hashlib.sha256(secret.encode()).hexdigest()):
        raise FocusSessionError('本机尚未登记或设备凭据无效，请刷新连接设备', 403, 'DEVICE_CREDENTIALS')
    return device


def paired(repo, owner, first, second):
    if first == second:
        return True
    return any(link['state'] == 'connected' and set(link['members']) == {first, second}
               for link in repo.query(LINKS, {'userId': owner}))


def authorized(repo, owner, session, device_id):
    return paired(repo, owner, session['initiatingDeviceId'], device_id)


def elapsed(session, now):
    milliseconds = session['accumulatedMs']
    if session['state'] == 'running':
        milliseconds += max(0, now - session['runningSince'])
    limit = session['task']['plannedMinutes'] * 60000 if session['task']['timerType'] == 'countdown' else 86400000
    return int(min(limit, max(0, milliseconds)))


def snapshot(repo, owner, device_id, session, now):
    view = deepcopy(session) if session else None
    if view:
        value = elapsed(session, now)
        view['elapsedMs'] = value
        view['remainingMs'] = max(0, session['task']['plannedMinutes'] * 60000 - value)
        devices = {d['deviceId']: d for d in repo.query(DEVICES, {'userId': owner})}
        for participant in view['participants']:
            device = devices.get(participant['deviceId'])
            participant['online'] = online(device, now / 1000)
            participant['background'] = background(device, now / 1000)
            participant['lastSeen'] = int(device['lastSeen'] * 1000) if device else participant['lastSeen']
        for internal in ('accumulatedMs', 'runningSince', 'initiatingDeviceId', 'effectiveAt'):
            view.pop(internal, None)
    return dict(userId=owner, deviceId=device_id, serverTime=now, session=view)


def read(repo, owner, data, now=None):
    now = int(time.time() * 1000) if now is None else int(now)
    device = authenticate(repo, owner, data)
    session = repo.get(STATES, owner)
    if session and not authorized(repo, owner, session, device['deviceId']):
        session = None
    return snapshot(repo, owner, device['deviceId'], session, now)


def receipt_deletes(repo, owner, now):
    commands = sorted(repo.query(COMMANDS, {'userId': owner}), key=lambda c: c['at'], reverse=True)
    return [(COMMANDS, key(owner, c['clientId'])) for index, c in enumerate(commands)
            if index >= 255 or now - c['at'] >= 86400000]


def execute(repo, owner, data, now=None):
    # Completion, plan progress, canonical history and the action receipt publish
    # together, including on the JSON backend which has no database rollback.
    from app.repositories.staged_repository import StagedRepository
    staged = StagedRepository(repo)
    result = _execute(staged, owner, data, now)
    if staged._saves or staged._deletes:
        staged.commit()
    return result


def _execute(repo, owner, data, now=None):
    now = int(time.time() * 1000) if now is None else int(now)
    if not isinstance(data, dict):
        raise FocusSessionError('专注请求格式不正确')
    action = text(data, 'action', 32)
    if action not in {'start', 'join', 'handoff', 'pause', 'resume', 'complete', 'abandon', 'heartbeat', 'leave'}:
        raise FocusSessionError('不支持的专注操作')
    device = authenticate(repo, owner, data)
    device_id = device['deviceId']
    client_id = text(data, 'clientId')
    fingerprint = hashlib.sha256(json.dumps({k: v for k, v in data.items() if k != 'deviceKey'},
                                            sort_keys=True, ensure_ascii=False).encode()).hexdigest()
    command_key = key(owner, client_id)
    session = repo.get(STATES, owner)
    if (session and not authorized(repo, owner, session, device_id)
            and not (action == 'start' and session['state'] not in ACTIVE)):
        raise FocusSessionError('请先与正在专注的设备完成配对', 403, 'PAIRING_REQUIRED')
    previous = repo.get(COMMANDS, command_key)
    if previous:
        if previous['fingerprint'] != fingerprint:
            raise FocusSessionError('操作编号已被使用，请刷新后重试', 409, 'CLIENT_ID_CONFLICT')
        return deepcopy(previous['response'])
    if action == 'heartbeat':
        return snapshot(repo, owner, device_id, session, now)
    expected = data.get('expectedRevision')
    if type(expected) is not int or expected < 0:
        raise FocusSessionError('请携带当前专注版本')
    if action == 'start':
        if session and session['state'] in ACTIVE:
            raise FocusSessionError('已有进行中的专注，请在这台设备继续', 409, 'ACTIVE_SESSION',
                                    snapshot(repo, owner, device_id, session, now))
        task = task_value(data.get('task'))
        session = dict(userId=owner, sessionId='fs-' + uuid.uuid4().hex, revision=0, state='running',
                       task=task, leaderDeviceId=device_id, leaderLabel=device['deviceLabel'],
                       initiatingDeviceId=device_id, startedAt=now, updatedAt=now,
                       runningSince=now, accumulatedMs=0, pauseCount=0, interruptionCount=0,
                       participants=[], record=None)
    else:
        if not session or data.get('sessionId') != session['sessionId']:
            raise FocusSessionError('专注会话已更新，请刷新后重试', 409, 'REVISION_CONFLICT',
                                    snapshot(repo, owner, device_id, session, now))
        # Concurrent copies of an already-applied pause/resume/finish are harmless.
        desired = {'pause': 'paused', 'resume': 'running', 'complete': 'completed', 'abandon': 'abandoned'}.get(action)
        if desired == session['state'] and action in ('pause', 'resume', 'complete', 'abandon'):
            response = snapshot(repo, owner, device_id, session, now)
            repo.apply_batch(receipt_deletes(repo, owner, now), [(COMMANDS, command_key,
                dict(userId=owner, clientId=client_id, fingerprint=fingerprint, response=response, at=now))])
            return response
        if expected != session['revision']:
            raise FocusSessionError('另一台设备已更新专注，已获取最新状态', 409, 'REVISION_CONFLICT',
                                    snapshot(repo, owner, device_id, session, now))
        if session['state'] not in ACTIVE:
            raise FocusSessionError('这次专注已结束，请刷新后开始新专注', 409, 'SESSION_ENDED',
                                    snapshot(repo, owner, device_id, session, now))
        if action not in ('join', 'handoff') and not any(p['deviceId'] == device_id for p in session['participants']):
            raise FocusSessionError('请先在这台设备继续专注', 403, 'JOIN_REQUIRED')
    before = deepcopy(session)
    event_at = data.get('occurredAt', now)
    if type(event_at) not in (int, float) or not math.isfinite(event_at):
        raise FocusSessionError('专注操作时间不正确')
    event_at = int(max(session.get('effectiveAt', session['startedAt']), now - 86400000, min(now, event_at)))
    if action in ('start', 'join', 'handoff'):
        target = data.get('targetDeviceId', device_id) if action == 'handoff' else device_id
        target_device = repo.get(DEVICES, key(owner, target)) if isinstance(target, str) else None
        if not target_device or not paired(repo, owner, session['initiatingDeviceId'], target):
            raise FocusSessionError('请先与目标设备完成配对', 403, 'PAIRING_REQUIRED')
        if target != device_id and not online(target_device, now / 1000):
            raise FocusSessionError('目标设备不在线，请打开对方应用', 409, 'DEVICE_OFFLINE')
        if not any(p['deviceId'] == target for p in session['participants']):
            session['participants'].append(dict(deviceId=target, deviceLabel=target_device['deviceLabel'],
                                                 role='follower', lastSeen=now))
        if action in ('start', 'handoff'):
            session.update(leaderDeviceId=target, leaderLabel=target_device['deviceLabel'])
        for participant in session['participants']:
            participant['role'] = 'leader' if participant['deviceId'] == session['leaderDeviceId'] else 'follower'
    elif action == 'pause':
        session.update(accumulatedMs=elapsed(session, event_at), runningSince=0, state='paused')
        session['pauseCount'] += 1
    elif action == 'resume':
        session.update(runningSince=event_at, state='running')
    elif action in ('complete', 'abandon'):
        session.update(accumulatedMs=elapsed(session, event_at), runningSince=0,
                       state='completed' if action == 'complete' else 'abandoned')
        assessment = data.get('selfAssessment', 'completed' if action == 'complete' else 'not_completed')
        if assessment not in ('completed', 'partial', 'not_completed'):
            raise FocusSessionError('完成情况不正确')
        task = session['task']
        value = session['accumulatedMs']
        record = dict(taskId=session['sessionId'], course=task['course'], task=task['task'],
                      plannedMinutes=task['plannedMinutes'], actualMinutes=round(value / 60000, 6),
                      pauseCount=session['pauseCount'], interruptionCount=session['interruptionCount'],
                      completionRate=round(min(100, value / (task['plannedMinutes'] * 600) if task['plannedMinutes'] else 100), 4),
                      selfAssessment=assessment, timerType=task['timerType'],
                      status='interrupted' if action == 'abandon' else 'completed' if assessment == 'completed' else 'not_completed',
                      endedAt=datetime.fromtimestamp(event_at / 1000, timezone.utc).isoformat())
        if task.get('planTaskId'):
            record['planTaskId'] = task['planTaskId']
        from app.api.focus import persist_focus_session
        try:
            session['record'] = persist_focus_session(repo, owner, record)['session']
        except ValueError as error:
            raise FocusSessionError(str(error), 409, 'HISTORY_CONFLICT',
                                    snapshot(repo, owner, device_id, before, now)) from error
    elif action == 'leave':
        if device_id == session['leaderDeviceId']:
            raise FocusSessionError('请先交给另一台设备，或结束本次专注', 409, 'LEADER_REQUIRED')
        session['participants'] = [p for p in session['participants'] if p['deviceId'] != device_id]
    changed = session != before or action == 'start'
    if changed:
        session['revision'] += 1
        session['updatedAt'] = now
        session['effectiveAt'] = event_at
        session['lastEvent'] = dict(action=action, by=device_id, deviceLabel=device['deviceLabel'], at=event_at, clientId=client_id)
    response = snapshot(repo, owner, device_id, session, now)
    saves = [(COMMANDS, command_key, dict(userId=owner, clientId=client_id, fingerprint=fingerprint, response=response, at=now))]
    if changed:
        saves.append((STATES, owner, session))
    # Bounded receipt retention; focus history is permanent and independent.
    repo.apply_batch(receipt_deletes(repo, owner, now), saves)
    return response
