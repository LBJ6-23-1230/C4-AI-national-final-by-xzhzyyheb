"""One durable reminder source for every surface. No model calls or client scores."""
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo
import hashlib
import json
import uuid

DEFAULTS = dict(enabled=False, timezone='Asia/Shanghai', quietStart=22, quietEnd=8,
                dailyLimit=2, minimumGapMinutes=240, urgentException=False, summaryHour=9,
                categories=['task', 'exam', 'gap', 'conflict'])
TERMINAL = {'completed', 'invalid'}


def now():
    return datetime.now(timezone.utc)


def digest(*parts):
    return hashlib.sha256('\0'.join(str(p) for p in parts).encode()).hexdigest()


def parse(value):
    try:
        result = datetime.fromisoformat(str(value).replace('Z', '+00:00'))
        return result if result.tzinfo else None
    except (ValueError, TypeError):
        return None


def preferences(repo, owner):
    return dict(DEFAULTS, **(repo.get('reminder_preferences', owner) or {}))


def save_preferences(repo, owner, data):
    result = preferences(repo, owner)
    if set(data) - set(DEFAULTS):
        raise ValueError('未知提醒设置')
    result.update(data)
    for key in ('enabled', 'urgentException'):
        if type(result[key]) is not bool:
            raise ValueError('提醒开关须为布尔值')
    categories = result['categories']
    if (not isinstance(categories, list) or any(not isinstance(c, str) or c not in DEFAULTS['categories'] for c in categories)
            or len(categories) != len(set(categories))):
        raise ValueError('提醒类别无效')
    for key, maximum in (('quietStart', 23), ('quietEnd', 23), ('summaryHour', 23),
                         ('dailyLimit', 2), ('minimumGapMinutes', 1440)):
        if type(result[key]) is not int or not 0 <= result[key] <= maximum:
            raise ValueError('提醒时间或次数超出范围')
    if result['minimumGapMinutes'] < 240:
        raise ValueError('两次主动提醒至少间隔240分钟')
    try:
        ZoneInfo(result['timezone'])
    except (KeyError, TypeError, ValueError):
        raise ValueError('时区无效') from None
    repo.save('reminder_preferences', owner, result)
    return result


