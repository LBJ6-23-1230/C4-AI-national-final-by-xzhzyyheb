"""Authenticated cross-device learning facts and evidence summaries."""
from flask import Blueprint, current_app, jsonify, request
from app.api.identity import current_user_id
from app.services import learning_data as service

learning_data_api = Blueprint('learning_data', __name__)


@learning_data_api.route('/api/v1/learning-data', methods=['GET', 'POST'])
def learning_data():
    owner = current_user_id()
    if not owner:
        return jsonify(errorCode='UNAUTHORIZED', message='请先登录'), 401
    repo = current_app.extensions['repository']
    try:
        with repo.transaction():
            result = service.snapshot(repo, owner) if request.method == 'GET' else service.apply(repo, owner, request.get_json(silent=True))
        return jsonify(result)
    except service.SyncConflict:
        return jsonify(errorCode='CONFLICT', message='其他设备有更新，请确认后同步'), 409
    except (ValueError, TypeError):
        return jsonify(errorCode='BAD_REQUEST', message='学习资料格式不正确'), 400


@learning_data_api.get('/api/v1/learning-effect')
def learning_effect():
    owner = current_user_id()
    if not owner:
        return jsonify(errorCode='UNAUTHORIZED', message='请先登录'), 401
    from app.services.learning_effect import summary
    days = request.args.get('days', '1')
    if days not in ('1', '7'):
        return jsonify(errorCode='BAD_REQUEST', message='请选择今天或近7天'), 400
    with current_app.extensions['repository'].transaction():
        return jsonify(summary(current_app.extensions['repository'], owner, int(days)))
