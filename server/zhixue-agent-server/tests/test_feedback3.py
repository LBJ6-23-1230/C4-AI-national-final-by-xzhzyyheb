"""Product regressions: grouped evidence, honest budgets, reminder actions and goal records."""
from copy import deepcopy
from datetime import datetime, timezone
import json
import pytest

from app import create_app
from app.services import topic_groups, review_actions, reminders
from app.tools import surplus_budget
from app.tools.time_budget import fit_plan_to_budget


def test_course_groups_weight_only_effective_answers_and_keep_members(tmp_path):
    repo = create_app(tmp_path/'topics.json').extensions['repository']
    names = ['二叉树先序遍历', '二叉树中序遍历', '二叉树后序遍历', '冒泡排序', '快速排序', '栈的操作', '队列操作', '链表插入']
    points = [dict(knowledgePointId=str(i), knowledgePointName=name, sourceCourse='数据结构',
        recentAccuracy=20 if i == 0 else 80, effectiveQuestionCount=1 if i == 0 else 3) for i, name in enumerate(names)]
    points[2].update(recentAccuracy=None, effectiveQuestionCount=0)
    for point in points:
        point.update(topic_groups.membership(repo, 'owner', point))
    grouped = topic_groups.aggregate(points)
    assert len(grouped) == 4 and sum(g['memberCount'] for g in grouped) == 8
    tree = next(g for g in grouped if g['topicGroupName'] == '树的遍历')
    assert tree['masteryScore'] == 65 and tree['evidenceQuestionCount'] == 4
    assert len(tree['memberPointIds']) == 3 and tree['memberPoints'][2]['masteryScore'] is None
    other = dict(points[0], sourceCourse='算法')
    assert topic_groups.membership(repo, 'owner', other)['topicGroupId'] != tree['topicGroupId']
    assert topic_groups.membership(repo, 'owner', points[0])['topicGroupId'] == tree['topicGroupId']


def plan():
    return dict(tasks=[dict(taskId='ddl', knowledgePointId='ddl:ddl', knowledgePointName='作业', status='pending',
        source='ddl', dueDate='2026-10-31', durationMinutes=30),
        dict(taskId='practice', knowledgePointId='tree', knowledgePointName='树遍历', status='pending',
        allowPartial=True, durationMinutes=30)])


@pytest.mark.parametrize('minutes,mode', [(0, 'under_budget'), (42, 'under_budget'), (60, 'exact_budget'), (90, 'surplus_fallback'), (1440, 'surplus_fallback')])
def test_budget_conservation_priority_cap_and_repeat(monkeypatch, minutes, mode):
    monkeypatch.setattr(surplus_budget, 'configuration', lambda: ('', ''))
    original = plan(); result = fit_plan_to_budget(original, minutes)['plan']; summary = result['budgetSummary']
    assert original == plan()
    assert summary['allocationMode'] == mode
    assert summary['scheduledMinutes'] + summary['unallocatedMinutes'] == minutes
    assert summary['scheduledMinutes'] == sum(t['durationMinutes'] for t in result['tasks'])
    if minutes == 42:
        assert result['tasks'][0]['taskId'] == 'ddl' and result['tasks'][1]['durationMinutes'] == 10
        assert result['unscheduledTasks'][0]['durationMinutes'] == 20
        assert summary['unallocatedMinutes'] == 2
    if minutes > 60:
        assert all(0 <= t['extraMinutes'] <= 60 and t['extraMinutes'] % 5 == 0 for t in result['tasks'])
    assert fit_plan_to_budget(result, minutes)['plan'] == result


@pytest.mark.parametrize('failure', [TimeoutError('timeout'), RuntimeError('429'), RuntimeError('model retired'), 'not-json', '{"allocations":[{"taskId":"other","extraMinutes":30,"reason":"bad"}]}'])
def test_surplus_rejects_bad_model_output_and_conserves(monkeypatch, failure):
    monkeypatch.setattr(surplus_budget, 'configuration', lambda: ('test-key', ''))
    def response(*args):
        if isinstance(failure, Exception): raise failure
        return failure
    monkeypatch.setattr(surplus_budget, 'bounded', response)
    result = fit_plan_to_budget(plan(), 90)['plan']
    assert result['budgetSummary']['allocationMode'] == 'surplus_fallback'
    assert sum(t['durationMinutes'] for t in result['tasks']) == 90
    assert '模型调用失败' in result['budgetSummary']['allocationReason']


def test_valid_model_allocation_is_bound_to_existing_tasks(monkeypatch):
    monkeypatch.setattr(surplus_budget, 'configuration', lambda: ('test-key', ''))
    monkeypatch.setattr(surplus_budget, 'bounded', lambda *args: json.dumps({'allocations': [
        {'taskId': 'ddl', 'extraMinutes': 20, 'reason': '截止近'}, {'taskId': 'practice', 'extraMinutes': 10, 'reason': '巩固'}]}))
    result = fit_plan_to_budget(plan(), 90)['plan']
    assert result['budgetSummary']['allocationMode'] == 'surplus_model'
    assert [t['durationMinutes'] for t in result['tasks']] == [50, 40]


