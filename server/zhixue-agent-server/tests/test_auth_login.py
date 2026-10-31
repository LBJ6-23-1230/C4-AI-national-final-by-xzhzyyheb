"""Phone is the password-login identity; nickname is optional display data."""
import pytest
from app import create_app

@pytest.fixture
def setup(tmp_path):
    app=create_app(tmp_path/'accounts.json')
    return app.test_client(),app.extensions['repository']

def register(client,phone='13900001234',**extra):
    return client.post('/api/v1/auth/register',json=dict(phone=phone,password='password123',**extra))

def test_phone_unique_and_nickname_optional(setup):
    c,r=setup; first=register(c); assert first.status_code==201
    user=first.get_json()['user']; assert user['nickname'].startswith('知学用户-')
    assert '13900001234' not in str(first.get_json())
    second=register(c,nickname='另一个'); assert second.status_code==409
    assert second.get_json()['errorCode']=='PHONE_ALREADY_REGISTERED'
    assert len(r.list('users'))==1
    login=c.post('/api/v1/auth/login',json=dict(phone='+86 139-0000-1234',password='password123')).get_json()
    assert login['user']['userId']==user['userId'] and 'accounts' not in login

@pytest.mark.parametrize('data',[{}, {'nickname':'someone','password':'password123'}, {'phone':'13900001234'},
    {'phone':'13900001234','password':'123'}, {'phone':'13900001234','password':False}])
def test_login_requires_phone_and_password(setup,data):
    assert setup[0].post('/api/v1/auth/login',json=data).status_code==400

@pytest.mark.parametrize('password',[None,'','123',False,123456])
def test_register_requires_valid_password(setup,password):
    assert setup[0].post('/api/v1/auth/register',json=dict(phone='13900001234',password=password)).status_code==400
    assert not setup[1].list('users')

def test_wrong_password_unknown_phone_and_compat_do_not_create(setup):
    c,r=setup; original=register(c).get_json()
    for path in ['/api/v1/auth/login','/api/v1/auth/login-or-register']:
        for phone,password in [('13900001234','wrong-password'),('13900001235','password123')]:
            response=c.post(path,json=dict(phone=phone,password=password))
            assert response.status_code==401 and response.get_json()['errorCode']=='AUTH_INVALID'
    assert len(r.list('users'))==1
    restored=c.post('/api/v1/auth/login',json=dict(userId=original['user']['userId'],token=original['token']))
    assert restored.status_code==200

def test_code_reuses_unique_account_and_first_password_setup(setup):
    c,r=setup; phone='13900001234'
    code=c.post('/api/v1/auth/send-code',json=dict(phone=phone)).get_json()['devCode']
    first=c.post('/api/v1/auth/verify-code',json=dict(phone=phone,code=code)).get_json()
    assert first['needsPasswordSetup'] is True and len(r.list('users'))==1
    assert c.post('/api/v1/auth/login',json=dict(phone=phone,password='anything')).status_code==401
    headers={'Authorization':'Bearer '+first['token']}
    assert c.post('/api/v1/auth/change-password',json=dict(newPassword='password123'),headers=headers).status_code==200
    login=c.post('/api/v1/auth/login',json=dict(phone=phone,password='password123')).get_json()
    assert login['user']['userId']==first['user']['userId'] and login['needsPasswordSetup'] is False
    user=r.get('users',first['user']['userId']); assert user['passwordHash'] and 'password123' not in user['passwordHash']

def test_change_password_requires_old_secret_and_isolation(setup):
    c,r=setup; a=register(c).get_json(); b=register(c,'13900001235').get_json()
    headers={'Authorization':'Bearer '+a['token']}
    assert c.post('/api/v1/auth/change-password',json=dict(oldPassword='wrong-old',newPassword='newpassword'),headers=headers).status_code==401
    assert c.post('/api/v1/auth/change-password',json=dict(oldPassword='password123',newPassword='newpassword'),headers=headers).status_code==200
    assert c.post('/api/v1/auth/login',json=dict(phone='13900001234',password='password123')).status_code==401
    assert c.post('/api/v1/auth/login',json=dict(phone='13900001234',password='newpassword')).status_code==200
    assert c.post('/api/v1/auth/login',json=dict(userId=b['user']['userId'],token=a['token'])).status_code==401
