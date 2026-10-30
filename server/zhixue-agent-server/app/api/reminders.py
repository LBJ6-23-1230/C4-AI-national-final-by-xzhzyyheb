from flask import Blueprint, current_app, jsonify, request
from app.api.identity import resolve_user_id
from app.services import reminders as service

reminders_api = Blueprint('reminders', __name__)


def repo():
    return current_app.extensions['repository']


@reminders_api.errorhandler(ValueError)
def bad_request(error):
    return jsonify(errorCode='BAD_REQUEST', message=str(error)), 400


@reminders_api.errorhandler(RuntimeError)
def conflict(error):
    return jsonify(errorCode='CONFLICT', message=str(error)), 409


@reminders_api.errorhandler(LookupError)
def missing(error):
    return jsonify(errorCode='NOT_FOUND', message=str(error)), 404


def body():
    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        raise ValueError('请求必须是对象')
    return data


@reminders_api.get('/api/v1/today')
def today():
    return jsonify(service.reconcile(repo(), resolve_user_id(None)))


@reminders_api.get('/api/v1/reminders')
def listing():
    owner = resolve_user_id(None)
    service.reconcile(repo(), owner)
    cursor = request.args.get('after', '')
    rows = sorted((r for r in repo().list('reminder_events') if r.get('userId') == owner), key=lambda r: r['eventId'])
    page = [r for r in rows if r['eventId'] > cursor][:30]
    return jsonify(events=[service.public(e) for e in page], cursor=page[-1]['eventId'] if page else cursor,
                   hasMore=any(r['eventId'] > page[-1]['eventId'] for r in rows) if page else False)


@reminders_api.post('/api/v1/reminders/<event_id>/actions')
def action(event_id):
    return jsonify(service.action(repo(), resolve_user_id(None), event_id, body()))


@reminders_api.route('/api/v1/reminder-preferences', methods=['GET', 'PUT'])
def preferences():
    owner = resolve_user_id(None)
    prefs = service.save_preferences(repo(), owner, body()) if request.method == 'PUT' else service.preferences(repo(), owner)
    from app.services.push_provider import configured
    return jsonify(preferences=prefs, pushConfigured=configured())


@reminders_api.route('/api/v1/reminder-devices', methods=['GET', 'POST', 'DELETE'])
def devices():
    owner = resolve_user_id(None)
    if request.method == 'POST':
        return jsonify(service.bind(repo(), owner, body()))
    if request.method == 'DELETE':
        device_id = body().get('deviceId')
        if not isinstance(device_id, str) or not device_id:
            raise ValueError('缺少设备标识')
        service.unbind(repo(), owner, device_id)
        return jsonify(status='unbound')
    return jsonify(devices=[{k: v for k, v in d.items() if k != 'pushToken'} for d in repo().list('reminder_devices') if d.get('userId') == owner])
