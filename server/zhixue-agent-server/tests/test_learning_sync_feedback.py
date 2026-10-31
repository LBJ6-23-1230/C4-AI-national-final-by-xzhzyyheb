from copy import deepcopy
from datetime import datetime, timedelta, timezone
import pytest
from app.repositories.json_repository import JsonRepository
from app.repositories.sqlite_repository import SQLiteRepository
from app.services import learning_data as sync
from app.services import learning_effect as effect
from app.services.assignment_plan import reconcile


@pytest.fixture(params=['json', 'sqlite', 'postgresql'])
def repo(tmp_path, request, monkeypatch):
    if request.param == 'postgresql':
        import os, uuid
        from sqlalchemy import create_engine, text
        from sqlalchemy.engine import make_url
        from alembic import command
        from alembic.config import Config
        from app.repositories.postgresql_repository import PostgreSQLRepository
        url = os.getenv('ZHIXUE_TEST_DATABASE_URL')
        if not url:
            pytest.skip('isolated PostgreSQL database not configured')
        assert make_url(url).database.startswith('zhixue_test')
        schema = 'feedback_' + uuid.uuid4().hex
        engine = create_engine(url)
        with engine.begin() as connection:
            connection.execute(text(f'CREATE SCHEMA "{schema}"'))
        engine.dispose()
        monkeypatch.setenv('DATABASE_URL', url)
        monkeypatch.setenv('DB_SCHEMA', schema)
        command.upgrade(Config('alembic.ini'), 'head')
        r = PostgreSQLRepository(url)
    else:
        r = JsonRepository(tmp_path / 'data.json') if request.param == 'json' else SQLiteRepository(tmp_path / 'data.sqlite')
    yield r
    if hasattr(r, 'close'):
        r.close()


def course(name='数据结构'):
    return dict(courseId='course-1', courseName=name, exam=dict(date='2026-11-10', daysLeft=11),
        priority='中', recentStatus=dict(studyHours=0, status='未开始'))


def ddl():
    return dict(id='ddl-1', courseName='数据结构', title='实验报告', dueDate='2026-11-01',
        daysLeft=2, priority='中', estimatedMinutes=30, completed=False)


def change(key, **kwargs):
    return dict(idempotencyKey=key, **kwargs)


def test_new_device_read_and_empty_legacy_snapshot_preserve_assignments(repo):
    first = sync.apply(repo, 'alice', change('import', courses=[course()], homeworkDDLs=[ddl()]))
    assert len(sync.snapshot(repo, 'alice')['homeworkDDLs']) == 1
    plan = repo.list('plans')[0]
    assert reconcile(plan, []) == plan
    assert sync.snapshot(repo, 'bob')['courses'] == []
    assert sync.apply(repo, 'alice', change('import', courses=[course()], homeworkDDLs=[ddl()])) == first


def test_versions_deletion_and_old_device_cannot_resurrect(repo):
    first = sync.apply(repo, 'alice', change('first', homeworkDDLs=[ddl()]))
    item = first['homeworkDDLs'][0]
    sync.apply(repo, 'alice', change('delete', deletedDDLs=[dict(id=item['id'], expectedVersion=item['syncVersion'])]))
    assert not sync.snapshot(repo, 'alice')['homeworkDDLs']
    assert not repo.list('plans')[0]['unscheduledTasks']
    with pytest.raises(sync.SyncConflict):
        sync.apply(repo, 'alice', change('stale', homeworkDDLs=[item]))
    sync.apply(repo, 'alice', change('old-install-migration', migration=True, homeworkDDLs=[ddl()]))
    assert not sync.snapshot(repo, 'alice')['homeworkDDLs']


def test_conflicting_batch_is_atomic_and_migration_never_overwrites(repo):
    first = sync.apply(repo, 'alice', change('first', courses=[course()]))
    updated = dict(first['courses'][0], courseName='新课程名')
    sync.apply(repo, 'alice', change('edit', courses=[updated]))
    before = deepcopy(repo.list('courses'))
    with pytest.raises(sync.SyncConflict):
        sync.apply(repo, 'alice', change('conflict', courses=[dict(course(), courseId='extra'), updated]))
    assert repo.list('courses') == before
    sync.apply(repo, 'alice', change('migration', migration=True, courses=[course()]))
    assert sync.snapshot(repo, 'alice')['courses'][0]['courseName'] == '新课程名'


