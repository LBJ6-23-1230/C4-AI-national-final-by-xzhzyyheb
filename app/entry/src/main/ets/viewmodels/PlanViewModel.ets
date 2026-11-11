import { AgentApiClient } from '../api/AgentApiClient';
import { LearningPlan, PlanBudgetRequest, PlanBudgetResponse, PlanTaskScheduleRequest } from '../api/ApiModels';
import { ApiFailure, ApiResult, apiFailure } from '../api/ApiResult';
import { ClientCache } from '../cache/ClientCache';
import { appState } from '../data/AppState';
import { HomeworkDDL } from '../models/AgentModels';
import { AssignmentSnapshot, AssignmentSyncRequest } from '../api/ApiModels';

export type PlanViewStateKind = 'ok' | 'no_plan' | 'error' | 'identity_changed';

export interface PlanViewState {
  plan: LearningPlan | null;
  kind: PlanViewStateKind;
  errorMessage: string;
  isCached: boolean;
}

export class PlanViewModel {
  async syncAssignments(selectedId?: string, scheduleToday: boolean = false): Promise<ApiResult<LearningPlan>> {
    const owner: string = ClientCache.currentOwnerUserId();
    if (!await appState.syncLearningData()) return apiFailure('SYNC_FAILED', '同步失败，请重试。', true, 'network');
    if (ClientCache.currentOwnerUserId() !== owner) {
      return apiFailure('IDENTITY_CHANGED', '账号已切换，请重新打开计划。', false, 'network');
    }
    const assignments: AssignmentSnapshot[] = appState.homeworkDDLs.map((ddl: HomeworkDDL): AssignmentSnapshot => ({
      id: ddl.id, title: ddl.title, courseName: ddl.courseName, dueDate: ddl.dueDate,
      estimatedMinutes: ddl.estimatedMinutes, priority: ddl.priority,
      completed: appState.isTaskCompleted(ddl.id, 'pending')
    }));
    const request: AssignmentSyncRequest = { assignments: assignments, selectedId: selectedId, scheduleToday: scheduleToday };
    const result = await AgentApiClient.syncAssignments(request);
    if (ClientCache.currentOwnerUserId() !== owner) {
      return apiFailure('IDENTITY_CHANGED', '账号已切换，请重新打开计划。', false, 'network');
    }
    if (result.ok) ClientCache.cacheCurrentPlan(result.data);
    return result;
  }

  async updateBudget(request: PlanBudgetRequest): Promise<ApiResult<PlanBudgetResponse>> {
    const owner: string = ClientCache.currentOwnerUserId();
    const result = await AgentApiClient.updatePlanBudget(request);
    if (ClientCache.currentOwnerUserId() !== owner) {
      return apiFailure('IDENTITY_CHANGED', '账号已切换，请重新打开计划。', false, 'network');
    }
    if (result.ok) {
      const current: LearningPlan | null = ClientCache.getCurrentPlan();
      if (current !== null && current.planId === result.data.plan.planId && current.version > result.data.plan.version) {
        return apiFailure('STALE_PLAN', '计划已有更新，请刷新查看当前安排。', true, 'network');
      }
      ClientCache.cacheCurrentPlan(result.data.plan);
    }
    return result;
  }

  async scheduleTask(request: PlanTaskScheduleRequest): Promise<ApiResult<PlanBudgetResponse>> {
    const owner: string = ClientCache.currentOwnerUserId();
    const result = await AgentApiClient.schedulePlanTask(request);
    if (ClientCache.currentOwnerUserId() !== owner) {
      return apiFailure('IDENTITY_CHANGED', '账号已切换，请重新打开计划。', false, 'network');
    }
    if (result.ok) {
      const current: LearningPlan | null = ClientCache.getCurrentPlan();
      if (current !== null && current.planId === result.data.plan.planId && current.version > result.data.plan.version) {
        return apiFailure('STALE_PLAN', '计划已有更新，请刷新查看当前安排。', true, 'network');
      }
      ClientCache.cacheCurrentPlan(result.data.plan);
    }
    return result;
  }

  async load(forceRefresh: boolean = false): Promise<PlanViewState> {
    const owner: string = ClientCache.currentOwnerUserId();
    const cached: LearningPlan | null = ClientCache.getCurrentPlan();
    if (!forceRefresh && cached !== null && AgentApiClient.getConfig().useFixture) {
      return { plan: cached, kind: 'ok', errorMessage: '', isCached: true };
    }

    const result = await AgentApiClient.getCurrentPlan();
    if (ClientCache.currentOwnerUserId() !== owner) {
      return { plan: null, kind: 'identity_changed', errorMessage: '账号已切换，请重新打开计划。', isCached: false };
    }
    if (result.ok) {
      const current: LearningPlan | null = ClientCache.getCurrentPlan();
      if (current !== null && current.planId === result.data.planId && current.version > result.data.version) {
        return { plan: current, kind: 'ok', errorMessage: '', isCached: true };
      }
      ClientCache.cacheCurrentPlan(result.data);
      return { plan: result.data, kind: 'ok', errorMessage: '', isCached: false };
    }

    const failure = result as ApiFailure;
    if (failure.error.statusCode === 404 || failure.error.code === 'NOT_FOUND') {
      ClientCache.invalidateCurrentPlan();
      return {
        plan: null,
        kind: 'no_plan',
        errorMessage: '这个账号还没有学习计划。计划由 Agent 根据你的真实课程、资料与练习记录生成，'
          + '不会预置示例数据。先导入课程或建立学习目标，计划才会出现。',
        isCached: false
      };
    }

    const detail: string = failure.error.message;
    if (cached !== null) {
      return { plan: cached, kind: 'ok', errorMessage: `${detail} 正在显示刚才获取的数据。`, isCached: true };
    }
    return { plan: null, kind: 'error', errorMessage: detail, isCached: false };
  }
}
