"""Explicit primary-account migration. Default is dry-run; backups support guarded rollback.

Retain primary account settings/credentials. Combine profile evidence/history and plan
tasks, retain every original row in an audit snapshot, revoke all affected sessions.
Unknown singleton/key collisions stop the transaction instead of overwriting data.
"""
import argparse
from collections import Counter
from copy import deepcopy
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import sys
from dotenv import load_dotenv
from sqlalchemy import MetaData, create_engine, select, text, update, delete, insert

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'server/zhixue-agent-server'))
from app.auth.service import normalize_phone, mask_phone


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, default=str).encode()).hexdigest()


def replace_owner(value, sources, primary):
    if isinstance(value, dict):
        return {k: replace_owner(v, sources, primary) for k, v in value.items()}
    if isinstance(value, list):
        return [replace_owner(v, sources, primary) for v in value]
    if isinstance(value, str) and value in sources:
        return primary
    return value


def unique(items):
    return list({digest(x): x for x in items}.values())


def migrate(conn, metadata, primary, backup, apply):
    tables = [t for t in metadata.sorted_tables if 'value' in t.c and 'item_id' in t.c]
    if apply:
        conn.execute(text('LOCK TABLE ' + ','.join('"'+t.name+'"' for t in tables) + ' IN EXCLUSIVE MODE'))
    before = {t.name: [dict(r) for r in conn.execute(select(t)).mappings()] for t in tables}
    users = before['users']
    main = next((r for r in users if r['item_id'] == primary and r['status'] == 'active'), None)
    if main is None:
        raise ValueError('Primary account must exist and be active')
    phone = normalize_phone(main['value']['phone'])
    group = [r for r in users if r['status'] == 'active' and r['value'].get('phone') and normalize_phone(r['value']['phone']) == phone]
    sources = {r['item_id'] for r in group if r['item_id'] != primary}
    if not sources:
        raise ValueError('No duplicate group for this primary')
    owners = sources | {primary}
    counts = {t.name: sum(r.get('user_id') in owners for r in before[t.name]) for t in tables}
    report = dict(primary=primary, sourceUserIds=sorted(sources), phoneMasked=mask_phone(phone),
                  beforeCounts=counts, mode='apply' if apply else 'dry-run')
    print(json.dumps(report, ensure_ascii=True, indent=2))
    # Dry-run verifies every collision before any remote write.
    work = deepcopy(before)
    archived = []
    for t in tables:
        name = t.name
        rows = work[name]
        primary_rows = [r for r in rows if r.get('user_id') == primary]
        if name == 'auth_sessions':
            work[name] = [r for r in rows if r['user_id'] not in owners]
            continue
        if name == 'users':
            for row in rows:
                if row['item_id'] in sources:
                    row['status'] = 'merged'
                    row['value'].update(status='merged', mergedInto=primary)
                elif row['item_id'] == primary:
                    row['phone'] = phone
                    row['value']['phone'] = phone
            continue
        moved = []
        for row in rows:
            old_owner = row.get('user_id')
            if old_owner not in sources:
                continue
            archived.append(dict(table=name, row=deepcopy(row)))
            row['user_id'] = primary
            row['value'] = replace_owner(row['value'], sources, primary)
            if row['item_id'] == old_owner:
                row['item_id'] = primary
            elif row['item_id'].startswith(old_owner + ':'):
                row['item_id'] = primary + row['item_id'][len(old_owner):]
            if name in ('learning_courses', 'learning_assignments'):
                from app.services.learning_data import key
                identity = row['value']['data']['courseId' if name == 'learning_courses' else 'id']
                row['item_id'] = key(primary, identity)
            moved.append(row)
        if name == 'learning_profiles':
            profiles = [r for r in rows if r.get('user_id') == primary]
            target = primary_rows[0] if primary_rows else profiles[0] if profiles else None
            if target:
                # Primary comes first for settings; newer measured point wins on duplicate IDs.
                value = target['value']
                for field in ('evidence', 'history'):
                    value[field] = unique([x for p in profiles for x in p['value'].get(field, [])])
                points = {}
                for p in profiles:
                    for point in p['value'].get('mastery', []):
                        key = point['knowledgePointId']
                        if key not in points or point.get('lastUpdated', '') > points[key].get('lastUpdated', ''):
                            points[key] = point
                value['mastery'] = list(points.values())
                value['profileVersion'] = max(p['value'].get('profileVersion', 0) for p in profiles) + 1
                value['targetCourses'] = list(dict.fromkeys(c for p in profiles for c in p['value'].get('targetCourses', [])))
                for field in ('courseExams', 'courseGoals', 'courseOutlines'):
                    for p in profiles:
                        for k, v in (p['value'].get(field) or {}).items():
                            value.setdefault(field, {}).setdefault(k, v)
                work[name] = [r for r in rows if r.get('user_id') != primary] + [target]
        if name == 'plans':
            plans = [r for r in rows if r.get('user_id') == primary]
            if plans:
                target = max(primary_rows, key=lambda r: r['value'].get('version', 0)) if primary_rows else plans[0]
                value = target['value']
                tasks = {}
                for p in plans:
                    for task in p['value'].get('tasks', []) + p['value'].get('unscheduledTasks', []):
                        if task['taskId'] in tasks and tasks[task['taskId']] != task:
                            raise ValueError('Plan task ID collision; explicit resolution required')
                        tasks[task['taskId']] = task
                value.update(tasks=list(tasks.values()), unscheduledTasks=[],
                    version=max(p['value'].get('version', 0) for p in plans) + 1,
                    reason='按用户指定主账号合并历史学习计划，保留全部任务')
                total = sum(t.get('durationMinutes', 0) for t in tasks.values() if t.get('status') != 'completed')
                value['constraints'] = dict(value.get('constraints') or {}, availableMinutes=total)
                value['budgetSummary'] = dict(availableMinutes=total, scheduledMinutes=total, unallocatedMinutes=0, unscheduledMinutes=0)
                work[name] = [r for r in rows if r.get('user_id') != primary] + [target]
        if name == 'chat_messages':
            affected = sorted((r for r in rows if r.get('user_id') == primary), key=lambda r: (str(r['created_at']), r['item_id']))
            for sequence, row in enumerate(affected, 1):
                row['sequence'] = sequence
                row['value']['sequence'] = sequence
        if name == 'chat_sessions':
            affected = [r for r in rows if r.get('user_id') == primary]
            if affected:
                target = primary_rows[0] if primary_rows else affected[0]
                target['item_id'] = primary
                target['value']['sequence'] = counts['chat_messages']
                work[name] = [r for r in rows if r.get('user_id') != primary] + [target]
        if name == 'compatibility_records':
            states = [r for r in rows if r.get('collection') == 'learning_sync_state' and r.get('user_id') == primary]
            if states:
                target = next((r for r in primary_rows if r.get('collection') == 'learning_sync_state'), states[0])
                target['value']['version'] = max(r['value'].get('version', 0) for r in states) + 1
                work[name] = [r for r in rows if r not in states] + [target]
            from app.services.learning_context import chat_workflow_id
            for row in work[name]:
                if row.get('collection') == 'chat_goal_links' and row.get('user_id') == primary:
                    row['item_id'] = chat_workflow_id(primary, row['value']['chatSessionId'])
        identities = [(r.get('collection'), r['item_id']) for r in work[name]]
        if len(identities) != len(set(identities)):
            duplicates = [key for key, n in Counter(identities).items() if n > 1]
            fields = [sorted(r['value']) for r in work[name] if (r.get('collection'), r['item_id']) in duplicates]
            raise ValueError('Unresolved key collision in ' + name + ': ' + str(duplicates) + ' fields=' + str(fields))
    if not apply:
        print('Dry-run OK. No remote rows changed.')
        return
    backup.parent.mkdir(parents=True, exist_ok=True)
    if backup.exists():
        raise ValueError('Backup already exists; choose a new file')
    # Full affected database snapshot includes credentials: keep in ignored local storage.
    payload = dict(report=report, before=before, afterDigest=digest(work))
    backup.write_text(json.dumps(payload, default=str, ensure_ascii=False, indent=2), encoding='utf-8')
    def identity(row):
        return (row.get('collection'), row['item_id'])
    for t in reversed(tables):
        retained = {identity(r): r for r in work[t.name]}
        for row in before[t.name]:
            if retained.get(identity(row)) != row:
                condition = t.c.item_id == row['item_id']
                if 'collection' in t.c:
                    condition = condition & (t.c.collection == row['collection'])
                conn.execute(delete(t).where(condition))
    for t in tables:
        old = {identity(r): r for r in before[t.name]}
        additions = [r for r in work[t.name] if old.get(identity(r)) != r]
        if additions:
            conn.execute(insert(t), additions)
    audit = metadata.tables['compatibility_records']
    stamp = datetime.now(timezone.utc)
    record = dict(userId=primary, sourceUserIds=sorted(sources), mergedAt=stamp.isoformat(),
                  beforeCounts=counts, originals=json.loads(json.dumps(archived, default=str)), backupDigest=digest(before))
    conn.execute(insert(audit).values(collection='account_merge_log', item_id='merge-' + stamp.strftime('%Y%m%d%H%M%S'),
        user_id=primary, status='completed', version=1, created_at=stamp, updated_at=stamp, value=record))
    for name in ('chat_messages', 'focus_sessions', 'file_objects', 'workflows', 'evidences'):
        actual = conn.execute(select(metadata.tables[name].c.user_id)).scalars().all()
        if actual.count(primary) != counts[name]:
            raise ValueError('Post-migration count mismatch: ' + name)
    after = {t.name: [dict(r) for r in conn.execute(select(t).order_by(*t.primary_key.columns)).mappings()] for t in tables}
    payload['afterDigest'] = digest(after)
    backup.write_text(json.dumps(payload, default=str, ensure_ascii=False, indent=2), encoding='utf-8')
    print('Migration and count verification completed; old sessions revoked. Backup: ' + str(backup))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--primary')
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--rollback', type=Path)
    parser.add_argument('--backup', type=Path, default=ROOT/'.local-work/account-backup-20261031.json')
    args=parser.parse_args()
    load_dotenv(ROOT/'server/zhixue-agent-server/.env')
    engine=create_engine(os.environ['DATABASE_URL'], connect_args={'connect_timeout': 5})
    metadata=MetaData(); metadata.reflect(engine)
    with engine.begin() as conn:
        if args.rollback:
            payload=json.loads(args.rollback.read_text(encoding='utf-8'))
            tables=[t for t in metadata.sorted_tables if t.name in payload['before']]
            conn.execute(text('LOCK TABLE ' + ','.join('"'+t.name+'"' for t in tables) + ' IN EXCLUSIVE MODE'))
            current={t.name: [dict(r) for r in conn.execute(select(t).order_by(*t.primary_key.columns)).mappings()] for t in tables}
            if digest(current) != payload['afterDigest']:
                raise ValueError('Database changed after migration; rollback requires manual review')
            if not args.apply:
                print('Rollback dry-run OK. Add --apply to restore the snapshot after Alembic downgrade.')
                return
            for t in reversed(tables):
                conn.execute(delete(t))
            from sqlalchemy import DateTime
            for t in tables:
                rows=payload['before'][t.name]
                for row in rows:
                    for c in t.c:
                        if isinstance(c.type, DateTime) and isinstance(row.get(c.name), str):
                            row[c.name]=datetime.fromisoformat(row[c.name])
                if rows:
                    conn.execute(insert(t), rows)
            print('Snapshot restored transactionally.')
        elif args.primary:
            migrate(conn, metadata, args.primary, args.backup, args.apply)
        else:
            parser.error('--primary or --rollback is required')

if __name__ == '__main__':
    main()
