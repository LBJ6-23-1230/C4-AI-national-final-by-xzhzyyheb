import { AgentApiClient } from '../api/AgentApiClient';
import { ApiDefaults } from '../api/ApiDefaults';
import { ExerciseQuery, ExerciseSetResponse, ExerciseSubmission, ExerciseSubmissionResult, LearningPlan, PlanDiff, WorkflowResponse, WorkflowRunResponse, WorkflowStatusResponse } from '../api/ApiModels';
import { ApiFailure } from '../api/ApiResult';
import { ClientCache } from '../cache/ClientCache';
import { appState } from '../data/AppState';

/**
 * Prepares the exercise flow for the page. Scores and mastery are always
 * returned by the API/fixture; this class does not calculate them.
 */
export class ExerciseViewModel {
  private errorMessage: string = '';
  private warningMessage: string = '';
  private loadVersion: number = 0;
  private submissionFailure: ApiFailure | null = null;

  getSubmissionFailure(): ApiFailure | null {
    return this.submissionFailure;
  }

  getErrorMessage(): string {
    return this.errorMessage;
  }

  getWarningMessage(): string {
    return this.warningMessage;
  }

  /**
   * 缓存里的题集是否就是本次要的题集。
   *
   * ⚠️ 不能只比 `setId`。同一个 `setId` 配上不同的 `knowledgePointId`
   * 会返回**完全不同的题目**（题库 30 题 / 6 个知识点），只按 setId 命中的话，
   * 「错题诊断 → 做同类专项题」会给回上一次那一套题 —— 也就是用户看到的
   * "永远是那三题"。
   */
  private static matchesQuery(cached: ExerciseSetResponse, query?: ExerciseQuery): boolean {
    if ((cached.sourceMode ?? 'general') !== (query?.sourceMode ?? 'general')) return false;
    if (query?.sourceMode === 'materials' && (cached.kbId !== query.kbId ||
      cached.documentId !== (query.documentId ?? '') || cached.knowledgePointId !== query.knowledgePointId)) return false;
    if (query?.count !== undefined && cached.exercises.length !== query.count) return false;
    if (cached.exercises.some((item) => (query?.excludeExerciseIds ?? []).indexOf(item.exerciseId) >= 0)) return false;
    if (query === undefined || query.knowledgePointId === undefined
      || query.knowledgePointId.length === 0) {
      return true;   // 没指定知识点：setId 相同即可复用
    }
    const first = cached.exercises.length > 0 ? cached.exercises[0] : undefined;
    if (first === undefined) {
      return false;
    }
    return first.knowledgePointId === query.knowledgePointId;
  }

  async load(setId: string, forceRefresh: boolean = false,
    query?: ExerciseQuery): Promise<ExerciseSetResponse | null> {
    const owner: string = ClientCache.currentOwnerUserId();
    const version: number = ++this.loadVersion;
    this.errorMessage = '';
    const cached: ExerciseSetResponse | null = ClientCache.getExerciseSet();
    if (!forceRefresh && query?.sourceMode !== 'materials' && cached !== null && cached.setId === setId
      && ExerciseViewModel.matchesQuery(cached, query)) {
      return cached;
    }
    const result = await AgentApiClient.getExerciseSet(setId, query);
    if (owner !== ClientCache.currentOwnerUserId() || version !== this.loadVersion) return null;
    if (result.ok) {
      if (query?.sourceMode === 'materials' && (result.data.sourceMode !== 'materials' ||
        result.data.kbId !== query.kbId || result.data.documentId !== (query.documentId ?? '') ||
        result.data.knowledgePointId !== query.knowledgePointId)) {
        this.errorMessage = '返回的题目与所选资料不一致，请重新加载。';
        return null;
      }
      if (result.data.exercises.length > 0) ClientCache.cacheExerciseSet(result.data);
      return result.data;
    }
    this.errorMessage = (result as ApiFailure).error.message;
    if (!forceRefresh && query?.sourceMode !== 'materials' && cached !== null && cached.setId === setId
      && ExerciseViewModel.matchesQuery(cached, query)) {
      this.errorMessage = `${this.errorMessage} 正在显示刚才获取的练习。`;
      return cached;
    }
    return null;
  }

