"""Course-scoped reviews, opt-in scanned questions and private partner messages.

New records use the repository compatibility collections: no startup DDL.
"""
import base64
import hashlib
import json
from datetime import datetime, timezone
from zoneinfo import ZoneInfo
from uuid import uuid4

from flask import Blueprint, abort, current_app, jsonify, request

from app.api.identity import current_user_id, resolve_user_id
from app.api.wrong_book import add_item
from app.services.llm_runtime import bounded, client, configuration
from app.services.partner_messages import message_order, public_message, save_message

learning_upgrade_api = Blueprint('learning_upgrade', __name__)


def repo():
    return current_app.extensions['repository']


def now():
    return datetime.now(timezone.utc).isoformat()


def body():
    value = request.get_json(silent=True)
    if not isinstance(value, dict):
        abort(400)
    return value


def string(data, key, limit, required=False):
    value = data.get(key, '')
    if not isinstance(value, str) or len(value) > limit or (required and not value.strip()):
        abort(400)
    return value.strip()


def authenticated():
    owner = current_user_id()
    if not owner:
        abort(401)
    return owner


def room_id(owner, partner):
    return hashlib.sha256('\0'.join(sorted([owner, partner])).encode()).hexdigest()


def relationship(owner, partner):
    if owner == partner:
        abort(400)
    contacts = [x for x in repo().list('contacts') if x.get('userId') == owner
                and x.get('partnerUserId') == partner and x.get('status') != 'ended']
    reverse = [x for x in repo().list('contacts') if x.get('userId') == partner
               and x.get('partnerUserId') == owner and x.get('status') != 'ended']
    account = repo().get('users', partner)
    if not contacts or not reverse or not account or account.get('status') == 'deactivated':
        abort(404)
    return contacts[0]


@learning_upgrade_api.route('/api/v1/partners/<partner>/messages', methods=['GET', 'POST'])
def messages(partner):
    owner = authenticated()
    room = room_id(owner, partner)
    if request.method == 'GET':
        relationship(owner, partner)
        cursor = request.args.get('after', '')
        records = sorted([x for x in repo().list('partner_messages') if x.get('roomId') == room],
                         key=message_order)
        boundary = next((message_order(x) for x in records if x['messageId'] == cursor), (0, cursor))
        unread = [x for x in records if message_order(x) > boundary]
        page = unread[:10]
        return jsonify(messages=[public_message(x) for x in page], cursor=page[-1]['messageId'] if page else cursor,
                       recalledMessageIds=[x['messageId'] for x in records if x.get('recalled') and message_order(x) <= boundary],
                       hasMore=len(unread) > 10)
    data = body()
    key = string(data, 'clientId', 128, True)
    text = string(data, 'text', 3000)
    image = string(data, 'image', 3_000_000)
    reply_to = string(data, 'replyTo', 160)
    forwarded = data.get('forwarded', False)
    if type(forwarded) is not bool:
        abort(400)
    if not text and not image:
        abort(400)
    if image:
        import pymupdf
        try:
            raw = base64.b64decode(image, validate=True)
            if not raw.startswith((b'\x89PNG\r\n\x1a\n', b'\xff\xd8\xff', b'RIFF')):
                abort(400)
            with pymupdf.open(stream=raw) as picture:
                if picture.page_count != 1 or picture[0].rect.width * picture[0].rect.height > 20_000_000:
                    abort(400)
        except (ValueError, RuntimeError):
            abort(400)
    identity = hashlib.sha256((owner + ':' + key).encode()).hexdigest()
    with repo().transaction():
        relationship(owner, partner)
        previous = repo().get('partner_message_keys', identity)
        if previous:
            prior_content = previous.get('contentHash') or message_content_hash(previous['text'], previous['image'])
            if (previous['roomId'] != room or previous.get('replyTo', '') != reply_to or
                    previous.get('forwarded', False) != forwarded or
                    prior_content != message_content_hash(text, image)):
                abort(409)
            return jsonify(message=public_message(repo().get('partner_messages', previous['messageId']) or previous))
        if reply_to:
            quoted = repo().get('partner_messages', reply_to)
            if not quoted or quoted['roomId'] != room or quoted.get('recalled'):
                abort(409, '原消息已撤回或不可用')
        created_at = now()
        record = dict(messageId=created_at + '-' + uuid4().hex, roomId=room, senderId=owner,
                      text=text, image=image, createdAt=created_at, clientId=key, userId=owner)
        if reply_to:
            record['replyTo'] = reply_to
        if forwarded:
            record['forwarded'] = True
        save_message(repo(), record, retry_key=identity)
    return jsonify(message=public_message(record)), 201


def message_content_hash(text, image):
    return hashlib.sha256((text + '\0' + image).encode()).hexdigest()


