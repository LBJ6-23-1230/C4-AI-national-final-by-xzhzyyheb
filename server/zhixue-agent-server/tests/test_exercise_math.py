from copy import deepcopy
from fractions import Fraction
import json

import pytest

from app import create_app
from app.agent import chat_llm, exercise_gen
from app.services import exercise_cache, grounded_exercises, practice_rounds
from app.services.exercise_math import calculation_is_valid, normalize_calculation


URL = '/api/v1/exercises/set-demo-binary-tree-001'


def question(**changes):
    return dict(dict(exerciseId='bad-wpl', knowledgePointId='huffman', knowledgePointName='哈夫曼编码',
        courseName='数据结构', source='llm',
        stem='在构造哈夫曼树时，若初始权值集合为 {2, 3, 5, 7}，则最终生成的哈夫曼树的带权路径长度（WPL）是多少？',
        options=['A. 19', 'B. 24', 'C. 28', 'D. 30'], answerKey='C', explanation='错误的模型解析'), **changes)


def model_row(**changes):
    row = question(**changes)
    row['answer'] = row.pop('answerKey')
    return row


def test_missing_correct_option_is_repaired_with_exact_derivation_without_mutating_input():
    original = question()
    before = deepcopy(original)
    corrected = normalize_calculation(original)
    assert original == before
    assert corrected['options'] == ['A. 19', 'B. 24', 'C. 32', 'D. 30']
    assert corrected['answerKey'] == 'C'
    assert '2+3=5；5+5=10；7+10=17' in corrected['explanation']
    assert 'WPL=5+10+17=32' in corrected['explanation']
    assert calculation_is_valid(corrected)
    assert not calculation_is_valid(original)


@pytest.mark.parametrize('weights,total', [
    ('{1,2,3,4}', '19'), ('（2，3，5，7）', '32'), ('[2、3、5、7]', '32'),
    ('2,3,5,7', '32'), ('{2,2,2,2}', '16'), ('{5,7}', '12'), ('{0,1}', '1'),
    ('{0.1,0.2,0.3,0.4}', '1.9'), ('.1,.2,.3,.4', '1.9'),
    ('{10%,20%,30%,40%}', '1.9'), ('{1/3,1/3,1/3}', '5/3'),
])
def test_weight_notations_and_ties_use_exact_arithmetic(weights, total):
    corrected = normalize_calculation(question(stem=f'哈夫曼树的叶子权值分别为{weights}，带权路径长度 WPL 是多少？'))
    index = 'ABCD'.index(corrected['answerKey'])
    assert corrected['options'][index] == f'{"ABCD"[index]}. {total}'
    assert calculation_is_valid(corrected)


def test_existing_correct_option_changes_key_and_explanation_without_rewriting_options():
    original = question(options=['A. 32', 'B. 24', 'C. 28', 'D. 30'])
    corrected = normalize_calculation(original)
    assert corrected['options'] == original['options']
    assert corrected['answerKey'] == 'A'
    assert '错误的模型解析' not in corrected['explanation']
    assert not calculation_is_valid(original)


@pytest.mark.parametrize('changes', [
    {'options': ['A. 19', 'B. 19', 'C. 32', 'D. 30']},
    {'options': ['A. 19', 'B. 24', 'C. 28', 'D. 无法确定']},
    {'stem': '哈夫曼树的带权路径长度 WPL 是多少？'},
    {'stem': '哈夫曼树的权值集合为{2,-3,5,7}，带权路径长度 WPL 是多少？'},
    {'stem': '哈夫曼树的权值分别为-2,3,5,7，带权路径长度 WPL 是多少？'},
    {'stem': '哈夫曼树的权值集合为{2,1/0,5,7}，带权路径长度 WPL 是多少？'},
    {'stem': '两棵哈夫曼树权值分别为{2,3,5,7}、权值为{1,2,3,4}，带权路径长度 WPL 是多少？'},
    {'stem': '两棵哈夫曼树权值分别为{2,3,5,7}、权值为1,2,3,4，带权路径长度 WPL 是多少？'},
    {'stem': '哈夫曼树的权值分别为2,3,5和7，带权路径长度 WPL 是多少？'},
    {'stem': '哈夫曼树的权值分别为2,3,5,7e2，带权路径长度 WPL 是多少？'},
    {'stem': '三叉哈夫曼树的权值集合为{2,3,5,7}，带权路径长度 WPL 是多少？'},
    {'stem': '3元哈夫曼树的权值集合为{2,3,5,7}，带权路径长度 WPL 是多少？'},
    {'stem': '11叉哈夫曼树的权值集合为{2,3,5,7}，带权路径长度 WPL 是多少？'},
    {'stem': 'ternary Huffman tree weights are {2,3,5,7}, WPL=?'},
    {'stem': '哈夫曼树的权值集合为{2,3,5,7}，平均带权路径长度 WPL 是多少？'},
])
def test_ambiguous_or_unsupported_calculations_are_rejected(changes):
    original = question(**changes)
    assert normalize_calculation(original) is None
    assert not calculation_is_valid(original)


def test_conceptual_and_unrelated_questions_keep_their_answers():
    for original in (question(stem='哈夫曼树的带权路径长度 WPL 如何计算？',
            options=['A. 叶子权值与路径长度乘积之和', 'B. 树高', 'C. 边数', 'D. 根权值']),
            question(stem='二叉树有 7 个结点，其中叶子有多少个？')):
        assert normalize_calculation(original) == original
        assert calculation_is_valid(original)


def test_general_generator_repairs_model_computation(monkeypatch):
    monkeypatch.setattr(exercise_gen, 'generation_available', lambda: True)
    monkeypatch.setattr(chat_llm, '_call_llm', lambda *args, **kwargs: json.dumps({'exercises': [model_row()]}))
    generated = exercise_gen.generate_exercises('哈夫曼编码', 1)
    assert len(generated) == 1
    assert calculation_is_valid(generated[0])
    assert generated[0]['options'][2] == 'C. 32'


