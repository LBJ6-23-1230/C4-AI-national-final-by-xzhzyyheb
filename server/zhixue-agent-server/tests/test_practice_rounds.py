import pytest

from app import create_app
from app.api import exercises
from app.services.practice_rounds import fingerprint

URL = '/api/v1/exercises/set-demo-binary-tree-001'


@pytest.fixture(params=['json', 'sqlite'])
def target(tmp_path, monkeypatch, request):
    monkeypatch.setenv('ZHIXUE_DB', request.param)
    app = create_app(tmp_path / 'rounds.json')
    repo = app.extensions['repository']
    repo.save('profiles', 'demo-user', dict(userId='demo-user', goal='复习', mastery=[dict(
        knowledgePointId='binary-tree-postorder', knowledgePointName='二叉树后序遍历',
        sourceCourse='数据结构', masteryScore=0, confidence=0)], history=[], evidence=[]))
    return app.test_client(), repo


def test_reenter_without_submission_rotates_content_and_retry_restores_round(target):
    client, repo = target
    query = dict(courseName='数据结构', knowledgePointId='binary-tree-postorder', count=1)
    first = client.get(URL, query_string=dict(query, roundId='one')).get_json()
    assert first['exercises']
    assert client.get(URL, query_string=dict(query, roundId='one')).get_json() == first
    second = client.get(URL, query_string=dict(query, roundId='two')).get_json()
    assert second['exercises']
    assert fingerprint(first['exercises'][0]) != fingerprint(second['exercises'][0])
    assert client.get(URL, query_string=dict(query, count=2, roundId='one')).status_code == 409
    assert not repo.list('submissions')


def test_does_not_recycle_used_bank_or_model_question_with_new_id(target, monkeypatch):
    client, repo = target
    query = dict(courseName='数据结构', knowledgePointId='binary-tree-postorder', count=1, generate='1')
    rows = [q for q in exercises._EXERCISE_BANK if q['knowledgePointId'] == 'binary-tree-postorder']
    for q in rows:
        repo.save('exercise_usage', 'demo-user:' + q['exerciseId'], dict(userId='demo-user', exerciseId=q['exerciseId']))
    repeated = dict(rows[0], exerciseId='new-uuid', source='llm')
    monkeypatch.setattr(exercises.exercise_gen, 'generate_exercises', lambda *args: [repeated])
    data = client.get(URL, query_string=dict(query, roundId='repeat')).get_json()
    assert data['exercises'] == [] and data['generationFailed']
    assert not repo.list('practice_rounds')


def test_generation_fills_short_bank_and_persists_round_without_answers(target, monkeypatch):
    client, repo = target
    calls = []
    def generate(point, count):
        calls.append((count, exercises.exercise_gen.avoid_questions.get()))
        return [dict(exerciseId='unique', stem='某表达式树的左右子树结果怎样合并计算？',
            options=['A. 左右根', 'B. 根左右', 'C. 右根左', 'D. 左根右'], answerKey='A',
            explanation='先求子树再求根', source='llm', difficulty='medium')]
    monkeypatch.setattr(exercises.exercise_gen, 'generate_exercises', generate)
    bank = [q for q in exercises._EXERCISE_BANK if q['knowledgePointId'] == 'binary-tree-postorder']
    for q in bank[1:]:
        repo.save('exercise_usage', 'demo-user:' + q['exerciseId'], dict(userId='demo-user', exerciseId=q['exerciseId']))
    data = client.get(URL, query_string=dict(courseName='数据结构', knowledgePointId='binary-tree-postorder',
        count=2, generate='1', roundId='fill')).get_json()
    assert len(data['exercises']) == 2 and calls[0][0] == 1
    assert calls[0][1]
    assert all('answerKey' not in q and 'explanation' not in q for q in data['exercises'])