@learning_upgrade_api.post('/api/v1/partners/<partner>/messages/<message_id>/recall')
def recall_message(partner, message_id):
    owner = authenticated()
    room = room_id(owner, partner)
    with repo().transaction():
        relationship(owner, partner)
        message = repo().get('partner_messages', message_id)
        if not message or message['roomId'] != room:
            abort(404)
        if message['senderId'] != owner or message['clientId'] == message_id:
            abort(403)
        if not message.get('recalled'):
            age = datetime.now(timezone.utc) - datetime.fromisoformat(message['createdAt'])
            if age.total_seconds() > 120:
                abort(409, '只能撤回两分钟内发送的消息')
            identity = hashlib.sha256((owner + ':' + message['clientId']).encode()).hexdigest()
            content_hash = message_content_hash(message['text'], message['image'])
            message.update(recalled=True, text='', image='')
            repo().apply_batch([], [('partner_messages', message_id, message),
                                    ('partner_message_keys', identity, dict(message, contentHash=content_hash))])
    return jsonify(message=public_message(message))


@learning_upgrade_api.post('/api/v1/wrong-book/scanned')
def save_scanned():
    owner = resolve_user_id()
    data = body()
    stem = string(data, 'stem', 12000, True)
    from app.services.subject_classification import subject
    course = subject(string(data, 'courseName', 120), data.get('knowledgePointName'), stem, repo().get('profiles', owner) or {})
    point = string(data, 'knowledgePointName', 200) or '待确认知识点'
    explanation = string(data, 'explanation', 20000)
    exercise_id = 'scan-' + hashlib.sha256((owner + '\0' + course + '\0' + stem).encode()).hexdigest()[:32]
    profile = repo().get('profiles', owner) or {}
    from app.services.subject_classification import normalized_mastery
    known = next((x for x in normalized_mastery(profile)
                  if x.get('knowledgePointName') == point and x.get('sourceCourse') == course), None)
    point_id = known['knowledgePointId'] if known else 'scan-point-' + hashlib.sha256(
        (course + '\0' + point).encode()).hexdigest()[:20]
    question = dict(exerciseId=exercise_id, userId=owner, stem=stem, courseName=course,
                    knowledgePointId=point_id, knowledgePointName=point, options=[],
                    answerKey='', explanation=explanation, source='scan', difficulty='unknown')
    with repo().transaction():
        existing = repo().get('wrong_book', f'{owner}:{exercise_id}')
        if existing:
            return jsonify(item={k: v for k, v in existing.items() if k != 'answerKey'})
        profile = repo().get('profiles', owner) or dict(userId=owner, mastery=[], evidence=[], history=[])
        if not any(x.get('knowledgePointId') == point_id for x in profile.get('mastery', [])):
            profile.setdefault('mastery', []).append(dict(knowledgePointId=point_id,
                knowledgePointName=point, sourceCourse=course, masteryScore=0,
                confidence=0, source='scan', lastUpdated=now()))
            profile['profileVersion'] = profile.get('profileVersion', 0) + 1
            repo().save('profiles', owner, profile)
            from app.services.reminders import reconcile
            reconcile(repo(), owner)
        repo().save('exercises', exercise_id, question)
        record = add_item(repo(), owner, question)
    return jsonify(item={k: v for k, v in record.items() if k != 'answerKey'}), 201


def review_snapshot(owner, course):
    profile = repo().get('profiles', owner) or {}
    from app.services.subject_classification import normalized_mastery
    from app.services.learning_effect import projected_mastery
    points = [x for x in projected_mastery(repo(), owner, normalized_mastery(profile)) if x.get('sourceCourse') == course]
    point_ids = {x.get('knowledgePointId') for x in points}
    evidence = [x for x in repo().list('evidences') if x.get('userId') == owner
                and x.get('knowledgePointId') in point_ids]
    evidence += [x for x in (profile.get('evidence') or []) if isinstance(x, dict) and x.get('knowledgePointId') in point_ids]
    evidence = list({str(x.get('id') or x.get('evidenceId') or json.dumps(x, sort_keys=True, default=str)): x for x in evidence}.values())
    assessed = {x.get('knowledgePointId') for x in evidence
                if x.get('sourceType') in ('exercise', 'assessment', 'exercise_submission', 'practice')}
    assessed.update(x.get('knowledgePointId') for x in (profile.get('history') or [])
                    if isinstance(x, dict) and x.get('source') == 'assessment' and x.get('questionCount', 0))
    measured = [x for x in points if x.get('knowledgePointId') in assessed or x.get('effectiveQuestionCount', 0)]
    measured.sort(key=lambda x: x.get('recentAccuracy') if x.get('recentAccuracy') is not None else x.get('masteryScore', 0))
    mistakes = [dict(knowledgePointId=q.get('knowledgePointId'), stem=str(q.get('stem', ''))[:500])
                for q in repo().list('wrong_book') if q.get('userId') == owner and q.get('knowledgePointId') in point_ids and q.get('wrongCount', 0) > 0][:6]
    exam_date = (profile.get('courseExams') or {}).get(course)
    days = (datetime.strptime(exam_date, '%Y-%m-%d').date() - datetime.now(ZoneInfo('Asia/Shanghai')).date()).days if exam_date else None
    snapshot = dict(courseName=course, profileVersion=profile.get('profileVersion', 0),
                    goal=(profile.get('courseGoals') or {}).get(course, profile.get('goal', '')), examDate=exam_date,
                    daysUntilExam=days, freeTimeSlots=profile.get('freeTimeSlots', []),
                    history=[x for x in (profile.get('history') or []) if isinstance(x, dict) and set(x.get('evidenceIds') or []) & {e.get('id') or e.get('evidenceId') for e in evidence}][-20:],
                    measuredPoints=measured, unassessedCount=len(points) - len(measured),
                    evidenceCount=len(evidence), evidence=evidence[-30:], wrongQuestions=mistakes)
    return snapshot


