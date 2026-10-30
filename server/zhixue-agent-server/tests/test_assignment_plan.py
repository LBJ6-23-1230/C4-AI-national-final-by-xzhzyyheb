from copy import deepcopy
from types import SimpleNamespace

import pytest

from app import create_app
from app.api import plans
from app.agent import chat_llm
from app.services import llm_runtime

URL = '/api/v1/plans/current/assignments'


def assignment(key='ddl-one', **changes):
    return dict(id=key, title='二叉树实验报告', courseName='数据结构', dueDate='2026-10-29',
                estimatedMinutes=60, priority='高', completed=False, **changes)


@pytest.mark.parametrize('backend', ['json', 'sqlite'])
def test_sync_add_complete_and_empty_device_snapshot_preserves_tasks(tmp_path, monkeypatch, backend):
    monkeypatch.setenv('ZHIXUE_DB', backend)
    client = create_app(tmp_path / 'assignments.json').test_client()
    original = client.get('/api/v1/plans/current').get_json()
    row = assignment()
    body = {'assignments': [row]}
    first = client.post(URL, json=body).get_json()
    assert first['tasks'] == original['tasks']
    assert first['unscheduledTasks'][0]['taskId'] == row['id']
    assert first['unscheduledTasks'][0]['dueDate'] == row['dueDate']
    assert client.post(URL, json=body).get_json() == first
    added = client.post(URL, json=dict(body, selectedId=row['id'])).get_json()
    assert len([t for t in added['tasks'] if t['taskId'] == row['id']]) == 1
    assert client.post(URL, json=dict(body, selectedId=row['id'])).get_json() == added
    completed = client.post(URL, json={'assignments': [dict(row, completed=True)]}).get_json()
    assert next(t for t in completed['tasks'] if t['taskId'] == row['id'])['status'] == 'completed'
    removed = client.post(URL, json={'assignments': []}).get_json()
    assert removed == completed  # Empty device cache is not a deletion request.


def test_new_account_sync_repairs_existing_local_ddls_and_isolates_identity(tmp_path):
    client = create_app(tmp_path / 'account.json').test_client()
    auth = client.post('/api/v1/auth/register', json={'nickname': 'DDL测试', 'phone': '13900008765',
        'grade': '大二', 'seedDemoData': False}).get_json()
    headers = {'Authorization': 'Bearer ' + auth['token']}
    body = {'assignments': [assignment()], 'userId': 'demo-user'}
    result = client.post(URL, json=body, headers=headers).get_json()
    assert result['userId'] == auth['user']['userId']
    assert not result['tasks'] and len(result['unscheduledTasks']) == 1
    assert not any(t.get('source') == 'ddl' for t in client.get('/api/v1/plans/current').get_json()['tasks'])
    assert client.post(URL, json=dict(body, userId=auth['user']['userId'])).status_code == 404
    response = client.post('/api/v1/plans/current/availability', headers=headers, json={
        'targetCourse': '数据结构', 'availableMinutes': 60, 'expectedPlanVersion': result['version'], 'idempotencyKey': 'ddl-budget'})
    assert response.status_code == 200
    assert response.get_json()['plan']['tasks'][0]['taskId'] == 'ddl-one'


@pytest.mark.parametrize('change', [{'estimatedMinutes': 0}, {'estimatedMinutes': True}, {'dueDate': 'bad'}, {'completed': 'false'}])
def test_invalid_snapshot_does_not_change_plan(tmp_path, change):
    client = create_app(tmp_path / 'validation.json').test_client()
    before = deepcopy(plans._repository.list('plans'))
    assert client.post(URL, json={'assignments': [dict(assignment(), **change)]}).status_code == 400
    assert plans._repository.list('plans') == before


def test_vision_has_independent_budget_and_timeout_is_reported(monkeypatch, tmp_path):
    monkeypatch.setenv('LLM_TIMEOUT_SECONDS', '30')
    monkeypatch.delenv('LLM_VISION_TIMEOUT_SECONDS', raising=False)
    seen = []
    def response(kind, payload, **kwargs):
        seen.append(kwargs['budget'])
        return SimpleNamespace(choices=[SimpleNamespace(finish_reason='stop', message=SimpleNamespace(content='{}'))])
    monkeypatch.setattr(llm_runtime, 'request', response)
    chat_llm._call_llm_with_image('system', 'question', 'image')
    assert seen == [120]
    monkeypatch.setenv('DASHSCOPE_API_KEY', 'test')
    monkeypatch.setenv('ZHIXUE_CHAT_DIR', str(tmp_path))
    monkeypatch.setattr(chat_llm, 'detect_intent', lambda *a, **k: ('analyze_wrong', True))
    def timeout(*args, **kwargs):
        raise TimeoutError('llm_budget')
    monkeypatch.setattr(chat_llm, '_handle_analyze_wrong', timeout)
    result = chat_llm.chat('分析图片', image_base64='image')
    assert not result['llmUsed'] and '识别超时' in result['reply']
    assert not result['wrongAnalysis']