@pytest.fixture
def client(tmp_path):
    app = create_app(tmp_path/'feedback3.json')
    return app.test_client(), app.extensions['repository']


def test_all_reminders_and_open_preserves_state_then_completion_removes(client):
    c, repo = client
    for key in repo.ids('plans'): repo.delete('plans', key)
    tasks = [dict(taskId='ddl-'+str(i), source='ddl', knowledgePointId='ddl:'+str(i), knowledgePointName='作业'+str(i),
        durationMinutes=30, dueDate=datetime.now(timezone.utc).date().isoformat(), status='pending') for i in range(6)]
    repo.save('plans', 'six', dict(planId='six', userId='demo-user', version=1, tasks=tasks))
    today = c.get('/api/v1/today').get_json()
    assert len(today['allTasks']) == 6 and today['pendingCount'] == 6
    item = today['allTasks'][0]
    assert item['targetPage'] == 'pages/CourseImport' and item['sourceType'] == 'ddl'
    response = c.post('/api/v1/reminders/'+item['eventId']+'/actions', json=dict(action='open', version=item['version'], idempotencyKey='open'))
    assert response.status_code == 200 and response.get_json()['event']['status'] == item['status']
    assert repo.get('plans', 'six')['tasks'] == tasks and repo.list('focus_sessions') == []
    current = repo.get('plans', 'six'); next(t for t in current['tasks'] if t['taskId'] == item['sourceId'])['status'] = 'completed'
    current['version'] += 1; repo.save('plans', 'six', current)
    assert c.get('/api/v1/today').get_json()['pendingCount'] == 5


@pytest.mark.parametrize('minutes,code', [(5,200),(45,200),(1440,200),(0,400),(6,400),(1445,400),(True,400),('30',400)])
def test_snooze_limits_and_custom_minutes(client, minutes, code):
    c, repo = client
    item = c.get('/api/v1/today').get_json()['highlight']
    response = c.post('/api/v1/reminders/'+item['eventId']+'/actions', json=dict(action='snooze', minutes=minutes, version=item['version'], idempotencyKey='delay'))
    assert response.status_code == code
    if code == 200:
        assert response.get_json()['event']['status'] == 'snoozed'
        assert response.get_json()['event']['snoozedUntil']


def test_learning_records_scopes_cursor_status_and_restart(client, monkeypatch):
    from app.agent import chat_llm
    c, repo = client
    monkeypatch.setattr(chat_llm, 'chat', lambda **kw: dict(reply='继续学习', intent='get_suggestion', card=None, llmUsed=False))
    auth = []
    for phone in ('13900006001', '13900006002'):
        body = c.post('/api/v1/auth/register', json=dict(phone=phone,password='test-password',seedDemoData=True)).get_json()
        auth.append({'Authorization':'Bearer '+body['token']})
    assert c.get('/api/v1/learning-records').status_code == 401
    for chat in ('chat-a', 'chat-b', 'chat-c'):
        response = c.post('/api/agent/chat',headers=auth[0],json=dict(message='帮我按薄弱点安排复习并诊断',sessionId=chat,coordinateLearning=True))
        assert response.status_code == 200
    page = c.get('/api/v1/learning-records?limit=2',headers=auth[0]).get_json()
    assert len(page['records']) == 2 and page['nextCursor']
    next_page = c.get('/api/v1/learning-records?limit=2&cursor='+page['nextCursor'],headers=auth[0]).get_json()
    assert len(next_page['records']) == 1 and not next_page['nextCursor']
    assert set(x['goalId'] for x in page['records']).isdisjoint(x['goalId'] for x in next_page['records'])
    assert len(c.get('/api/v1/learning-records?chatSessionId=chat-a',headers=auth[0]).get_json()['records']) == 1
    assert c.get('/api/v1/learning-records',headers=auth[1]).get_json()['records'] == []
    restored = create_app(repo.path).test_client()
    assert len(restored.get('/api/v1/learning-records',headers=auth[0]).get_json()['records']) == 3
    for query in ('limit=0', 'cursor=!bad', 'status=deleted'):
        assert c.get('/api/v1/learning-records?'+query,headers=auth[0]).status_code == 400


@pytest.mark.parametrize('value', [[], '', 0, False])
def test_proactive_rejects_falsy_non_objects(client, value):
    assert client[0].post('/api/v1/agent/proactive',json=value).status_code == 400


@pytest.mark.parametrize('failure', [TimeoutError('timeout'),RuntimeError('429'),RuntimeError('model retired'),'not-json'])
def test_review_model_failure_remains_executable_and_honest(monkeypatch, failure):
    monkeypatch.setattr(review_actions,'configuration',lambda:('test-key',''))
    def response(*args):
        if isinstance(failure,Exception): raise failure
        return failure
    monkeypatch.setattr(review_actions,'bounded',response)
    result,source,reason=review_actions.generate(dict(measuredPoints=[dict(knowledgePointId='tree',knowledgePointName='树遍历',masteryScore=40)],daysUntilExam=3,evidenceCount=1,evidence=[dict(id='e1')]))
    assert source == 'rules' and '模型调用失败' in reason and result['examMode'] == 'near_exam'
    assert result['actions'][0]['steps'] and result['actions'][0]['doneWhen'] and '40' in result['actions'][0]['why']
