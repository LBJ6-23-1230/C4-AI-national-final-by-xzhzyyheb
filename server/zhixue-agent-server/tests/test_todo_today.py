from copy import deepcopy
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

import pytest
from app import create_app

URL = '/api/v1/plans/current/today-items'


@pytest.fixture
def setup(tmp_path):
    app = create_app(tmp_path / 'todo.json')
    client = app.test_client()
    identities = []
    for i in range(2):
        result = client.post('/api/v1/auth/register', json=dict(phone=f'1380044660{i}',
            nickname='今日复习测试', password='test-pw-123456', seedDemoData=False)).get_json()
        identities.append((result['user']['userId'], {'Authorization': 'Bearer ' + result['token']}))
    repo = app.extensions['repository']
    owner = identities[0][0]
    day = datetime.now(ZoneInfo('Asia/Shanghai')).date()
    repo.save('profiles', owner, dict(userId=owner, profileVersion=1, goal='复习课程',
        mastery=[dict(knowledgePointId='linked', knowledgePointName='线性表与链表', sourceCourse='数据结构', masteryScore=40)],
        evidence=[dict(id='e-one', knowledgePointId='linked', sourceType='assessment')],
        history=[], courseExams={'数据结构': (day + timedelta(days=6)).isoformat()}))
    return client, repo, identities, day


def exam(client, headers):
    return next(e for e in client.get('/api/v1/today', headers=headers).get_json()['allTasks'] if e['kind'] == 'exam')


def test_review_can_join_without_existing_plan_and_survives_replan(setup):
    client, repo, identities, day = setup
    owner, headers = identities[0]
    item = exam(client, headers)
    payload = dict(eventId=item['eventId'], expectedPlanVersion=0, availableMinutes=10)
    response = client.post(URL, headers=headers, json=payload)
    assert response.status_code == 200
    plan = response.get_json()
    assert len(plan['tasks']) == 1
    task = plan['tasks'][0]
    assert task['sourceCourse'] == '数据结构' and task['knowledgePointId'] == 'linked'
    assert task['scheduledDate'] == day.isoformat() and task['durationMinutes'] == 10
    # Both double taps and lost-response retries return the same single task.
    assert client.post(URL, headers=headers, json=payload).get_json() == plan
    plan['tasks'] = []
    repo.save('plans', plan['planId'], plan)
    restored = client.get('/api/v1/plans/current', headers=headers).get_json()
    assert restored['tasks'][0]['knowledgePointId'] == 'linked'
    assert restored['tasks'][0]['steps'] == task['steps']
    assert repo.query('study_tasks', {'userId': owner})[0]['taskId'] == task['taskId']


def test_budget_confirmation_keeps_future_dates_and_no_partial_writes(setup):
    client, repo, identities, day = setup
    owner, headers = identities[0]
    future = (day + timedelta(days=1)).isoformat()
    base = dict(planId='test-plan', userId=owner, version=1, generatedFromProfileVersion=1,
        tasks=[dict(taskId='current', knowledgePointId='other', knowledgePointName='已有任务', durationMinutes=20, status='pending', scheduledDate=day.isoformat()),
               dict(taskId='future', knowledgePointId='future', knowledgePointName='明日任务', durationMinutes=30, status='pending', scheduledDate=future)],
        unscheduledTasks=[], constraints=dict(availableMinutes=20),
        budgetSummary=dict(availableMinutes=20, scheduledMinutes=20, unallocatedMinutes=0, unscheduledMinutes=0),
        calendarDays=[dict(date=day.isoformat(), minutes=20, scheduledMinutes=20), dict(date=future, minutes=30, scheduledMinutes=30)])
    repo.save('plans', base['planId'], base)
    item = exam(client, headers)
    payload = dict(eventId=item['eventId'], expectedPlanVersion=1, availableMinutes=20)
    assert client.post(URL, headers=headers, json=payload).status_code == 409
    assert repo.get('plans', base['planId']) == base and not repo.query('study_tasks', {'userId': owner})
    payload['availableMinutes'] = 30
    changed = client.post(URL, headers=headers, json=payload).get_json()
    assert changed['budgetSummary']['scheduledMinutes'] == 30
    assert next(t for t in changed['tasks'] if t['taskId'] == 'future')['scheduledDate'] == future
    assert changed['calendarDays'][1] == base['calendarDays'][1]


