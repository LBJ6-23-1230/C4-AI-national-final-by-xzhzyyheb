from concurrent.futures import ThreadPoolExecutor

import pytest

from app import create_app


@pytest.fixture(params=['json', 'sqlite'])
def manual_points(tmp_path, monkeypatch, request):
    monkeypatch.setenv('ZHIXUE_DB', request.param)
    app = create_app(tmp_path / 'manual-points.json')
    client = app.test_client()
    users = []
    for phone in ['13900007731', '13900007732']:
        auth = client.post('/api/v1/auth/register', json={
            'phone': phone, 'password': 'Manual-point-1234', 'nickname': '知识点测试',
            'seedDemoData': False,
        }).get_json()
        users.append((auth['user']['userId'], {'Authorization': 'Bearer ' + auth['token']}))
    return app, client, users


def test_create_persists_course_without_changing_plan(manual_points):
    app, client, users = manual_points
    owner, headers = users[0]
    repository = app.extensions['repository']
    profile_before = repository.get('profiles', owner)
    repository.save('plans', 'manual-plan', {'planId': 'manual-plan', 'userId': owner,
        'version': 7, 'tasks': [{'taskId': 'existing', 'status': 'in_progress'}]})
    plan_before = repository.get('plans', 'manual-plan')
    result = client.post(f'/api/v1/profile/{owner}/knowledge-points/manual', headers=headers,
        json={'courseName': ' 自选专题 ', 'knowledgePointName': ' 二叉树的层序遍历 '})
    assert result.status_code == 200
    point = result.get_json()
    assert point['knowledgePointName'] == '二叉树的层序遍历'
    assert point['sourceCourse'] == '自选专题' and point['classificationRequired'] is False
    assert point['masteryScore'] == 0 and point['confidence'] == 0
    loaded = client.get(f'/api/v1/profile/{owner}', headers=headers).get_json()
    assert loaded['profileVersion'] == profile_before['profileVersion'] + 1
    assert loaded['mastery'] == [point]
    assert repository.get('plans', 'manual-plan') == plan_before
    assert repository.get('profiles', users[1][0])['mastery'] == []


def test_duplicate_preserves_assessment_and_is_scoped_to_course(manual_points):
    app, client, users = manual_points
    owner, headers = users[0]
    path = f'/api/v1/profile/{owner}/knowledge-points/manual'
    body = {'courseName': '数据结构', 'knowledgePointName': '二叉树遍历'}
    first = client.post(path, headers=headers, json=body).get_json()
    repository = app.extensions['repository']
    profile = repository.get('profiles', owner)
    profile['mastery'][0].update(masteryScore=76, confidence=0.8)
    repository.save('profiles', owner, profile)
    before = client.get(f'/api/v1/profile/{owner}', headers=headers).get_json()
    repeated = client.post(path, headers=headers, json={**body, 'knowledgePointName': ' 二叉树 遍历 '})
    assert repeated.status_code == 200 and repeated.get_json() == before['mastery'][0]
    assert repository.get('profiles', owner) == profile
    other = client.post(path, headers=headers, json={**body, 'courseName': '算法专题'}).get_json()
    assert other['knowledgePointId'] != first['knowledgePointId']
    assert other['sourceCourse'] == '算法专题'


@pytest.mark.parametrize('body', [None, [], {}, {'courseName': '数据结构'},
    {'courseName': '', 'knowledgePointName': '树'}, {'courseName': '待分类', 'knowledgePointName': '树'},
    {'courseName': '数据结构', 'knowledgePointName': ' '}, {'courseName': '数据结构', 'knowledgePointName': 3},
    {'courseName': '课' * 81, 'knowledgePointName': '树'}, {'courseName': '数据结构', 'knowledgePointName': '树' * 81}])
def test_invalid_input_has_no_write(manual_points, body):
    app, client, users = manual_points
    owner, headers = users[0]
    repository = app.extensions['repository']
    before = repository.get('profiles', owner)
    result = client.post(f'/api/v1/profile/{owner}/knowledge-points/manual', headers=headers,
        data=__import__('json').dumps(body), content_type='application/json')
    assert result.status_code == 400
    assert repository.get('profiles', owner) == before


def test_identity_capacity_and_concurrent_retries(manual_points):
    app, client, users = manual_points
    owner, headers = users[0]
    other = users[1][0]
    path = f'/api/v1/profile/{owner}/knowledge-points/manual'
    body = {'courseName': '数据结构', 'knowledgePointName': '哈希查找'}
    assert client.post(path, json=body).status_code == 404
    assert client.post(path, headers={'Authorization': 'Bearer invalid'}, json=body).status_code == 401

    def create_point(_attempt):
        with app.test_client() as thread_client:
            response = thread_client.post(f'/api/v1/profile/{other}/knowledge-points/manual', headers=headers, json=body)
            assert response.status_code == 200
            return response.get_json()['knowledgePointId']

    with ThreadPoolExecutor(max_workers=4) as executor:
        ids = list(executor.map(create_point, range(8)))
    assert len(set(ids)) == 1
    repository = app.extensions['repository']
    profile = repository.get('profiles', owner)
    assert len(profile['mastery']) == 1
    assert repository.get('profiles', other)['mastery'] == []
    profile['mastery'] += [dict(profile['mastery'][0], knowledgePointId=f'capacity-{index}',
        knowledgePointName=f'已有知识点{index}') for index in range(59)]
    repository.save('profiles', owner, profile)
    assert client.post(path, headers=headers, json=body).status_code == 200
    assert client.post(path, headers=headers, json={**body, 'knowledgePointName': '新知识点'}).status_code == 400
    assert repository.get('profiles', owner) == profile
