"""Regressions for stale prompts, syllabus quizzes and accidental goals."""
import base64
import json

import pytest

from app import create_app
from app.agent import chat_llm, exercise_gen
from app.api import workflows
from app.services import grounded_exercises, learning_context
from app.services.exercise_quality import is_subject_question, has_subject_content


@pytest.fixture(params=['json', 'sqlite'])
def setup(tmp_path, monkeypatch, request):
    monkeypatch.setenv('ZHIXUE_DB', request.param)
    client = create_app(tmp_path / 'usability.json').test_client()
    auth = client.post('/api/v1/auth/register', json={'nickname': '练习测试', 'phone': '13900009701', 'seedDemoData': True}).get_json()
    return client, workflows._repository, auth['user']['userId'], {'Authorization': 'Bearer ' + auth['token']}


@pytest.mark.parametrize('message', ['我要更新学习画像：我的学习目标或掌握情况有变化。我不需要学数据结构了',
                                    '帮我看看我的薄弱知识点', '今天有什么任务', '帮我匹配学习搭子'])
def test_routine_chat_never_creates_or_resends_goal(setup, monkeypatch, message):
    client, repo, owner, headers = setup
    learning_context.ensure_chat_context(repo, owner, 'chat', '帮我按薄弱点安排复习')
    count = len(repo.list('workflows'))
    monkeypatch.setattr(chat_llm, 'chat', lambda **kw: {'reply': '查看结果', 'intent': 'update_profile', 'card': None})
    result = client.post('/api/agent/chat', headers=headers, json={'message': message, 'sessionId': 'chat', 'coordinateLearning': True}).get_json()
    assert 'learningContext' not in result
    assert len(repo.list('workflows')) == count


def test_legacy_invalid_goal_is_history_only_and_can_be_ended(setup):
    client, repo, owner, headers = setup
    context = learning_context.ensure_chat_context(repo, owner, 'chat', '我要更新学习画像：学习目标有变化', point='掌握')
    assert not learning_context.current_chat_workflow(repo, owner, 'chat')
    assert context['needsConfirmation'] and not context['knowledgePointName']
    result = client.post('/api/v1/workflows/chat/chat/goals', headers=headers, json={'action': 'end', 'goalId': context['goalId']})
    assert result.status_code == 200
    assert repo.get('workflows', context['goalId'])['userEnded']


@pytest.mark.parametrize('stem', ['根据资料，关于二叉树算法应用的掌握程度要求是？', '十字链表、邻接多重表的要求掌握程度是？'])
def test_syllabus_quiz_rejected_in_both_generators(monkeypatch, stem):
    row = {'stem': stem, 'options': ['A.重点掌握，必考', 'B.掌握', 'C.熟悉', 'D.了解'], 'answer': 'B', 'explanation': '资料中标明掌握。',
           'sourceIds': ['chunk'], 'supportingQuote': '二叉树算法应用要求掌握'}
    monkeypatch.setattr(exercise_gen, 'generation_available', lambda: True)
    monkeypatch.setattr(chat_llm, '_call_llm', lambda *a, **kw: json.dumps({'exercises': [row]}))
    assert not exercise_gen.generate_exercises('二叉树', 1)
    assert not grounded_exercises.generate('二叉树', 1, [{'chunkId': 'chunk', 'fileName': '考纲', 'headingPath': '树', 'text': row['supportingQuote']}])
    assert not is_subject_question(row)


def test_syllabus_only_is_not_subject_evidence():
    assert not has_subject_content('二叉树算法应用：掌握\n十字链表、邻接多重表：熟悉\n排序算法：重点掌握，必考')
    assert has_subject_content('后序遍历的顺序是左子树、右子树、根节点，因此根节点最后访问。')
    assert is_subject_question({'stem': '二叉树后序遍历何时访问根结点？', 'options': ['最后', '最先', '中间', '任意']})


def test_invalid_v2_tag_migrates_without_deleting_assessed_history(setup):
    client, repo, owner, headers = setup
    kb = client.post('/api/v1/knowledge-bases', headers=headers, json={'name': '考纲', 'courseName': '数据结构'}).get_json()['kbId']
    doc = client.post(f'/api/v1/knowledge-bases/{kb}/documents', headers=headers, json={
        'fileName': 'tree.md', 'contentBase64': base64.b64encode('二叉树算法应用：掌握\n后序遍历：熟悉'.encode()).decode()}).get_json()
    repo.save('documents', doc['documentId'], dict(doc, extractionVersion=2, tagsConfirmed=True, knowledgePoints=['掌握', '二叉树']))
    profile = repo.get('profiles', owner)
    profile['mastery'].append({'knowledgePointId': 'bad', 'knowledgePointName': '掌握', 'source': 'document', 'confidence': 0, 'masteryScore': 0})
    repo.save('profiles', owner, profile)
    upgraded = client.get(f'/api/v1/knowledge-bases/{kb}', headers=headers).get_json()['documents'][0]
    assert upgraded['knowledgePoints'] == ['二叉树']
    assert not any(p['knowledgePointName'] == '掌握' for p in repo.get('profiles', owner)['mastery'])
    assert repo.get('document_tag_revisions', doc['documentId'] + ':before-v2')


def test_old_syllabus_question_cannot_update_mastery(setup):
    client, repo, owner, headers = setup
    profile = repo.get('profiles', owner)
    repo.save('exercises', 'old-syllabus', {'exerciseId': 'old-syllabus', 'userId': owner,
        'knowledgePointId': '掌握', 'knowledgePointName': '掌握', 'source': 'materials',
        'stem': '关于二叉树算法应用的掌握程度要求是？',
        'options': ['A.重点掌握，必考', 'B.掌握', 'C.熟悉', 'D.了解'], 'answerKey': 'B'})
    result = client.post('/api/v1/exercises/set-demo-binary-tree-001/submit', headers=headers,
        json={'idempotencyKey': 'old-question', 'answers': [{'exerciseId': 'old-syllabus', 'answer': 'B'}]})
    assert result.status_code == 409
    assert repo.get('profiles', owner) == profile
    assert not repo.list('submissions')
