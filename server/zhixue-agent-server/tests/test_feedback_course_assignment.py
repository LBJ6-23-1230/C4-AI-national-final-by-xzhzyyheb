import pytest
from app import create_app
from app.api import wrong_book


def test_unverified_photo_has_no_empty_answer_claim(tmp_path):
    create_app(tmp_path / 'preview.json')
    record = wrong_book.add_item(wrong_book._repository, 'demo-user', {
        'exerciseId': 'photo', 'stem': '待核对题目', 'answerKey': '', 'source': 'photo'})
    assert '尚待核对' in record['explanation']
    legacy = dict(record, explanation='正确答案是 。请结合题干与选项重新核对概念。')
    assert '尚待核对' in wrong_book._public(legacy)['explanation']
    assert 'answerKey' not in wrong_book._public(legacy)
    assert wrong_book._public(dict(record, explanation='保留原始解析'))['explanation'] == '保留原始解析'


def setup_book(tmp_path):
    client = create_app(tmp_path / 'feedback.json').test_client()
    for exercise in ('exercise-preorder-001', 'exercise-inorder-001'):
        assert client.post('/api/v1/wrong-book/' + exercise, json={'added': True}).status_code == 200
    return client


def test_manual_course_survives_inference_and_preserves_history(tmp_path):
    client = setup_book(tmp_path)
    client.post('/api/v1/wrong-book/exercise-preorder-001/attempt', json={'answer': 'A'})
    before = wrong_book._repository.get('wrong_book', 'demo-user:exercise-preorder-001')
    response = client.post('/api/v1/wrong-book/classify', json={
        'exerciseIds': ['exercise-preorder-001', 'exercise-preorder-001'], 'courseName': ' 算法专题 '})
    assert response.status_code == 200
    assert response.get_json() == {'courseName': '算法专题', 'updatedCount': 1}
    after = wrong_book._repository.get('wrong_book', 'demo-user:exercise-preorder-001')
    assert {k: v for k, v in before.items() if k not in ('courseName', 'courseConfirmed')} == {
        k: v for k, v in after.items() if k not in ('courseName', 'courseConfirmed')}
    book = client.get('/api/v1/wrong-book').get_json()
    assert book['total'] == 2
    assert any(c['courseName'] == '算法专题' for c in book['courses'])
    # Adding the same item again must not lose the user's explicit decision.
    client.post('/api/v1/wrong-book/exercise-preorder-001', json={'added': True})
    assert any(c['courseName'] == '算法专题' for c in client.get('/api/v1/wrong-book').get_json()['courses'])


def test_batch_assignment_is_atomic_and_owner_scoped(tmp_path):
    client = setup_book(tmp_path)
    foreign = dict(wrong_book._repository.get('wrong_book', 'demo-user:exercise-preorder-001'), userId='other', exerciseId='foreign')
    wrong_book._repository.save('wrong_book', 'other:foreign', foreign)
    response = client.post('/api/v1/wrong-book/classify', json={
        'exerciseIds': ['exercise-preorder-001', 'foreign'], 'courseName': '新课程'})
    assert response.status_code == 404
    assert wrong_book._repository.get('wrong_book', 'demo-user:exercise-preorder-001')['courseName'] == '数据结构'
    assert wrong_book._repository.get('wrong_book', 'other:foreign') == foreign
    response = client.post('/api/v1/wrong-book/classify', json={
        'exerciseIds': ['exercise-preorder-001', 'exercise-inorder-001'], 'courseName': '新课程'})
    assert response.get_json()['updatedCount'] == 2
    assert len(client.get('/api/v1/wrong-book').get_json()['courses']) == 1


@pytest.mark.parametrize('course,ids', [('', ['x']), ('待确认科目', ['x']), ('x' * 31, ['x']),
    ('数学\n', ['x']), (123, ['x']), ('数学', []), ('数学', ['x'] * 101), ('数学', [None])])
def test_invalid_assignment_rejected(tmp_path, course, ids):
    client = setup_book(tmp_path)
    assert client.post('/api/v1/wrong-book/classify', json={'courseName': course, 'exerciseIds': ids}).status_code == 400


def test_vision_course_recommendation_preserves_uncertainty():
    from app.services.vision_diagnosis import normalize
    _, result = normalize({'questionCount': 3, 'complete': False, 'questions': [
        {'readable': True, 'questionText': '求导', 'reply': '答案', 'courseName': '高等数学'},
        {'readable': True, 'questionText': '综合题', 'reply': '答案'},
        {'readable': False, 'questionText': '', 'courseName': '猜测科目'}]})
    assert [q['courseName'] for q in result['questions']] == ['高等数学', '', '']
    assert result['courseName'] == '高等数学'
