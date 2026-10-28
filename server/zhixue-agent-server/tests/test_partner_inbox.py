import pytest
from app import create_app


@pytest.fixture
def inbox_setup(tmp_path):
    app = create_app(tmp_path / 'inbox.json')
    client = app.test_client()
    repository = app.extensions['repository']
    people = []
    for index in range(3):
        response = client.post('/api/v1/auth/register', json={
            'nickname': f'消息同学{index}', 'phone': f'1380055000{index}', 'seedDemoData': False})
        assert response.status_code == 201
        record = response.get_json()
        people.append((record['user']['userId'], {'Authorization': 'Bearer ' + record['token']}))
    for left, right in [(0, 1), (1, 0), (0, 2), (2, 0)]:
        owner, other = people[left][0], people[right][0]
        repository.save('contacts', owner + ':' + other, dict(userId=owner, partnerUserId=other,
            pairedAt='2026-10-27T00:00:00Z', courseName='数据结构'))
    return client, repository, people


def send(client, sender, target, key, text):
    result = client.post(f'/api/v1/partners/{target[0]}/messages', headers=sender[1],
                         json=dict(clientId=key, text=text, image=''))
    assert result.status_code == 201
    return result.get_json()['message']


def test_inbox_counts_only_incoming_and_read_watermarks_are_monotonic(inbox_setup):
    client, repository, people = inbox_setup
    me, first, second = people
    earlier = send(client, first, me, '1', '一起复习栈')
    later = send(client, first, me, '2', '明天有空吗')
    send(client, second, me, '3', '一起学习网络')
    send(client, me, first, '4', '收到')
    response = client.get('/api/v1/partner-conversations', headers=me[1])
    assert response.status_code == 200
    inbox = response.get_json()
    assert inbox['totalUnread'] == 3
    assert len(inbox['conversations']) == 2
    item = next(x for x in inbox['conversations'] if x['partnerUserId'] == first[0])
    assert item['lastMessage'] == '收到' and item['unreadCount'] == 2
    assert item['sharedCourses'] == ['数据结构'] and item['sharedStudyMinutes'] is None
    assert 'image' not in item
    read_url = f'/api/v1/partners/{first[0]}/read'
    assert client.post(read_url, headers=me[1], json={'lastReadMessageId': later['messageId']}).status_code == 200
    result = client.post(read_url, headers=me[1], json={'lastReadMessageId': earlier['messageId']})
    assert result.get_json()['lastReadMessageId'] == later['messageId']
    assert client.get('/api/v1/partner-conversations', headers=me[1]).get_json()['totalUnread'] == 1
    send(client, first, me, '5', '新消息')
    assert client.get('/api/v1/partner-conversations', headers=me[1]).get_json()['totalUnread'] == 2


def test_read_is_private_and_cannot_consume_another_room(inbox_setup):
    client, repository, people = inbox_setup
    me, first, second = people
    message = send(client, first, me, '1', '私密消息')
    assert client.get('/api/v1/partner-conversations').status_code == 401
    assert client.get(f'/api/v1/partners/{first[0]}/summary', headers=second[1]).status_code == 404
    assert client.post(f'/api/v1/partners/{second[0]}/read', headers=me[1],
                       json={'lastReadMessageId': message['messageId']}).status_code == 404
    assert client.get('/api/v1/partner-conversations?offset=-1', headers=me[1]).status_code == 400
    assert client.get('/api/v1/partner-conversations?offset=30', headers=me[1]).get_json()['conversations'] == []
    repository.delete('contacts', first[0] + ':' + me[0])
    inbox = client.get('/api/v1/partner-conversations', headers=me[1]).get_json()
    assert all(x['partnerUserId'] != first[0] for x in inbox['conversations'])


def test_manual_course_is_canonical_and_does_not_fabricate_mastery(inbox_setup):
    client, repository, people = inbox_setup
    owner, headers = people[0]
    before = repository.get('profiles', owner) or {}
    for name in [' 数据库 ', '数据库原理']:
        result = client.post('/api/v1/learning-course-settings', headers=headers,
                             json={'courseName': name, 'goal': '期末复习', 'examDate': ''})
        assert result.status_code == 200
    courses = result.get_json()['courses']
    assert [x['courseName'] for x in courses].count('数据库原理') == 1
    assert (repository.get('profiles', owner) or {}).get('mastery', []) == before.get('mastery', [])
    assert client.post('/api/v1/learning-course-settings', headers=headers, json={'courseName': ';;;'}).status_code == 400