def test_idempotent_acknowledgement_does_not_rebase_over_another_devices_edit(repo):
    request = change('first', courses=[course()])
    first = sync.apply(repo, 'alice', request)
    sync.apply(repo, 'alice', change('other-device', courses=[dict(first['courses'][0], courseName='其他设备修改')]))
    assert sync.apply(repo, 'alice', request)['courses'][0]['syncVersion'] == 1
    with pytest.raises(sync.SyncConflict):
        sync.apply(repo, 'alice', change('stale-follow-up', courses=[dict(first['courses'][0], courseName='本机后续修改')]))


def submit(repo, name, stamp, correct, prefix, difficulties=None):
    facts = [dict(knowledgePointId='stack', exerciseId=f'{prefix}-{i}', fingerprint=f'{prefix}-{i}',
        correct=ok, difficulty=(difficulties or ['easy', 'medium', 'medium', 'easy', 'medium'])[i], assisted=False)
        for i, ok in enumerate(correct)]
    repo.save('submissions', name, dict(userId='alice', createdAt=stamp.isoformat(), idempotencyKey=name,
        questionFacts=facts, response=dict(review=[dict(exerciseId=f['exerciseId'], correct=f['correct']) for f in facts])))


def test_repeated_questions_do_not_inflate_evidence_and_delayed_new_questions_do(repo):
    stamp = datetime(2026, 10, 28, 8, tzinfo=timezone.utc)
    submit(repo, 'baseline', stamp, [False, False, True, False, True], 'a')
    submit(repo, 'repeat', stamp + timedelta(hours=1), [True] * 5, 'a')
    first = effect.statistics(repo, 'alice', stamp + timedelta(hours=2))['stack']
    assert first['effectiveQuestionCount'] == 5 and first['recentAccuracy'] == 40
    assert first['performanceChange'] is None and first['retentionStatus'] == 'not_tested'
    submit(repo, 'delayed', stamp + timedelta(hours=30), [True] * 5, 'b')
    later = effect.statistics(repo, 'alice', stamp + timedelta(hours=31))['stack']
    assert later['effectiveQuestionCount'] == 10
    assert later['performanceChange'] == 60 and later['retentionStatus'] == 'preliminary_good'
    assert effect.statistics(repo, 'bob', stamp + timedelta(days=2)) == {}


def test_focus_only_does_not_claim_mastery_and_today_excludes_yesterday(repo):
    stamp = datetime(2026, 10, 30, 3, tzinfo=timezone.utc)
    repo.save('focus_sessions', 'yesterday', dict(userId='alice', session=dict(endedAt=(stamp-timedelta(days=1)).isoformat(),
        actualMinutes=30, completionRate=40, selfAssessment='partial')))
    today = effect.summary(repo, 'alice', 1, stamp)
    assert today['focusMinutes'] == 0 and today['practiceAccuracy'] is None and today['points'] == []
    repo.save('focus_sessions', 'today', dict(userId='alice', session=dict(endedAt=stamp.isoformat(), actualMinutes=20, selfAssessment='completed')))
    today = effect.summary(repo, 'alice', 1, stamp)
    assert today['focusMinutes'] == 20 and today['practiceAccuracy'] is None
    assert '投入' in today['conclusion']


def test_unknown_points_and_true_zero_are_distinct(repo):
    stamp = datetime(2026, 10, 30, 3, tzinfo=timezone.utc)
    rows = [dict(knowledgePointId='stack', knowledgePointName='栈的基本操作', masteryScore=0),
            dict(knowledgePointId='tree', knowledgePointName='二叉树遍历', masteryScore=0)]
    submit(repo, 'first', stamp, [False] * 3, 'a')
    projected = effect.projected_mastery(repo, 'alice', rows, stamp)
    assert projected[0]['recentAccuracy'] == 0 and projected[0]['effectiveQuestionCount'] == 3
    assert projected[1]['recentAccuracy'] is None and projected[1]['assessmentStatus'] == 'unassessed'


