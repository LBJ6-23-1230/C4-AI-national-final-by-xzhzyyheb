"""Fixed, synthetic single-model baseline vs the shipped rule role handoff.

Opt-in: makes billed model requests. Does not read or change any user's data.
The same three tools and 15-second / four-call ceiling are available to both
paths. The shipped assessment -> planner path needs no model on these inputs.
This is an assessment-replanning benchmark, not proof about all chat scenarios.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from copy import deepcopy
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
SERVER = ROOT / 'server/zhixue-agent-server'
sys.path.insert(0, str(SERVER))
from dotenv import load_dotenv
from app.agents.planner import PlannerAgent
from app.runtime.tool_registry import create_default_registry
from app.services.llm_runtime import request

TOOLS = [
    dict(type='function', function=dict(name='replan_learning_path', description='根据测评调整学习任务，保留DDL与进行中任务',
        parameters=dict(type='object', properties=dict(old_plan=dict(type='object'), state=dict(type='object')), required=['old_plan', 'state']))),
    dict(type='function', function=dict(name='fit_plan_to_budget', description='按预算安排，优先保留DDL；目标学习任务标记allowPartial=true后可分段，保留未安排部分',
        parameters=dict(type='object', properties=dict(old_plan=dict(type='object'), available_minutes=dict(type='integer'), prioritize_point=dict(type='string')),
                        required=['old_plan', 'available_minutes']))),
    dict(type='function', function=dict(name='build_plan_diff', description='比较计划真实变化',
        parameters=dict(type='object', properties=dict(old_plan=dict(type='object'), new_plan=dict(type='object')), required=['old_plan', 'new_plan']))),
]


def dataset():
    rows = []
    for i in range(30):
        course = ['数据结构', '计算机网络', '线性代数'][i % 3]
        point = ['linear', 'network', 'matrix'][i % 3]
        rows.append(dict(scenario=i + 1, plan=dict(version=1, planId=f'fixed-{i + 1}',
            constraints=dict(availableMinutes=[20, 40, 60][i % 3]), tasks=[
                dict(taskId='practice', knowledgePointId=point, knowledgePointName=course + '基础巩固',
                     sourceCourse=course, durationMinutes=30, status='pending'),
                dict(taskId='ddl', knowledgePointId='ddl:homework', knowledgePointName='操作系统实验',
                     sourceCourse='操作系统', source='ddl', dueDate='2026-10-31', durationMinutes=20 + i % 5 * 5, status='pending')]),
            replanState=dict(knowledgePointId=point, masteryScore=20, assessmentScore=40, repeatedError=True),
            evidenceIds=[f'synthetic-assessment-{i + 1}']))
    return rows


def metrics(plan, scenario):
    if not isinstance(plan, dict) or not isinstance(plan.get('tasks'), list):
        return dict(valid=False, budgetViolation=None, deadlineViolation=None, attributionErrors=None, actionable=False)
    tasks = plan['tasks']
    original = scenario['plan']['tasks']
    ddl = original[1]
    known = {t['taskId']: t for t in original}
    wrong = 0
    for task in tasks + plan.get('unscheduledTasks', []):
        source = known.get(task.get('parentTaskId') or task.get('taskId'))
        if not source or any(task.get(k) != source.get(k) for k in ('knowledgePointId', 'sourceCourse')):
            wrong += 1
    minutes = [t.get('durationMinutes') for t in tasks]
    valid = bool(tasks) and all(type(m) is int and m > 0 for m in minutes)
    budget = scenario['plan']['constraints']['availableMinutes']
    ddl_scheduled = any(t.get('taskId') == 'ddl' and t.get('durationMinutes') == ddl['durationMinutes'] for t in tasks)
    return dict(valid=valid, budgetViolation=sum(minutes) > budget if valid else None,
        deadlineViolation=ddl['durationMinutes'] <= budget and not ddl_scheduled,
        attributionErrors=wrong, actionable=bool(tasks) and valid, scheduledMinutes=sum(minutes) if valid else None)


def model_baseline(scenario, model, direct=True):
    started = time.perf_counter()
    messages = [dict(role='system', content='你是统一单Agent学习规划器。依据给定事实完成测评后重排，不新增课程或知识点，不修改硬DDL工作量，不打断运行任务；不超过明确可用时间。'
        '完整任务放不下时保留未完成部分。可按测评规则增加补弱需求，目标学习任务可标记allowPartial=true再分段。'
        '输入已包含全部事实，请优先直接计算并输出计划，仅缺少信息时才使用工具。可调用所提供的三个工具，每个至多一次。'
        '不重复输入或逐步说明。最终只返回简短JSON对象，含plan（完整计划，包括tasks、unscheduledTasks、constraints）和一句依据。'),
        dict(role='user', content=json.dumps(scenario, ensure_ascii=False))]
    registry = create_default_registry()
    calls, tokens, tools, error, plan = 0, 0, [], None, None
    try:
        for _ in range(4):
            remaining = 15 - (time.perf_counter() - started)
            if remaining <= 0.05:
                raise TimeoutError()
            payload = dict(model=model, messages=messages, temperature=0, max_tokens=1400)
            if len(tools) < 3:
                payload['tools'] = [t for t in TOOLS if t['function']['name'] not in tools]
            if direct:
                # All facts are already supplied. Direct single-agent policy is
                # a one-pass baseline; the same tool definitions remain visible.
                payload['tool_choice'] = 'none'
                payload['response_format'] = dict(type='json_object')
            if 'dashscope' in os.getenv('LLM_BASE_URL', 'dashscope'):
                payload['extra_body'] = dict(enable_thinking=False)
            calls += 1
            response = request('coordination-benchmark', payload, budget=remaining)
            usage = getattr(response, 'usage', None)
            tokens += getattr(usage, 'total_tokens', 0) or 0
            message = response.choices[0].message
            tool_calls = getattr(message, 'tool_calls', None)
            if not tool_calls:
                content = message.content or ''
                if content.strip().startswith('```'):
                    content = content.strip().split('\n', 1)[1].rsplit('```', 1)[0]
                value = json.loads(content)
                plan = value.get('plan')
                break
            messages.append(dict(role='assistant', content=message.content or '',
                tool_calls=[t.model_dump(exclude_none=True) for t in tool_calls]))
            for call in tool_calls:
                name = call.function.name
                if name in tools or name not in {t['function']['name'] for t in TOOLS} or len(tools) >= 3:
                    output = dict(error='tool_budget_or_permission')
                else:
                    tools.append(name)
                    try:
                        output = registry.execute(name, 'planner', json.loads(call.function.arguments))
                    except Exception as exc:
                        output = dict(error=type(exc).__name__)
                messages.append(dict(role='tool', tool_call_id=call.id, content=json.dumps(output, ensure_ascii=False)))
        if plan is None:
            error = 'no_final_plan'
    except Exception as exc:
        error = type(exc).__name__  # Never print provider text or credentials.
    return dict(plan=plan, error=error, modelCalls=calls, tokens=tokens,
        toolCalls=tools, cacheHit=False, cacheScope='application', providerCacheHit=None,
        elapsedMs=round((time.perf_counter() - started) * 1000, 2),
        metrics=metrics(plan, scenario))


def run(scenario, model, direct):
    started = time.perf_counter()
    coordinated = PlannerAgent().run(dict(plan=deepcopy(scenario['plan']), needReplan=True, replanState=scenario['replanState']))
    actual = dict(plan=coordinated.output['plan'], error=None, modelCalls=0, tokens=0,
        toolCalls=list(coordinated.tool_calls), cacheHit=False, cacheScope='application', providerCacheHit=None,
        elapsedMs=round((time.perf_counter() - started) * 1000, 2),
        metrics=metrics(coordinated.output['plan'], scenario))
    return dict(input=scenario, baseline=model_baseline(scenario, model, direct), coordinated=actual)


def summarize(rows):
    output = {}
    for path in ('baseline', 'coordinated'):
        values = [r[path] for r in rows]
        output[path] = dict(samples=len(values), failures=sum(bool(v['error']) or not v['metrics']['valid'] for v in values),
            budgetViolations=sum(v['metrics'].get('budgetViolation') is True for v in values),
            deadlineViolations=sum(v['metrics'].get('deadlineViolation') is True for v in values),
            attributionErrors=sum(v['metrics'].get('attributionErrors') or 0 for v in values),
            actionablePlans=sum(v['metrics']['actionable'] for v in values),
            modelCalls=sum(v['modelCalls'] for v in values), tokens=sum(v['tokens'] for v in values),
            p95Ms=sorted(v['elapsedMs'] for v in values)[max(0, int(len(values) * .95 + .999) - 1)])
    return output


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--run-model', action='store_true', required=True)
    parser.add_argument('--tool-baseline', action='store_true')
    args = parser.parse_args()
    load_dotenv(SERVER / '.env')
    if not os.getenv('DASHSCOPE_API_KEY'):
        raise SystemExit('Model key is not configured')
    model = os.getenv('LLM_MODEL', 'qwen3.8-flash')
    cases = dataset()
    report = dict(createdAt=datetime.now(timezone.utc).isoformat(), sampleSize=30,
        scope='Synthetic assessment-to-planner only. Single model with optional same tools vs shipped rule role coordination. Not a claim of multi-model superiority.',
        modelAvailableToBoth=model, limits=dict(seconds=15, modelCalls=4, toolCalls=3),
        baselinePolicy='optional model-selected tools' if args.tool_baseline else 'direct one-pass JSON; tool definitions visible, invocation disabled by baseline policy',
        environment=dict(python=platform.python_version(), os=platform.system(), concurrentCases=4,
                         processWarm=True, applicationCache='disabled', providerCache='not measured'),
        datasetSha256=hashlib.sha256(json.dumps(cases, sort_keys=True).encode()).hexdigest(),
        manualReview='pending; structural metrics are automatic', scenarios=[])
    destination = ROOT / 'evidence/coordination-models-20261030.json'
    with ThreadPoolExecutor(max_workers=4) as pool:
        futures = [pool.submit(run, row, model, not args.tool_baseline) for row in cases]
        for future in as_completed(futures):
            report['scenarios'].append(future.result())
            report['scenarios'].sort(key=lambda r: r['input']['scenario'])
            report['summary'] = summarize(report['scenarios'])
            destination.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
            print(f"completed {len(report['scenarios'])}/30", flush=True)
    print(json.dumps(report['summary']), flush=True)


if __name__ == '__main__':
    main()
