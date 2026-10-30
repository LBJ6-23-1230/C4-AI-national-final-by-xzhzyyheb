"""Regression for course-scoped question selection and the completed-book handoff."""
from app import create_app
from app.api import exercises
from app.services import exercise_cache


URL = '/api/v1/exercises/set-demo-binary-tree-001'


def setup_target(tmp_path, point='import-tree', name='二叉树后序遍历'):
    app = create_app(tmp_path / 'feedback.json')
    repo = app.extensions['repository']
    repo.save('profiles', 'demo-user', dict(userId='demo-user', goal='课程复习', profileVersion=1,
        mastery=[dict(knowledgePointId=point, knowledgePointName=name,
            sourceCourse='数据结构', masteryScore=0, confidence=0, lastUpdated='2026-10-30T00:00:00Z')], history=[], evidence=[]))
    return app.test_client(), repo


def stub_generator(monkeypatch):
    calls = []
    def generate(point, count):
        calls.append((point, count))
        return [dict(exerciseId=f'fresh-{len(calls)}', knowledgePointId=point,
            knowledgePointName=point, difficulty='medium', stem=f'二叉树后序遍历练习{len(calls)}：根节点何时访问？',
            options=['A. 最后', 'B. 最先', 'C. 中间', 'D. 不访问'], answerKey='A',
            explanation='左右子树之后访问根节点。', source='llm')]
    monkeypatch.setattr(exercises.exercise_gen, 'generate_exercises', generate)
    return calls


def test_imported_id_uses_matching_bank_and_grades_original_profile_point(tmp_path):
    client, repo = setup_target(tmp_path)
    result = client.get(URL, query_string=dict(courseName='数据结构', knowledgePointId='import-tree')).get_json()
    assert result['exercises'] and not result['generationFailed']
    question = result['exercises'][0]
    assert question['knowledgePointId'] == 'import-tree'
    assert 'answerKey' not in question and 'explanation' not in question
    answer = repo.get('exercises', question['exerciseId'])['answerKey']
    response = client.post(URL + '/submit', json=dict(idempotencyKey='imported-target',
        answers=[dict(exerciseId=question['exerciseId'], answer=answer)]))
    assert response.status_code == 200
    profile = repo.get('profiles', 'demo-user')
    assert profile['mastery'][0]['masteryScore'] > 0
    assert profile['mastery'][0]['sourceCourse'] == '数据结构'
    assert profile['history'][-1]['knowledgePointId'] == 'import-tree'


def test_similar_practice_always_generates_and_records_mastery(tmp_path, monkeypatch):
    client, repo = setup_target(tmp_path, 'binary-tree-postorder')
    calls = stub_generator(monkeypatch)
    query = dict(courseName='数据结构', knowledgePointId='binary-tree-postorder', forceGenerate='1', generate='1')
    first = client.get(URL, query_string=query).get_json()['exercises'][0]
    second = client.get(URL, query_string=query).get_json()['exercises'][0]
    assert len(calls) == 2 and first['exerciseId'] != second['exerciseId']
    assert first['source'] == 'llm' and first['knowledgePointId'] == 'binary-tree-postorder'
    response = client.post(URL + '/submit', json=dict(idempotencyKey='similar',
        answers=[dict(exerciseId=first['exerciseId'], answer='A')]))
    assert response.status_code == 200
    assert repo.get('profiles', 'demo-user')['mastery'][0]['masteryScore'] > 0
    assert repo.list('evidences')


def test_course_generation_cache_retains_bound_metadata(tmp_path, monkeypatch):
    client, _ = setup_target(tmp_path, 'new-point', '红黑树')
    exercise_cache.clear()
    calls = stub_generator(monkeypatch)
    query = dict(courseName='数据结构', knowledgePointId='new-point', generate='1', count=1)
    first = client.get(URL, query_string=query).get_json()['exercises']
    assert client.get(URL, query_string=query).get_json()['exercises'] == first
    assert len(calls) == 1
    query['excludeExerciseId'] = first[0]['exerciseId']
    assert client.get(URL, query_string=query).get_json()['exercises'][0]['exerciseId'] != first[0]['exerciseId']
    assert len(calls) == 2


def test_reclassified_photo_handoff_is_owned_and_keeps_old_course_scores(tmp_path, monkeypatch):
    client, repo = setup_target(tmp_path, 'scan-point', '红黑树')
    repo.save('wrong_book', 'demo-user:photo', dict(userId='demo-user', exerciseId='photo',
        courseName='算法专题', courseConfirmed=True, knowledgePointId='scan-point', knowledgePointName='红黑树'))
    stub_generator(monkeypatch)
    query = dict(courseName='算法专题', knowledgePointId='scan-point', forceGenerate='1')
    response = client.get(URL, query_string=query)
    assert response.status_code == 200
    question = response.get_json()['exercises'][0]
    assert question['knowledgePointId'] != 'scan-point'
    response = client.post(URL + '/submit', json=dict(idempotencyKey='reclassified',
        answers=[dict(exerciseId=question['exerciseId'], answer='A')]))
    assert response.status_code == 200
    points = repo.get('profiles', 'demo-user')['mastery']
    assert next(p for p in points if p['knowledgePointId'] == 'scan-point')['masteryScore'] == 0
    target = next(p for p in points if p['knowledgePointId'] == question['knowledgePointId'])
    assert target['sourceCourse'] == '算法专题' and target['masteryScore'] > 0
    assert client.get(URL, query_string=dict(query, courseName='其他账号的课程')).status_code == 400


def test_unconfigured_generation_is_explicit_and_never_returns_unrelated_questions(tmp_path):
    client, _ = setup_target(tmp_path, 'new-point', '红黑树')
    data = client.get(URL, query_string=dict(courseName='数据结构', knowledgePointId='new-point', generate='1')).get_json()
    assert data['exercises'] == [] and data['generationFailed']
    assert '尚未配置' in data['message']


def test_similar_practice_survives_final_original_auto_removal_after_reclassification(tmp_path, monkeypatch):
    client, _ = setup_target(tmp_path, 'binary-tree-postorder')
    client.post('/api/v1/wrong-book/exercise-preorder-001', json={'added': True})
    assert client.post('/api/v1/wrong-book/classify', json=dict(
        courseName='算法专题', exerciseIds=['exercise-preorder-001'])).status_code == 200
    for _ in range(3):
        assert client.post('/api/v1/wrong-book/exercise-preorder-001/attempt', json={'answer': 'A'}).status_code == 200
    assert client.get('/api/v1/wrong-book').get_json()['total'] == 0
    stub_generator(monkeypatch)
    response = client.get(URL, query_string=dict(courseName='算法专题', knowledgePointId='binary-tree-postorder', forceGenerate='1'))
    assert response.status_code == 200
    assert response.get_json()['exercises']


def test_unverified_questions_expose_grading_capability_without_leaking_answers(tmp_path):
    client, repo = setup_target(tmp_path)
    repo.save('wrong_book', 'demo-user:photo', dict(userId='demo-user', exerciseId='photo',
        courseName='数据结构', knowledgePointName='树', options=[], answerKey='', addedAt='2026-10-30'))
    client.post('/api/v1/wrong-book/exercise-preorder-001', json={'added': True})
    items = [q for c in client.get('/api/v1/wrong-book').get_json()['courses'] for q in c['items']]
    assert next(q for q in items if q['exerciseId'] == 'photo')['canAutoGrade'] is False
    assert next(q for q in items if q['exerciseId'] == 'exercise-preorder-001')['canAutoGrade'] is True
    assert all('answerKey' not in q for q in items)