@learning_upgrade_api.post('/api/v1/learning-reviews')
def create_review():
    owner = resolve_user_id()
    data = body()
    course = string(data, 'courseName', 120, True)
    snapshot = review_snapshot(owner, course)
    from app.services.review_actions import REVIEW_VERSION
    from app.services.llm_runtime import fingerprint as model_fingerprint
    retry = data.get('retry', False)
    if type(retry) is not bool:
        abort(400)
    fingerprint = hashlib.sha256(json.dumps(snapshot, sort_keys=True, ensure_ascii=False, default=str).encode()).hexdigest()
    key = owner + ':' + course + ':' + datetime.now(ZoneInfo('Asia/Shanghai')).date().isoformat() + ':' + fingerprint + ':' + REVIEW_VERSION + ':' + model_fingerprint()
    old = repo().get('learning_reviews', key)
    if old and not retry and (old.get('source') == 'model' or old.get('failureCode') in ('insufficient_evidence', 'not_configured')) and old.get('actions') and isinstance(old['actions'][0], dict):
        return jsonify(old)
    if old:
        repo().save('learning_reviews', 'archive:' + old['reviewId'], old)
    from app.services.review_actions import generate
    result, source, fallback = generate(snapshot)
    record = dict(reviewId=hashlib.sha256((key + now()).encode()).hexdigest(), userId=owner,
                  courseName=course, summary=result['conclusion'], **result, source=source,
                  fallbackReason=fallback, createdAt=now(), snapshot=snapshot)
    repo().save('learning_reviews', key, record)
    return jsonify(record)


@learning_upgrade_api.post('/api/v1/learning-reviews/<review_id>/accept')
def accept_review(review_id):
    owner = resolve_user_id()
    review = next((x for x in repo().list('learning_reviews') if x.get('userId') == owner
                   and x.get('reviewId') == review_id), None)
    if not review:
        abort(404)
    with repo().transaction():
        for index, action in enumerate(review['actions']):
            key = f'{owner}:{review_id}:{index}'
            if not repo().get('review_tasks', key):
                points = review['snapshot']['measuredPoints']
                point = points[index] if index < len(points) else {}
                repo().save('review_tasks', key, dict(taskId=key, userId=owner, courseName=review['courseName'],
                    knowledgePointId=action.get('knowledgePointId', '') if isinstance(action, dict) else point.get('knowledgePointId', ''),
                    title=action['title'] if isinstance(action, dict) else action,
                    **({k: v for k, v in action.items() if k not in ('title', 'knowledgePointId')} if isinstance(action, dict) else {}),
                    actionType='settings' if isinstance(action, dict) and action.get('targetPage') == 'pages/LearningSetup' else 'practice',
                    status='pending', reviewId=review_id, createdAt=now()))
        from app.api.plans import plan_belongs_to
        plan = next((p for p in repo().list('plans') if plan_belongs_to(p, owner)), None)
        if not plan:
            plan = dict(planId='plan-review-' + owner, userId=owner, version=1, generatedFromProfileVersion=review['snapshot'].get('profileVersion', 1), tasks=[], unscheduledTasks=[])
        if plan:
            existing = {t['taskId'] for t in plan.get('tasks', []) + plan.get('unscheduledTasks', [])}
            added = []
            for index, action in enumerate(review['actions']):
                task_id = f'{owner}:{review_id}:{index}'
                if not isinstance(action, dict) or action.get('targetPage') != 'pages/ExercisePractice' or task_id in existing:
                    continue
                added.append(dict(taskId=task_id, knowledgePointId=action.get('knowledgePointId', ''),
                    knowledgePointName=action['title'], sourceCourse=review['courseName'], source='review',
                    durationMinutes=action['durationMinutes'], status='pending', priority=action['priority'],
                    steps=action['steps'], deferredReason='已采纳复盘行动，请在本周计划确认时间后排期'))
            if added:
                plan['unscheduledTasks'] = plan.get('unscheduledTasks', []) + added
                plan['version'] += 1
                repo().save('plans', plan['planId'], plan)
    return jsonify(tasks=review_task_progress(owner))


