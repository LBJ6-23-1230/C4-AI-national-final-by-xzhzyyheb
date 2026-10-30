from copy import deepcopy
from app.agents.planner import PlannerAgent
from app.tools.time_budget import fit_plan_to_budget


def test_assessment_preserves_ddl_and_uses_remaining_ten_minutes():
    plan = dict(version=3, constraints=dict(availableMinutes=40), tasks=[
        dict(taskId='practice', knowledgePointId='linear', knowledgePointName='线性表基础练习',
             durationMinutes=30, status='pending'),
        dict(taskId='homework', knowledgePointId='ddl:hw', source='ddl', dueDate='2026-10-31',
             knowledgePointName='操作系统实验', durationMinutes=30, status='pending')])
    original = deepcopy(plan)
    result = PlannerAgent().run(dict(plan=plan, needReplan=True, replanState=dict(
        knowledgePointId='linear', masteryScore=20, assessmentScore=40, repeatedError=True))).output
    assert plan == original
    assert result['plan']['version'] == 4
    assert result['plan']['budgetSummary']['scheduledMinutes'] == 40
    assert result['plan']['tasks'][0]['taskId'] == 'homework'
    assert result['plan']['tasks'][0]['durationMinutes'] == 30
    assert result['plan']['tasks'][1]['durationMinutes'] == 10
    assert result['plan']['unscheduledTasks']


def test_running_task_is_retained_with_explicit_budget_conflict():
    task = dict(taskId='running', knowledgePointId='tree', durationMinutes=45, status='running')
    result = fit_plan_to_budget(dict(version=1, tasks=[task]), 20)['plan']
    assert result['tasks'] == [task]
    assert result['budgetSummary']['conflictMinutes'] == 25


def test_assessment_of_running_target_does_not_change_other_task_durations():
    plan = dict(version=2, tasks=[dict(taskId='run', knowledgePointId='tree', durationMinutes=30, status='running'),
        dict(taskId='pending', knowledgePointId='linear', durationMinutes=30, status='pending')])
    result = PlannerAgent().run(dict(plan=plan, needReplan=True,
        replanState=dict(knowledgePointId='tree', masteryScore=20))).output
    assert result['plan'] == plan and not result['changedTasks']
