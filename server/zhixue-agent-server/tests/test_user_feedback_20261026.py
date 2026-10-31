"""User feedback regression: real document containers, two accounts and explicit scope."""
import base64
import io
import zipfile

import pytest

from app import create_app
from app.agent import chat_llm, knowledge
from app.agent.partner_match import score_partner


def encoded(value):
    return base64.b64encode(value).decode()


@pytest.fixture
def accounts(tmp_path):
    client = create_app(tmp_path / 'feedback.json').test_client()
    users = [client.post('/api/v1/auth/register', json={'password': 'test-pw-123456', 
        'phone': phone, 'nickname': phone, 'seedDemoData': False}).get_json()
        for phone in ('13900002601', '13900002602')]
    return client, [(u['user']['userId'], {'Authorization': 'Bearer ' + u['token']}) for u in users]


def pptx_bytes(with_text=True):
    stream = io.BytesIO()
    ns = 'http://schemas.openxmlformats.org/presentationml/2006/main'
    rel = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
    drawing = 'http://schemas.openxmlformats.org/drawingml/2006/main'
    with zipfile.ZipFile(stream, 'w') as archive:
        archive.writestr('ppt/presentation.xml', f'<p:presentation xmlns:p="{ns}" xmlns:r="{rel}"><p:sldIdLst><p:sldId id="256" r:id="rId1"/><p:sldId id="257" r:id="rId2"/></p:sldIdLst></p:presentation>')
        archive.writestr('ppt/_rels/presentation.xml.rels', '<Relationships><Relationship Id="rId1" Target="slides/slide1.xml"/><Relationship Id="rId2" Target="slides/slide2.xml"/></Relationships>')
        text = '<p:sp><p:txBody><a:p><a:r><a:t>网络层</a:t></a:r></a:p><a:p><a:r><a:t>路由选择决定路径</a:t></a:r></a:p></p:txBody></p:sp><a:tbl><a:tr><a:tc><a:txBody><a:p><a:r><a:t>TCP可靠传输</a:t></a:r></a:p></a:txBody></a:tc></a:tr></a:tbl>' if with_text else ''
        archive.writestr('ppt/slides/slide1.xml', f'<p:sld xmlns:p="{ns}" xmlns:a="{drawing}"><p:cSld><p:spTree>{text}</p:spTree></p:cSld></p:sld>')
        archive.writestr('ppt/slides/slide2.xml', f'<p:sld xmlns:p="{ns}"/>')
    return stream.getvalue()


def test_pptx_title_body_table_and_slide_order():
    result = knowledge.process_document('讲义.pptx', encoded(pptx_bytes()))
    assert result['status'] == 'ready'
    text = '\n'.join(c['text'] for c in result['chunks'])
    assert all(word in text for word in ('网络层', '路由选择', 'TCP', '可靠传输', '需 OCR'))
    assert result['chunks'][0]['headingPath'] == '幻灯片 1'
    assert not any(p.startswith('幻灯片') for p in result['knowledgePoints'])


def test_empty_pptx_old_ppt_and_malformed_zip_are_honest():
    assert knowledge.process_document('图片.pptx', encoded(pptx_bytes(False)))['status'] == 'failed'
    assert 'PPTX' in knowledge.classify('旧.ppt')[1]
    assert knowledge.process_document('坏.pptx', encoded(b'bad'))['status'] == 'failed'


def test_real_pdf_removes_metadata_and_preserves_page_sources():
    import pymupdf
    pdf = pymupdf.open()
    for i in range(3):
        page = pdf.new_page()
        page.insert_text((60, 60), '计算机网络 谢希仁 编著', fontname='china-s')
        page.insert_text((60, 130), f'第{i+1}章 网络层\n路由选择用于确定路径。TCP提供可靠传输。\n每题2分', fontname='china-s')
        page.insert_text((60, 760), str(i + 1))
    result = knowledge.process_document('计算机网络.pdf', encoded(pdf.tobytes()))
    pdf.close()
    assert result['status'] == 'ready'
    assert {'路由选择', 'TCP', '可靠传输'} & set(result['knowledgePoints'])
    assert not {'编著', '谢希仁', '每题', '协议'} & set(result['knowledgePoints'])
    assert any('第1页' in c['headingPath'] for c in result['chunks'])


