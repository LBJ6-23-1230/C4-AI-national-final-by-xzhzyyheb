import base64
import io
import zipfile
from xml.sax.saxutils import escape

from app import create_app
from app.api import exercises
from app.services.file_storage import storage


def _docx(lines):
    ns = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'
    paragraphs = ''.join('<w:p><w:r><w:t>' + escape(line) + '</w:t></w:r></w:p>' for line in lines)
    output = io.BytesIO()
    with zipfile.ZipFile(output, 'w') as archive:
        archive.writestr('word/document.xml', f'<w:document xmlns:w="{ns}"><w:body>{paragraphs}'
                         '<w:p><w:r><w:t>23. 图中矩阵正确。（√）</w:t><w:drawing/></w:r></w:p>'
                         '</w:body></w:document>')
    return output.getvalue()


def test_document_bank_draw_grade_and_prefer_unseen(tmp_path, monkeypatch):
    monkeypatch.setenv('FILE_STORAGE', 'local')
    monkeypatch.setenv('FILE_STORAGE_DIR', str(tmp_path / 'originals'))
    client = create_app(tmp_path / 'bank.json').test_client()
    repository = exercises._repository
    accounts = [client.post('/api/v1/auth/register', json={'phone': phone, 'nickname': phone,
        'password': 'bank-test-password', 'seedDemoData': False}).get_json()
        for phone in ('13900004601', '13900004602')]
    owner = accounts[0]['user']['userId']
    headers, other = [{'Authorization': 'Bearer ' + account['token']} for account in accounts]
    course = '数值分析'
    kb_id = client.post('/api/v1/knowledge-bases', headers=headers, json={
        'courseName': course, 'name': '测试资料库'}).get_json()['kbId']
    name = '客观题汇总.docx'
    raw = _docx(['1. 下面哪个是插值算法？（B）', 'A. 高斯消去', 'B. 拉格朗日插值', 'C. 幂法'] +
        [f'{number}. 算法示例 {number} 的描述符合定义。（√）' for number in range(2, 22)] +
        ['22. 这道题缺少答案。'])
    document = client.post(f'/api/v1/knowledge-bases/{kb_id}/documents', headers=headers, json={
        'fileName': name, 'contentBase64': base64.b64encode(raw).decode()}).get_json()
    doc_id = document['documentId']
    original = storage().put(owner, raw, name)
    repository.save('file_objects', original['fileId'], dict(original, documentId=doc_id))
    repository.save('documents', doc_id, dict(document, fileId=original['fileId']))
    listing = '/api/v1/exercises/document-banks'
    query = {'courseName': course}
    banks = client.get(listing, headers=headers, query_string=query).get_json()
    assert banks == {'banks': [dict(kbId=kb_id, documentId=doc_id, fileName=name, count=21, remaining=21)], 'maxCount': 20}
    assert client.get(listing, headers=other, query_string={'documentId': doc_id}).status_code == 404
    assert client.get(listing, headers=headers, query_string={'courseName': '操作系统'}).get_json()['banks'] == []
    route = '/api/v1/exercises/set-demo-binary-tree-001'
    draw = dict(kbId=kb_id, documentId=doc_id, sourceMode='document_bank', count=20)
    assert client.get(route, headers=other, query_string=draw).status_code == 404
    assert client.get(route, headers=headers, query_string=dict(draw, count=21)).status_code == 400
    questions = client.get(route, headers=headers, query_string=draw).get_json()['exercises']
    assert len(questions) == 20 and len({q['exerciseId'] for q in questions}) == 20
    assert all(q['source'] == 'document_bank' and 'answerKey' not in q and 'explanation' not in q for q in questions)
    assert questions[0]['stem'].endswith('？') and len(questions[0]['options']) == 3
    assert questions[1]['options'] == ['A. 正确', 'B. 错误']
    before = repository.get('profiles', owner)
    submission = dict(idempotencyKey='document-bank-round', answers=[
        dict(exerciseId=q['exerciseId'], answer='A') for q in questions])
    graded = client.post(route + '/submit', headers=headers, json=submission).get_json()
    assert graded['assessment']['score'] == 95
    assert graded['review'][0]['correctAnswer'] == 'B' and graded['review'][0]['inWrongBook']
    assert graded['masteryUpdate'] is None and not graded['needReplan'] and graded['reviewStatus'] == 'completed'
    assert repository.get('profiles', owner) == before
    assert client.post(route + '/submit', headers=headers, json=submission).get_json() == graded
    assert client.get(listing, headers=headers, query_string=query).get_json()['banks'][0]['remaining'] == 1
    next_set = client.get(route, headers=headers, query_string=dict(draw, count=3)).get_json()['exercises']
    assert next_set[0]['exerciseId'] not in {q['exerciseId'] for q in questions}


def test_unverified_section_and_conflicting_keys_are_skipped():
    from app.services.document_bank import parse_questions

    text = ('1. 有效的判断题。（√）\n2. 同一个判断题。（×）\n3. 同一个判断题。（√）\n'
            '第四章（答案还没出，以下答案是AI给的）\n1. 未核实的判断题。（×）')
    assert parse_questions(text) == (('有效的判断题。', ('A. 正确', 'B. 错误'), 'A'),)
