"""Schedule existing work against explicitly confirmed daily capacities."""
from copy import deepcopy
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo


def schedule(plan, days):
    today = datetime.now(ZoneInfo('Asia/Shanghai')).date()
    if not isinstance(days, list) or not 1 <= len(days) <= 14:
        raise ValueError('请确认1至14天的每日可用时间')
    capacities = {}
    for row in days:
        if not isinstance(row, dict) or type(row.get('minutes')) is not int or not 0 <= row['minutes'] <= 1440:
            raise ValueError('每日时长须为0至1440的整数分钟')
        try:
            date = datetime.strptime(row.get('date', ''), '%Y-%m-%d').date()
        except (ValueError, TypeError):
            raise ValueError('请填写有效日期') from None
        if not today <= date < today + timedelta(days=14) or date.isoformat() in capacities:
            raise ValueError('日期须在未来14天内且不能重复')
        capacities[date.isoformat()] = row['minutes']
    tasks = {t['taskId']: deepcopy(t) for t in plan.get('tasks', []) + plan.get('unscheduledTasks', [])}
    completed = [t for t in tasks.values() if t.get('status') == 'completed']
    pending = sorted((t for t in tasks.values() if t.get('status') not in ('completed', 'cancelled', 'deleted')),
        key=lambda t: (t.get('status') not in ('running', 'in_progress'), t.get('dueAt') or t.get('dueDate') or '9999',
                       t.get('priority') != 'high', t.get('masteryScore', 50), t['taskId']))
    remaining = dict(capacities)
    scheduled, deferred = [], []
    for task in pending:
        duration = task.get('durationMinutes')
        if type(duration) is not int or duration <= 0:
            task['deferredReason'] = '缺少预计时长，请在任务来源处补充'
            deferred.append(task)
            continue
        due = (task.get('dueAt') or task.get('dueDate') or '9999')[:10]
        running = task.get('status') in ('running', 'in_progress')
        pinned = (task.get('scheduledDate') or today.isoformat()) if running else None
        if running and (pinned not in remaining or remaining[pinned] < duration):
            raise ValueError('进行中任务超过该日剩余时间，请先完成或主动调整任务，再确认每日预算')
        available = [day for day in sorted(remaining) if (not pinned or day == pinned) and remaining[day] >= duration
                     and (day <= due or due < today.isoformat())]
        if not available:
            task.pop('scheduledDate', None)
            task['deferredReason'] = f'预计{duration}分钟，截止前没有足够的连续预算；请拆成明确步骤、调整其他任务或增加可用时间'
            deferred.append(task)
            continue
        day = available[0]
        task.update(scheduledDate=day, allocationReason=('已逾期，优先补做' if due < today.isoformat() else
                    '按截止日期、优先级与已确认每日时长安排'),
                    steps=(['核对该作业的要求和提交标准', '完成作业并检查提交结果'] if task.get('source') == 'ddl' else
                           [f'完成「{task["knowledgePointName"]}」的一轮新题', '核对解析并记录出错步骤，查看学习报告']))
        task.pop('deferredReason', None)
        remaining[day] -= duration
        scheduled.append(task)
    result = deepcopy(plan)
    result.update(tasks=completed + scheduled, unscheduledTasks=deferred,
        calendarDays=[dict(date=day, minutes=minutes, scheduledMinutes=minutes - remaining[day]) for day, minutes in sorted(capacities.items())],
        calendarUnscheduledMinutes=sum(t.get('durationMinutes', 0) for t in deferred if type(t.get('durationMinutes')) is int),
        reason='已按确认的每日可用时间和截止日期排期；无法容纳的任务保留并说明原因。')
    # A confirmed date is not an invented clock time or an automatic extension.
    result['constraints'] = dict(plan.get('constraints', {}), availableMinutes=capacities.get(today.isoformat(), 0))
    result['budgetSummary'] = dict(availableMinutes=capacities.get(today.isoformat(), 0),
        scheduledMinutes=sum(t['durationMinutes'] for t in scheduled if t['scheduledDate'] == today.isoformat()),
        unallocatedMinutes=remaining.get(today.isoformat(), 0),
        unscheduledMinutes=result['calendarUnscheduledMinutes'])
    return result
