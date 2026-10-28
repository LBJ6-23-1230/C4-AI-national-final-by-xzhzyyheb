import base64
from io import BytesIO

import pytest
import pymupdf

from app import create_app


@pytest.fixture
def setup(tmp_path):
    app = create_app(tmp_path / 'upgrade.json')
    client = app.test_client()
    headers = []
    ids = []
    for index in range(3):
        response = client.post('/api/v1/auth/register', json={
            'nickname': f'协作同学{index}', 'phone': f'1380013880{index}', 'seedDemoData': False})
        assert response.status_code == 201
        data = response.get_json()
        headers.append({'Authorization': 'Bearer ' + data['token']})
        ids.append(data['user']['userId'])
    repository = app.extensions['repository']
    for left, right in [(0, 1), (1, 0)]:
        repository.save('contacts', f'{ids[left]}:{ids[right]}', {
            'userId': ids[left], 'partnerUserId': ids[right], 'pairedAt': '2026-10-28T00:00:00Z'})
    return client, repository, headers, ids


def test_private_messages_retry_and_isolation(setup):
    client, repository, headers, ids = setup
    url = f'/api/v1/partners/{ids[1]}/messages'
    payload = {'clientId': 'retry-1', 'text': '一起学习', 'image': ''}
    first = client.post(url, json=payload, headers=headers[0])
    assert first.status_code == 201
    assert client.post(url, json=payload, headers=headers[0]).get_json() == first.get_json()
    payload['text'] = '不同消息'
    assert client.post(url, json=payload, headers=headers[0]).status_code == 409
    received = client.get(f'/api/v1/partners/{ids[0]}/messages', headers=headers[1]).get_json()
    assert len(received['messages']) == 1
    assert client.get(url, headers=headers[2]).status_code == 404
    assert client.get(url).status_code == 401
    after = received['cursor']
    assert not client.get(url, query_string={'after': after}, headers=headers[0]).get_json()['messages']


def test_image_messages_validated(setup):
    client, _, headers, ids = setup
    url = f'/api/v1/partners/{ids[1]}/messages'
    assert client.post(url, headers=headers[0], json={'clientId': 'bad', 'image': 'invalid'}).status_code == 400
    buffer = BytesIO(pymupdf.Pixmap(pymupdf.csRGB, (0, 0, 2, 2), False).tobytes('png'))
    response = client.post(url, headers=headers[0], json={'clientId': 'image', 'image': base64.b64encode(buffer.getvalue()).decode()})
    assert response.status_code == 201


def test_scanned_question_opt_in_idempotent_and_not_an_error(setup):
    client, repository, headers, ids = setup
    payload = dict(stem='解释栈的后进先出', courseName='数据结构', knowledgePointName='栈', explanation='示例解析')
    for _ in range(2):
        assert client.post('/api/v1/wrong-book/scanned', json=payload, headers=headers[0]).status_code in (200, 201)
    items = client.get('/api/v1/wrong-book', headers=headers[0]).get_json()
    assert items['total'] == 1
    item = items['courses'][0]['items'][0]
    assert item['wrongCount'] == 0
    assert client.get('/api/v1/wrong-book', headers=headers[1]).get_json()['total'] == 0


def test_review_without_evidence_and_task_isolation(setup):
    client, repository, headers, ids = setup
    repository.save('profiles', ids[0], {'userId': ids[0], 'profileVersion': 1, 'mastery': [
        {'knowledgePointId': 'a', 'knowledgePointName': '树', 'sourceCourse': '数据结构', 'masteryScore': 0, 'confidence': 0}]})
    payload = dict(courseName='数据结构')
    response = client.post('/api/v1/learning-reviews', json=payload, headers=headers[0]).get_json()
    assert '缺少有效测评' in response['summary']
    assert response['source'] == 'rules'
    assert response['snapshot']['unassessedCount'] == 1
    assert client.post('/api/v1/learning-reviews', json=payload, headers=headers[0]).get_json()['reviewId'] == response['reviewId']
    url = '/api/v1/learning-reviews/' + response['reviewId'] + '/accept'
    tasks = client.post(url, headers=headers[0]).get_json()['tasks']
    assert len(tasks) == 2
    assert len(client.post(url, headers=headers[0]).get_json()['tasks']) == 2
    assert client.post(url, headers=headers[1]).status_code == 404
    assert client.post('/api/v1/learning-review-tasks/complete', json={'taskId': tasks[0]['taskId']}, headers=headers[1]).status_code == 404
    assert client.post('/api/v1/learning-review-tasks/complete', json={'taskId': tasks[0]['taskId']}, headers=headers[0]).status_code == 200


def test_course_settings_and_scoped_exercises(setup):
    client, repository, headers, ids = setup
    repository.save('profiles', ids[0], {'userId': ids[0], 'profileVersion': 1, 'mastery': [
        {'knowledgePointId': 'binary-tree-postorder', 'knowledgePointName': '二叉树后序遍历',
         'sourceCourse': '数据结构', 'masteryScore': 42, 'confidence': 0.7}]})
    settings = dict(courseName='数据结构', goal='期末复习', examDate='2026-02-30')
    assert client.post('/api/v1/learning-course-settings', headers=headers[0], json=settings).status_code == 400
    from datetime import datetime, timedelta
    from zoneinfo import ZoneInfo
    settings['examDate'] = (datetime.now(ZoneInfo('Asia/Shanghai')).date() + timedelta(days=3)).isoformat()
    result = client.post('/api/v1/learning-course-settings', headers=headers[0], json=settings)
    assert result.status_code == 200
    assert result.get_json()['courses'][0]['reviewDue'] is True
    report = client.post('/api/v1/learning-reviews', headers=headers[0], json={'courseName': '数据结构'}).get_json()
    assert report['snapshot']['daysUntilExam'] == 3
    assert '核心概念' in report['summary']
    url = '/api/v1/exercises/exercise-set-demo-001'
    from app.api.exercises import DEMO_EXERCISE_SET_ID
    url = '/api/v1/exercises/' + DEMO_EXERCISE_SET_ID
    assert client.get(url, headers=headers[0], query_string={
        'courseName': '计算机网络', 'knowledgePointId': 'binary-tree-postorder'}).status_code == 400
    result = client.get(url, headers=headers[0], query_string={
        'courseName': '数据结构', 'knowledgePointId': 'binary-tree-postorder'})
    assert result.status_code == 200
    assert all(x['knowledgePointId'] == 'binary-tree-postorder' for x in result.get_json()['exercises'])


def test_scanned_questions_without_answer_cannot_be_auto_graded(setup):
    client, _, headers, _ = setup
    result = client.post('/api/v1/wrong-book/scanned', headers=headers[0], json={
        'stem': '解释开放问题', 'courseName': '数据结构', 'knowledgePointName': '栈'})
    exercise_id = result.get_json()['item']['exerciseId']
    result = client.post(f'/api/v1/wrong-book/{exercise_id}/attempt', headers=headers[0], json={'answer': ''})
    assert result.status_code == 409