def test_document_revision_deduplicates_reparses_and_checks_ownership(accounts):
    client, users = accounts
    owner, headers = users[0]
    kb = client.post('/api/v1/knowledge-bases', headers=headers,
        json={'courseName': '计算机网络', 'name': '网络资料'}).get_json()['kbId']
    doc = client.post(f'/api/v1/knowledge-bases/{kb}/documents', headers=headers,
        json={'fileName': '课件.md', 'contentBase64': encoded('# 网络层\n\nTCP提供可靠传输，路由选择决定路径。'.encode())}).get_json()
    url = f"/api/v1/documents/{doc['documentId']}/knowledge-points"
    request = {'knowledgePoints': ['TCP', 'TCP', '路由选择'], 'expectedParsedAt': doc['parsedAt']}
    assert client.put(url, headers=users[1][1], json=request).status_code == 404
    revised = client.put(url, headers=headers, json=request).get_json()
    assert revised['knowledgePoints'] == ['TCP', '路由选择'] and revised['tagsConfirmed']
    assert client.put(url, headers=headers, json=request).status_code == 409
    reparsed = client.put(url, headers=headers, json={'reparse': True, 'expectedParsedAt': revised['parsedAt']}).get_json()
    assert not reparsed['tagsConfirmed']
    detail = client.get(f"/api/v1/documents/{doc['documentId']}", headers=headers).get_json()
    assert any(e['chunkId'] and e['excerpt'] for e in detail['knowledgePointEvidence'])


def test_explicit_preferences_sync_and_do_not_guess_course(accounts):
    client, users = accounts
    for owner, headers in users:
        client.post(f'/api/v1/profile/{owner}/knowledge-points', headers=headers, json={'courses': ['数据结构', '操作系统']})
    result = client.post('/api/v1/agent/partner-match', headers=users[0][1], json={}).get_json()
    assert result['candidates'][0]['candidate']['learningGoal']['course'] == ''
    for owner, headers in users:
        response = client.put(f'/api/v1/profile/{owner}/preferences', headers=headers, json={
            'targetCourse': '计算机网络', 'goal': '准备期末', 'freeTimeSlots': ['19:00-21:00']})
        assert response.status_code == 200
    result = client.post('/api/v1/agent/partner-match', headers=users[0][1], json={}).get_json()
    factors = result['candidates'][0]['factors']
    assert factors['goal'] == 30 and factors['timeOverlap'] == 30
    assert factors['knowledgeComplement'] == 0
    assert score_partner({}, {'time': {'freeTime': []}})['factors']['stability'] == 0


@pytest.mark.parametrize('slots', [['25:00-26:00'], ['19:60-21:00'], ['21:00-19:00'], '晚上'])
def test_preferences_reject_invalid_times(accounts, slots):
    client, users = accounts
    owner, headers = users[0]
    assert client.put(f'/api/v1/profile/{owner}/preferences', headers=headers,
        json={'targetCourse': '网络', 'goal': '期末', 'freeTimeSlots': slots}).status_code == 400


def test_discovery_pool_and_course_budget_preserve_completed_work(accounts):
    from app.api.profile import _repository
    client, users = accounts
    owner, headers = users[0]
    client.post(f'/api/v1/profile/{owner}/knowledge-points', headers=headers, json={'courses': ['数据结构', '操作系统']})
    plan = client.get('/api/v1/plans/current', headers=headers).get_json()
    assert not plan['tasks'] and len(plan['candidatePool']) > 3
    url = '/api/v1/plans/current/availability'
    request = {'availableMinutes': 30, 'expectedPlanVersion': plan['version'], 'idempotencyKey': 'scoped'}
    assert client.post(url, headers=headers, json=request).status_code == 400
    request['targetCourse'] = '操作系统'
    response = client.post(url, headers=headers, json=request)
    assert response.status_code == 200
    planned = response.get_json()['plan']
    assert 1 <= len(planned['tasks']) <= 3
    assert all(t['sourceCourse'] == '操作系统' for t in planned['tasks'])
    assert sum(t['durationMinutes'] for t in planned['tasks']) <= 30
    assert not planned['unscheduledTasks'] and planned['candidatePool']
    assert client.post(url, headers=headers, json=request).get_json() == response.get_json()
    saved = _repository.get('plans', planned['planId'])
    saved['tasks'][0]['status'] = 'completed'
    done = saved['tasks'][0].copy()
    _repository.save('plans', saved['planId'], saved)
    request.update(targetCourse='数据结构', expectedPlanVersion=saved['version'], idempotencyKey='next')
    next_plan = client.post(url, headers=headers, json=request).get_json()['plan']
    assert done in next_plan['tasks']