def candidates(repo, owner, stamp):
    """Keep course facts together; date-only deadlines never become six-hour risks."""
    local = stamp.astimezone(ZoneInfo(preferences(repo, owner)['timezone']))
    profile = repo.get('profiles', owner) or {}
    plans = sorted((p for p in repo.list('plans') if p.get('userId', 'demo-user') == owner),
                   key=lambda p: (p.get('version', 0), p.get('planId', '')), reverse=True)
    plan = plans[0] if plans else {}
    rows = []
    all_tasks = plan.get('tasks', []) + plan.get('unscheduledTasks', [])
    tasks = {t['taskId']: t for t in all_tasks if t.get('taskId')}
    budget = plan.get('constraints', {}).get('availableMinutes')
    scheduled = sum(t.get('durationMinutes', 0) for t in plan.get('tasks', [])
                    if t.get('status') not in ('completed', 'deleted', 'cancelled'))
    if type(budget) in (int, float) and scheduled > budget:
        rows.append(dict(kind='conflict', objectId=plan.get('planId', ''), courseName='',
            title='今日安排超出可用时间', level='important',
            reason=f'已安排{scheduled}分钟，已确认可用{budget}分钟；请查看并选择如何调整。',
            due=local.date().isoformat(), deadline='', durationMinutes=0, evidenceIds=[],
            sourceVersion=plan.get('version', 1), planId=plan.get('planId', ''),
            knowledgePointId='', targetPage='pages/StudyPlan'))
    for task_id, task in tasks.items():
        if task.get('status') in ('completed', 'deleted', 'cancelled'):
            continue
        course = task.get('sourceCourse') or task.get('courseName') or ''
        title = task.get('knowledgePointName') or task.get('title') or '学习任务'
        precise = parse(task.get('dueAt'))
        due_date = task.get('dueDate') or ''
        level, reason, sort_due = 'normal', '当前计划中的待完成任务', '9999'
        if precise:
            hours = (precise - stamp).total_seconds() / 3600
            level = 'urgent' if hours <= 6 else 'important' if hours <= 48 else 'normal'
            reason = '截止时间：' + precise.astimezone(local.tzinfo).strftime('%m月%d日 %H:%M')
            sort_due = precise.isoformat()
        elif due_date:
            try:
                days = (date.fromisoformat(due_date) - local.date()).days
            except ValueError:
                continue
            level = 'urgent' if days < 0 else 'important' if days <= 2 else 'normal'
            reason = '截止日期：' + due_date + '（具体时刻未设置）'
            sort_due = due_date
        rows.append(dict(kind='task', objectId=task_id, courseName=course, title=title,
            level=level, reason=reason, due=sort_due, deadline=task.get('dueAt') or due_date,
            durationMinutes=task.get('durationMinutes', 0), evidenceIds=[],
            sourceVersion=plan.get('version', 1), planId=plan.get('planId', ''),
            knowledgePointId=task.get('knowledgePointId', ''), targetPage='pages/FocusSetup'))
    evidence = profile.get('evidence', [])
    history = profile.get('history', [])
    for point in profile.get('mastery', []):
        point_id = point.get('knowledgePointId', '')
        assessed = [e for e in evidence if e.get('knowledgePointId') == point_id and
                    e.get('sourceType') in ('assessment', 'exercise', 'practice')]
        if not assessed and not any(h.get('knowledgePointId') == point_id and h.get('source') == 'assessment' for h in history):
            continue
        course = point.get('sourceCourse') or ''
        exam = (profile.get('courseExams') or {}).get(course)
        try:
            days = (date.fromisoformat(exam) - local.date()).days
        except (ValueError, TypeError):
            continue
        if not 0 <= days <= 14 or point.get('masteryScore', 100) >= 80:
            continue
        rows.append(dict(kind='exam', objectId=point_id, courseName=course,
            title=point.get('knowledgePointName') or point_id, level='important' if days <= 7 else 'normal',
            reason=f'{course}考试日期：{exam}；本知识点已有测评记录，需巩固', due=exam, deadline=exam,
            durationMinutes=10, evidenceIds=[e.get('id') or e.get('evidenceId', '') for e in assessed],
            sourceVersion=profile.get('profileVersion', 1), planId='', knowledgePointId=point_id,
            targetPage='pages/ExercisePractice'))
    sessions = [parse(r.get('session', {}).get('endedAt')) for r in repo.list('focus_sessions') if r.get('userId') == owner]
    last = max((s for s in sessions if s and s <= stamp), default=None)
    if last and (local.date() - last.astimezone(local.tzinfo).date()).days >= 2 and not rows:
        rows.append(dict(kind='gap', objectId='study', courseName='', title='继续学习', level='normal',
            reason='最近一次专注记录：' + last.astimezone(local.tzinfo).strftime('%m月%d日'), due='9999',
            deadline='', durationMinutes=0, evidenceIds=[], sourceVersion=1, planId='', knowledgePointId='',
            targetPage='pages/StudyPlan'))
    return sorted(rows, key=lambda r: ({'urgent': 0, 'important': 1, 'normal': 2}[r['level']],
                  r['due'], r['courseName'], r['objectId']))