def test_material_generator_applies_the_same_computation_check(monkeypatch):
    quote = '哈夫曼树的带权路径长度等于每次合并两个最小权值的和。'
    source = dict(chunkId='chunk', documentId='doc', fileName='讲义.txt', headingPath='哈夫曼树', text=quote)
    row = model_row(sourceIds=['chunk'], supportingQuote=quote)
    monkeypatch.setattr(exercise_gen, 'generation_available', lambda: True)
    monkeypatch.setattr(chat_llm, '_call_llm', lambda *args, **kwargs: json.dumps({'exercises': [row]}))
    generated = grounded_exercises.generate('哈夫曼编码', 1, [source])
    assert len(generated) == 1
    assert generated[0]['source'] == 'materials'
    assert calculation_is_valid(generated[0])
    assert generated[0]['options'][2] == 'C. 32'


@pytest.fixture(params=['json', 'sqlite'])
def target(tmp_path, monkeypatch, request):
    monkeypatch.setenv('ZHIXUE_DB', request.param)
    app = create_app(tmp_path / 'calculation.json')
    repo = app.extensions['repository']
    repo.save('profiles', 'demo-user', dict(userId='demo-user', goal='课程复习', profileVersion=1,
        mastery=[dict(knowledgePointId='huffman', knowledgePointName='哈夫曼编码', sourceCourse='数据结构',
            masteryScore=0, confidence=0, lastUpdated='2026-11-08T07:00:00Z')], history=[], evidence=[]))
    return app.test_client(), repo


def test_api_persists_corrected_key_hides_answers_and_grades_correct_option(target, monkeypatch):
    client, repo = target
    monkeypatch.setattr(exercise_gen, 'generation_available', lambda: True)
    monkeypatch.setattr(chat_llm, '_call_llm', lambda *args, **kwargs: json.dumps({'exercises': [model_row()]}))
    data = client.get(URL, query_string=dict(courseName='数据结构', knowledgePointId='huffman',
        count=1, forceGenerate=1, roundId='corrected')).get_json()
    public = data['exercises'][0]
    assert public['options'][2] == 'C. 32'
    assert 'answerKey' not in public and 'explanation' not in public
    stored = repo.get('exercises', public['exerciseId'])
    assert calculation_is_valid(stored)
    monkeypatch.setattr(chat_llm, '_call_llm', lambda *args, **kwargs: pytest.fail('Exact calculation must not need model review'))
    result = client.post(URL + '/submit', json=dict(idempotencyKey='corrected',
        answers=[dict(exerciseId=public['exerciseId'], answer='C')])).get_json()
    assert result['assessment']['score'] == 100
    assert result['review'][0]['correctAnswer'] == 'C'
    assert result['review'][0]['explanationSource'] == 'calculation'
    assert 'WPL=5+10+17=32' in result['review'][0]['explanation']
    assert result['reviewStatus'] == 'completed'


def test_old_bad_calculation_cannot_grade_or_change_profile(target):
    client, repo = target
    repo.save('exercises', 'bad-wpl', dict(question(), userId='demo-user'))
    before = repo.get('profiles', 'demo-user')
    result = client.post(URL + '/submit', json=dict(idempotencyKey='old-bad',
        answers=[dict(exerciseId='bad-wpl', answer='C')]))
    assert result.status_code == 409
    assert '计算答案未通过校验' in result.get_json()['message']
    assert repo.get('profiles', 'demo-user') == before
    assert not repo.list('submissions') and not repo.list('exercise_usage')


def test_old_bad_calculation_is_not_reused_from_cache_or_saved_round(target, monkeypatch):
    client, repo = target
    bad = question()
    repo.save('exercises', bad['exerciseId'], dict(bad, userId='demo-user'))
    key = exercise_cache.key(repo, 'demo-user', '哈夫曼编码', 1)
    exercise_cache.put(key, [bad])
    assert exercise_cache.get(key, repo) is None
    query = dict(courseName='数据结构', knowledgePointId='huffman', count=1, forceGenerate=1, roundId='old')
    response = dict(setId='set-demo-binary-tree-001', exercises=[{key: value for key, value in bad.items()
        if key not in ('answerKey', 'explanation')}])
    repo.save('practice_rounds', practice_rounds.identity('demo-user', 'old'), dict(userId='demo-user',
        signature=practice_rounds.signature('数据结构', 'huffman', None, 1, [], True), response=response))
    monkeypatch.setattr(exercise_gen, 'generate_exercises', lambda *_: pytest.fail('Must not change an existing round'))
    assert client.get(URL, query_string=query).status_code == 409
    fresh = client.get(URL, query_string=dict(courseName='数据结构', knowledgePointId='huffman', count=1)).get_json()
    assert fresh['exercises'] == []


def test_wpl_matches_exhaustive_binary_merge_costs():
    def minimum_cost(weights):
        if len(weights) == 1:
            return Fraction(0)
        return min(weights[left] + weights[right] + minimum_cost(tuple(
            value for index, value in enumerate(weights) if index not in (left, right)) +
            (weights[left] + weights[right],))
            for left in range(len(weights)) for right in range(left + 1, len(weights)))

    for weights in ((1, 2, 3, 4), (2, 3, 5, 7), (3, 3, 4, 8), (1, 5, 8)):
        corrected = normalize_calculation(question(stem=f'哈夫曼树的权值集合为{list(weights)}，WPL是多少？'))
        correct = corrected['options']['ABCD'.index(corrected['answerKey'])].split('. ', 1)[1]
        assert Fraction(correct) == minimum_cost(weights)