def test_chat_missing_attachment_and_session_context_are_isolated(monkeypatch):
    chat_llm.append_history('甲会话秘密', '甲回答', 'u', 'a')
    chat_llm.append_history('乙会话问题', '乙回答', 'u', 'b')
    prompts = []
    monkeypatch.setattr(chat_llm, 'detect_intent', lambda *a, **k: ('get_suggestion', True))
    monkeypatch.setattr(chat_llm, '_call_llm', lambda system, prompt, **kwargs: prompts.append(prompt) or '建议')
    chat_llm.chat('今天学什么', user_id='u', session_id='b')
    assert '乙会话问题' in prompts[-1] and '甲会话秘密' not in prompts[-1]
    missing = chat_llm.chat('分析这张图片里的题', user_id='u', session_id='b')
    assert '没有附带' in missing['reply'] and not missing['wrongAnalysis']


def test_consultation_does_not_start_learning_goal(accounts):
    client, users = accounts
    _, headers = users[0]
    for text in ('这个学习软件怎么使用', '学习搭子有哪些功能', '请介绍学习计划功能', '帮我生成学习计划功能介绍'):
        result = client.post('/api/agent/chat', headers=headers, json={
            'message': text, 'sessionId': text, 'coordinateLearning': True}).get_json()
        assert 'learningContext' not in result


def test_submission_review_read_is_owner_scoped(accounts):
    client, users = accounts
    from app.api.exercises import _repository
    owner, headers = users[0]
    response = {'userId': owner, 'submissionId': 'sample', 'review': [], 'assessment': {}, 'reviewStatus': 'pending'}
    _repository.save('submissions', 'sample', {'response': response})
    assert client.get('/api/v1/exercise-submissions/sample', headers=headers).get_json() == response
    assert client.get('/api/v1/exercise-submissions/sample', headers=users[1][1]).status_code == 404


def test_legacy_backlog_becomes_candidates_and_keeps_completion(accounts):
    from app.api.profile import _repository
    client, users = accounts
    owner, headers = users[0]
    profile = _repository.get('profiles', owner)
    profile['mastery'] = [{'knowledgePointId': str(i), 'knowledgePointName': f'知识{i}', 'sourceCourse': '网络'} for i in range(31)]
    _repository.save('profiles', owner, profile)
    tasks = [{'taskId': f'task-{i}', 'knowledgePointId': str(i), 'knowledgePointName': f'知识{i}',
        'durationMinutes': 30, 'status': 'completed' if i == 0 else 'pending'} for i in range(31)]
    _repository.save('plans', f'plan-import-{owner}', {'planId': f'plan-import-{owner}', 'userId': owner,
        'version': 2, 'tasks': tasks, 'generatedFromProfileVersion': 1})
    plan = client.get('/api/v1/plans/current', headers=headers).get_json()
    assert plan['tasks'] == [tasks[0]] and len(plan['candidatePool']) == 30
    assert plan['version'] == 3
    assert client.get('/api/v1/plans/current', headers=headers).get_json()['version'] == 3


def test_long_document_has_bounded_chunks():
    result = knowledge.process_document('long.txt', encoded(('网络' * 3000).encode()))
    assert result['status'] == 'ready' and len(result['chunks']) > 1
    assert all(len(c['text']) <= knowledge.MAX_CHUNK_CHARS for c in result['chunks'])


def test_profile_confirmation_cannot_cross_chat_sessions(monkeypatch):
    updates = {'course': [{'courseName': '网络', 'tasks': [{'taskname': '复习'}]}]}
    monkeypatch.setattr(chat_llm, 'detect_intent', lambda *a, **k: ('unknown', False))
    with chat_llm._PENDING_PROFILE_LOCK:
        chat_llm._PENDING_PROFILE_UPDATES[('u', 'a')] = updates
    assert not chat_llm.chat('确认更新', user_id='u', session_id='b')['profileUpdates']
    assert chat_llm.chat('确认更新', user_id='u', session_id='a')['profileUpdates'] == updates
