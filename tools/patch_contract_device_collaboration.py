"""Declare the additive account-scoped device relay and sync the app mirror."""
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
target = root / 'contracts/openapi.json'
doc = json.loads(target.read_text(encoding='utf-8'))
schemas = doc['components']['schemas']


def ref(name, nullable=False):
    return dict(allOf=[{'$ref': '#/components/schemas/' + name}], nullable=True) if nullable else {'$ref': '#/components/schemas/' + name}


def obj(properties, required=None):
    return dict(type='object', properties=properties, required=list(properties) if required is None else required)


string = {'type': 'string'}
number = {'type': 'number'}
boolean = {'type': 'boolean'}
schemas['DeviceFocusTask'] = obj(dict(
    course=dict(type='string', minLength=1, maxLength=100), task=dict(type='string', minLength=1, maxLength=500),
    plannedMinutes=dict(type='integer', minimum=0, maximum=180),
    mode=dict(type='string', enum=['normal', 'strict']), timerType=dict(type='string', enum=['countdown', 'stopwatch']),
    source=string, allowBackgroundTiming=boolean), ['course', 'task', 'plannedMinutes', 'mode'])
schemas['CollaborationDevice'] = obj(dict(deviceId=string, deviceLabel=string, online=boolean,
    lastSeen=dict(type='integer', description='上次前台心跳的Unix毫秒时间')))
schemas['CollaborationMessage'] = obj(dict(messageId=string, task=ref('DeviceFocusTask', True),
    sentAt=dict(type='number', description='服务端发送时间，Unix秒'),
    ackedAt=dict(type='number', description='接收端确认时间，Unix秒；0为未确认')))
schemas['CollaborationLink'] = obj(dict(invitationId=string, peerDeviceId=string, peerDeviceLabel=string,
    state=dict(type='string', enum=['pending', 'connected', 'expired', 'rejected', 'disconnected']),
    incoming=boolean, expiresAt=dict(type='integer', description='请求到期时间，Unix毫秒'),
    received=ref('CollaborationMessage', True), sentMessageId=string,
    acknowledgedAt=dict(type='integer', description='对方确认本机最新消息的Unix毫秒时间；0为未确认')))
schemas['CollaborationRequest'] = obj(dict(
    action=dict(type='string', enum=['register', 'heartbeat', 'invite', 'accept', 'reject', 'disconnect', 'publish', 'clear', 'ack', 'offline']),
    deviceId=dict(type='string', minLength=1, maxLength=128),
    deviceKey=dict(type='string', minLength=32, maxLength=128, writeOnly=True,
        description='本机生成并保存在应用沙箱的随机凭据。服务端仅保存哈希；响应和设备列表不返回。'),
    deviceLabel=dict(type='string', minLength=1, maxLength=80), targetDeviceId=string,
    invitationId=string, messageId=string, task=ref('DeviceFocusTask')), ['action', 'deviceId', 'deviceKey'])
schemas['CollaborationResponse'] = obj(dict(userId=string, deviceId=string, serverTime=dict(type='integer'),
    devices=dict(type='array', items=ref('CollaborationDevice')), links=dict(type='array', items=ref('CollaborationLink'))))
responses = {str(status): dict(description=description, content={'application/json': {'schema': ref(schema)}})
    for status, description, schema in [(200, '当前账号本机可见快照', 'CollaborationResponse'),
        (400, '无效设备请求或任务', 'ErrorResponse'), (401, '未登录或会话失效', 'ErrorResponse'),
        (403, '设备凭据不符或试图自确认', 'ErrorResponse'), (404, '本机未登记或邀请不存在', 'ErrorResponse'),
        (409, '对端离线、请求过期或任务已更新', 'ErrorResponse'), (413, '请求超过8KiB', 'ErrorResponse'),
        (405, '只支持POST', 'ErrorResponse')]}
doc['paths']['/api/v1/device-collaboration'] = {'post': dict(summary='同账号设备连接、前台在线状态与专注任务接收确认',
    operationId='deviceCollaboration', security=[{'BearerAuth': []}],
    description='仅在服务端已认证的账号内发现设备。register需deviceLabel；invite需targetDeviceId；'
        'accept/reject/disconnect需invitationId；publish需messageId和task；clear需messageId；'
        'ack需invitationId和messageId，且只能确认对端消息。25秒无心跳失效，邀请60秒过期。'
        'offline主动断开；重返前台不会恢复旧连接。仅同步任务设置，不迁移计时进度。',
    requestBody=dict(required=True, content={'application/json': {'schema': ref('CollaborationRequest')}}), responses=responses)}
content = json.dumps(doc, ensure_ascii=False, indent=2) + '\n'
target.write_text(content, encoding='utf-8', newline='\n')
(root / 'app/contracts/openapi.json').write_text(content, encoding='utf-8', newline='\n')
