from app import create_app

PHONE = '13912345678'
PW = 'secret123'

def setup_accounts(tmp_path):
    client = create_app(tmp_path / 'multi.json').test_client()
    users = []
    for nickname, grade in [('账号一', '大一'), ('账号二', '研一')]:
        response = client.post('/api/v1/auth/register', json={'phone': PHONE,
            'nickname': nickname, 'grade': grade, 'password': PW})
        assert response.status_code == 201
        users.append(response.get_json()['user'])
    assert users[0]['userId'] != users[1]['userId']
    return client, users

def test_password_login_selects_either_account_and_rejects_replay(tmp_path):
    client, users = setup_accounts(tmp_path)
    for user in users:
        choice = client.post('/api/v1/auth/login', json={'phone': '+86 ' + PHONE, 'password': PW}).get_json()
        assert 'token' not in choice and 'user' not in choice
        assert {u['userId'] for u in choice['accounts']} == {u['userId'] for u in users}
        for item in choice['accounts']:
            assert all(k in item for k in ('nickname', 'avatar', 'grade', 'createdAt'))
            assert 'passwordHash' not in item and 'phone' not in item
        body = {'selectionToken': choice['selectionToken'], 'accountId': user['userId'], 'password': PW}
        foreign = {**body, 'accountId': 'foreign'}
        assert client.post('/api/v1/auth/select-account', json=foreign).status_code == 401
        bad_password = {**body, 'password': 'wrong123'}
        assert client.post('/api/v1/auth/select-account', json=bad_password).status_code == 401
        selected = client.post('/api/v1/auth/select-account', json=body)
        assert selected.status_code == 200
        me = client.get('/api/v1/auth/me', headers={'Authorization': 'Bearer ' + selected.get_json()['token']})
        assert me.get_json()['user']['userId'] == user['userId']
        assert client.post('/api/v1/auth/select-account', json=body).status_code == 401
    assert client.post('/api/v1/auth/login', json={'phone': PHONE, 'password': 'wrong123'}).status_code == 401

def test_sms_verification_selects_without_reusing_code(tmp_path):
    client, users = setup_accounts(tmp_path)
    code = client.post('/api/v1/auth/send-code', json={'phone': PHONE}).get_json()['devCode']
    response = client.post('/api/v1/auth/verify-code', json={'phone': PHONE, 'code': code})
    assert response.status_code == 200
    choice = response.get_json()
    assert len(choice['accounts']) == 2
    assert client.post('/api/v1/auth/verify-code', json={'phone': PHONE, 'code': code}).status_code == 400
    selected = client.post('/api/v1/auth/select-account', json={'selectionToken': choice['selectionToken'], 'accountId': users[1]['userId']})
    assert selected.status_code == 200
    assert selected.get_json()['user']['userId'] == users[1]['userId']


def test_passwords_are_checked_for_selected_account(tmp_path):
    client, users = setup_accounts(tmp_path)
    other = client.post('/api/v1/auth/register', json={'phone': PHONE, 'nickname': '独立密码', 'password': 'another123'}).get_json()['user']
    choice = client.post('/api/v1/auth/login', json={'phone': PHONE, 'password': PW}).get_json()
    assert len(choice['accounts']) == 3
    body = {'selectionToken': choice['selectionToken'], 'accountId': other['userId'], 'password': PW}
    assert client.post('/api/v1/auth/select-account', json=body).status_code == 401
    body['password'] = 'another123'
    assert client.post('/api/v1/auth/select-account', json=body).get_json()['user']['userId'] == other['userId']

def test_selection_challenge_expires(tmp_path, monkeypatch):
    from datetime import timedelta
    from app.auth import service
    client, users = setup_accounts(tmp_path)
    choice = client.post('/api/v1/auth/login', json={'phone': PHONE, 'password': PW}).get_json()
    later = service._now() + timedelta(minutes=6)
    monkeypatch.setattr(service, '_now', lambda: later)
    assert client.post('/api/v1/auth/select-account', json={'selectionToken': choice['selectionToken'],
        'accountId': users[0]['userId'], 'password': PW}).status_code == 401
