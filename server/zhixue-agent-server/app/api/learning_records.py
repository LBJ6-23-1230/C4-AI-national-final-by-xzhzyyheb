"""Account scoped confirmed learning goals, with stable keyset pagination."""
import base64
import json
from flask import Blueprint, abort, current_app, jsonify, request
from app.api.identity import current_user_id
from app.services.learning_context import snapshot

learning_records_api = Blueprint('learning_records', __name__)


@learning_records_api.get('/api/v1/learning-records')
def learning_records():
    owner = current_user_id()
    if not owner:
        abort(401)
    status = request.args.get('status', '')
    if status not in ('', 'in_progress', 'completed', 'ended', 'waiting'):
        abort(400)
    try:
        limit = int(request.args.get('limit', '20'))
        if not 1 <= limit <= 100:
            abort(400)
        cursor = request.args.get('cursor', '')
        after = json.loads(base64.urlsafe_b64decode(cursor.encode()).decode()) if cursor else None
        if after is not None and (not isinstance(after, list) or len(after) != 2 or not all(isinstance(s, str) for s in after)):
            abort(400)
    except (ValueError, TypeError, UnicodeError):
        abort(400)
    repo = current_app.extensions['repository']
    rows = []
    for w in repo.query('workflows', {'userId': owner}):
        chat = w.get('state', {}).get('coordination', {}).get('chatSessionId', '')
        if not chat:
            continue
        if request.args.get('chatSessionId') and chat != request.args['chatSessionId']:
            continue
        context = snapshot(repo, w)
        if not context or context.get('needsConfirmation') or not context.get('knowledgePointId'):
            continue
        state = 'completed' if context['status'] == 'completed' else 'ended' if context['status'] == 'ended' else 'waiting' if context['status'].startswith('waiting') or context['status'] == 'tool_failed' else 'in_progress'
        if status and state != status:
            continue
        point = next((p for p in (repo.get('profiles', owner) or {}).get('mastery', []) if p.get('knowledgePointId') == context['knowledgePointId']), {})
        updated = w.get('updatedAt') or w.get('createdAt', '')
        record = dict(context, recordId=context['goalId'], chatSessionId=chat,
            courseName=point.get('sourceCourse', ''), status=state, createdAt=w.get('createdAt', ''),
            updatedAt=updated, completedAt=w.get('completedAt'), learningContext=context)
        if after is None or (updated, context['goalId']) < tuple(after):
            rows.append(record)
    rows.sort(key=lambda r: (r['updatedAt'], r['goalId']), reverse=True)
    page = rows[:limit]
    cursor = base64.urlsafe_b64encode(json.dumps([page[-1]['updatedAt'], page[-1]['goalId']]).encode()).decode() if len(rows) > limit else None
    return jsonify(records=page, nextCursor=cursor)
