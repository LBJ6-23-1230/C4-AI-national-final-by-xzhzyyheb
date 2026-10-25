import { AgentApiClient } from '../api/AgentApiClient';
import { WorkflowCreateRequest, WorkflowResponse, WorkflowRunResponse, WorkflowStatusResponse } from '../api/ApiModels';
import { ApiFailure } from '../api/ApiResult';
import { ClientCache } from '../cache/ClientCache';
import { appState } from '../data/AppState';

/** Owns the client-side identity and latest status of one backend workflow. */
export class WorkflowViewModel {
  private errorMessage: string = '';
  //: 上一次操作是否因为"服务端已无此会话"而丢弃了本地缓存（供调用方决定要不要重建）。
  private staleSession: boolean = false;
  private requestVersion: number = 0;

  private ownsRequest(owner: string, version: number, sessionId?: string): boolean {
    return owner === ClientCache.currentOwnerUserId() && version === this.requestVersion &&
      (sessionId === undefined || ClientCache.getWorkflow()?.sessionId === sessionId);
  }

  getErrorMessage(): string {
    return this.errorMessage;
  }

  /** 上一次操作是否发现本地缓存的服务端会话已失效（服务端 404）。 */
  wasSessionStale(): boolean {
    return this.staleSession;
  }

  /**
   * 会话在服务端已不存在时**丢弃本地缓存并立刻重建一个**，返回是否命中。
   *
   * 触发场景（已实测复现）：`POST /api/v1/demo/reset` 会清理演示名下的
   * workflows，而 App 侧 `ClientCache` / `WorkflowSessionStore` 还留着那个
   * sessionId → 页面复用旧 id 请求 → `GET /api/v1/workflows/session-demo-001` **404**，
   * 卡片显示「workflow not found」并只给一个「重试」按钮 —— **而重试永远不会成功**，
   * 因为那个会话是真的没了。
   *
   * ⚠️ 自愈必须做在**这一层**：404 可能来自任何一个持有本 ViewModel 的页面
   * （实测首次触发的是 `ChatMain` —— 游客的落地页，而不是 `Index`）。
   * 只修某一个调用方，换个入口就又会卡住。
   *
   * 判据用 `statusCode === 404`：只有"服务端明确说这条会话不存在"才丢缓存。
   * 网络故障（statusCode = 0）**绝不能丢** —— 否则断网一次就把会话清了。
   */
  private async discardIfMissing(failure: ApiFailure, owner: string, version: number,
    sessionId: string): Promise<boolean> {
    if (!this.ownsRequest(owner, version, sessionId)) return false;
    if (failure.error.statusCode !== 404) {
      return false;
    }
    ClientCache.invalidateWorkflow();
    ClientCache.invalidateWorkflowStatus();
    ClientCache.invalidateTrace();
    this.staleSession = true;
    // 立刻重建，用户不必自己点「重试」。
    const rebuilt = await AgentApiClient.createWorkflow({
      goal: appState.currentUser.learningGoal.goal,
      userId: appState.currentUser.userId,
      maxSteps: 5
    });
    if (!this.ownsRequest(owner, version) || ClientCache.getWorkflow() !== null) return true;
    if (rebuilt.ok) {
      ClientCache.cacheWorkflow(rebuilt.data);
      // 自愈成功 = 问题已经解决，不要再把"刚失效过一次"以红字+重试的形式留在卡片上
      // （用户/评委会以为还没修好）。
      this.errorMessage = '';
    } else {
      // 连重建都失败：如实说明并保留重试入口，不假装正常。
      this.errorMessage = '本地 Agent 会话已失效，且自动新建失败，请点「重试」。';
    }
    return true;
  }

  getCurrentWorkflow(): WorkflowResponse | null {
    return ClientCache.getWorkflow();
  }