  async submit(setId: string, submission: ExerciseSubmission): Promise<ExerciseSubmissionResult | null> {
    this.submissionFailure = null;
    const owner: string = ClientCache.currentOwnerUserId();
    this.errorMessage = '';
    this.warningMessage = '';
    const workflow: WorkflowResponse | null = ClientCache.getWorkflow();
    // 兜底必须是**当前身份**，而不是写死的演示账号。
    //
    // 修复的缺陷：原先兜底 `ApiDefaults.DEMO_USER_ID`，于是真实账号做题时
    // 掌握度被写进演示账号（后端侧同步修了身份解析，两端都改才生效）。
    // 游客/离线态下 `appState.currentUser.userId` 本来就是 demo-user。
    const fallbackUserId: string = appState.currentUser.userId;
    const request: ExerciseSubmission = {
      goalId: submission.goalId,
      goalStateVersion: submission.goalStateVersion,
      userId: submission.userId ?? (fallbackUserId.length > 0 ? fallbackUserId : ApiDefaults.DEMO_USER_ID),
      sessionId: submission.goalId ?? submission.sessionId ??
        (workflow !== null && !workflow.sessionId.startsWith('goal-') ? workflow.sessionId : undefined),
      idempotencyKey: submission.idempotencyKey,
      answers: submission.answers
    };
    const result = await AgentApiClient.submitExercise(setId, request);
    if (owner !== ClientCache.currentOwnerUserId()) return null;
    if (result.ok) {
      const submissionResult: ExerciseSubmissionResult = result.data;
      let plan: LearningPlan | undefined = submissionResult.plan;
      if (submissionResult.needReplan && plan === undefined) {
        const planResult = await AgentApiClient.getCurrentPlan();
        if (owner !== ClientCache.currentOwnerUserId()) return null;
        if (planResult.ok) {
          plan = planResult.data;
          submissionResult.plan = plan;
        } else {
          this.warningMessage = '诊断已完成，但暂时无法读取更新后的学习计划。';
        }
      }
      if (submissionResult.needReplan && submissionResult.planDiff === undefined &&
        plan !== undefined && plan.planId !== null) {
        const diffResult = await AgentApiClient.getPlanDiff(plan.planId);
        if (owner !== ClientCache.currentOwnerUserId()) return null;
        if (diffResult.ok) {
          const planDiff: PlanDiff = diffResult.data;
          submissionResult.planDiff = planDiff;
        } else {
          this.warningMessage = '诊断和计划更新已完成，但暂时无法读取计划变更详情。';
        }
      }
      ClientCache.cacheAssessment(submissionResult);
      if (submissionResult.planDiff !== undefined) {
        ClientCache.cachePlanDiff(submissionResult.planDiff);
      }
      if (submissionResult.plan !== undefined) {
        ClientCache.cacheCurrentPlan(submissionResult.plan);
      }
      ClientCache.invalidateProfile();
      ClientCache.invalidateTrace();
      const targetWorkflowId: string | undefined = submission.goalId ??
        (workflow !== null && !workflow.sessionId.startsWith('goal-') ? workflow.sessionId : undefined);
      if (targetWorkflowId !== undefined && submissionResult.submissionId !== undefined) {
        const workflowResult = await AgentApiClient.runWorkflow(targetWorkflowId,
          { submissionId: submissionResult.submissionId });
        if (owner !== ClientCache.currentOwnerUserId()) return null;
        if (workflowResult.ok) {
          const run: WorkflowRunResponse = workflowResult.data;
          submissionResult.learningContext = run.learningContext;
          if (workflow === null || workflow.sessionId !== targetWorkflowId) {
            ClientCache.cacheWorkflow({ sessionId: run.sessionId, traceId: run.traceId,
              status: run.status, currentStep: run.currentStep, nextAction: run.finalAction ?? '' });
          }
          const status: WorkflowStatusResponse = {
            status: run.status,
            currentAgent: run.currentAgent,
            stateVersion: run.stateVersion,
            finalAction: run.finalAction
          };
          ClientCache.cacheWorkflowStatus(status);
        } else if (this.warningMessage.length === 0) {
          this.warningMessage = '诊断结果已保存，但 Agent 工作流状态暂时未能同步。';
        }
      }
      return submissionResult;
    }
    this.submissionFailure = result as ApiFailure;
    this.errorMessage = this.submissionFailure.error.message;
    return null;
  }
}
