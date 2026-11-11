"""Regressions for the Nov 1 document: manual matching, retries and honest planning."""
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo
import json
from copy import deepcopy

import pytest
from app import create_app
from app.services import review_actions
from app.services.calendar_plan import schedule
from app.services.learning_effect import projected_mastery
from app.services.subject_classification import normalized_mastery


@pytest.fixture
def setup(tmp_path):
    app = create_app(tmp_path / 'feedback.json')
    return app.test_client(), app.extensions['repository']


def point(index='p', name='量子信息的自定义概念', course=''):
    return dict(knowledgePointId=index, knowledgePointName=name, sourceCourse=course,
                masteryScore=0, confidence=0, lastUpdated='2026-11-01T00:00:00Z')


def test_missing_classification_is_retained_without_fake_categories(setup):
    _, repo = setup
    rows = normalized_mastery(dict(mastery=[point(), point('os', '宏内核与微内核的特性对比')]))
    result = projected_mastery(repo, 'demo-user', rows)
    assert len(result) == 2 and result[0]['classificationRequired']
    assert result[0]['sourceCourse'] == result[0]['topicGroup'] == ''
    assert result[1]['sourceCourse'] == '操作系统'
    assert result[1]['topicGroupName'] == '操作系统内核'


def test_manual_match_is_versioned_and_survives_projection_without_rewriting_answers(setup):
    c, repo = setup
    profile = repo.get('profiles', 'demo-user')
    profile['mastery'].append(point())
    repo.save('profiles', 'demo-user', profile)
    payload = dict(knowledgePointId='p', courseName='自定义课程', topicName='量子信息', expectedProfileVersion=profile['profileVersion'])
    response = c.put('/api/v1/profile/demo-user/knowledge-points/classification', json=payload)
    assert response.status_code == 200
    matched = next(p for p in response.json['mastery'] if p['knowledgePointId'] == 'p')
    assert matched['sourceCourse'] == '自定义课程' and matched['topicGroupName'] == '量子信息'
    assert not matched['classificationRequired'] and matched['effectiveQuestionCount'] == 0
    assert c.put('/api/v1/profile/demo-user/knowledge-points/classification', json=payload).status_code == 409
    assert c.put('/api/v1/profile/another-user/knowledge-points/classification', json=payload).status_code in (401, 404)


def test_manual_match_refuses_placeholder_and_nonexistent_points(setup):
    c, repo = setup
    version = repo.get('profiles', 'demo-user')['profileVersion']
    payload = dict(knowledgePointId='missing', courseName='操作系统', topicName='内核结构', expectedProfileVersion=version)
    assert c.put('/api/v1/profile/demo-user/knowledge-points/classification', json=payload).status_code == 404
    payload['courseName'] = '待确认科目'
    assert c.put('/api/v1/profile/demo-user/knowledge-points/classification', json=payload).status_code == 400


def test_model_can_choose_fourth_measured_point(monkeypatch):
    snapshot = dict(measuredPoints=[point(str(i), '知识点'+str(i), '数据结构') for i in range(4)],
                    daysUntilExam=3, evidenceCount=1, evidence=[])
    action = dict(actionId='a', title='巩固第四项', why='模型不能覆盖服务器依据', durationMinutes=20,
                  steps=['完成第四项的新题并核对错题'], doneWhen='已提交并核对解析', priority='high',
                  targetPage='untrusted-page', knowledgePointId='3')
    monkeypatch.setattr(review_actions, 'configuration', lambda: ('configured', ''))
    monkeypatch.setattr(review_actions, 'bounded', lambda *args: json.dumps(dict(conclusion='先巩固第四项', actions=[action])))
    result, source, reason = review_actions.generate(snapshot)
    assert source == 'model' and reason == ''
    assert result['actions'][0]['targetPage'] == 'pages/ExercisePractice'
    assert result['actions'][0]['why'] != action['why']


@pytest.mark.parametrize('error,code', [(TimeoutError(), 'timeout'), ('not json', 'invalid_json'), ('{}', 'invalid_structure')])
def test_model_failures_have_specific_diagnostics_and_executable_fallback(monkeypatch, error, code):
    monkeypatch.setattr(review_actions, 'configuration', lambda: ('configured', ''))
    def respond(*args):
        if isinstance(error, Exception): raise error
        return error
    monkeypatch.setattr(review_actions, 'bounded', respond)
    result, source, reason = review_actions.generate(dict(measuredPoints=[point()], daysUntilExam=None, evidenceCount=1, evidence=[]))
    assert source == 'rules' and result['failureCode'] == code
    assert '重新生成' in reason and result['actions'][0]['steps']


