"""Legacy selection credentials cannot bypass phone uniqueness."""
import pytest
from app import create_app

@pytest.mark.parametrize('payload', [{}, {'selectionToken':'old', 'accountId':'any', 'password':'password123'}])
def test_account_selection_disabled(tmp_path, payload):
    client=create_app(tmp_path/'accounts.json').test_client()
    response=client.post('/api/v1/auth/select-account',json=payload)
    assert response.status_code==409
    assert response.get_json()['errorCode']=='ACCOUNT_SWITCH_DISABLED'

def test_legacy_duplicate_group_cannot_silently_choose_an_account(tmp_path):
    app=create_app(tmp_path/'accounts.json'); client=app.test_client(); repo=app.extensions['repository']
    first=client.post('/api/v1/auth/register',json=dict(phone='13900001234',password='password123')).get_json()
    user=repo.get('users',first['user']['userId']); user.update(userId='legacy-other')
    repo.save('users','legacy-other',user)
    response=client.post('/api/v1/auth/login',json=dict(phone='13900001234',password='password123'))
    assert response.status_code==409
    assert response.get_json()['errorCode']=='ACCOUNT_MIGRATION_REQUIRED'
