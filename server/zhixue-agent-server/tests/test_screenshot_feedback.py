"""Regressions for the seven user screenshots, not canned model replies."""
import base64
import copy
import json
from concurrent.futures import ThreadPoolExecutor

import pytest

from app import create_app
from app.agent import chat_llm, knowledge
from app.api import knowledge as knowledge_api, workflows
from app.services.course_names import course_names


@pytest.fixture(params=['json', 'sqlite'])
def setup(tmp_path, monkeypatch, request):
    monkeypatch.setenv('ZHIXUE_DB', request.param)
    client = create_app(tmp_path / 'screenshots.json').test_client()
    users = []
    for i in (1, 2):
        auth = client.post('/api/v1/auth/register', json={
            'nickname': f'截图测试{i}', 'phone': f'1390000960{i}', 'grade': '大二', 'seedDemoData': False}).get_json()
        users.append((auth['user']['userId'], {'Authorization': 'Bearer ' + auth['token']}))
    return client, workflows._repository, users


def png():
    import pymupdf
    pixmap = pymupdf.Pixmap(pymupdf.csRGB, pymupdf.IRect(0, 0, 16, 16), False)
    pixmap.clear_with(255)
    return base64.b64encode(pixmap.tobytes('png')).decode()


def vision(monkeypatch, point='二叉树后序遍历', readable=True, reply='请核对识别出的题目。'):
    monkeypatch.setattr(chat_llm, '_call_llm_with_image', lambda *a, **k: json.dumps({
        'readable': readable, 'questionText': '已知二叉树结构，请写出后序遍历序列。' if readable else '',
        'knowledgePoint': point, 'reply': reply, 'wrongType': '概念混淆', 'answerVisible': False}, ensure_ascii=False))


def send(setup, **fields):
    return setup[0].post('/api/agent/chat', headers=setup[2][0][1], json={
        'message': '帮我诊断这道错题', 'sessionId': 'same-chat', 'coordinateLearning': True, **fields})


@pytest.mark.parametrize('message', ['帮我诊断这道错题', '帮我分析这道题', '这张图片为什么错了'])
def test_missing_attachment_never_calls_model_or_starts_goal(setup, monkeypatch, message):
    monkeypatch.setattr(chat_llm, 'detect_intent', lambda *a, **k: (_ for _ in ()).throw(AssertionError('model called')))
    result = send(setup, message=message).get_json()
    assert not result['llmUsed'] and ('未附' in result['reply'] or '没有附带' in result['reply'])
    assert result['attachmentReceipt']['status'] == 'missing'
    assert 'learningContext' not in result and 'wrongAnalysis' not in result


def test_invalid_image_is_rejected_before_vision(setup, monkeypatch):
    monkeypatch.setattr(chat_llm, 'chat', lambda **k: (_ for _ in ()).throw(AssertionError('invalid image routed')))
    response = send(setup, image='ZmFrZS1pbWFnZQ==')
    assert response.status_code == 400 and response.get_json()['errorCode'] == 'INVALID_IMAGE'


def test_received_but_unreadable_is_not_reported_as_no_upload(setup, monkeypatch):
    vision(monkeypatch, readable=False)
    result = send(setup, image=png()).get_json()
    assert result['attachmentReceipt']['status'] == 'unreadable'
    assert '图片已接收' in result['reply'] and not result['wrongAnalysis']['knowledgePoint']
    assert 'learningContext' not in result


@pytest.mark.parametrize('error', [TimeoutError('llm_budget'), RuntimeError('upstream unavailable')])
def test_vision_failure_has_received_receipt_and_no_false_goal(setup, monkeypatch, error):
    monkeypatch.setattr(chat_llm, '_call_llm_with_image', lambda *a, **k: (_ for _ in ()).throw(error))
    diagnoses_before = copy.deepcopy(setup[1].list('chat_diagnoses'))
    result = send(setup, image=png()).get_json()
    assert result['attachmentReceipt']['status'] == 'failed'
    assert '图片已接收' in result['reply'] and not result['llmUsed']
    assert result['reply'] == ('图片已接收，但识别超时。请重试，或裁剪成单题后上传。'
                               if isinstance(error, TimeoutError) else
                               '图片已接收，但识别未完成。请重试，或裁剪成单题后上传。')
    assert not result.get('wrongAnalysis')
    assert 'learningContext' not in result
    assert setup[1].list('chat_diagnoses') == diagnoses_before