def reconcile(repo, owner, stamp=None):
    stamp = stamp or now()
    local_day = stamp.astimezone(ZoneInfo(preferences(repo, owner)['timezone'])).date().isoformat()
    active = set()
    with repo.transaction():
        for item in candidates(repo, owner, stamp):
            event_id = 'rem-' + digest(owner, item['kind'], item['objectId'], item['level'])[:28]
            active.add(event_id)
            old = repo.get('reminder_events', event_id)
            facts = json.dumps(item, ensure_ascii=False, sort_keys=True)
            changed = old is None or old.get('facts') != facts
            state = (old or {}).get('status', 'pending')
            deadline_changed = old and old.get('deadline') != item['deadline']
            if state in TERMINAL or deadline_changed:
                state = 'pending'
            if state == 'ignored' and old.get('ignoredDate') != local_day:
                state = 'pending'
            if state == 'snoozed' and (parse(old.get('snoozedUntil')) or stamp) <= stamp:
                state = 'pending'
            event = dict(old or {}, **item, eventId=event_id, userId=owner, facts=facts,
                status=state, version=(old or {}).get('version', 0) + int(changed or state != (old or {}).get('status')),
                dataTime=stamp.isoformat() if changed else old['dataTime'])
            if deadline_changed:
                event.pop('snoozeKey', None)
                event.pop('snoozedUntil', None)
            if event != old:
                repo.save('reminder_events', event_id, event)
        for old in repo.list('reminder_events'):
            if old.get('userId') != owner or old['eventId'] in active or old['status'] in TERMINAL:
                continue
            complete = any(t.get('taskId') == old['objectId'] and t.get('status') == 'completed'
                for p in repo.list('plans') if p.get('userId', 'demo-user') == owner for t in p.get('tasks', []))
            repo.save('reminder_events', old['eventId'], dict(old, status='completed' if complete else 'invalid', version=old['version'] + 1))
        for job in repo.list('reminder_deliveries'):
            if job.get('userId') != owner or job['status'] not in ('queued', 'sending'):
                continue
            event = repo.get('reminder_events', job['eventId'])
            if not event or event['status'] != 'pending' or job['deadline'] != event['deadline']:
                repo.save('reminder_deliveries', job['deliveryId'], dict(job, status='cancelled'))
    return overview(repo, owner, stamp)


def public(event):
    return {k: v for k, v in event.items() if k not in ('facts', 'ignoredDate')}


def overview(repo, owner, stamp=None):
    events = [e for e in repo.list('reminder_events') if e.get('userId') == owner and e['status'] not in TERMINAL]
    events.sort(key=lambda e: ({'urgent': 0, 'important': 1, 'normal': 2}[e['level']], e['due'], e['eventId']))
    visible = [e for e in events if e['status'] == 'pending']
    return dict(userId=owner, dataTime=(stamp or now()).isoformat(),
        version=digest(*(str((e['eventId'], e['version'], e['status'])) for e in events))[:20],
        highlight=public(visible[0]) if visible else None, tasks=[public(e) for e in visible[1:3]],
        pendingCount=len(visible), guidance='先导入课程或完成一次知识点诊断，建立学情。' if not events else '今天的事项已处理，可查看安排。',
        modelCalls=0)


def action(repo, owner, event_id, data):
    key = data.get('idempotencyKey')
    if not isinstance(key, str) or not 1 <= len(key) <= 128:
        raise ValueError('请提供操作标识')
    operation = digest(owner, key)
    with repo.transaction():
        reconcile(repo, owner)
        old = repo.get('reminder_actions', operation)
        if old:
            if old['request'] != dict(data, eventId=event_id):
                raise RuntimeError('该操作标识已使用，请刷新')
            return old['response']
        event = repo.get('reminder_events', event_id)
        if not event or event['userId'] != owner:
            raise LookupError('提醒不存在')
        if event['status'] in TERMINAL or type(data.get('version')) is not int or event['version'] != data['version']:
            raise RuntimeError('提醒已更新或已处理，请刷新')
        verb = data.get('action')
        states = {'start': 'started', 'snooze': 'snoozed', 'ignore': 'ignored'}
        if verb not in states:
            raise ValueError('不支持的提醒动作')
        stamp = now()
        if verb == 'snooze':
            minutes = data.get('minutes', 30)
            if type(minutes) is not int or minutes not in (15, 30, 60):
                raise ValueError('请选择15、30或60分钟')
            event['snoozedUntil'] = (stamp + timedelta(minutes=minutes)).isoformat()
            event['snoozeKey'] = key
        if verb == 'ignore':
            event['ignoredDate'] = stamp.astimezone(ZoneInfo(preferences(repo, owner)['timezone'])).date().isoformat()
        if verb != 'snooze':
            event.pop('snoozeKey', None)
            event.pop('snoozedUntil', None)
        event.update(status=states[verb], version=event['version'] + 1)
        response = dict(event=public(event))
        repo.apply_batch([], [('reminder_events', event_id, event), ('reminder_actions', operation,
            dict(userId=owner, request=dict(data, eventId=event_id), response=response))])
        reconcile(repo, owner, stamp)
        return response