  async start(goal: string, userId: string): Promise<WorkflowResponse | null> {
    const owner: string = ClientCache.currentOwnerUserId();
    const version: number = ++this.requestVersion;
    this.errorMessage = '';
    const request: WorkflowCreateRequest = {
      goal: goal.trim().length > 0 ? goal : '完成当前薄弱知识点诊断',
      userId: userId.trim().length > 0 ? userId : undefined,
      maxSteps: 5
    };
    const result = await AgentApiClient.createWorkflow(request);
    if (!this.ownsRequest(owner, version)) return null;
    if (result.ok) {
      ClientCache.cacheWorkflow(result.data);
      ClientCache.invalidateWorkflowStatus();
      ClientCache.invalidateTrace();
      return result.data;
    }
    this.errorMessage = (result as ApiFailure).error.message;
    return null;
  }

  async refreshStatus(forceRefresh: boolean = false): Promise<WorkflowStatusResponse | null> {
    const owner: string = ClientCache.currentOwnerUserId();
    const version: number = ++this.requestVersion;
    this.errorMessage = '';
    this.staleSession = false;
    const workflow: WorkflowResponse | null = ClientCache.getWorkflow();
    if (workflow === null) {
      this.errorMessage = '当前还没有进行中的 Agent 会话。';
      return null;
    }
    const cached: WorkflowStatusResponse | null = ClientCache.getWorkflowStatus();
    if (!forceRefresh && cached !== null) {
      return cached;
    }
    const result = await AgentApiClient.getWorkflow(workflow.sessionId);
    if (!this.ownsRequest(owner, version, workflow.sessionId)) return null;
    if (result.ok) {
      ClientCache.cacheWorkflowStatus(result.data);
      return result.data;
    }
    const failure: ApiFailure = result as ApiFailure;
    if (await this.discardIfMissing(failure, owner, version, workflow.sessionId)) {
      return null;   // 文案由 discardIfMissing 按"重建成功与否"如实决定
    }
    this.errorMessage = failure.error.message;
    return null;
  }

  async runUntilComplete(maxRuns: number = 5): Promise<WorkflowStatusResponse | null> {
    const owner: string = ClientCache.currentOwnerUserId();
    const version: number = ++this.requestVersion;
    this.errorMessage = '';
    this.staleSession = false;
    const workflow: WorkflowResponse | null = ClientCache.getWorkflow();
    if (workflow === null) {
      this.errorMessage = '当前还没有可推进的 Agent 会话。';
      return null;
    }
    let latest: WorkflowStatusResponse | null = null;
    for (let runIndex: number = 0; runIndex < maxRuns; runIndex++) {
      const result = await AgentApiClient.runWorkflow(workflow.sessionId);
      if (!this.ownsRequest(owner, version, workflow.sessionId)) return null;
      if (!result.ok) {
        const failure: ApiFailure = result as ApiFailure;
        if (await this.discardIfMissing(failure, owner, version, workflow.sessionId)) {
          return latest;   // 文案由 discardIfMissing 按"重建成功与否"如实决定
        }
        this.errorMessage = failure.error.message;
        return latest;
      }
      const runResponse: WorkflowRunResponse = result.data;
      latest = { status: runResponse.status, currentAgent: runResponse.currentAgent,
        stateVersion: runResponse.stateVersion, finalAction: runResponse.finalAction };
      ClientCache.cacheWorkflowStatus(latest);
      ClientCache.invalidateTrace();
      if (latest.status === 'completed' || latest.status === 'failed' || latest.status === 'fallback' || latest.status === 'error') {
        return latest;
      }
      if (WorkflowViewModel.isAwaitingAnswers(latest)) {
        // 等待用户作答是正常的交接点，不应继续空转，也不应显示错误。
        this.errorMessage = '';
        return latest;
      }
    }
    this.errorMessage = `Agent 会话在 ${maxRuns} 步内尚未完成，可稍后继续推进。`;
    return latest;
  }

  static isAwaitingAnswers(status: WorkflowStatusResponse): boolean {
    return status.currentAgent === 'exercise' && status.status !== 'completed' &&
      status.status !== 'failed' && status.status !== 'fallback' && status.status !== 'error';
  }
}
