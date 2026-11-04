import base64
import pytest
from app import create_app
from app.services.vision_diagnosis import normalize


@pytest.fixture
def accounts(tmp_path):
    app = create_app(tmp_path / 'tasks.json')
    client = app.test_client()
    headers, ids = [], []
    for i in range(3):
        response = client.post('/api/v1/auth/register', json=dict(
            phone=f'1380099770{i}', nickname=f'搭子{i}', password='test-pw-123456', seedDemoData=False))
        assert response.status_code == 201
        data = response.get_json()
        ids.append(data['user']['userId'])
        headers.append({'Authorization': 'Bearer ' + data['token']})
    repo = app.extensions['repository']
    for left, right in ((0, 1), (1, 0)):
        repo.save('contacts', f'{ids[left]}:{ids[right]}', dict(userId=ids[left], partnerUserId=ids[right]))
    return client, repo, headers, ids


def task():
    return dict(title='复习二叉树', courseName='数据结构', scheduledDate='2026-11-04', durationMinutes=30)


def test_manual_edit_delete_version_and_isolation(accounts):
    client, repo, headers, ids = accounts
    payload = dict(task(), taskId='manual-test', expectedPlanVersion=0)
    first = client.post('/api/v1/study-tasks', json=payload, headers=headers[0])
    assert first.status_code == 200
    plan = first.get_json()
    assert plan['tasks'][0]['knowledgePointName'] == payload['title']
    assert client.post('/api/v1/study-tasks', json=payload, headers=headers[1]).status_code == 404
    assert client.post('/api/v1/study-tasks', json=payload, headers=headers[0]).status_code == 409
    payload.update(expectedPlanVersion=plan['version'], durationMinutes=45, scheduledDate='2026-11-05')
    changed = client.post('/api/v1/study-tasks', json=payload, headers=headers[0]).get_json()
    assert changed['tasks'][0]['durationMinutes'] == 45
    assert changed['tasks'][0]['scheduledDate'] == '2026-11-05'
    # Automatic planning must not remove the explicit commitment.
    changed['tasks'] = []
    repo.save('plans', changed['planId'], changed)
    restored = client.get('/api/v1/plans/current', headers=headers[0]).get_json()
    assert restored['tasks'][0]['taskId'] == 'manual-test'
    payload.update(action='delete', expectedPlanVersion=restored['version'])
    deleted = client.post('/api/v1/study-tasks', json=payload, headers=headers[0]).get_json()
    assert not deleted['tasks']
    assert not client.get('/api/v1/plans/current', headers=headers[0]).get_json()['tasks']


def test_shared_consent_two_plans_progress_and_reminder(accounts):
    client, repo, headers, ids = accounts
    url = '/api/v1/shared-study-tasks'
    payload = dict(task(), action='create', taskId='shared-test', partnerId=ids[1], myPart='整理概念', partnerPart='互测三题')
    first = client.post(url, json=payload, headers=headers[0])
    assert first.status_code == 200
    assert client.post(url, json=payload, headers=headers[0]).get_json() == first.get_json()
    assert not repo.query('plans', {'userId': ids[0]})
    assert len(client.get(url, headers=headers[1]).get_json()['tasks']) == 1
    assert client.get(url, headers=headers[2]).get_json()['tasks'] == []
    action = dict(action='accept', taskId='shared-test')
    assert client.post(url, json=action, headers=headers[0]).status_code == 403
    assert client.post(url, json=action, headers=headers[2]).status_code == 404
    assert client.post(url, json=action, headers=headers[1]).status_code == 200
    for header in headers[:2]:
        plan = client.get('/api/v1/plans/current', headers=header).get_json()
        assert len(plan['tasks']) == 1 and plan['tasks'][0]['source'] == 'partner'
    assert client.post(url, json=action, headers=headers[1]).status_code == 200
    action['action'] = 'remind'
    assert client.post(url, json=action, headers=headers[0]).status_code == 200
    assert client.post(url, json=action, headers=headers[0]).status_code == 429
    messages = client.get(f'/api/v1/partners/{ids[0]}/messages', headers=headers[1]).get_json()['messages']
    assert any('提醒一起完成' in m['text'] and '互测三题' in m['text'] for m in messages)
    action['action'] = 'complete'
    complete = client.post(url, json=action, headers=headers[1]).get_json()['tasks'][0]
    assert complete['myStatus'] == 'completed' and complete['partnerStatus'] == 'pending'
    action['action'] = 'remind'
    assert client.post(url, json=action, headers=headers[0]).status_code == 409
    assert client.get('/api/v1/plans/current', headers=headers[1]).get_json()['tasks'][0]['status'] == 'completed'


