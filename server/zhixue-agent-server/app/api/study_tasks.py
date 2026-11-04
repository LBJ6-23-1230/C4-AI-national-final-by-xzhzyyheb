"""Account-owned editable tasks and consent-based partner study arrangements."""
from copy import deepcopy
from datetime import date, datetime, timezone
from uuid import uuid4

from flask import Blueprint, abort, jsonify, request, g
from functools import wraps
from app.repositories.staged_repository import StagedRepository
from app.api.learning_upgrade import authenticated, body, now, relationship, repo as backing_repo, string
from app.api.plans import plan_belongs_to
from app.tools.profile_merge import PROFILE_LOCK

study_tasks_api = Blueprint('study_tasks', __name__)


def repo():
    return getattr(g, 'study_task_repository', None) or backing_repo()


def atomic_operation(function):
    @wraps(function)
    def wrapped(*args, **kwargs):
        repository = backing_repo()
        with PROFILE_LOCK, repository.transaction():
            staged = StagedRepository(repository)
            g.study_task_repository = staged
            try:
                response = function(*args, **kwargs)
                staged.commit()
                return response
            finally:
                g.pop('study_task_repository', None)
    return wrapped


@study_tasks_api.post('/api/v1/chat-files')
def read_chat_file():
    owner = authenticated()
    data = body()
    name = string(data, 'fileName', 200, True)
    content = string(data, 'contentBase64', 12_000_000, True)
    from app.agent.knowledge import process_document
    parsed = process_document(name, content, [], scope=owner + ':chat')
    if parsed['status'] != 'ready':
        return jsonify(errorCode='FILE_PARSE_FAILED', message=parsed['statusMessage']), 400
    text = '\n\n'.join(chunk['text'] for chunk in parsed['chunks'])
    return jsonify(fileName=name, text=text[:12000], truncated=len(text) > 12000)


def fields(data):
    title = string(data, 'title', 200, True)
    course = string(data, 'courseName', 80, True)
    day = string(data, 'scheduledDate', 10, True)
    try:
        date.fromisoformat(day)
    except ValueError:
        abort(400, '日期请使用 YYYY-MM-DD')
    minutes = data.get('durationMinutes')
    if type(minutes) is not int or not 1 <= minutes <= 1440:
        abort(400, '预计时长须为1至1440分钟')
    return dict(title=title, courseName=course, scheduledDate=day, durationMinutes=minutes)


def current_plan(owner):
    return next((p for p in repo().list('plans') if plan_belongs_to(p, owner)), None) or dict(
        planId='plan-personal-' + owner, userId=owner, version=0,
        generatedFromProfileVersion=(repo().get('profiles', owner) or {}).get('profileVersion', 1),
        tasks=[], unscheduledTasks=[])


def merge_owned_tasks(repository, plan, owner):
    """Restore explicit commitments after automatic replanning without losing completion."""
    plan = deepcopy(plan)
    records = [r for r in repository.query('study_tasks', {'userId': owner}) if not r.get('deleted')]
    for shared in repository.list('shared_study_tasks'):
        if owner in shared['members'] and shared['status'] == 'accepted':
            records.append(dict(shared, taskId=shared['taskId'], source='partner',
                                status=shared['progress'].get(owner, 'pending'), myPart=shared['parts'][owner]))
    if not records:
        return plan
    existing = {t['taskId']: t for t in plan.get('tasks', []) + plan.get('unscheduledTasks', [])}
    for record in records:
        task_id = record['taskId']
        previous = existing.get(task_id, {})
        task = dict(record.get('task', {}), **previous)
        task.update(taskId=task_id, knowledgePointId=record.get('knowledgePointId', task_id), knowledgePointName=record['title'],
                    sourceCourse=record['courseName'], source=record.get('source', 'manual'),
                    durationMinutes=record['durationMinutes'], scheduledDate=record['scheduledDate'],
                    status='completed' if 'completed' in (previous.get('status'), record.get('status')) else previous.get('status', record.get('status', 'pending')),
                    priority=record.get('priority', previous.get('priority', 'normal')),
                    steps=record.get('steps') or [record.get('myPart') or '完成约定的学习内容'])
        plan['tasks'] = [t for t in plan.get('tasks', []) if t['taskId'] != task_id] + [task]
        plan['unscheduledTasks'] = [t for t in plan.get('unscheduledTasks', []) if t['taskId'] != task_id]
    plan['tasks'].sort(key=lambda t: (t.get('scheduledDate', ''), t.get('priority') != 'high', t.get('dueDate', '9999')))
    return plan


