"""Observable practice performance; never equate attendance with learning."""
from collections import defaultdict
from datetime import datetime, timedelta, timezone
import hashlib
import re
from zoneinfo import ZoneInfo

RULE_VERSION = 'practice-evidence-v1'


def timestamp(raw):
    try:
        stamp = datetime.fromisoformat(str(raw).replace('Z', '+00:00'))
        return stamp if stamp.tzinfo else None
    except (ValueError, TypeError):
        return None


def question_facts(questions, correct_ids):
    facts = []
    for q in questions:
        stem = re.sub(r'\s+', '', q.get('stem', '')).casefold()
        if not stem:
            continue
        facts.append(dict(knowledgePointId=q.get('knowledgePointId', ''), exerciseId=q['exerciseId'],
            fingerprint=hashlib.sha256(stem.encode()).hexdigest(), correct=q['exerciseId'] in correct_ids,
            difficulty=q.get('difficulty', 'unknown'), assisted=False))
    return facts


def topic(name):
    groups = [('二叉树', '二叉树'), ('栈', '栈'), ('队列', '队列'), ('链表', '链表'),
              ('排序', '排序'), ('图算法', '图'), ('最短路径', '图'), ('死锁', '死锁'), ('进程', '进程')]
    return next((group for term, group in groups if term in name), '其他知识点')


def statistics(repo, owner, now=None):
    now = now or datetime.now(timezone.utc)
    from app.api.exercises import _EXERCISE_BANK
    bank = {q['exerciseId']: q for q in _EXERCISE_BANK}
    bank.update({q['exerciseId']: q for q in repo.query('exercises', {'userId': owner}) if q.get('exerciseId')})
    submissions = sorted(repo.query('submissions', {'userId': owner}), key=lambda r: r.get('createdAt', ''))
    seen, attempts, rounds = set(), defaultdict(list), defaultdict(list)
    for record in submissions:
        stamp = timestamp(record.get('createdAt'))
        if stamp is None or stamp > now:
            continue
        facts = record.get('questionFacts')
        if facts is None:
            reviews = record.get('response', {}).get('review', [])
            facts = question_facts([bank[r['exerciseId']] for r in reviews if r.get('exerciseId') in bank],
                {r['exerciseId'] for r in reviews if r.get('correct') is True})
        by_point = defaultdict(list)
        for fact in facts:
            fingerprint, point = fact.get('fingerprint'), fact.get('knowledgePointId')
            if not fingerprint or not point:
                continue
            identity = (point, fingerprint)
            repeated = identity in seen
            seen.add(identity)
            if repeated or fact.get('assisted') or type(fact.get('correct')) is not bool:
                continue
            item = dict(fact, timestamp=stamp, submissionId=record.get('idempotencyKey', record.get('createdAt')))
            attempts[point].append(item)
            by_point[point].append(item)
        for point, items in by_point.items():
            rounds[point].append(dict(timestamp=stamp, count=len(items),
                correct=sum(i['correct'] for i in items),
                difficulties=sorted(i.get('difficulty', 'unknown') for i in items)))
    result = {}
    for point, all_items in attempts.items():
        recent = all_items[-20:]
        correct = sum(i['correct'] for i in recent)
        accuracy = round(correct / len(recent) * 100)
        point_rounds = rounds[point]
        last = all_items[-1]['timestamp']
        varied = any(i.get('difficulty') == 'easy' for i in recent) and any(i.get('difficulty') in ('medium', 'hard') for i in recent)
        recent_rounds = len({i['submissionId'] for i in recent})
        status = 'evidence_limited' if len(recent) < 8 or recent_rounds < 2 else 'needs_practice'
        if len(recent) >= 8 and recent_rounds >= 2 and varied and accuracy >= 80:
            status = 'stable'
        if now - last >= timedelta(days=7):
            status = 'retest_due'
        baseline = next((r for r in point_rounds if r['count'] >= 3 and 'unknown' not in r['difficulties']), None)
        comparable = [r for r in point_rounds if baseline and r['timestamp'] > baseline['timestamp'] and r['difficulties'] == baseline['difficulties']]
        change = None
        if comparable:
            latest = comparable[-1]
            change = round(100 * latest['correct'] / latest['count'] - 100 * baseline['correct'] / baseline['count'])
        retention = 'not_tested'
        delayed = [r for r in comparable if timedelta(hours=24) <= r['timestamp'] - baseline['timestamp'] <= timedelta(hours=72)]
        if delayed:
            latest = delayed[-1]
            retention = 'preliminary_good' if latest['correct'] / latest['count'] >= .8 else 'needs_review'
        result[point] = dict(assessmentStatus=status, effectiveQuestionCount=len(recent), correctCount=correct,
            recentAccuracy=accuracy, lastAssessedAt=last.isoformat(), assessmentRoundCount=len(point_rounds),
            performanceChange=change, retentionStatus=retention, ruleVersion=RULE_VERSION)
    return result


