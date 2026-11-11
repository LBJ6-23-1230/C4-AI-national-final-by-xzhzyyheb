from datetime import datetime, timedelta, timezone

import pytest

from app import create_app
from app.agent import exercise_gen as gen
from app.services import reminders as r, push_provider


@pytest.fixture(params=['json', 'sqlite'])
def setup(tmp_path, monkeypatch, request):
    monkeypatch.setenv('ZHIXUE_DB', request.param)
    app = create_app(tmp_path / 'settings.json')
    repo = app.extensions['repository']
    repo.apply_batch([(name, key) for name in ('plans', 'profiles', 'focus_sessions')
                      for key in repo.ids(name)], [])
    return app.test_client(), repo


def test_minute_precision_overnight_daytime_and_disabling_quiet_hours(setup):
    client, repo = setup
    r.save_preferences(repo, 'demo-user', dict(enabled=True, quietStart=22, quietStartMinute=35,
                                              quietEnd=8, quietEndMinute=20))
    event = dict(userId='demo-user', status='pending', kind='task', level='urgent')
    def allowed(hour, minute):
        return r.allowed(repo, event, datetime(2026, 11, 3, hour, minute, tzinfo=timezone(timedelta(hours=8))))
    assert allowed(22, 34)
    assert not allowed(22, 35)
    assert not allowed(8, 19)
    assert allowed(8, 20)
    r.save_preferences(repo, 'demo-user', dict(quietStart=12, quietEnd=14, quietStartMinute=15, quietEndMinute=45))
    assert allowed(12, 14)
    assert not allowed(12, 15)
    assert not allowed(14, 44)
    assert allowed(14, 45)
    r.save_preferences(repo, 'demo-user', dict(quietEnabled=False))
    assert allowed(13, 0)
    r.save_preferences(repo, 'demo-user', dict(quietEnabled=True, urgentException=True))
    assert allowed(13, 0)
    assert client.get('/api/v1/reminder-preferences').get_json()['preferences']['quietStartMinute'] == 15
    for invalid in [dict(quietEndMinute=60), dict(quietStartMinute=True), dict(quietEnabled='yes'),
                    dict(studyGapEnabled=1), dict(quietStart=14, quietStartMinute=45)]:
        assert client.put('/api/v1/reminder-preferences', json=invalid).status_code == 400


def test_old_preferences_keep_hours_and_gain_defaults(setup):
    client, repo = setup
    repo.save('reminder_preferences', 'alice', dict(quietStart=23, quietEnd=9))
    prefs = r.preferences(repo, 'alice')
    assert prefs['quietStartMinute'] == prefs['quietEndMinute'] == 0
    assert prefs['quietStart'] == 23 and prefs['quietEnd'] == 9
    assert prefs['studyGapEnabled'] and prefs['quietEnabled']
    assert r.preferences(repo, 'bob')['quietStart'] == 22
    r.bind(repo, 'demo-user', dict(deviceId='local-device', permission=True, pushToken='private-token'))
    r.bind(repo, 'bob', dict(deviceId='other-device', permission=True, pushToken='other-token'))
    devices = client.get('/api/v1/reminder-devices').get_json()['devices']
    assert len(devices) == 1 and devices[0]['hasToken']
    assert 'pushToken' not in devices[0] and 'private-token' not in str(devices)


