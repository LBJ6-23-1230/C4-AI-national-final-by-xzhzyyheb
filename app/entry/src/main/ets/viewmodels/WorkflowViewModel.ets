import { AgentApiClient } from '../api/AgentApiClient';
import { WorkflowCreateRequest, WorkflowResponse, WorkflowRunResponse, WorkflowStatusResponse } from '../api/ApiModels';
import { ApiFailure } from '../api/ApiResult';
import { ClientCache } from '../cache/ClientCache';
import { appState } from '../data/AppState';

export class WorkflowViewModel {
  private errorMessage: string = '';
  private staleSession: boolean = false;
  private requestVersion: number = 0;

  private ownsRequest(owner: string, version: number, sessionId?: string): boolean {
    return owner === ClientCache.currentOwnerUserId() && version === this.requestVersion &&
      (sessionId === undefined || ClientCache.getWorkflow()?.sessionId === sessionId);
  }

  getErrorMessage(): string {
    return this.errorMessage;
  }

  wasSessionStale(): boolean {
    return this.staleSession;
  }

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
    const rebuilt = await AgentApiClient.createWorkflow({
      goal: appState.currentUser.learningGoal.goal,
      userId: appState.currentUser.userId,
      maxSteps: 5
    });
    if (!this.ownsRequest(owner, version) || ClientCache.getWorkflow() !== null) return true;
    if (rebuilt.ok) {
      ClientCache.cacheWorkflow(rebuilt.data);
      this.errorMessage = '';
    } else {
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
      return null;
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
          return latest;
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