def test_two_devices_http_restore_conflict_and_explicit_delete(tmp_path):
    from app import create_app
    app = create_app(tmp_path / 'two-devices.json')
    a, b = app.test_client(), app.test_client()
    auth = a.post('/api/v1/auth/register', json=dict(nickname='同步测试', phone='13900008881', seedDemoData=False, password='test-pw-123456')).get_json()
    headers = {'Authorization': 'Bearer ' + auth['token']}
    first = a.post('/api/v1/learning-data', headers=headers, json=change('first', courses=[course()], homeworkDDLs=[ddl()]))
    assert first.status_code == 200
    initial = first.get_json()
    assert b.get('/api/v1/learning-data', headers=headers).get_json() == initial
    assert b.get('/api/v1/learning-data').status_code == 401
    repository = app.extensions['repository']
    before = deepcopy(repository.list('plans'))
    b.get('/api/v1/plans/current', headers=headers)
    assert repository.list('plans') == before
    # Even an old client can no longer erase/replace canonical assignments.
    b.post('/api/v1/plans/current/assignments', headers=headers, json={'assignments': []})
    assert repository.list('plans') == before
    item = initial['courses'][0]
    a.post('/api/v1/learning-data', headers=headers, json=change('edit-a', courses=[dict(item, courseName='新名称')]))
    assert b.post('/api/v1/learning-data', headers=headers, json=change('edit-b', courses=[dict(item, courseName='旧设备修改')])).status_code == 409
    assert b.get('/api/v1/learning-data', headers=headers).get_json()['courses'][0]['courseName'] == '新名称'
    deleted = b.post('/api/v1/learning-data', headers=headers, json=change('delete', deletedDDLs=[dict(id='ddl-1', expectedVersion=1)]))
    assert deleted.status_code == 200 and deleted.get_json()['homeworkDDLs'] == []
    assert b.get('/api/v1/learning-effect?days=1', headers=headers).get_json()['practiceAccuracy'] is None
    assert b.get('/api/v1/learning-effect?days=bad', headers=headers).status_code == 400


def test_course_rename_keeps_ddl_identity_and_completion_is_read_from_server(repo):
    first = sync.apply(repo, 'alice', change('import', courses=[course()], homeworkDDLs=[ddl()]))
    assert first['homeworkDDLs'][0]['courseId'] == 'course-1'
    renamed = sync.apply(repo, 'alice', change('rename', courses=[dict(first['courses'][0], courseName='课程新名称')]))
    assert renamed['homeworkDDLs'][0]['courseName'] == '课程新名称'
    assert renamed['homeworkDDLs'][0]['id'] == 'ddl-1'
    assert renamed['homeworkDDLs'][0]['syncVersion'] == 1
    plan = repo.list('plans')[0]
    task = plan['unscheduledTasks'].pop()
    task['status'] = 'completed'; plan['tasks'].append(task)
    repo.save('plans', plan['planId'], plan)
    assert sync.snapshot(repo, 'alice')['homeworkDDLs'][0]['completed'] is True


def test_topic_aliases_are_scoped_and_do_not_merge_different_skills(repo):
    from app.tools.profile_merge import merge_points_into_profile
    repo.save('profiles', 'alice', dict(userId='alice', goal='学习课程', profileVersion=1, mastery=[]))
    profile = merge_points_into_profile(repo, 'alice', [
        dict(name='二叉树遍历基础', sourceCourse='数据结构'), dict(name='二叉树遍历', sourceCourse='数据结构'),
        dict(name='栈的基本操作', sourceCourse='数据结构'), dict(name='栈出栈序列的不确定性', sourceCourse='数据结构'),
        dict(name='共同主题', sourceCourse='课程甲'), dict(name='共同主题', sourceCourse='课程乙')])
    assert len(profile['mastery']) == 5
    assert len({r['knowledgePointId'] for r in profile['mastery']}) == 5