def test_gap_switch_changes_home_guidance_without_push_or_other_accounts(setup):
    client, repo = setup
    stamp = datetime(2026, 11, 3, 2, tzinfo=timezone.utc)
    repo.save('focus_sessions', 'recent', dict(userId='demo-user', session=dict(endedAt=(stamp-timedelta(days=2)).isoformat())))
    first = r.reconcile(repo, 'demo-user', stamp)
    assert '两天' in first['guidance'] and first['highlight'] is None
    assert not repo.list('reminder_deliveries')
    r.save_preferences(repo, 'demo-user', dict(enabled=True))
    gap = next(e for e in repo.list('reminder_events') if e['kind'] == 'gap')
    assert not r.allowed(repo, dict(gap, snoozeKey='old-client'), stamp)
    assert client.put('/api/v1/reminder-preferences', json=dict(studyGapEnabled=False)).status_code == 200
    assert '两天' not in r.reconcile(repo, 'demo-user', stamp)['guidance']
    assert '两天' not in r.reconcile(repo, 'bob', stamp)['guidance']
    r.save_preferences(repo, 'demo-user', dict(studyGapEnabled=True))
    assert '两天' in r.reconcile(repo, 'demo-user', stamp)['guidance']
    repo.save('plans', 'p', dict(userId='demo-user', planId='p', version=1, tasks=[dict(
        taskId='task', knowledgePointName='待完成实验', durationMinutes=30, status='pending')]))
    assert '两天' not in r.reconcile(repo, 'demo-user', stamp)['guidance']


@pytest.mark.parametrize('status,name,reason', [
    (401, 'Error', 'MODEL_AUTH_FAILED'), (429, 'Error', 'MODEL_BUSY'),
    (None, 'APITimeoutError', 'MODEL_TIMEOUT'), (503, 'Error', 'MODEL_UNAVAILABLE'),
])
def test_generation_errors_are_actionable_and_never_leak_provider_messages(monkeypatch, status, name, reason):
    monkeypatch.setattr(gen, 'generation_available', lambda: True)
    error = type(name, (Exception,), {'status_code': status})('private-provider-secret')
    def fail(*a, **kw):
        raise error
    monkeypatch.setattr(gen.chat_llm, '_call_llm', fail)
    assert gen.generate_exercises('哈希表', 3) is None
    details = gen.failure_details()
    assert details['failureReason'] == reason
    assert 'private-provider-secret' not in str(details)


def test_generation_distinguishes_configuration_and_invalid_responses(monkeypatch):
    monkeypatch.setattr(gen, 'generation_available', lambda: False)
    assert gen.generate_exercises('哈希表', 3) is None
    assert gen.failure_details()['failureReason'] == 'MODEL_NOT_CONFIGURED'
    monkeypatch.setattr(gen, 'generation_available', lambda: True)
    for response, reason in [('incomplete {', 'INVALID_RESPONSE'), ('{"exercises":[]}', 'INVALID_QUESTION')]:
        monkeypatch.setattr(gen.chat_llm, '_call_llm', lambda *a, **k: response)
        assert gen.generate_exercises('哈希表', 3) is None
        assert gen.failure_details()['failureReason'] == reason


def test_generation_api_returns_reason_without_unrelated_bank_questions(setup, monkeypatch):
    client, _ = setup
    monkeypatch.setattr(gen, 'generation_available', lambda: False)
    response = client.get('/api/v1/exercises/set-demo-binary-tree-001', query_string=dict(knowledgePointId='红黑树旋转', generate='1'))
    assert response.status_code == 200
    data = response.get_json()
    assert data['exercises'] == [] and data['generationFailed']
    assert data['failureReason'] == 'MODEL_NOT_CONFIGURED'


def test_push_configuration_requires_readable_credentials(tmp_path, monkeypatch):
    monkeypatch.delenv('HUAWEI_PUSH_SERVICE_ACCOUNT_FILE', raising=False)
    monkeypatch.setenv('HUAWEI_PUSH_PROJECT_ID', '123456')
    filename = tmp_path / 'push.jwt'
    monkeypatch.setenv('HUAWEI_PUSH_JWT_FILE', str(filename))
    assert not push_provider.configured()
    filename.write_text('  ', encoding='utf-8')
    assert not push_provider.configured()
    filename.write_text('test-only-token', encoding='utf-8')
    assert push_provider.configured()
    monkeypatch.setenv('HUAWEI_PUSH_PROJECT_ID', 'not-a-project')
    assert not push_provider.configured()