def persist(owner):
    previous = current_plan(owner)
    plan = merge_owned_tasks(repo(), previous, owner)
    plan['version'] = previous['version'] + 1
    # A prior budget summary describes the old selection and must not be presented as current.
    plan.pop('budgetSummary', None)
    plan['reason'] = '保留已确认任务；按安排日期、优先级与截止日期执行，可随时编辑自己的任务。'
    repo().save('plans', plan['planId'], plan)
    return plan


@study_tasks_api.post('/api/v1/plans/current/today-items')
@atomic_operation
def add_today_item():
    from app.services import reminders
    from zoneinfo import ZoneInfo
    import hashlib
    owner = authenticated()
    data = body()
    event_id = string(data, 'eventId', 128, True)
    version = data.get('expectedPlanVersion')
    available = data.get('availableMinutes')
    if type(version) is not int or version < 0 or type(available) is not int or not 0 <= available <= 1440:
        abort(400, '请确认有效的计划版本和今日可用分钟数')
    reminders.reconcile(repo(), owner)
    event = repo().get('reminder_events', event_id)
    if not event or event.get('userId') != owner:
        abort(404, '待办不存在，请刷新列表')
    if event.get('kind') not in ('exam', 'task') or event.get('sourceType') == 'ddl':
        abort(400, '请选择复习或学习待办；课程作业使用下方作业入口')
    plan = current_plan(owner)
    today = datetime.now(ZoneInfo('Asia/Shanghai')).date().isoformat()
    all_tasks = plan.get('tasks', []) + plan.get('unscheduledTasks', [])
    if event['kind'] == 'task':
        selected = [t for t in all_tasks if t['taskId'] == (event.get('sourceId') or event['objectId'])]
        if not selected:
            selected = [t for t in all_tasks if t.get('parentTaskId') == event['objectId'] and t.get('status') != 'completed']
    else:
        selected = [t for t in all_tasks if t.get('knowledgePointId') == event.get('knowledgePointId')
                    and t.get('sourceCourse') == event['courseName'] and t.get('source') not in ('ddl', 'manual', 'partner') and t.get('status') != 'completed'][:1]
    ids = {t['taskId'] for t in selected}
    scheduled = {t['taskId'] for t in plan.get('tasks', []) if t.get('status') != 'completed'
                 and (not t.get('scheduledDate') or t['scheduledDate'] <= today)}
    # A lost-response retry or another entry point must not create a second task.
    if selected and ids <= scheduled:
        return jsonify(plan)
    if event.get('status') in ('invalid', 'completed'):
        abort(409, '待办已完成或发生变化，请刷新列表')
    if plan['version'] != version:
        abort(409, '计划已有更新，请刷新后重新加入')
    if event['kind'] == 'exam' and not selected:
        task_id = 'exam-today-' + hashlib.sha256((owner + '\0' + event['objectId'] + '\0' + today).encode()).hexdigest()[:24]
        if any(t['taskId'] == task_id for t in all_tasks):
            abort(409, '这项今日复习已完成，可直接开始新一轮复习')
        selected = [dict(taskId=task_id, knowledgePointId=event['knowledgePointId'],
            knowledgePointName='复习' + event['title'], sourceCourse=event['courseName'], source='exam_review',
            status='pending', priority='normal', durationMinutes=event['durationMinutes'],
            steps=['完成该知识点的新题', '核对答案与解析，查看学习报告中的表现'])]
        ids = {task_id}
    if not selected or any(t.get('status') == 'completed' for t in selected):
        abort(409, '这项任务已完成或移除，请刷新待办')
    if any(type(t.get('durationMinutes')) is not int or t['durationMinutes'] <= 0 for t in selected):
        abort(400, '任务预计时长尚未明确，请先补充时长')
    current = [t for t in plan.get('tasks', []) if t['taskId'] not in ids]
    used = sum(t['durationMinutes'] for t in current if t.get('status') != 'completed'
               and (not t.get('scheduledDate') or t['scheduledDate'] <= today))
    total = used + sum(t['durationMinutes'] for t in selected)
    existing_budget = (plan.get('budgetSummary') or {}).get('availableMinutes', plan.get('constraints', {}).get('availableMinutes', 0))
    if available < max(total, existing_budget):
        abort(409, f'加入后今日需{total}分钟，请重新确认可用时间')
    for task in selected:
        task.update(scheduledDate=today)
        task.pop('deferredReason', None)
        # Explicit review commitments survive automatic plan regeneration.
        if task.get('source') not in ('partner', 'manual'):
            task['source'] = 'exam_review' if event['kind'] == 'exam' else 'today'
            repo().save('study_tasks', task['taskId'], dict(userId=owner, taskId=task['taskId'],
                title=task['knowledgePointName'], courseName=task['sourceCourse'], scheduledDate=today,
                durationMinutes=task['durationMinutes'], source=task['source'], status=task['status'],
                knowledgePointId=task['knowledgePointId'], steps=task.get('steps', []),
                priority=task.get('priority', 'normal'), task=deepcopy(task)))
    plan['tasks'] = current + selected
    plan['unscheduledTasks'] = [t for t in plan.get('unscheduledTasks', []) if t['taskId'] not in ids]
    plan['constraints'] = dict(plan.get('constraints', {}), availableMinutes=available)
    plan['budgetSummary'] = dict(availableMinutes=available, scheduledMinutes=total,
        unallocatedMinutes=available-total,
        unscheduledMinutes=sum(t['durationMinutes'] for t in plan['unscheduledTasks'] if t.get('status') != 'completed'))
    for day in plan.get('calendarDays', []):
        day['scheduledMinutes'] = sum(t['durationMinutes'] for t in plan['tasks'] if t.get('status') != 'completed'
                                     and t.get('scheduledDate') == day['date'])
    if 'calendarDays' in plan:
        day = next((d for d in plan['calendarDays'] if d['date'] == today), None)
        if day is None:
            day = dict(date=today)
            plan['calendarDays'].append(day)
            plan['calendarDays'].sort(key=lambda d: d['date'])
        day.update(minutes=available, scheduledMinutes=total)
    plan['version'] += 1
    plan['reason'] = '已将所选待办加入今日计划，其他任务日期保留。'
    repo().save('plans', plan['planId'], plan)
    return jsonify(plan)


