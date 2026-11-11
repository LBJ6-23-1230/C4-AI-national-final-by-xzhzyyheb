import { AgentApiClient } from '../api/AgentApiClient';
import { CourseLabels } from '../utils/CourseLabels';
import router from '@ohos.router';
import { ReminderEvent } from '../api/ReminderModels';
import { PlanTask } from '../api/ApiModels';
import { FocusMode, FocusTask } from '../models/AgentModels';
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

  static actionLabel(item: ReminderEvent): string {
    return item.kind === 'task' ? ReminderNavigation.focusActionLabel(item.sourceId || item.objectId) : '开始任务';
  }

  static taskActionLabel(task: PlanTask): string {
    return ReminderNavigation.practiceTask(task) ? '开始本项练习' : ReminderNavigation.focusActionLabel(task.taskId);
  }

  private static focusActionLabel(id: string): string {
    const runtime = appState.focusRuntime;
    return runtime !== null && runtime.ownerId === appState.currentUser.userId &&
      (runtime.task.planTaskId === id || runtime.task.parentTaskId === id) ? '继续专注' : '开始任务';
  }

  static async start(item: ReminderEvent, chooseFocus: (task: PlanTask) => string): Promise<string> {
    if (item.status === 'completed' || item.status === 'invalid') return '任务已完成或移除，请刷新待办。';
    if (item.kind !== 'task') { ReminderNavigation.open(item); return ''; }
    const owner: string = appState.currentUser.userId;
    const result = await AgentApiClient.getCurrentPlan();
    if (owner !== appState.currentUser.userId) return '账号已切换，请刷新待办。';
    if (!result.ok) return '暂时无法确认这项任务，请刷新后重试。';
    const id: string = item.sourceId || item.objectId;
    const tasks: PlanTask[] = result.data.tasks.concat(result.data.unscheduledTasks || []);
    const steps: PlanTask[] = tasks.filter((task: PlanTask) => task.parentTaskId === id && task.status !== 'completed');
    const activeId: string | undefined = appState.focusRuntime?.task.planTaskId;
    const resumed: PlanTask | undefined = tasks.find((task: PlanTask) => task.taskId === activeId &&
      (task.taskId === id || task.parentTaskId === id));
    const task: PlanTask | undefined = resumed || steps[0] || tasks.find((task: PlanTask) => task.taskId === id);
    if (!task) return '这项任务已发生变化，请刷新待办。';
    return ReminderNavigation.startTask(task, chooseFocus);
  }

  static practiceTask(task: PlanTask): boolean {
    return task.source !== 'ddl' && task.source !== 'ddl_step' &&
      !!task.knowledgePointId && !task.knowledgePointId.startsWith('ddl:');
  }

  static startTask(task: PlanTask, chooseFocus: (task: PlanTask) => string): string {
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
    return chooseFocus(task);
  }

  static async confirmFocus(taskId: string, minutes: number, mode: FocusMode, owner: string,
    isActive: () => boolean, allowBackgroundTiming: boolean = false): Promise<string> {
    if (!isActive()) return '';
    if (owner !== appState.currentUser.userId) return '账号已切换，请重新打开任务。';
    if (!Number.isInteger(minutes) || minutes < 1 || minutes > 180) return '请输入1到180之间的整数分钟。';
    if (mode !== 'normal' && mode !== 'strict') return '请选择专注模式。';
    const result = await AgentApiClient.getCurrentPlan();
    if (!isActive()) return '';
    if (owner !== appState.currentUser.userId) return '账号已切换，请重新打开任务。';
    if (!result.ok) return '暂时无法确认这项任务，请重试。';
    const task: PlanTask | undefined = result.data.tasks.concat(result.data.unscheduledTasks || [])
      .find((item: PlanTask) => item.taskId === taskId);
    if (!task) return '这项任务已发生变化，请关闭面板并刷新待办。';
    return ReminderNavigation.startTask(task, (selected: PlanTask): string =>
      ReminderNavigation.beginTaskFocus(selected, minutes, mode, allowBackgroundTiming));
  }

  private static beginTaskFocus(task: PlanTask, minutes: number, mode: FocusMode, allowBackgroundTiming: boolean): string {
    const focusTask: FocusTask = { course: task.sourceCourse || '学习任务', task: task.knowledgePointName,
      plannedMinutes: minutes, planTaskId: task.taskId, parentTaskId: task.parentTaskId,
      source: 'agent', mode: mode, timerType: 'countdown' };
    focusTask.allowBackgroundTiming = mode === 'normal' && allowBackgroundTiming;
    if (!appState.beginFocusRuntime(focusTask)) return '计时记录未能保存，请重试。';
    appState.setFocusTask(focusTask);
    appState.updatePlanTaskStatus(task.taskId, 'in_progress');
    DistributedStateService.getInstance().publishFocusTask(focusTask);
    router.pushUrl({ url: 'pages/FocusTimer' });
    return '';
  }
}
