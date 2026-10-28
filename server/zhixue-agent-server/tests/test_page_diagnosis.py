"""Whole-page coverage, scoped reuse, and independent learning goals."""
import json
import threading
from concurrent.futures import ThreadPoolExecutor
from types import SimpleNamespace

import pytest

from app import create_app
from app.agent import chat_llm
from app.services import llm_runtime, vision_cache
from app.services.vision_diagnosis import normalize


def page():
    return {"questionCount": 3, "complete": True, "questions": [
        {"questionNumber": str(n), "readable": True, "answerVisible": n == 2,
         "questionText": f"题目{n}：请选择正确的选项。A.甲 B.乙 C.丙 D.丁",
         "knowledgePoint": f"知识点{n}", "wrongType": "概念混淆", "reply": f"答案：B；解析：第{n}题的推导。"}
        for n in (1, 2, 3)]}


@pytest.fixture(autouse=True)
def clean_cache():
    vision_cache.clear()
    yield
    vision_cache.clear()


def test_every_question_survives_and_error_attribution_is_per_question(monkeypatch):
    calls = []
    def vision(*args, **kwargs):
        calls.append(args)
        return json.dumps(page(), ensure_ascii=False)
    monkeypatch.setattr(chat_llm, '_call_llm_with_image', vision)
    reply, result = chat_llm._handle_analyze_wrong('整页分析', {}, 'image', 'alice')
    assert len(calls) == 1
    assert result['complete'] and result['questionCount'] == 3
    assert [q['questionNumber'] for q in result['questions']] == ['1', '2', '3']
    assert [q['wrongType'] for q in result['questions']] == ['', '概念混淆', '']
    assert all(f'第{n}题' in reply for n in (1, 2, 3))


@pytest.mark.parametrize('failure', ['missing', 'unreadable', 'no_reply', 'incomplete'])
def test_partial_page_is_never_reported_as_complete(failure):
    data = page()
    if failure == 'missing':
        data['questions'].pop()
    elif failure == 'unreadable':
        data['questions'][1]['readable'] = False
    elif failure == 'no_reply':
        data['questions'][1]['reply'] = ''
    else:
        data['complete'] = False
    reply, result = normalize(data)
    assert not result['complete'] and result['recognitionStatus'] == 'partial'
    assert '部分' in reply
    if failure == 'unreadable':
        assert result['questions'][1]['knowledgePoint'] == ''
        assert result['questions'][1]['wrongType'] == ''


@pytest.mark.parametrize('data', [{}, {'questions': 'bad'}, {'questions': [1]},
                                  dict(page(), questionCount=2), dict(page(), questionCount=True)])
def test_invalid_page_structure_is_rejected(data):
    with pytest.raises(ValueError, match='vision_invalid_structure'):
        normalize(data)


def test_repeated_image_reuses_only_same_owner_prompt_model_and_thinking(monkeypatch):
    calls = []
    def request(*args, **kwargs):
        calls.append(args[1])
        return SimpleNamespace(choices=[SimpleNamespace(finish_reason='stop',
            message=SimpleNamespace(content=json.dumps(page())))])
    monkeypatch.setattr(llm_runtime, 'request', request)
    call = lambda owner='alice', prompt='all': chat_llm._call_llm_with_image('system', prompt, 'image', True, owner)
    first = call()
    assert call() == first and len(calls) == 1
    call('bob')
    call(prompt='only question 2')
    monkeypatch.setenv('LLM_VL_MODEL', 'different-vision-model')
    call()
    monkeypatch.setenv('LLM_ENABLE_THINKING', '1')
    call()
    assert len(calls) == 5
    assert calls[0]['max_tokens'] >= 12000


def test_partial_vision_output_is_not_cached(monkeypatch):
    calls = []
    def request(*args, **kwargs):
        calls.append(1)
        data = page()
        data['complete'] = len(calls) > 1
        return SimpleNamespace(choices=[SimpleNamespace(finish_reason='stop',
            message=SimpleNamespace(content=json.dumps(data)))])
    monkeypatch.setattr(llm_runtime, 'request', request)
    for _ in range(3):
        chat_llm._call_llm_with_image('system', 'all', 'image', True, 'alice')
    assert len(calls) == 2