@study_tasks_api.post('/api/v1/study-tasks')
@atomic_operation
def manual_task():
    owner = authenticated()
    data = body()
    action = data.get('action', 'save')
    if action not in ('save', 'delete'):
        abort(400)
    value = fields(data) if action == 'save' else {}
    key = string(data, 'taskId', 128, True)
    if not key.startswith('manual-'):
        abort(400)
    with PROFILE_LOCK, repo().transaction():
        previous = repo().get('study_tasks', key)
        if previous and previous['userId'] != owner:
            abort(404)
        plan = current_plan(owner)
        if type(data.get('expectedPlanVersion')) is not int or data['expectedPlanVersion'] != plan['version']:
            abort(409, '计划已变化，请刷新后重新编辑')
        active = next((t for t in plan.get('tasks', []) if t['taskId'] == key), {})
        if active.get('status') in ('completed', 'running', 'in_progress'):
            abort(409, '已开始或完成的任务不能修改')
        if action == 'delete' and not previous:
            abort(404)
        repo().save('study_tasks', key, dict(value, taskId=key, userId=owner, source='manual',
                    status='pending', deleted=action == 'delete', updatedAt=now()))
        if action == 'delete':
            plan['tasks'] = [t for t in plan.get('tasks', []) if t['taskId'] != key]
            plan['unscheduledTasks'] = [t for t in plan.get('unscheduledTasks', []) if t['taskId'] != key]
            repo().save('plans', plan['planId'], plan)
        return jsonify(persist(owner))


def public(shared, owner):
    partner = next(member for member in shared['members'] if member != owner)
    progress = dict(shared['progress'])
    for member in shared['members']:
        plan = current_plan(member)
        if any(t['taskId'] == shared['taskId'] and t.get('status') == 'completed'
               for t in plan.get('tasks', []) + plan.get('unscheduledTasks', [])):
            progress[member] = 'completed'
    return dict(taskId=shared['taskId'], title=shared['title'], courseName=shared['courseName'],
                scheduledDate=shared['scheduledDate'], durationMinutes=shared['durationMinutes'],
                status=shared['status'], fromUserId=shared['fromUserId'], partnerId=partner,
                partnerName=(repo().get('users', partner) or {}).get('nickname') or '学习搭子',
                myStatus=progress[owner], partnerStatus=progress[partner],
                myPart=shared['parts'][owner], partnerPart=shared['parts'][partner])


