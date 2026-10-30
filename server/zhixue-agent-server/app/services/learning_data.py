"""Account-owned course/assignment facts. Reads never replace a device snapshot."""
from copy import deepcopy
from datetime import date, datetime, timezone
import hashlib
import json
import math
from zoneinfo import ZoneInfo


class SyncConflict(RuntimeError):
    pass


def key(owner, item_id):
    return hashlib.sha256(f'{owner}\0{item_id}'.encode()).hexdigest()


def records(repo, owner, collection):
    return repo.query(collection, {'userId': owner})


def snapshot(repo, owner):
    result = {'userId': owner, 'courses': [], 'homeworkDDLs': [], 'deletedCourses': [], 'deletedDDLs': []}
    completed = {t.get('taskId') for p in repo.query('plans', {'userId': owner})
        for t in p.get('tasks', []) + p.get('unscheduledTasks', []) if t.get('source') == 'ddl' and t.get('status') == 'completed'}
    for collection, field in [('courses', 'courses'), ('assignments', 'homeworkDDLs')]:
        for row in records(repo, owner, collection):
            if row.get('deleted'):
                result['deletedCourses' if collection == 'courses' else 'deletedDDLs'].append(dict(
                    id=row['data']['courseId' if collection == 'courses' else 'id'], expectedVersion=row['version']))
                continue
            value = deepcopy(row['data'])
            value['syncVersion'] = row['version']
            if collection == 'assignments':
                value['daysLeft'] = (date.fromisoformat(value['dueDate']) - datetime.now(ZoneInfo('Asia/Shanghai')).date()).days
                value['completed'] = value.get('completed', False) or value['id'] in completed
                linked = next((r for r in result['courses'] if r['courseId'] == value.get('courseId')), None)
                if linked:
                    value['courseName'] = linked['courseName']
            elif value['exam']['date'] not in ('', '未设置'):
                value['exam']['daysLeft'] = (date.fromisoformat(value['exam']['date']) - datetime.now(ZoneInfo('Asia/Shanghai')).date()).days
            result[field].append(value)
        result[field].sort(key=lambda r: r.get('dueDate', r.get('courseName', '')))
    result['revision'] = (repo.get('learning_sync_state', owner) or {}).get('version', 0)
    return result


def _text(data, field, limit=200):
    value = data.get(field)
    if not isinstance(value, str) or not value.strip() or len(value) > limit:
        raise ValueError(f'invalid {field}')
    return value.strip()


def validate(collection, raw):
    if not isinstance(raw, dict):
        raise ValueError('invalid learning record')
    value = deepcopy(raw)
    identity = 'courseId' if collection == 'courses' else 'id'
    value[identity] = _text(value, identity, 128)
    value['courseName'] = _text(value, 'courseName', 80)
    value['priority'] = _text(value, 'priority', 20)
    version = value.pop('syncVersion', 0)
    if type(version) is not int or version < 0:
        raise ValueError('invalid syncVersion')
    if collection == 'courses':
        exam = value.get('exam')
        if not isinstance(exam, dict) or not isinstance(exam.get('date'), str):
            raise ValueError('invalid exam')
        if exam['date'] not in ('', '未设置'):
            date.fromisoformat(exam['date'])
        if not isinstance(value.get('recentStatus'), dict) or not isinstance(value.get('priority'), str):
            raise ValueError('invalid course')
        hours = value['recentStatus'].get('studyHours')
        if type(hours) not in (int, float) or not math.isfinite(hours) or hours < 0 or not isinstance(value['recentStatus'].get('status'), str):
            raise ValueError('invalid recentStatus')
        if type(exam.get('daysLeft')) is not int:
            raise ValueError('invalid exam daysLeft')
    else:
        value['title'] = _text(value, 'title')
        value['dueDate'] = _text(value, 'dueDate', 10)
        date.fromisoformat(value['dueDate'])
        if type(value.get('estimatedMinutes')) is not int or not 1 <= value['estimatedMinutes'] <= 1440:
            raise ValueError('invalid estimatedMinutes')
        if type(value.get('completed', False)) is not bool:
            raise ValueError('invalid completed')
    return value, version