def test_failed_review_does_not_poison_cache_and_retry_refreshes_success(setup, monkeypatch):
    c, repo = setup
    calls = []
    def generate(snapshot):
        calls.append(1)
        result = dict(conclusion='建议', evidenceSummary=[], examMode='normal', sourceFacts=[],
                      failureCode='timeout' if len(calls) == 1 else '', actions=[dict(actionId='a', title='诊断',
                      why='证据', durationMinutes=15, steps=['做题'], doneWhen='已提交', priority='high',
                      targetPage='pages/ExercisePractice', knowledgePointId='')])
        return result, 'rules' if len(calls) == 1 else 'model', '超时' if len(calls) == 1 else ''
    monkeypatch.setattr(review_actions, 'generate', generate)
    payload = dict(courseName='数据结构')
    first = c.post('/api/v1/learning-reviews', json=payload).json
    second = c.post('/api/v1/learning-reviews', json=payload).json
    assert first['source'] == 'rules' and second['source'] == 'model' and len(calls) == 2
    assert c.post('/api/v1/learning-reviews', json=payload).json['reviewId'] == second['reviewId']
    assert len(calls) == 2
    assert c.post('/api/v1/learning-reviews', json=dict(payload, retry=True)).json['source'] == 'model'
    assert len(calls) == 3
    assert c.post('/api/v1/learning-reviews/'+first['reviewId']+'/accept').status_code == 200


def test_calendar_respects_daily_capacity_deadlines_and_keeps_long_tasks():
    today = datetime.now(ZoneInfo('Asia/Shanghai')).date()
    days = [dict(date=(today+timedelta(days=i)).isoformat(), minutes=60) for i in range(2)]
    tasks = [dict(taskId='a',knowledgePointId='a',knowledgePointName='作业A',durationMinutes=50,status='pending',dueDate=days[0]['date']),
             dict(taskId='b',knowledgePointId='b',knowledgePointName='作业B',durationMinutes=45,status='pending',dueDate=days[1]['date']),
             dict(taskId='long',knowledgePointId='long',knowledgePointName='长作业',durationMinutes=90,status='pending')]
    plan = dict(tasks=tasks,version=1)
    original = deepcopy(plan)
    result = schedule(plan, days)
    assert plan == original
    assert [t['scheduledDate'] for t in result['tasks']] == [d['date'] for d in days]
    assert result['unscheduledTasks'][0]['taskId'] == 'long'
    assert '拆成明确步骤' in result['unscheduledTasks'][0]['deferredReason']
    assert all(d['scheduledMinutes'] <= d['minutes'] for d in result['calendarDays'])
    assert sum(t['durationMinutes'] for t in result['tasks']+result['unscheduledTasks']) == 185


def test_calendar_fills_remaining_time_with_priority_course_practice():
    today = datetime.now(ZoneInfo('Asia/Shanghai')).date().isoformat()
    deadline = dict(taskId='assignment', knowledgePointId='assignment', knowledgePointName='到期作业',
                    source='ddl', dueDate=today, durationMinutes=30, status='pending')
    points = [dict(knowledgePointId='other', knowledgePointName='图', sourceCourse='数据结构', masteryScore=10),
              dict(knowledgePointId='priority', knowledgePointName='分页', sourceCourse='操作系统', masteryScore=40)]
    days = [dict(date=today, minutes=45)]
    plan = schedule(dict(tasks=[deadline], candidatePool=points), days, '操作系统')
    assert [(task['knowledgePointId'], task['scheduledDate']) for task in plan['tasks']] == [
        ('assignment', today), ('priority', today)]
    assert plan['calendarDays'][0]['scheduledMinutes'] == 45
    assert [point['knowledgePointId'] for point in plan['candidatePool']] == ['other']
    assert len(schedule(plan, days, '操作系统')['tasks']) == 2


def test_calendar_route_version_guard_and_real_dates(setup):
    c, _ = setup
    current = c.get('/api/v1/plans/current').json
    today = datetime.now(ZoneInfo('Asia/Shanghai')).date().isoformat()
    payload = dict(expectedPlanVersion=current['version'],days=[dict(date=today,minutes=0)])
    response = c.post('/api/v1/plans/current/calendar',json=payload)
    assert response.status_code == 200 and response.json['calendarDays'][0]['scheduledMinutes'] == 0
    assert c.post('/api/v1/plans/current/calendar',json=payload).status_code == 409


def test_assessment_action_enters_shared_backlog_once_without_extending_budget(setup):
    c, repo = setup
    profile = repo.get('profiles', 'demo-user')
    profile['mastery'].append(point('improve-me', '二叉树遍历', '数据结构'))
    repo.save('profiles', 'demo-user', profile)
    before = c.get('/api/v1/plans/current').json
    for _ in range(2):
        response = c.post('/api/v1/plans/current/recommendation', json=dict(knowledgePointId='improve-me'))
        assert response.status_code == 200
    tasks = [t for t in response.json['unscheduledTasks'] if t.get('source') == 'assessment']
    assert len(tasks) == 1 and tasks[0]['durationMinutes'] == 15 and tasks[0]['knowledgePointId'] == 'improve-me'
    assert response.json.get('constraints') == before.get('constraints')
    assert c.post('/api/v1/plans/current/recommendation', json=dict(knowledgePointId='foreign-point')).status_code == 404