def unbind(repo, owner, device_id=None):
    with repo.transaction():
        for device in repo.list('reminder_devices'):
            if device.get('userId') == owner and (not device_id or device['deviceId'] == device_id):
                repo.save('reminder_devices', device['deviceId'], dict(device, active=False, pushToken=''))


def bind(repo, owner, data):
    device_id, token = data.get('deviceId'), data.get('pushToken', '')
    if not isinstance(device_id, str) or not 1 <= len(device_id) <= 128 or not isinstance(token, str) or len(token) > 4096:
        raise ValueError('设备标识或Token无效')
    if type(data.get('permission')) is not bool or type(data.get('foreground', False)) is not bool or type(data.get('focusing', False)) is not bool:
        raise ValueError('设备状态无效')
    # Installation IDs are secrets generated by the client, not hardware identifiers.
    record = dict(deviceId=device_id, userId=owner, pushToken=token, permission=data['permission'],
        foreground=data.get('foreground', False), focusing=data.get('focusing', False),
        lastActive=now().isoformat(), active=True)
    with repo.transaction():
        repo.save('reminder_devices', device_id, record)
    return dict(deviceId=device_id, active=True, hasToken=bool(token), lastActive=record['lastActive'])


def allowed(repo, event, stamp, current_id=None):
    prefs = preferences(repo, event['userId'])
    if not prefs['enabled'] or event['status'] != 'pending':
        return False
    if event['kind'] not in prefs['categories']:
        return False
    local = stamp.astimezone(ZoneInfo(prefs['timezone']))
    start, end = prefs['quietStart'], prefs['quietEnd']
    quiet = start == end or (start <= local.hour < end if start < end else local.hour >= start or local.hour < end)
    if quiet and not (event['level'] == 'urgent' and prefs['urgentException']):
        return False
    devices = [d for d in repo.list('reminder_devices') if d.get('userId') == event['userId'] and d.get('active')]
    if any(d.get('focusing') or (d.get('foreground') and
           (parse(d.get('lastActive')) or stamp - timedelta(days=1)) > stamp - timedelta(minutes=3)) for d in devices):
        return False
    sent = [d for d in repo.list('reminder_deliveries') if d.get('userId') == event['userId'] and
            d['deliveryId'] != current_id and d['status'] in ('sending', 'accepted', 'delivered', 'clicked')]
    today = [d for d in sent if d['deliveryDate'] == local.date().isoformat()]
    if len(today) >= prefs['dailyLimit']:
        return False
    snoozed = bool(event.get('snoozeKey'))
    if any(d['eventId'] == event['eventId'] and d['deadline'] == event['deadline'] for d in today) and not snoozed:
        return False
    if not snoozed and any((stamp - (parse(d.get('attemptedAt')) or stamp)).total_seconds() < prefs['minimumGapMinutes'] * 60 for d in sent):
        return False
    if event['level'] != 'urgent' and not snoozed:
        if local.hour < prefs['summaryHour'] or any(d['category'] == 'summary' for d in today):
            return False
    return True


