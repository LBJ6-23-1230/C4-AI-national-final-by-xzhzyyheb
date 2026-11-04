from flask import Blueprint, current_app, jsonify, request
from app.api.identity import current_user_id
from app.services.device_collaboration import CollaborationError, execute

device_collaboration_api = Blueprint('device_collaboration', __name__)


@device_collaboration_api.post('/api/v1/device-collaboration')
def collaboration():
    owner = current_user_id()
    if not owner:
        return jsonify(errorCode='UNAUTHORIZED', message='请先登录后连接设备'), 401
    if request.content_length and request.content_length > 8192:
        return jsonify(errorCode='BAD_REQUEST', message='设备请求过大'), 413
    repo = current_app.extensions['repository']
    try:
        with repo.transaction():
            result = execute(repo, owner, request.get_json(silent=True))
        return jsonify(result)
    except CollaborationError as error:
        return jsonify(errorCode='DEVICE_COLLABORATION', message=str(error)), error.status
