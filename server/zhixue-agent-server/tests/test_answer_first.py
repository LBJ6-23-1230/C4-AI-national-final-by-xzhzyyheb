"""Answer a readable question before asking for the student's attempt."""
import json
from types import SimpleNamespace

import pytest

from app.agent import chat_llm
from app.services import llm_runtime


QUESTION = '栈和队列具有相同的（）。A.抽象数据类型 B.逻辑结构 C.存储结构 D.运算'


def answer():
    return json.dumps({'readable': True, 'answerVisible': False,
                       'questionText': QUESTION, 'knowledgePoint': '栈和队列',
                       'reply': '答案：B。解析：二者都是线性逻辑结构；没有你的作答，不能判断错误原因。'}, ensure_ascii=False)


def test_readable_question_without_attempt_keeps_answer_and_explanation(monkeypatch):
    monkeypatch.setattr(chat_llm, '_call_llm_with_image', lambda *a, **k: answer())
    reply, analysis = chat_llm._handle_analyze_wrong('解题', {}, 'image', 'owner')
    assert '答案：B' in reply and '线性逻辑结构' in reply
    assert analysis['wrongType'] == ''


def test_invalid_json_is_service_failure_not_bad_image(monkeypatch):
    monkeypatch.setattr(chat_llm, '_call_llm_with_image', lambda *a, **k: '{"readable":true,"questionText":"截断')
    with pytest.raises(ValueError, match='vision_invalid_structure'):
        chat_llm._handle_analyze_wrong('解题', {}, 'image', 'owner')


def test_token_limit_is_explicit_failure(monkeypatch):
    monkeypatch.setattr(llm_runtime, 'request', lambda *a, **k: SimpleNamespace(
        choices=[SimpleNamespace(finish_reason='length', message=SimpleNamespace(content='broken'))]))
    with pytest.raises(ValueError, match='vision_output_truncated'):
        chat_llm._call_llm_with_image('system', 'user', 'image')


def test_followup_reuses_question_and_skips_classifier(monkeypatch):
    monkeypatch.setenv('DASHSCOPE_API_KEY', 'configured')
    monkeypatch.setattr(chat_llm, '_call_llm_with_image', lambda *a, **k: answer())
    chat_llm.chat('解题', 'image', user_id='owner', session_id='room')
    monkeypatch.setattr(chat_llm, 'detect_intent', lambda *a, **k: pytest.fail('extra classifier call'))
    calls = []
    def solve(system, user, **kw):
        calls.append(user)
        return answer()
    monkeypatch.setattr(chat_llm, '_call_llm', solve)
    result = chat_llm.chat('这道题答案是什么', user_id='owner', session_id='room')
    assert len(calls) == 1 and QUESTION in calls[0]
    assert '答案：B' in result['reply']
    assert not chat_llm._recent_question('other-owner', 'room')
    assert not chat_llm._recent_question('owner', 'other-room')


def test_new_failed_upload_invalidates_old_question(monkeypatch):
    monkeypatch.setattr(chat_llm, '_call_llm_with_image', lambda *a, **k: answer())
    chat_llm.chat('解题', 'image', user_id='owner', session_id='room')
    monkeypatch.setattr(chat_llm, '_call_llm_with_image', lambda *a, **k: '{')
    chat_llm.chat('请分析这张图片', 'image', user_id='owner', session_id='room')
    assert not chat_llm._recent_question('owner', 'room')


def test_multi_question_prompt_scopes_output_before_token_limit(monkeypatch):
    prompts = []
    def vision(system, user, image, **kw):
        prompts.append(system)
        return answer()
    monkeypatch.setattr(chat_llm, '_call_llm_with_image', vision)
    chat_llm._handle_analyze_wrong('分析整页', {}, 'image', 'owner')
    assert '识别图片中全部题目' in prompts[0] and 'questionCount' in prompts[0]
