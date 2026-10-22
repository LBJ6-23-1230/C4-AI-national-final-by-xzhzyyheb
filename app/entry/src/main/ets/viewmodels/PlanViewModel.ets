import { AgentApiClient } from '../api/AgentApiClient';
import { LearningPlan, PlanBudgetRequest, PlanBudgetResponse } from '../api/ApiModels';
import { ApiFailure, ApiResult, apiFailure } from '../api/ApiResult';
import { ClientCache } from '../cache/ClientCache';

/**
 * 计划读取结果的**种类**。
 *
 * ⚠️ 为什么必须区分：`plan === null` 至少有三种完全不同的现实，
 * 而它们的下一步动作互相排斥：
 *   · `no_plan`    —— 服务端明确说"这个账号还没有计划"（404 / NOT_FOUND）。
 *                     这不是错误，用户该做的是**去建立目标或导入课程**，
 *                     反复点"重试"永远不会让计划出现。
 *   · `error`      —— 连不上、超时、契约不符等真实故障，可以重试。
 *   · `identity_changed` —— 请求期间换了账号，结果必须丢弃。
 * 旧实现只给一句 `errorMessage`，页面只能一律显示"暂时无法读取学习建议 + 重新加载"，
 * 于是空账号用户看到的就是"读不出来"——把"还没有"说成了"坏了"。
 */
export type PlanViewStateKind = 'ok' | 'no_plan' | 'error' | 'identity_changed';

export interface PlanViewState {
  plan: LearningPlan | null;
  kind: PlanViewStateKind;
  errorMessage: string;
  isCached: boolean;
}

/** Reads the current plan from the contract API without creating plan data locally. */
export class PlanViewModel {
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

  async load(forceRefresh: boolean = false): Promise<PlanViewState> {
    const owner: string = ClientCache.currentOwnerUserId();
    const cached: LearningPlan | null = ClientCache.getCurrentPlan();
    if (!forceRefresh && cached !== null) {
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
    // ⚠️ 404 **不是"出错了"，而是"还没有计划"** —— 两者必须分开说。
    //
    // 这条区分是注册流程改动的直接后果：新注册的账号默认**不再预置**那份写死的
    // 二叉树起始计划（用户反馈「创建一个新账号最好不直接给出已经写死的数据，
    // 比如二叉树…否则会给用户一种虚假的感觉」）。于是「学习建议」「学习计划」等页
    // 首次打开必然拿到 404。原样把后端的英文 `current plan not found` 抛给用户，
    // 会让人以为 App 坏了 —— 而真实情况是"还没让 Agent 生成过计划"，
    // 下一步该去智能体页跑一次。这里如实说清，并给出可执行的下一步。
    if (failure.error.statusCode === 404 || failure.error.code === 'NOT_FOUND') {
      // 服务端明确说没有计划时，缓存里的旧计划必须一并作废：
      // 否则其他页面仍会拿着上一份计划渲染任务，而"当前计划"页显示空，
      // 两处说法互相矛盾。
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