def projected_mastery(repo, owner, rows, now=None):
    stats = statistics(repo, owner, now)
    from app.services.topic_groups import membership
    return [dict(row, **membership(repo, owner, row), topicGroup=topic(row.get('knowledgePointName', '')),
        **stats.get(row['knowledgePointId'], dict(assessmentStatus='unassessed', effectiveQuestionCount=0,
            correctCount=0, recentAccuracy=None, lastAssessedAt='', assessmentRoundCount=0,
            performanceChange=None, retentionStatus='not_tested', ruleVersion=RULE_VERSION))) for row in rows]


def summary(repo, owner, days=1, now=None):
    now = now or datetime.now(timezone.utc)
    zone = ZoneInfo('Asia/Shanghai')
    start = (now.astimezone(zone).replace(hour=0, minute=0, second=0, microsecond=0) - timedelta(days=days - 1)).astimezone(timezone.utc)
    minutes, sessions = 0., 0
    for record in repo.query('focus_sessions', {'userId': owner}):
        session = record.get('session', {})
        end = timestamp(session.get('endedAt'))
        actual = session.get('actualMinutes', 0)
        if end is None or end > now or not isinstance(actual, (int, float)) or actual <= 0:
            continue
        # Legacy sessions have no active intervals. Attribute by end date rather
        # than inventing an exact midnight split across unknown pauses.
        if start <= end <= now:
            minutes += actual
            sessions += 1
    profile = repo.get('profiles', owner) or {}
    from app.services.subject_classification import normalized_mastery
    points = projected_mastery(repo, owner, normalized_mastery(profile), now)
    period_submissions = [r for r in repo.query('submissions', {'userId': owner})
        if (stamp := timestamp(r.get('createdAt'))) and start <= stamp <= now]
    reviewed = [r for s in period_submissions for r in s.get('response', {}).get('review', []) if type(r.get('correct')) is bool]
    # A frozen planned-task cohort is not recorded by old clients. Avoid an
    # invented task percentage until that denominator exists.
    completed = sum(1 for r in repo.query('focus_sessions', {'userId': owner})
        if r.get('session', {}).get('selfAssessment') == 'completed' and
        (stamp := timestamp(r.get('session', {}).get('endedAt'))) and start <= stamp <= now)
    has_practice = bool(reviewed)
    conclusion = '今天还没有学习记录' if not sessions and not has_practice else '已记录学习投入，完成练习后可验证表现'
    if has_practice:
        conclusion = '已有练习结果，可查看各知识点表现'
    return dict(userId=owner, days=days, timezone='Asia/Shanghai', focusMinutes=round(minutes),
        timeAttribution='专注时长按记录结束日期统计，跨日记录暂不拆分。',
        completedFocusSessions=completed, answeredCount=len(reviewed), correctCount=sum(r['correct'] for r in reviewed),
        practiceAccuracy=round(100 * sum(r['correct'] for r in reviewed) / len(reviewed)) if reviewed else None,
        conclusion=conclusion, points=points, ruleVersion=RULE_VERSION)
