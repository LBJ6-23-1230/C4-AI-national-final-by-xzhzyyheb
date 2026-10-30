from datetime import datetime, timedelta, timezone
import pytest
from app import create_app
from app.services import reminders as r


@pytest.fixture(params=['json', 'sqlite'])
def setup(tmp_path, monkeypatch, request):
    monkeypatch.setenv('ZHIXUE_DB', request.param)
    stamp = datetime(2026, 10, 30, 2, tzinfo=timezone.utc)  # 10:00 Shanghai
    monkeypatch.setattr(r, 'now', lambda: stamp)
    app = create_app(tmp_path / 'reminders.json')
    repo = app.extensions['repository']
    repo.apply_batch([(collection, key) for collection in ('plans', 'profiles', 'focus_sessions')
                      for key in repo.ids(collection)], [])
    repo.save('plans', 'plan-a', dict(userId='demo-user', planId='plan-a', version=1, tasks=[dict(
        taskId='ddl-a', knowledgePointName='操作系统实验', sourceCourse='操作系统',
        dueDate='2026-10-31', durationMinutes=30, status='pending', source='ddl')]))
    return app.test_client(), repo, stamp


def test_cold_start_no_llm_stable_identity_and_date_precision(setup):
    c, repo, stamp = setup
    first = c.get('/api/v1/today').get_json()
    second = c.get('/api/v1/today').get_json()
    assert first['highlight']['eventId'] == second['highlight']['eventId']
    assert first['highlight']['level'] == 'important'
    assert '时刻未设置' in first['highlight']['reason']
    assert first['modelCalls'] == 0 and not repo.list('reminder_deliveries')


def test_unknown_mastery_and_exam_courses_are_not_mixed(setup):
    c, repo, stamp = setup
    repo.delete('plans', 'plan-a')
    repo.save('profiles', 'demo-user', dict(userId='demo-user', courseExams={'网络': '2026-11-01'},
        mastery=[dict(knowledgePointId='tree', knowledgePointName='二叉树', sourceCourse='数据结构', masteryScore=0)],
        evidence=[dict(id='import', knowledgePointId='tree', sourceType='document')], history=[]))
    assert c.get('/api/v1/today').get_json()['highlight'] is None
    profile = repo.get('profiles', 'demo-user')
    profile['courseExams']['数据结构'] = '2026-11-02'
    profile['evidence'].append(dict(id='assessment', knowledgePointId='tree', sourceType='assessment'))
    repo.save('profiles', 'demo-user', profile)
    d = c.get('/api/v1/today').get_json()['highlight']
    assert d['courseName'] == '数据结构' and '2026-11-02' in d['reason']


def test_actions_idempotent_version_guard_and_completed_entry(setup):
    c, repo, stamp = setup
    event = c.get('/api/v1/today').get_json()['highlight']
    url = '/api/v1/reminders/' + event['eventId'] + '/actions'
    data = dict(action='ignore', version=event['version'], idempotencyKey='ignore')
    first = c.post(url, json=data)
    assert first.status_code == 200
    assert c.post(url, json=data).get_json() == first.get_json()
    assert c.get('/api/v1/today').get_json()['highlight'] is None
    assert c.post(url, json=dict(data, action='start', idempotencyKey='stale')).status_code == 409
    assert not r.overview(repo, 'other-user')['pendingCount']
    plan = repo.get('plans', 'plan-a'); plan['tasks'][0]['status'] = 'completed'; repo.save('plans', 'plan-a', plan)
    c.get('/api/v1/today')
    assert repo.get('reminder_events', event['eventId'])['status'] == 'completed'
    assert c.post(url, json=dict(data, idempotencyKey='after-completion')).status_code == 409


def test_snooze_survives_reload_and_does_not_bypass_quiet_hours(setup):
    c, repo, stamp = setup
    e = c.get('/api/v1/today').get_json()['highlight']
    response = c.post('/api/v1/reminders/' + e['eventId'] + '/actions', json=dict(
        action='snooze', minutes=30, version=e['version'], idempotencyKey='snooze'))
    assert response.status_code == 200
    assert r.reconcile(repo, 'demo-user', stamp + timedelta(minutes=29))['highlight'] is None
    assert r.reconcile(repo, 'demo-user', stamp + timedelta(minutes=31))['highlight']
    r.save_preferences(repo, 'demo-user', {'enabled': True})
    assert not r.allowed(repo, repo.get('reminder_events', e['eventId']), stamp.replace(hour=15))


def enable(repo):
    r.save_preferences(repo, 'demo-user', {'enabled': True})
    r.bind(repo, 'demo-user', dict(deviceId='phone', pushToken='test-only', permission=True))
    r.bind(repo, 'demo-user', dict(deviceId='tablet', pushToken='second', permission=True))


