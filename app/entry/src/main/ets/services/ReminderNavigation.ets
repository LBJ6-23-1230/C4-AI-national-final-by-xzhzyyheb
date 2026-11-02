import { AgentApiClient } from '../api/AgentApiClient';
import { CourseLabels } from '../utils/CourseLabels';
import router from '@ohos.router';
import { ReminderEvent } from '../api/ReminderModels';
import { PlanTask } from '../api/ApiModels';
import { FocusTask } from '../models/AgentModels';
import { appState } from '../data/AppState';
import { DistributedStateService } from './DistributedStateService';

export class ReminderNavigation {
  static open(item: ReminderEvent): void {
    if (item.kind === 'task') {
      router.pushUrl({ url: 'pages/TaskDetail', params: { taskId: item.sourceId || item.objectId } });
    } else {
      router.pushUrl({ url: item.targetPage, params: { courseName: item.courseName, knowledgePointId: item.knowledgePointId } });
    }
  }

  static async start(item: ReminderEvent): Promise<string> {
    if (item.status === 'completed' || item.status === 'invalid') return '任务已完成或移除，请刷新待办。';
    if (item.kind !== 'task') { ReminderNavigation.open(item); return ''; }
    const owner: string = appState.currentUser.userId;
    const result = await AgentApiClient.getCurrentPlan();
    if (owner !== appState.currentUser.userId) return '账号已切换，请刷新待办。';
    if (!result.ok) return '暂时无法确认这项任务，请刷新后重试。';
    const id: string = item.sourceId || item.objectId;
    const tasks: PlanTask[] = result.data.tasks.concat(result.data.unscheduledTasks || []);
    const steps: PlanTask[] = tasks.filter((task: PlanTask) => task.parentTaskId === id && task.status !== 'completed');
    const task: PlanTask | undefined = steps[0] || tasks.find((task: PlanTask) => task.taskId === id);
    if (!task) return '这项任务已发生变化，请刷新待办。';
    return ReminderNavigation.startTask(task);
  }

  static practiceTask(task: PlanTask): boolean {
    return task.source !== 'ddl' && task.source !== 'ddl_step' &&
      !!task.knowledgePointId && !task.knowledgePointId.startsWith('ddl:');
  }

  static startTask(task: PlanTask): string {
    if (task.status === 'completed') return '这项任务已完成，请刷新待办。';
    if (!CourseLabels.valid(task.sourceCourse || '')) {
      router.pushUrl({ url: 'pages/KnowledgeCatalog', params: { matching: 'true' } }); return '';
    }
    if (ReminderNavigation.practiceTask(task)) {
      router.pushUrl({ url: 'pages/ExercisePractice', params: { knowledgePointId: task.knowledgePointId,
        courseName: task.sourceCourse || '' } });
      return '';
    }
    if (appState.focusResultDraft !== null) return '上次专注尚未结算，请先到“学习 → 开始专注”保存或处理上次记录。';
    if (appState.focusRuntime !== null) {
      if (appState.focusRuntime.task.planTaskId === task.taskId) {
        router.pushUrl({ url: 'pages/FocusTimer' }); return '';
      }
      return '已有另一项专注进行中，请先在“学习 → 继续专注”处理当前任务。';
    }
    if (!Number.isInteger(task.durationMinutes) || task.durationMinutes <= 0) return '请先在任务详情确认预计时长。';
    const focusTask: FocusTask = { course: task.sourceCourse || '学习任务', task: task.knowledgePointName,
      plannedMinutes: task.durationMinutes, planTaskId: task.taskId, source: 'agent', mode: 'normal', timerType: 'countdown' };
    if (!appState.beginFocusRuntime(focusTask)) return '计时记录未能保存，请重试。';
    appState.setFocusTask(focusTask);
    appState.updatePlanTaskStatus(task.taskId, 'in_progress');
    DistributedStateService.getInstance().publishFocusTask(focusTask);
    router.pushUrl({ url: 'pages/FocusTimer' });
    return '';
  }
}