def test_confirmation_binds_current_question_and_keeps_multiple_goal_history(setup, monkeypatch):
    client, repo, users = setup
    owner, headers = users[0]
    profile = repo.get('profiles', owner)
    profile['mastery'] = [{'knowledgePointId': 'http', 'knowledgePointName': 'HTTP 协议',
                           'masteryScore': 0, 'confidence': 0}]
    repo.save('profiles', owner, profile)
    vision(monkeypatch)
    result = send(setup, image=png()).get_json()
    assert result['attachmentReceipt']['status'] == 'recognized'
    assert result['wrongAnalysis']['wrongType'] == '', 'no visible answer means no personal error attribution'
    assert 'learningContext' not in result and len(repo.get('profiles', owner)['mastery']) == 1
    url = '/api/v1/workflows/chat/same-chat/goals'
    request = {'action': 'start', 'diagnosisId': result['wrongAnalysis']['diagnosisId']}
    first = client.post(url, headers=headers, json=request).get_json()['learningContext']
    assert '后序遍历' in first['knowledgePointName'] and first['knowledgePointId'] != 'http'
    assert client.post(url, headers=headers, json=request).get_json()['learningContext']['goalId'] == first['goalId']
    vision(monkeypatch, point='图算法')
    second_result = send(setup, image=png()).get_json()
    second = client.post(url, headers=headers, json={'action': 'start',
        'diagnosisId': second_result['wrongAnalysis']['diagnosisId']}).get_json()['learningContext']
    assert second['goalId'] != first['goalId'] and second['knowledgePointName'] == '图算法'
    goals = client.get(url, headers=headers).get_json()['goals']
    assert {g['goalId'] for g in goals} == {first['goalId'], second['goalId']}
    assert client.get(url, headers=users[1][1]).get_json()['goals'] == []
    assert client.post(url, headers=users[1][1], json={'action': 'select', 'goalId': first['goalId']}).status_code == 404
    restored = client.post(url, headers=headers, json={'action': 'select', 'goalId': first['goalId']}).get_json()['learningContext']
    assert restored['knowledgePointName'] == first['knowledgePointName']
    assert client.post(url, headers=headers, json={'action': 'end', 'goalId': first['goalId']}).status_code == 200
    assert client.get('/api/v1/workflows/chat/same-chat', headers=headers).status_code == 404
    assert client.post(f"/api/v1/workflows/{first['goalId']}/run", headers=headers, json={}).status_code == 409
    assert next(g for g in client.get(url, headers=headers).get_json()['goals'] if g['goalId'] == first['goalId'])['status'] == 'ended'


def test_concurrent_confirmation_creates_one_goal(setup, monkeypatch):
    client, repo, users = setup
    vision(monkeypatch)
    diagnosis = send(setup, image=png()).get_json()['wrongAnalysis']['diagnosisId']
    def confirm(_):
        with client.application.test_client() as c:
            response = c.post('/api/v1/workflows/chat/same-chat/goals', headers=users[0][1],
                json={'action': 'start', 'diagnosisId': diagnosis})
            assert response.status_code == 200
            return response.get_json()['learningContext']['goalId']
    with ThreadPoolExecutor(max_workers=4) as pool:
        assert len(set(pool.map(confirm, range(4)))) == 1
    assert len([w for w in repo.list('workflows') if w.get('state', {}).get('coordination', {}).get('diagnosisId') == diagnosis]) == 1


def test_partial_course_overlap_and_scoped_invitation(setup):
    client, repo, users = setup
    for i, (owner, headers) in enumerate(users):
        response = client.put(f'/api/v1/profile/{owner}/preferences', headers=headers, json={
            'targetCourses': ['数据结构', '计算机网络'] if i == 0 else ['数据结构'],
            'goal': '期末复习' if i == 0 else '补基础', 'freeTimeSlots': ['19:00-21:00']})
        assert response.status_code == 200
    best = client.post('/api/v1/agent/partner-match', headers=users[0][1], json={}).get_json()['matchedCandidate']
    assert best['sharedCourses'] == ['数据结构'] and best['courseMatch'] == 'partial'
    assert best['factors']['goal'] == 20 and best['score'] == 55
    response = client.post('/api/v1/agent/partner-invitations', headers=users[0][1],
        json={'toUserId': users[1][0], 'courseName': '计算机网络'})
    assert response.status_code == 400
    invitation = client.post('/api/v1/agent/partner-invitations', headers=users[0][1],
        json={'toUserId': users[1][0], 'courseName': '数据结构'}).get_json()['invitation']
    assert invitation['courseName'] == '数据结构'
    assert client.post(f"/api/v1/agent/partner-invitations/{invitation['invitationId']}/accept", headers=users[1][1]).status_code == 200
    assert all(c['courseName'] == '数据结构' for c in repo.list('contacts'))


