"""Declare durable pairing and the shared focus clock, then update the app mirror."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
target = ROOT / 'contracts/openapi.json'
doc = json.loads(target.read_text(encoding='utf-8'))
schemas = doc['components']['schemas']


def ref(name, nullable=False):
    value = {'$ref': '#/components/schemas/' + name}
    return {'allOf': [value], 'nullable': True} if nullable else value


def obj(properties, required=None):
    return {'type': 'object', 'properties': properties,
            'required': list(properties) if required is None else required}


string = {'type': 'string'}
integer = {'type': 'integer', 'minimum': 0}
boolean = {'type': 'boolean'}
device_task = schemas['DeviceFocusTask']['properties']
device_task['planTaskId'] = {'type': 'string', 'maxLength': 128}
schemas['CollaborationDevice']['properties']['background'] = boolean
schemas['CollaborationMessage']['properties']['consumedAt'] = {'type': 'number', 'minimum': 0}
schemas['CollaborationLink']['properties'].update(peerOnline=boolean, peerBackground=boolean)
actions = schemas['CollaborationRequest']['properties']['action']['enum']
for action in ['background', 'consume']:
    if action not in actions:
        actions.append(action)
relay = doc['paths']['/api/v1/device-collaboration']['post']
relay['summary'] = '同账号设备配对、状态与任务接收确认'
relay['description'] = ('仅发现当前认证账号的设备。首次邀请须对端确认；显式disconnect才解除配对。'
    'background与offline标记暂时离线，保留配对和未消费任务，重新联网自动恢复。'
    '前台90秒内为在线，后台5分钟内为后台状态；邀请60秒过期，任务保留24小时。'
    'ack仅表示送达，consume表示已采用，均须invitationId与messageId。'
    '此接口兼容旧任务广播；共享计时使用focus-session接口。')

schemas['SharedFocusParticipant'] = obj(dict(deviceId=string, deviceLabel=string,
    role={'type': 'string', 'enum': ['leader', 'follower']}, lastSeen=integer,
    online=boolean, background=boolean))
schemas['SharedFocusEvent'] = obj(dict(action=string, by=string, deviceLabel=string,
    at=integer, clientId=string))
schemas['SharedFocusSession'] = obj(dict(sessionId=string, revision=integer,
    state={'type': 'string', 'enum': ['running', 'paused', 'completed', 'abandoned']},
    task=ref('DeviceFocusTask'), leaderDeviceId=string, leaderLabel=string,
    elapsedMs=integer, remainingMs=integer, startedAt=integer, updatedAt=integer,
    participants={'type': 'array', 'items': ref('SharedFocusParticipant')}, lastEvent=ref('SharedFocusEvent'),
    pauseCount=integer, interruptionCount=integer, record=ref('FocusSession', True)),
    ['sessionId', 'revision', 'state', 'task', 'leaderDeviceId', 'leaderLabel', 'elapsedMs',
     'remainingMs', 'startedAt', 'updatedAt', 'participants', 'lastEvent'])
schemas['SharedFocusResponse'] = obj(dict(userId=string, deviceId=string, serverTime=integer,
    session=ref('SharedFocusSession', True)))
schemas['SharedFocusRequest'] = obj(dict(
    action={'type': 'string', 'enum': ['start', 'join', 'handoff', 'pause', 'resume', 'complete',
                                     'abandon', 'heartbeat', 'leave']},
    deviceId={'type': 'string', 'minLength': 1, 'maxLength': 128},
    deviceKey={'type': 'string', 'minLength': 32, 'maxLength': 128, 'writeOnly': True},
    clientId={'type': 'string', 'minLength': 1, 'maxLength': 128}, expectedRevision=integer,
    sessionId=string, targetDeviceId=string, task=ref('DeviceFocusTask'),
    selfAssessment={'type': 'string', 'enum': ['completed', 'partial', 'not_completed']},
    occurredAt=integer), ['action', 'deviceId', 'deviceKey', 'clientId', 'expectedRevision'])
schemas['SharedFocusConflict'] = obj(dict(errorCode=string, message=string,
    snapshot=ref('SharedFocusResponse')), ['errorCode', 'message'])


def response(name, description):
    return {'description': description, 'content': {'application/json': {'schema': ref(name)}}}


responses = {'200': response('SharedFocusResponse', '当前账号本机可见会话，所有时间均为Unix毫秒'),
    '400': response('ErrorResponse', '无效参数'), '401': response('ErrorResponse', '需要登录'),
    '403': response('ErrorResponse', '设备凭据不符或尚未配对'),
    '404': response('ErrorResponse', '设备未登记或会话不可用'),
    '413': response('ErrorResponse', '请求超过16KiB'),
    '409': response('SharedFocusConflict', '版本冲突或已有进行中的专注；采纳snapshot后重新操作')}
doc['paths']['/api/v1/focus-session'] = {'get': {
    'summary': '读取同账号的共享专注时钟', 'operationId': 'getSharedFocusSession',
    'security': [{'BearerAuth': []}], 'parameters': [
        {'name': name, 'in': 'header', 'required': True, 'schema': {'type': 'string'}}
        for name in ['X-Device-Id', 'X-Device-Key']], 'responses': responses}}
doc['paths']['/api/v1/focus-session/actions'] = {'post': {
    'summary': '共享专注开始、接管、暂停、继续与结算', 'operationId': 'sharedFocusAction',
    'security': [{'BearerAuth': []}],
    'description': ('同一账号只有一份进行中的专注。计时以服务端时钟为准，接管不重置计时。'
        'clientId使重试幂等；expectedRevision防止过期操作覆盖另一端状态。'
        'complete/abandon以sessionId为记录键，仅生成一条专注记录并回写关联计划。'),
    'requestBody': {'required': True, 'content': {'application/json': {'schema': ref('SharedFocusRequest')}}},
    'responses': responses}}
content = json.dumps(doc, ensure_ascii=False, indent=2) + '\n'
for path in [target, ROOT / 'app/contracts/openapi.json']:
    path.write_text(content, encoding='utf-8', newline='\n')

if __name__ == '__main__':
    print('Shared focus API contract and app mirror updated.')