def test_simultaneous_retries_share_one_model_call_and_expire(monkeypatch):
    calls = []
    entered, release = threading.Event(), threading.Event()
    def compute():
        calls.append(1)
        entered.set()
        assert release.wait(2)
        return 'validated'
    with ThreadPoolExecutor(max_workers=4) as pool:
        futures = [pool.submit(vision_cache.resolve, 'same-owner-key', compute, lambda _: True, 2) for _ in range(4)]
        assert entered.wait(2)
        release.set()
        assert [f.result() for f in futures] == ['validated'] * 4
    assert len(calls) == 1
    monkeypatch.setattr(vision_cache.time, 'monotonic', lambda: float('inf'))
    vision_cache.resolve('same-owner-key', compute, lambda _: True, 2)
    assert len(calls) == 2


def test_failure_does_not_poison_retry():
    def fail():
        raise TimeoutError('model deadline')
    with pytest.raises(TimeoutError):
        vision_cache.resolve('key', fail, lambda _: True, 1)
    assert vision_cache.resolve('key', lambda: 'ok', lambda _: True, 1) == 'ok'


@pytest.mark.parametrize('backend', ['json', 'sqlite'])
def test_http_preserves_all_diagnoses_and_numbered_followup(tmp_path, monkeypatch, backend):
    from tests.test_screenshot_feedback import png
    monkeypatch.setenv('ZHIXUE_DB', backend)
    monkeypatch.setenv('DASHSCOPE_API_KEY', 'test-only')
    monkeypatch.setattr(chat_llm, '_call_llm_with_image', lambda *a, **k: json.dumps(page()))
    client = create_app(tmp_path / 'pages.json').test_client()
    auth = client.post('/api/v1/auth/register', json={'nickname': '整页测试', 'phone': '13900009801',
        'grade': '大二', 'seedDemoData': False}).get_json()
    headers = {'Authorization': 'Bearer ' + auth['token']}
    result = client.post('/api/agent/chat', headers=headers, json={'message': '整页分析', 'image': png(),
        'sessionId': 'page-chat', 'coordinateLearning': True}).get_json()
    questions = result['wrongAnalysis']['questions']
    assert result['attachmentReceipt']['status'] == 'recognized'
    assert len({q['diagnosisId'] for q in questions}) == 3
    goal = client.post('/api/v1/workflows/chat/page-chat/goals', headers=headers,
        json={'action': 'start', 'diagnosisId': questions[2]['diagnosisId']}).get_json()
    assert goal['learningContext']['knowledgePointName'] == '知识点3'
    context = chat_llm._recent_question(auth['user']['userId'], 'page-chat')
    assert all(f'题目{n}' in context['questionText'] for n in (1, 2, 3))
    assert not chat_llm._recent_question('another-owner', 'page-chat')


def test_short_equation_is_not_rejected_by_arbitrary_text_length():
    data = page()
    data['questions'][0]['questionText'] = '1+1=?'
    assert normalize(data)[1]['questions'][0]['recognitionStatus'] == 'recognized'


def test_whitespace_reply_and_missing_count_cannot_claim_full_coverage():
    data = page()
    data['questions'][0]['reply'] = '   '
    assert not normalize(data)[1]['complete']
    data = page()
    del data['questionCount']
    assert not normalize(data)[1]['complete']


def test_unreadable_first_question_keeps_readable_followup_context(monkeypatch):
    data = page()
    data['questions'][0].update(readable=False, questionText='')
    monkeypatch.setattr(chat_llm, '_call_llm_with_image', lambda *a, **k: json.dumps(data))
    chat_llm.chat('整页分析', 'image', user_id='partial-owner', session_id='page')
    context = chat_llm._recent_question('partial-owner', 'page')
    assert '题目2' in context['questionText'] and '题目3' in context['questionText']