def test_existing_backlog_moves_to_today_and_existing_today_is_not_duplicated(setup):
    client, repo, identities, day = setup
    owner, headers = identities[0]
    task = dict(taskId='backlog', knowledgePointId='linked', knowledgePointName='巩固链表', sourceCourse='数据结构',
        source='assessment', durationMinutes=15, status='pending', deferredReason='待安排', priority='high',
        dueDate=(day + timedelta(days=4)).isoformat(), steps=['核对错题'])
    repo.save('plans', 'test-plan', dict(planId='test-plan', userId=owner, version=1,
        generatedFromProfileVersion=1, tasks=[], unscheduledTasks=[task]))
    item = exam(client, headers)
    response = client.post(URL, headers=headers, json=dict(eventId=item['eventId'], expectedPlanVersion=1, availableMinutes=15))
    assert response.status_code == 200
    plan = response.get_json()
    assert len(plan['tasks']) == 1 and not plan['unscheduledTasks']
    assert plan['tasks'][0]['taskId'] == 'backlog' and plan['tasks'][0]['durationMinutes'] == 15
    loaded = client.get('/api/v1/plans/current', headers=headers).get_json()
    assert loaded['tasks'][0]['dueDate'] == task['dueDate'] and loaded['tasks'][0]['priority'] == 'high'
    assert loaded['tasks'][0]['steps'] == task['steps']
    plan_event = next(e for e in client.get('/api/v1/today', headers=headers).get_json()['allTasks'] if e['kind'] == 'task')
    duplicate = client.post(URL, headers=headers, json=dict(eventId=plan_event['eventId'], expectedPlanVersion=0, availableMinutes=15)).get_json()
    assert len(duplicate['tasks']) == 1


def test_permissions_stale_events_and_plan_versions(setup):
    client, repo, identities, _ = setup
    owner, headers = identities[0]
    item = exam(client, headers)
    payload = dict(eventId=item['eventId'], expectedPlanVersion=0, availableMinutes=10)
    assert client.post(URL, json=payload).status_code == 401
    assert client.post(URL, headers=identities[1][1], json=payload).status_code == 404
    assert client.post(URL, headers=headers, json=dict(payload, expectedPlanVersion=True)).status_code == 400
    assert client.post(URL, headers=headers, json=dict(payload, expectedPlanVersion=9)).status_code == 409
    assert not repo.query('plans', {'userId': owner})
    profile = repo.get('profiles', owner)
    profile['mastery'][0]['masteryScore'] = 90
    repo.save('profiles', owner, profile)
    assert client.post(URL, headers=headers, json=payload).status_code == 409


def test_matching_review_already_planned_is_not_created_again(setup):
    client, repo, identities, day = setup
    owner, headers = identities[0]
    task = dict(taskId='known', knowledgePointId='linked', knowledgePointName='巩固链表', sourceCourse='数据结构',
        durationMinutes=15, status='pending', scheduledDate=day.isoformat())
    plan = dict(planId='test-plan', userId=owner, version=1, generatedFromProfileVersion=1, tasks=[task], unscheduledTasks=[])
    repo.save('plans', 'test-plan', plan)
    item = exam(client, headers)
    response = client.post(URL, headers=headers, json=dict(eventId=item['eventId'], expectedPlanVersion=1, availableMinutes=15))
    assert response.get_json() == plan
    assert not repo.query('study_tasks', {'userId': owner})


def test_commit_failure_is_atomic(setup, monkeypatch):
    client, repo, identities, _ = setup
    owner, headers = identities[0]
    item = exam(client, headers)
    original = repo.apply_batch
    def fail(deletes, saves):
        if any(collection == 'plans' for collection, _, _ in saves):
            raise OSError('simulated storage failure')
        return original(deletes, saves)
    monkeypatch.setattr(repo, 'apply_batch', fail)
    assert client.post(URL, headers=headers, json=dict(eventId=item['eventId'], expectedPlanVersion=0, availableMinutes=10)).status_code == 500
    assert not repo.query('plans', {'userId': owner}) and not repo.query('study_tasks', {'userId': owner})