def review_task_progress(owner):
    """Practice progress is derived from an actual later submission, never a checkbox."""
    from app.services.learning_effect import timestamp
    from app.api.exercises import _EXERCISE_BANK
    bank = {q['exerciseId']: q.get('knowledgePointId') for q in _EXERCISE_BANK}
    bank.update({q['exerciseId']: q.get('knowledgePointId') for q in repo().query('exercises', {'userId': owner}) if q.get('exerciseId')})
    evidence = {}
    current = datetime.now(timezone.utc)
    for submission in repo().query('submissions', {'userId': owner}):
        stamp = timestamp(submission.get('createdAt'))
        if stamp is None or stamp > current:
            continue
        points = {fact.get('knowledgePointId') for fact in (submission.get('questionFacts') or []) if type(fact.get('correct')) is bool}
        if not points:
            points = {bank.get(row.get('exerciseId')) for row in submission.get('response', {}).get('review', []) if type(row.get('correct')) is bool}
        for point in points - {None, ''}:
            evidence.setdefault(point, []).append(stamp)
    result = []
    for task in repo().query('review_tasks', {'userId': owner}):
        item = dict(task)
        created = timestamp(item.get('createdAt'))
        later = [stamp for stamp in evidence.get(item.get('knowledgePointId'), []) if created and stamp >= created]
        item['practiceVerified'] = bool(later) and item.get('actionType') != 'settings'
        if item['practiceVerified']:
            item.update(status='practiced', completedAt=min(later).isoformat(), completionSource='exercise_submission')
        result.append(item)
    return result


@learning_upgrade_api.get('/api/v1/learning-review-tasks')
def review_tasks():
    owner = resolve_user_id()
    return jsonify(tasks=review_task_progress(owner))


@learning_upgrade_api.post('/api/v1/learning-review-tasks/complete')
def complete_review_task():
    owner = resolve_user_id()
    key = string(body(), 'taskId', 300, True)
    with repo().transaction():
        task = repo().get('review_tasks', key)
        if not task or task.get('userId') != owner:
            abort(404)
        task.update(status='completed', completedAt=now())
        repo().save('review_tasks', key, task)
    return jsonify(tasks=review_task_progress(owner))


@learning_upgrade_api.route('/api/v1/learning-course-settings', methods=['GET', 'POST'])
def course_settings():
    owner = resolve_user_id()
    profile = repo().get('profiles', owner) or {}
    if request.method == 'POST':
        data = body()
        from app.services.course_names import course_names
        entered_courses = course_names(string(data, 'courseName', 120, True))
        if len(entered_courses) != 1:
            abort(400)
        course = entered_courses[0]
        goal = string(data, 'goal', 200)
        exam = string(data, 'examDate', 10)
        if exam:
            try:
                if datetime.strptime(exam, '%Y-%m-%d').strftime('%Y-%m-%d') != exam:
                    abort(400)
            except ValueError:
                abort(400)
        with repo().transaction():
            profile = repo().get('profiles', owner) or dict(userId=owner, mastery=[], evidence=[], history=[])
            profile['courseGoals'] = profile.get('courseGoals') or {}
            profile['courseExams'] = profile.get('courseExams') or {}
            profile['courseGoals'][course] = goal
            profile.setdefault('courseExams', {})[course] = exam or None
            courses = profile.get('targetCourses', [])
            if course not in courses:
                courses.append(course)
            profile.update(targetCourses=courses, targetCourse=course,
                           profileVersion=profile.get('profileVersion', 0) + 1)
            repo().save('profiles', owner, profile)
            from app.services.reminders import reconcile
            reconcile(repo(), owner)
    courses = set(profile.get('targetCourses', []))
    from app.services.subject_classification import normalized_mastery, subject
    courses = {subject(c) for c in courses if isinstance(c, str) and c.strip()}
    courses.update(x['sourceCourse'] for x in normalized_mastery(profile))
    today = datetime.now(ZoneInfo('Asia/Shanghai')).date()
    settings = []
    for course in sorted(c for c in courses if c and c not in ('待确认科目', '待分类', '其他')):
        exam = (profile.get('courseExams') or {}).get(course)
        days = (datetime.strptime(exam, '%Y-%m-%d').date() - today).days if exam else None
        settings.append(dict(courseName=course, goal=(profile.get('courseGoals') or {}).get(course, ''),
                             examDate=exam or '', daysUntilExam=days,
                             reviewDue=days is not None and 0 <= days <= 14))
    return jsonify(courses=settings)
