from app import create_app
from app.services.subject_classification import subject, topic_group


def test_topics_are_not_subjects():
    assert subject('栈出栈序列的不确定性', '栈出栈序列的不确定性') == '数据结构'
    assert subject('', '栈的基本操作：Push、Pop、Top的语义与副作用') == '数据结构'
    assert subject('', 'TCP 三次握手') == '计算机网络'
    assert topic_group('栈的基本操作：Push、Pop、Top的语义与副作用') == '栈'
    assert topic_group('栈出栈序列的不确定性') == '栈'
    assert subject('离散数学', '命题逻辑') == '离散数学'


def test_legacy_wrong_book_is_grouped_without_mutating_progress(tmp_path):
    app = create_app(tmp_path / 'legacy.json')
    repository = app.extensions['repository']
    owner = 'demo-user'
    original = dict(userId=owner, exerciseId='stack-test', courseName='栈出栈序列的不确定性',
        knowledgePointId='stack-x', knowledgePointName='栈出栈序列的不确定性', stem='判断合法出栈顺序',
        correctCount=2, wrongCount=3, options=[], addedAt='2026-10-29')
    repository.save('wrong_book', owner + ':stack-test', original)
    response = app.test_client().get('/api/v1/wrong-book').get_json()
    group = next(x for x in response['courses'] if any(q['exerciseId'] == 'stack-test' for q in x['items']))
    assert group['courseName'] == '数据结构'
    item = next(x for x in group['items'] if x['exerciseId'] == 'stack-test')
    assert item['knowledgeGroup'] == '栈' and item['correctCount'] == 2
    assert repository.get('wrong_book', owner + ':stack-test') == original


def test_import_confidence_is_not_assessment_and_scanning_is_opt_in(tmp_path):
    app = create_app(tmp_path / 'evidence.json')
    repository = app.extensions['repository']
    repository.save('profiles', 'demo-user', {'userId': 'demo-user', 'mastery': [
        {'knowledgePointId': 'stack-x', 'knowledgePointName': '栈', 'sourceCourse': '数据结构',
         'confidence': 0.9, 'masteryScore': 0}], 'evidence': [
        {'id': 'import-1', 'knowledgePointId': 'stack-x', 'sourceType': 'document'}],
        'history': [], 'courseGoals': None, 'courseExams': None})
    client = app.test_client()
    response = client.post('/api/v1/learning-reviews', json={'courseName': '数据结构'})
    assert response.status_code == 200
    assert response.get_json()['snapshot']['unassessedCount'] == 1
    assert not any(x.get('exerciseId') == 'stack-x' for x in repository.list('wrong_book'))