def schedule(repo, owner, stamp=None):
    stamp = stamp or now()
    reconcile(repo, owner, stamp)
    prefs = preferences(repo, owner)
    local = stamp.astimezone(ZoneInfo(prefs['timezone']))
    with repo.transaction():
        events = [e for e in repo.list('reminder_events') if e.get('userId') == owner and allowed(repo, e, stamp)]
        events.sort(key=lambda e: ({'urgent': 0, 'important': 1, 'normal': 2}[e['level']], e['due'], e['eventId']))
        for event in events[:1]:
            # Regular low-priority suggestions stay inside the app.
            if event['level'] == 'normal' and not event.get('snoozeKey'):
                continue
            day = local.date().isoformat()
            delivery_id = 'delivery-' + digest(owner, event['eventId'], event['deadline'], day, event.get('snoozeKey', ''))[:28]
            if repo.get('reminder_deliveries', delivery_id):
                continue
            repo.save('reminder_deliveries', delivery_id, dict(deliveryId=delivery_id, userId=owner,
                eventId=event['eventId'], deadline=event['deadline'], deliveryDate=day,
                snoozeKey=event.get('snoozeKey', ''),
                category='snooze' if event.get('snoozeKey') else 'urgent' if event['level'] == 'urgent' else 'summary', status='queued',
                runAfter=stamp.isoformat(), attempts=0, leaseToken='', lockedUntil='', receipt=''))


def deliver_once(repo, sender, stamp=None):
    stamp = stamp or now()
    job = event = device = None
    with repo.transaction():
        for row in sorted(repo.list('reminder_deliveries'), key=lambda d: (d['runAfter'], d['deliveryId'])):
            if row['status'] == 'sending' and (parse(row['lockedUntil']) or stamp) > stamp:
                continue
            if row['status'] not in ('queued', 'sending') or (parse(row['runAfter']) or stamp) > stamp:
                continue
            reconcile(repo, row['userId'], stamp)
            row = repo.get('reminder_deliveries', row['deliveryId'])
            event = repo.get('reminder_events', row['eventId'])
            today = stamp.astimezone(ZoneInfo(preferences(repo, row['userId'])['timezone'])).date().isoformat()
            if row['deliveryDate'] != today:
                repo.save('reminder_deliveries', row['deliveryId'], dict(row, status='cancelled'))
                continue
            if row['status'] == 'cancelled' or not event or not allowed(repo, event, stamp, row['deliveryId']):
                continue
            devices = sorted((d for d in repo.list('reminder_devices') if d.get('userId') == row['userId'] and
                d.get('active') and d.get('permission') and d.get('pushToken')), key=lambda d: d['lastActive'], reverse=True)
            account = repo.get('users', row['userId'])
            if account and account.get('status') == 'deactivated':
                repo.save('reminder_deliveries', row['deliveryId'], dict(row, status='cancelled'))
                continue
            if not devices:
                continue
            if row['attempts'] >= 3:
                repo.save('reminder_deliveries', row['deliveryId'], dict(row, status='failed', receipt='retry_limit'))
                continue
            device = devices[0]
            job = dict(row, status='sending', deviceId=device['deviceId'], leaseToken=uuid.uuid4().hex,
                attempts=row['attempts'] + 1, attemptedAt=stamp.isoformat(), lockedUntil=(stamp + timedelta(seconds=60)).isoformat())
            repo.save('reminder_deliveries', job['deliveryId'], job)
            break
    if job is None:
        return False
    # The provider request has a 15-second timeout, shorter than the lease.
    try:
        receipt = sender(event, device, job)
        status = 'accepted'  # This is never a claim of delivery/read.
    except Exception as error:
        receipt = getattr(error, 'code', 'provider_failed')
        status = 'failed' if job['attempts'] >= 3 else 'queued'
        if receipt == 'invalid_token':
            unbind(repo, job['userId'], device['deviceId'])
            status = 'failed'
    with repo.transaction():
        current = repo.get('reminder_deliveries', job['deliveryId'])
        if current and current['status'] == 'sending' and current['leaseToken'] == job['leaseToken']:
            repo.save('reminder_deliveries', job['deliveryId'], dict(current, status=status, receipt=str(receipt)[:200],
                lockedUntil='', runAfter=(stamp + timedelta(seconds=60 * job['attempts'])).isoformat()))
            if status == 'accepted' and job.get('snoozeKey'):
                latest = repo.get('reminder_events', job['eventId'])
                if latest and latest.get('snoozeKey') == job['snoozeKey']:
                    latest.pop('snoozeKey', None)
                    latest.pop('snoozedUntil', None)
                    repo.save('reminder_events', latest['eventId'], latest)
    return True
