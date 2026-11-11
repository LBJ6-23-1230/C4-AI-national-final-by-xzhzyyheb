from datetime import datetime, timedelta, timezone
import pytest
from app import create_app
from app.services.learning_effect import projected_mastery
from app.services.subject_classification import normalized_mastery


@pytest.fixture
def setup(tmp_path):
    app = create_app(tmp_path/'screenshots.json')
    return app.test_client(), app.extensions['repository']


@pytest.mark.parametrize('name,course', [('二叉搜索树','数据结构'),('内存分页机制','操作系统'),
                                      ('内存管理','操作系统'),('排序算法','数据结构'),('自定义课程专题','自定义课程')])
def test_course_match_is_sufficient_even_without_a_chapter_group(setup,name,course):
    _,repo=setup
    point=dict(knowledgePointId='p',knowledgePointName=name,sourceCourse=course,masteryScore=0,confidence=0)
    result=projected_mastery(repo,'demo-user',normalized_mastery(dict(mastery=[point])))[0]
    assert result['sourceCourse']==course
    assert result['classificationRequired'] is False


def test_confirm_course_does_not_require_a_theme_or_change_answer_statistics(setup):
    c,repo=setup
    profile=repo.get('profiles','demo-user')
    profile['mastery'].append(dict(knowledgePointId='custom',knowledgePointName='陌生资料专题',sourceCourse='',masteryScore=0,confidence=0))
    repo.save('profiles','demo-user',profile)
    payload=dict(knowledgePointId='custom',courseName='用户确认的课程',expectedProfileVersion=profile['profileVersion'])
    response=c.put('/api/v1/profile/demo-user/knowledge-points/classification',json=payload)
    assert response.status_code==200
    matched=next(p for p in response.json['mastery'] if p['knowledgePointId']=='custom')
    assert matched['classificationRequired'] is False and matched['sourceCourse']=='用户确认的课程'
    assert matched['effectiveQuestionCount']==0


def test_review_progress_requires_later_matching_owned_submission(setup):
    c,repo=setup
    start=datetime.now(timezone.utc)-timedelta(hours=1)
    task=dict(taskId='review-a',userId='demo-user',knowledgePointId='p',courseName='数据结构',title='复习P',
              actionType='practice',status='pending',createdAt=start.isoformat())
    repo.save('review_tasks','review-a',task)
    def submission(key,owner,point,stamp):
        repo.save('submissions',key,dict(userId=owner,createdAt=stamp.isoformat(),questionFacts=[dict(knowledgePointId=point,correct=False)]))
    submission('early','demo-user','p',start-timedelta(seconds=1))
    submission('foreign','someone-else','p',start+timedelta(seconds=1))
    submission('unrelated','demo-user','q',start+timedelta(seconds=1))
    assert not c.get('/api/v1/learning-review-tasks').json['tasks'][0]['practiceVerified']
    submission('matching','demo-user','p',start+timedelta(seconds=2))
    result=c.get('/api/v1/learning-review-tasks').json['tasks'][0]
    assert result['practiceVerified'] and result['status']=='practiced'
    assert result['completionSource']=='exercise_submission'
    assert repo.get('review_tasks','review-a')==task


def test_legacy_checkbox_is_not_treated_as_practice_evidence(setup):
    c,repo=setup
    repo.save('review_tasks','legacy',dict(taskId='legacy',userId='demo-user',knowledgePointId='p',status='completed',createdAt=datetime.now(timezone.utc).isoformat()))
    item=c.get('/api/v1/learning-review-tasks').json['tasks'][0]
    assert item['status']=='completed' and item['practiceVerified'] is False