def test_one_primary_device_no_repeat_on_refresh_and_no_false_delivery(setup):
    c, repo, stamp = setup
    enable(repo)
    for _ in range(4):
        r.schedule(repo, 'demo-user', stamp)
    sent = []
    assert r.deliver_once(repo, lambda e, d, j: sent.append(d['deviceId']) or 'provider-receipt', stamp)
    assert len(sent) == 1
    assert repo.list('reminder_deliveries')[0]['status'] == 'accepted'
    r.schedule(repo, 'demo-user', stamp + timedelta(hours=5))
    assert not r.deliver_once(repo, lambda *a: sent.append('duplicate'), stamp + timedelta(hours=5))
    assert len(sent) == 1


def test_focus_permission_completion_and_retry_limit(setup):
    c, repo, stamp = setup
    enable(repo)
    r.bind(repo, 'demo-user', dict(deviceId='phone', pushToken='test', permission=True, focusing=True))
    r.schedule(repo, 'demo-user', stamp)
    assert not repo.list('reminder_deliveries')
    r.bind(repo, 'demo-user', dict(deviceId='phone', pushToken='test', permission=True))
    r.schedule(repo, 'demo-user', stamp)
    def fail(*args):
        raise RuntimeError('offline')
    for minutes in (0, 2, 5):
        r.deliver_once(repo, fail, stamp + timedelta(minutes=minutes))
    assert repo.list('reminder_deliveries')[0]['status'] == 'failed'
    assert repo.list('reminder_deliveries')[0]['attempts'] == 3


def test_account_ownership_and_invalid_action_payloads(setup):
    c, repo, stamp = setup
    assert c.put('/api/v1/reminder-preferences', json={'dailyLimit': 3}).status_code == 400
    assert c.put('/api/v1/reminder-preferences', json={'timezone': 'invalid'}).status_code == 400
    assert c.post('/api/v1/reminder-devices', json={'deviceId': 'phone', 'permission': 'yes'}).status_code == 400
    e = c.get('/api/v1/today').get_json()['highlight']
    with pytest.raises(LookupError):
        r.action(repo, 'foreign', e['eventId'], dict(action='start', version=1, idempotencyKey='foreign'))


def test_successful_snooze_is_consumed_and_later_days_keep_minimum_gap(setup):
    c, repo, stamp = setup
    enable(repo)
    event = c.get('/api/v1/today').get_json()['highlight']
    r.action(repo, 'demo-user', event['eventId'], dict(action='snooze', minutes=30,
        version=event['version'], idempotencyKey='one-snooze'))
    due = stamp + timedelta(minutes=30)
    r.schedule(repo, 'demo-user', due)
    assert r.deliver_once(repo, lambda *args: 'accepted', due)
    assert repo.list('reminder_deliveries')[0]['category'] == 'snooze'
    latest = repo.get('reminder_events', event['eventId'])
    assert 'snoozeKey' not in latest and 'snoozedUntil' not in latest
    tomorrow = stamp + timedelta(days=1)
    repo.save('reminder_deliveries', 'other-recent', dict(deliveryId='other-recent', userId='demo-user',
        eventId='other', deadline='', deliveryDate='2026-10-31', status='accepted',
        category='urgent', attemptedAt=(tomorrow - timedelta(hours=1)).isoformat()))
    assert not r.allowed(repo, latest, tomorrow)


def test_budget_conflict_uses_only_confirmed_time_and_updates_without_adoption(setup):
    c, repo, stamp = setup
    assert not any(e['kind'] == 'conflict' for e in r.candidates(repo, 'demo-user', stamp))
    plan = repo.get('plans', 'plan-a')
    plan['constraints'] = dict(availableMinutes=20)
    repo.save('plans', 'plan-a', plan)
    conflict = next(e for e in r.candidates(repo, 'demo-user', stamp) if e['kind'] == 'conflict')
    assert '30分钟' in conflict['reason'] and '20分钟' in conflict['reason']
    assert conflict['targetPage'] == 'pages/StudyPlan'
    c.get('/api/v1/today')
    assert repo.get('plans', 'plan-a') == plan  # Viewing never adopts a new plan.


def test_category_preferences_suppress_external_sending_without_hiding_today(setup):
    c, repo, stamp = setup
    enable(repo)
    assert c.put('/api/v1/reminder-preferences', json=dict(categories=['unknown'])).status_code == 400
    assert c.put('/api/v1/reminder-preferences', json=dict(categories=['task', 'task'])).status_code == 400
    assert c.put('/api/v1/reminder-preferences', json=dict(categories=['exam'])).status_code == 200
    assert c.get('/api/v1/today').get_json()['highlight']['kind'] == 'task'
    r.schedule(repo, 'demo-user', stamp)
    assert not repo.list('reminder_deliveries')
