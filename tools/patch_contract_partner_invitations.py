"""Declare the implemented invitation/contact routes in both contract copies."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def sync():
    source = ROOT / 'contracts/openapi.json'
    contract = json.loads(source.read_bytes())
    schemas = contract['components']['schemas']
    def ref(name):
        return {'$ref': '#/components/schemas/' + name}
    def obj(properties, required=None):
        return {'type': 'object', 'required': list(properties) if required is None else required,
                'properties': properties}
    def array(item):
        return {'type': 'array', 'items': item}
    def text():
        return {'type': 'string'}
    schemas['PartnerInvitation'] = obj({key: text() for key in (
        'invitationId', 'fromUserId', 'fromName', 'toUserId', 'toName', 'message',
        'status', 'targetKind', 'createdAt', 'respondedAt')})
    schemas['PartnerInvitation']['properties']['status']['enum'] = ['pending', 'accepted', 'declined', 'dismissed']
    schemas['PartnerInvitationCreateRequest'] = obj({
        'toUserId': {'type': 'string', 'minLength': 1, 'maxLength': 128},
        'message': {'type': 'string', 'maxLength': 200}}, ['toUserId'])
    schemas['PartnerInvitationResponse'] = obj({'invitation': ref('PartnerInvitation')})
    schemas['PartnerInvitationListResponse'] = obj({
        'box': text(), 'userId': text(), 'invitations': array(ref('PartnerInvitation')),
        'pendingCount': {'type': 'integer', 'minimum': 0}})
    schemas['PartnerContact'] = obj({key: text() for key in ('partnerUserId', 'partnerName', 'pairedAt')})
    schemas['PartnerContactListResponse'] = obj({'userId': text(), 'contacts': array(ref('PartnerContact'))})
    def response(description, schema):
        return {'description': description, 'content': {'application/json': {'schema': schema}}}
    def operation(operation_id, summary, schema, success='200', errors=()):
        return {'operationId': operation_id, 'summary': summary,
                'parameters': [{'$ref': '#/components/parameters/ContractVersionHeader'}],
                'responses': {success: response(summary, ref(schema)), **{
                    str(code): response(description, ref('ErrorResponse')) for code, description in errors}}}
    common_errors = [(400, '请求参数不合法'), (401, '凭据无效或过期'), (405, '不支持的方法')]
    base = '/api/v1/agent/partner-invitations'
    create = operation('createPartnerInvitation', '真实账号发起学习邀请', 'PartnerInvitationResponse', '201',
                       common_errors + [(404, '目标真实账号不存在')])
    create['security'] = [{'BearerAuth': []}]
    create['requestBody'] = {'required': True, 'content': {'application/json': {
        'schema': ref('PartnerInvitationCreateRequest')}}}
    listing = operation('listPartnerInvitations', '读取当前身份的邀请', 'PartnerInvitationListResponse',
                        errors=common_errors)
    listing['parameters'].append({'name': 'box', 'in': 'query', 'required': False,
        'schema': {'type': 'string', 'enum': ['inbox', 'outbox'], 'default': 'inbox'}})
    contract['paths'][base] = {'post': create, 'get': listing}
    for action, label in [('accept', '接受'), ('decline', '拒绝'), ('dismiss', '无视')]:
        op = operation(action + 'PartnerInvitation', label + '邀请；相同动作可幂等重试',
            'PartnerInvitationResponse', errors=common_errors + [
                (403, '只有被邀请人可以处理'), (404, '邀请不存在'), (409, '已被处理为不同状态')])
        op['parameters'].append({'name': 'invitationId', 'in': 'path', 'required': True,
                                 'schema': {'type': 'string'}})
        contract['paths'][base + '/{invitationId}/' + action] = {'post': op}
    contract['paths']['/api/v1/agent/partner-contacts'] = {'get': operation(
        'listPartnerContacts', '读取当前身份已建立联系的搭子', 'PartnerContactListResponse', errors=common_errors)}
    raw = (json.dumps(contract, ensure_ascii=False, indent=2) + '\n').replace('\n', '\r\n').encode('utf-8')
    source.write_bytes(raw)
    (ROOT / 'app/contracts/openapi.json').write_bytes(raw)
    print('Partner invitation/contact declarations synchronized.')


if __name__ == '__main__':
    sync()