def test_shared_decline_invalid_and_non_contact(accounts):
    client, repo, headers, ids = accounts
    url = '/api/v1/shared-study-tasks'
    payload = dict(task(), action='create', taskId='shared-decline', partnerId=ids[2], myPart='总结', partnerPart='练习')
    assert client.post(url, json=payload, headers=headers[0]).status_code == 404
    payload['partnerId'] = ids[1]
    payload['durationMinutes'] = True
    assert client.post(url, json=payload, headers=headers[0]).status_code == 400
    payload['durationMinutes'] = 30
    assert client.post(url, json=payload, headers=headers[0]).status_code == 200
    assert client.post(url, json=dict(action='decline', taskId='shared-decline'), headers=headers[1]).status_code == 200
    assert not repo.query('plans', {'userId': ids[0]}) and not repo.query('plans', {'userId': ids[1]})
    assert client.post(url, json=dict(action='accept', taskId='shared-decline'), headers=headers[1]).status_code == 409
    assert client.get(url).status_code == 401


def test_chat_file_parse_and_limits(accounts):
    client, _, headers, _ = accounts
    payload = dict(fileName='笔记.md', contentBase64=base64.b64encode('二叉树遍历：前序为根左右。'.encode()).decode())
    result = client.post('/api/v1/chat-files', json=payload, headers=headers[0])
    assert result.status_code == 200
    assert '根左右' in result.get_json()['text']
    assert client.post('/api/v1/chat-files', json=payload).status_code == 401
    payload['contentBase64'] = 'invalid'
    assert client.post('/api/v1/chat-files', json=payload, headers=headers[0]).status_code == 400


def test_duplicate_page_questions_are_flagged_instead_of_repeated():
    row = dict(questionText='栈和队列的逻辑结构？', readable=True, reply='均为线性结构。')
    _, analysis = normalize(dict(questions=[dict(row, questionNumber='1'), dict(row, questionNumber='2')], questionCount=2, complete=True))
    assert analysis['recognitionStatus'] == 'partial'
    assert analysis['questions'][0]['questionText']
    assert analysis['questions'][1]['questionText'] == ''
    assert '重复' in analysis['questions'][1]['reply']


def test_accept_failure_never_publishes_only_one_plan(accounts, monkeypatch):
    client, repo, headers, ids = accounts
    url = '/api/v1/shared-study-tasks'
    client.post(url, json=dict(task(), action='create', taskId='shared-atomic', partnerId=ids[1],
                             myPart='总结', partnerPart='练习'), headers=headers[0])
    original = repo.apply_batch
    def fail(deletes, saves):
        if any(collection == 'plans' for collection, _, _ in saves):
            raise OSError('simulated disk failure')
        return original(deletes, saves)
    monkeypatch.setattr(repo, 'apply_batch', fail)
    result = client.post(url, json=dict(action='accept', taskId='shared-atomic'), headers=headers[1])
    assert result.status_code == 500
    assert repo.get('shared_study_tasks', 'shared-atomic')['status'] == 'pending'
    assert not repo.query('plans', {'userId': ids[0]})
    assert not repo.query('plans', {'userId': ids[1]})


def test_focus_completion_survives_replan_and_account_deletion(accounts):
    from datetime import datetime, timezone
    client, repo, headers, ids = accounts
    url = '/api/v1/shared-study-tasks'
    client.post(url, json=dict(task(), action='create', taskId='shared-focus', partnerId=ids[1],
                             myPart='总结', partnerPart='练习'), headers=headers[0])
    client.post(url, json=dict(action='accept', taskId='shared-focus'), headers=headers[1])
    session = dict(taskId='focus-shared', planTaskId='shared-focus', course='数据结构', task='总结',
                   plannedMinutes=30, actualMinutes=30, pauseCount=0, interruptionCount=0,
                   completionRate=100, selfAssessment='completed', timerType='countdown',
                   status='completed', endedAt=datetime.now(timezone.utc).isoformat())
    assert client.post('/api/v1/focus-sessions', json=session, headers=headers[0]).status_code == 200
    plan = repo.query('plans', {'userId': ids[0]})[0]
    plan['tasks'] = []
    repo.save('plans', plan['planId'], plan)
    restored = client.get('/api/v1/plans/current', headers=headers[0]).get_json()
    assert restored['tasks'][0]['status'] == 'completed'
    assert client.get(url, headers=headers[1]).get_json()['tasks'][0]['partnerStatus'] == 'completed'
    assert client.delete('/api/v1/auth/account', headers=headers[0]).status_code == 200
    assert not client.get(url, headers=headers[1]).get_json()['tasks']
    assert not client.get('/api/v1/plans/current', headers=headers[1]).get_json()['tasks']


def test_similar_equations_are_not_confused_with_repeated_questions():
    _, analysis = normalize(dict(questions=[dict(questionNumber=str(i), questionText=text, readable=True, reply='计算结果')
        for i, text in enumerate(['1+2等于多少？', '2+2等于多少？', '1.5加2等于多少？'], 1)], questionCount=3, complete=True))
    assert analysis['recognitionStatus'] == 'recognized'
    assert len({q['questionText'] for q in analysis['questions']}) == 3