@study_tasks_api.route('/api/v1/shared-study-tasks', methods=['GET', 'POST'])
@atomic_operation
def shared_tasks():
    owner = authenticated()
    if request.method == 'GET':
        return jsonify(tasks=[public(s, owner) for s in repo().list('shared_study_tasks')
                              if owner in s['members']])
    data = body()
    action = data.get('action')
    with PROFILE_LOCK, repo().transaction():
        if action == 'create':
            partner = string(data, 'partnerId', 128, True)
            relationship(owner, partner)
            value = fields(data)
            key = string(data, 'taskId', 128, True)
            if not key.startswith('shared-'):
                abort(400)
            shared = dict(value, taskId=key, userId=owner, members=[owner, partner], fromUserId=owner,
                          status='pending', progress={owner: 'pending', partner: 'pending'},
                          parts={owner: string(data, 'myPart', 300, True),
                                 partner: string(data, 'partnerPart', 300, True)}, createdAt=now())
            previous = repo().get('shared_study_tasks', key)
            if previous:
                if previous['fromUserId'] != owner or any(previous.get(k) != shared.get(k) for k in
                    ('title', 'courseName', 'scheduledDate', 'durationMinutes', 'members', 'parts')):
                    abort(409)
                shared = previous
            repo().save('shared_study_tasks', key, shared)
            if not previous:
                import hashlib
                room = hashlib.sha256('\0'.join(sorted(shared['members'])).encode()).hexdigest()
                message_id = now() + '-' + uuid4().hex
                repo().save('partner_messages', message_id, dict(messageId=message_id, roomId=room,
                    userId=owner, senderId=owner, text=f"协同任务邀请：「{shared['title']}」，{shared['scheduledDate']}，各{shared['durationMinutes']}分钟。你的分工：{shared['parts'][partner]}。请在协同任务页确认或拒绝，确认后加入双方计划。",
                    image='', createdAt=now(), clientId=message_id))
        else:
            key = string(data, 'taskId', 128, True)
            shared = repo().get('shared_study_tasks', key)
            if not shared or owner not in shared['members']:
                abort(404)
            partner = next(m for m in shared['members'] if m != owner)
            relationship(owner, partner)
            if action in ('accept', 'decline'):
                if shared['fromUserId'] == owner:
                    abort(403)
                target = 'accepted' if action == 'accept' else 'declined'
                if shared['status'] not in ('pending', target):
                    abort(409)
                shared['status'] = target
                repo().save('shared_study_tasks', key, shared)
                if action == 'accept':
                    for member in shared['members']:
                        persist(member)
            elif action in ('complete', 'remind'):
                if shared['status'] != 'accepted':
                    abort(409)
                if action == 'complete':
                    shared['progress'][owner] = 'completed'
                    repo().save('shared_study_tasks', key, shared)
                    persist(owner)
                else:
                    if public(shared, owner)['partnerStatus'] == 'completed':
                        abort(409, '对方已经完成')
                    reminder_key = key + ':' + owner
                    previous = repo().get('shared_task_reminders', reminder_key)
                    if previous and (datetime.now(timezone.utc) - datetime.fromisoformat(previous['createdAt'])).total_seconds() < 3600:
                        abort(429, '一小时内已提醒过，请给搭子一些时间')
                    import hashlib
                    room = hashlib.sha256('\0'.join(sorted(shared['members'])).encode()).hexdigest()
                    message_id = now() + '-' + uuid4().hex
                    repo().save('partner_messages', message_id, dict(messageId=message_id, roomId=room,
                        userId=owner, senderId=owner, text=f"提醒一起完成「{shared['title']}」：你的分工是{shared['parts'][partner]}。需要帮助可以在这里商量。",
                        image='', createdAt=now(), clientId=message_id))
                    repo().save('shared_task_reminders', reminder_key, dict(createdAt=now(), userId=owner))
            else:
                abort(400)
        return jsonify(tasks=[public(s, owner) for s in repo().list('shared_study_tasks') if owner in s['members']])
