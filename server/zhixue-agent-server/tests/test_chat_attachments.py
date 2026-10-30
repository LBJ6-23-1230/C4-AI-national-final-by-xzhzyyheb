import base64

import pytest

from app import create_app
from app.agent import chat_llm, knowledge


PNG = "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAFklEQVR4nGO4o6FBEmIY1TCqYfhqAAAyBCwQhvh37QAAAABJRU5ErkJggg=="


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setattr(chat_llm, 'llm_ready', lambda: False)
    monkeypatch.setattr(chat_llm, 'detect_intent', lambda message, has_image=False: ('analyze_wrong' if has_image else 'get_suggestion', False))
    monkeypatch.setenv("FILE_STORAGE", "local")
    monkeypatch.setenv("FILE_STORAGE_DIR", str(tmp_path / "files"))
    result = create_app(tmp_path / "repository.json").test_client()
    alice = result.post('/api/v1/auth/register', json={'phone': '13900009501', 'nickname': 'Alice'}).get_json()
    bob = result.post('/api/v1/auth/register', json={'phone': '13900009502', 'nickname': 'Bob'}).get_json()
    result.environ_base['HTTP_AUTHORIZATION'] = 'Bearer ' + alice['token']
    result.bob_headers = {'Authorization': 'Bearer ' + bob['token']}
    return result


def test_image_history_restores_preview_and_owned_original(client):
    result = client.post('/api/agent/chat', json={'message': '帮我诊断这道错题', 'image': PNG,
                                                'userId': 'alice', 'sessionId': 'image-session'})
    assert result.status_code == 200
    # A new app instance using the same files must still recover the image.
    repository = client.application.extensions['repository']
    restored = create_app(repository.path).test_client()
    restored.environ_base.update(client.environ_base)
    row = restored.get('/api/agent/history?userId=alice').get_json()['history'][-1]
    assert row['image_preview'].startswith('data:image/jpeg;base64,')
    assert len(row['image_preview']) < 110_000
    file_id = row['image_file_id']
    original = restored.get(f'/api/agent/images/{file_id}?userId=alice')
    assert original.status_code == 200
    assert base64.b64decode(original.get_json()['image'].split(',', 1)[1]) == base64.b64decode(PNG)
    assert 'no-store' in original.headers['Cache-Control']
    assert restored.get(f'/api/agent/images/{file_id}?userId=alice', headers=client.bob_headers).status_code == 404
    assert restored.get('/api/agent/history?userId=alice', headers=client.bob_headers).get_json()['history'] == []
    restored.delete('/api/agent/history?userId=alice')
    assert restored.get(f'/api/agent/images/{file_id}?userId=alice').status_code == 404
    assert restored.application.extensions['repository'].ids('file_objects') == []


def test_image_only_message_is_not_dropped_from_history(client):
    assert client.post('/api/agent/chat', json={'image': PNG, 'userId': 'alice'}).status_code == 200
    row = client.get('/api/agent/history?userId=alice').get_json()['history'][-1]
    assert row['user_input'] and row['image_preview']


def test_coordinated_photo_reaches_recognition_with_initialized_session(client, monkeypatch):
    calls = []
    def recognize(**kwargs):
        calls.append(kwargs)
        return dict(reply='请核对图片内容', intent='analyze_wrong', card=None, llmUsed=False)
    monkeypatch.setattr(chat_llm, 'chat', recognize)
    body = dict(message='识别错题', image=PNG, coordinateLearning=True)
    assert client.post('/api/agent/chat', json=body).status_code == 400
    assert calls == []  # The old empty-session request never reached recognition.
    response = client.post('/api/agent/chat', json=dict(body, sessionId='chat-photo-first-request'))
    assert response.status_code == 200
    assert len(calls) == 1 and calls[0]['session_id'] == 'chat-photo-first-request'
    assert calls[0]['image_base64'] == PNG


def test_expired_history_removes_old_original(client, monkeypatch):
    monkeypatch.setattr(chat_llm, 'HISTORY_MAX_ENTRIES', 1)
    client.post('/api/agent/chat', json={'message': '诊断', 'image': PNG, 'userId': 'alice'})
    row = client.get('/api/agent/history?userId=alice').get_json()['history'][0]
    client.post('/api/agent/chat', json={'message': '你好', 'userId': 'alice'})
    assert client.get(f"/api/agent/images/{row['image_file_id']}?userId=alice").status_code == 404


def test_pdf_fragments_preserve_words_and_page_boundaries():
    text = '# 第1页\n\n几个基本概念：解析解、精确解；收敛性、稳\n\n定性；\n\n误差的来源：模型误差、舍入误差。\n\n# 第2页\n\n绝对误差和相对误差。'
    chunks = knowledge.split_into_chunks(text)
    assert len(chunks) == 2
    assert '稳定性' in chunks[0]['text']
    assert '误差的来源' in chunks[0]['text']
    assert '绝对误差' not in chunks[0]['text']
    assert chunks[1]['headingPath'] == '第2页'


def test_long_chunks_end_at_sentences_and_keep_all_content():
    sentences = [f'知识点{i}：' + '完整的定义与例子' * 8 + '。' for i in range(35)]
    chunks = knowledge.split_into_chunks('# 第一章\n\n' + ''.join(sentences))
    assert len(chunks) > 1
    assert all(len(chunk['text']) <= knowledge.MAX_CHUNK_CHARS for chunk in chunks)
    assert all(chunk['text'].endswith('。') for chunk in chunks)
    for sentence in sentences:
        assert any(sentence in chunk['text'] for chunk in chunks)