def reconcile_plan(repo, owner):
    """Only invoked after an explicit write, using the server-owned full list."""
    from app.services.assignment_plan import reconcile
    plans = [p for p in repo.list('plans') if p.get('userId') == owner]
    previous = max(plans, key=lambda p: (p.get('version', 0), p['planId']), default=None)
    rows = snapshot(repo, owner)['homeworkDDLs']
    if previous is None and not rows:
        return
    base = previous or dict(planId=f'plan-ddl-{owner}', userId=owner, version=0,
        generatedFromProfileVersion=(repo.get('profiles', owner) or {}).get('profileVersion', 1), tasks=[], unscheduledTasks=[])
    plan = reconcile(base, [dict(r, completed=r.get('completed', False)) for r in rows], authoritative=True)
    if plan != previous:
        repo.save('plans', plan['planId'], plan)
        if previous:
            from app.tools.plan_tools import create_plan_history
            history = create_plan_history(previous, plan, '课程作业已同步', [])
            history.update(planId=plan['planId'])
            repo.save('plan_histories', f"{plan['planId']}:v{plan['version']}", history)


def apply(repo, owner, data):
    if not isinstance(data, dict):
        raise ValueError('invalid change request')
    operation = key(owner, _text(data, 'idempotencyKey', 128))
    fingerprint = hashlib.sha256(json.dumps(data, sort_keys=True, ensure_ascii=False).encode()).hexdigest()
    migration = data.get('migration', False)
    if type(migration) is not bool:
        raise ValueError('invalid migration')
    changes = []
    for collection, field, deleted_field in [('courses', 'courses', 'deletedCourses'), ('assignments', 'homeworkDDLs', 'deletedDDLs')]:
        rows, deleted = data.get(field, []), data.get(deleted_field, [])
        if not isinstance(rows, list) or not isinstance(deleted, list) or len(rows) + len(deleted) > 300:
            raise ValueError('too many changes')
        seen = set()
        for raw in rows:
            value, version = validate(collection, raw)
            identity = value['courseId' if collection == 'courses' else 'id']
            if identity in seen:
                raise ValueError('duplicate record')
            seen.add(identity)
            changes.append((collection, identity, value, version))
        for raw in deleted:
            if not isinstance(raw, dict) or type(raw.get('expectedVersion')) is not int or raw['expectedVersion'] < 0:
                raise ValueError('invalid deletion')
            identity = _text(raw, 'id', 128)
            if identity in seen or migration:
                raise ValueError('invalid duplicate deletion')
            seen.add(identity)
            changes.append((collection, identity, None, raw['expectedVersion']))
    with repo.transaction():
        from app.repositories.staged_repository import StagedRepository
        repo = StagedRepository(repo)
        previous = repo.get('learning_sync_operations', operation)
        if previous:
            if previous['fingerprint'] != fingerprint:
                raise SyncConflict('request already used')
            return previous['response']
        stamp = datetime.now(timezone.utc).isoformat()
        for collection, identity, value, expected in changes:
            record_key = key(owner, identity)
            old = repo.get(collection, record_key)
            if collection == 'assignments' and value is not None:
                linked = next((r for r in records(repo, owner, 'courses') if not r.get('deleted') and r['data']['courseName'] == value['courseName']), None)
                if linked:
                    value['courseId'] = linked['data']['courseId']
            if migration:
                # Legacy imports are additions only; never overwrite or resurrect.
                if old:
                    continue
                duplicate = any(not r.get('deleted') and (
                    r['data'].get('courseName') == value.get('courseName') if collection == 'courses'
                    else all(r['data'].get(k) == value.get(k) for k in ('courseName', 'title', 'dueDate')))
                    for r in records(repo, owner, collection))
                if duplicate:
                    continue
            elif (old or {}).get('version', 0) != expected:
                raise SyncConflict('其他设备已更新这条记录')
            if value is None and old is None:
                continue
            repo.save(collection, record_key, dict(userId=owner, version=(old or {}).get('version', 0) + 1,
                deleted=value is None, data=value if value is not None else old['data'], updatedAt=stamp))
            if collection == 'courses':
                profile = repo.get('profiles', owner)
                if profile is not None:
                    exams = dict(profile.get('courseExams', {}))
                    if old:
                        exams.pop(old['data']['courseName'], None)
                    if value and value['exam']['date'] not in ('', '未设置'):
                        exams[value['courseName']] = value['exam']['date']
                    profile.update(courseExams=exams, profileVersion=profile.get('profileVersion', 1) + 1)
                    repo.save('profiles', owner, profile)
        state = repo.get('learning_sync_state', owner) or {'version': 0}
        repo.save('learning_sync_state', owner, dict(userId=owner, version=state['version'] + 1))
        reconcile_plan(repo, owner)
        result = snapshot(repo, owner)
        repo.save('learning_sync_operations', operation, dict(userId=owner, fingerprint=fingerprint, response=result))
        repo.commit()
        return result