def test_assessment_replan_keeps_confirmed_daily_budgets_and_completed_work():
    from app.agents.planner import PlannerAgent
    today = datetime.now(ZoneInfo('Asia/Shanghai')).date()
    days = [dict(date=(today+timedelta(days=i)).isoformat(),minutes=60) for i in range(2)]
    plan = dict(planId='p',version=1,tasks=[
        dict(taskId='done',knowledgePointId='done',knowledgePointName='已完成',durationMinutes=15,status='completed'),
        dict(taskId='weak',knowledgePointId='weak',knowledgePointName='薄弱项',durationMinutes=30,status='pending'),
        dict(taskId='other',knowledgePointId='other',knowledgePointName='另一项',durationMinutes=45,status='pending')])
    original = schedule(plan, days)
    result = PlannerAgent().run(dict(plan=original,needReplan=True,
        replanState=dict(knowledgePointId='weak',masteryScore=20,assessmentScore=20,repeatedError=True))).output['plan']
    assert [d['minutes'] for d in result['calendarDays']] == [60,60]
    assert all(d['scheduledMinutes'] <= d['minutes'] for d in result['calendarDays'])
    assert next(t for t in result['tasks'] if t['taskId']=='done')['status']=='completed'


def test_split_assignment_conserves_work_and_sync_does_not_restore_parent(setup):
    from app.services.assignment_plan import reconcile
    c, repo = setup
    plan = c.get('/api/v1/plans/current').json
    parent = dict(taskId='long-ddl',knowledgePointId='ddl:long-ddl',knowledgePointName='实验报告',sourceCourse='操作系统',
                  source='ddl',durationMinutes=90,status='pending',dueDate='2026-11-06')
    plan.setdefault('unscheduledTasks', []).append(parent)
    repo.save('plans', plan['planId'], plan)
    payload = dict(taskId=parent['taskId'],expectedPlanVersion=plan['version'],steps=[dict(title='完成实现',minutes=60),dict(title='测试并提交报告',minutes=30)])
    response = c.post('/api/v1/plans/current/tasks/split',json=payload)
    assert response.status_code == 200
    current = response.json
    children = [t for t in current['unscheduledTasks'] if t.get('parentTaskId')=='long-ddl']
    assert len(children)==2 and sum(t['durationMinutes'] for t in children)==90
    synced = reconcile(current,[dict(id='long-ddl',title='实验报告',courseName='操作系统',dueDate='2026-11-06',estimatedMinutes=90,completed=False)])
    assert not any(t['taskId']=='long-ddl' for t in synced['tasks']+synced['unscheduledTasks'])
    assert sum(t['durationMinutes'] for t in synced['tasks']+synced['unscheduledTasks'] if t.get('parentTaskId')=='long-ddl')==90
    assert c.post('/api/v1/plans/current/tasks/split',json=payload).status_code==409
    today_items = c.get('/api/v1/today').json['allTasks']
    assert sum(item['objectId']=='long-ddl' for item in today_items)==1
    assert not any(item['objectId'] in {t['taskId'] for t in children} for item in today_items)


def test_week_budget_addition_counts_today_only():
    from app.tools.time_budget import schedule_deferred_task
    today = datetime.now(ZoneInfo('Asia/Shanghai')).date()
    tomorrow = (today+timedelta(days=1)).isoformat()
    plan = dict(tasks=[dict(taskId='future',durationMinutes=120,status='pending',scheduledDate=tomorrow)],
                unscheduledTasks=[dict(taskId='new',durationMinutes=30,status='pending')],
                calendarDays=[dict(date=today.isoformat(),minutes=60),dict(date=tomorrow,minutes=120)])
    result = schedule_deferred_task(plan,'new')
    assert result['budgetSummary']['availableMinutes']==60
    assert result['budgetSummary']['scheduledMinutes']==30
    assert result['tasks'][0]['scheduledDate']==tomorrow


def test_parent_assignment_completes_only_after_every_confirmed_step(setup):
    from app.services.learning_data import snapshot, key
    _, repo = setup
    repo.save('assignments', key('demo-user', 'parent'), dict(userId='demo-user', version=1,
        data=dict(id='parent',title='作业',courseName='数据结构',dueDate='2026-11-06',estimatedMinutes=90,completed=False)))
    plan = dict(planId='split-proof',userId='demo-user',version=1,tasks=[
        dict(taskId='one',status='completed'),dict(taskId='two',status='pending')],
        taskDecompositions={'parent':dict(original=dict(source='ddl'),childIds=['one','two'])})
    repo.save('plans', plan['planId'], plan)
    assert not next(r for r in snapshot(repo,'demo-user')['homeworkDDLs'] if r['id']=='parent')['completed']
    plan['tasks'][1]['status']='completed'
    repo.save('plans', plan['planId'], plan)
    assert next(r for r in snapshot(repo,'demo-user')['homeworkDDLs'] if r['id']=='parent')['completed']
