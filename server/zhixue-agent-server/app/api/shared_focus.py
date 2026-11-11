"""Authenticated shared focus-session API; device pairing is separately authorized."""
from flask import Blueprint, current_app, jsonify, request
from app.api.identity import current_user_id
from app.services.device_collaboration import CollaborationError
from app.services.shared_focus import FocusSessionError, read, execute

shared_focus_api = Blueprint('shared_focus', __name__)


@shared_focus_api.get('/api/v1/focus-session')
@shared_focus_api.post('/api/v1/focus-session/actions')
def shared_focus():
    owner = current_user_id()
    if not owner:
        return jsonify(errorCode='UNAUTHORIZED', message='请先登录后同步专注'), 401
    if request.content_length and request.content_length > 16384:
        return jsonify(errorCode='BAD_REQUEST', message='专注请求过大'), 413
    data = request.args.to_dict() if request.method == 'GET' else request.get_json(silent=True)
    if not isinstance(data, dict):
        return jsonify(errorCode='BAD_REQUEST', message='专注请求格式不正确'), 400
    if request.method == 'GET':
        for name, header in (('deviceId', 'X-Device-Id'), ('deviceKey', 'X-Device-Key')):
            if request.headers.get(header):
                data[name] = request.headers[header]
    repo = current_app.extensions['repository']
    try:
        with repo.transaction(user_id=owner):
            result = read(repo, owner, data) if request.method == 'GET' else execute(repo, owner, data)
        return jsonify(result)
    except FocusSessionError as error:
        payload = dict(errorCode=error.code, message=str(error))
        if error.snapshot is not None:
            payload['snapshot'] = error.snapshot
        return jsonify(payload), error.status
    except CollaborationError as error:
        return jsonify(errorCode='BAD_REQUEST', message=str(error)), error.status