def test_course_normalization_preserves_compound_course_names():
    assert course_names('数据结构与计算机网络') == ['数据结构', '计算机网络']
    assert course_names('概率论与数理统计') == ['概率论与数理统计']
    assert course_names(['数据库', '数据库原理']) == ['数据库原理']


def test_extraction_rejects_screenshot_fragments_without_truncating_good_topics():
    terms = ['排序算法', '堆排序', '归并排序', '快速排序', '冒泡排序', '选择排序', '插入排序', '希尔排序', '基数排序', '哈希表']
    junk = ['个字符和开头', '个字符相同', '字符前面最多', '得分', '掌握', '选择', '解答', '程序填空题']
    chunks = [{'text': '\n'.join(terms + junk), 'headingPath': term} for term in terms + junk]
    points = knowledge.extract_knowledge_points(chunks, junk)
    assert set(terms) <= set(points) and not set(junk) & set(points)
    assert len(points) > 8


def test_upload_candidates_need_confirmation_and_legacy_cleanup_is_reversible(setup):
    client, repo, users = setup
    owner, headers = users[0]
    kb = client.post('/api/v1/knowledge-bases', headers=headers, json={'name': '截图课件', 'courseName': '数据结构'}).get_json()['kbId']
    doc = client.post(f'/api/v1/knowledge-bases/{kb}/documents', headers=headers, json={
        'fileName': 'sorting.md', 'contentBase64': base64.b64encode('# 堆排序\n\n堆排序用于排序，归并排序也用于排序。'.encode()).decode()}).get_json()
    assert not repo.get('profiles', owner)['mastery']
    assert not doc['tagsConfirmed']
    legacy = dict(doc, knowledgePoints=['掌握', '个字符和开头'], extractionVersion=1)
    repo.save('documents', doc['documentId'], legacy)
    profile = repo.get('profiles', owner)
    profile['mastery'] = [{'knowledgePointId': 'junk', 'knowledgePointName': '掌握', 'source': 'document', 'confidence': 0},
                          {'knowledgePointId': 'assessed', 'knowledgePointName': '归并排序', 'source': 'document', 'confidence': 0.7}]
    repo.save('profiles', owner, profile)
    repo.save('plans', 'legacy-plan', {'planId': 'legacy-plan', 'userId': owner, 'version': 1,
        'tasks': [{'taskId': 'done', 'knowledgePointId': 'junk', 'status': 'completed', 'durationMinutes': 20}], 'candidatePool': profile['mastery']})
    upgraded = client.get(f'/api/v1/knowledge-bases/{kb}', headers=headers).get_json()['documents'][0]
    assert '掌握' not in upgraded['knowledgePoints'] and '堆排序' in upgraded['knowledgePoints']
    assert repo.get('document_tag_revisions', doc['documentId'] + ':before-v2')['previous'] == legacy
    assert [p['knowledgePointId'] for p in repo.get('profiles', owner)['mastery']] == ['assessed']
    assert repo.get('plans', 'legacy-plan')['tasks'][0]['status'] == 'completed'
    before_version = repo.get('profiles', owner)['profileVersion']
    client.get(f'/api/v1/knowledge-bases/{kb}', headers=headers)
    assert repo.get('profiles', owner)['profileVersion'] == before_version
    confirmed = client.put(f"/api/v1/documents/{doc['documentId']}/knowledge-points", headers=headers,
        json={'expectedParsedAt': upgraded['parsedAt'], 'knowledgePoints': ['堆排序']})
    assert confirmed.status_code == 200
    assert any(r['knowledgePointName'] == '堆排序' for r in repo.get('profiles', owner)['mastery'])


def test_document_revision_fence_advances_on_a_frozen_or_backward_clock(monkeypatch):
    from datetime import datetime, timezone
    class FrozenClock(datetime):
        @classmethod
        def now(cls, tz=None):
            return datetime(2026, 10, 26, tzinfo=timezone.utc)
    monkeypatch.setattr(knowledge, 'datetime', FrozenClock)
    first = knowledge.next_parsed_at('2026-10-26T00:00:00+00:00')
    second = knowledge.next_parsed_at(first)
    assert first > '2026-10-26T00:00:00+00:00' and second > first
    assert knowledge.next_parsed_at('2027-01-01T00:00:00+00:00') > '2027-01-01T00:00:00+00:00'
