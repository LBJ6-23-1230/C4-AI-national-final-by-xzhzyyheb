import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { AgentApiClient } from '../api/AgentApiClient';
import { AuthStore } from '../api/AuthStore';
import { ApiFailure } from '../api/ApiResult';
import { SharedFocusSession, SharedFocusRequest, SharedFocusResponse } from '../api/SharedFocusModels';
import { FocusTask, FocusRuntime, FocusSelfAssessment } from '../models/AgentModels';
import { appState } from '../data/AppState';

export interface SharedFocusSnapshot {
  available: boolean;
  session: SharedFocusSession | null;
  lastResponseAt: number;
  stale: boolean;
  busy: boolean;
  lastError: string;
  localDeviceId: string;
}

/** One server clock, fenced by account/environment, with durable ordered offline actions. */
export class FocusSessionSyncService {
  private static instance: FocusSessionSyncService | null = null;
  private context: common.UIAbilityContext | null = null;
  private identity: string = '';
  private deviceId: string = '';
  private deviceKey: string = '';
  private session: SharedFocusSession | null = null;
  private receivedAt: number = 0;
  private serverTime: number = 0;
  private lastResponseAt: number = 0;
  private lastError: string = '';
  private busy: boolean = false;
  private pending: SharedFocusRequest[] = [];

  public static getInstance(): FocusSessionSyncService {
    if (FocusSessionSyncService.instance === null) FocusSessionSyncService.instance = new FocusSessionSyncService();
    return FocusSessionSyncService.instance;
  }
  private currentIdentity(): string {
    const config = AgentApiClient.getConfig();
    return AuthStore.isSignedIn() && !config.useFixture ? `${config.baseUrl}|${AuthStore.getUserId()}|${AuthStore.getToken()}` : '';
  }
  private reconcile(): boolean {
    const current = this.currentIdentity();
    if (current !== this.identity) {
      this.identity = current;
      this.deviceId = ''; this.deviceKey = ''; this.session = null;
      this.pending = []; this.lastResponseAt = 0; this.lastError = '';
    }
    return current.length > 0;
  }
  public configure(context: common.UIAbilityContext, deviceId: string, deviceKey: string): void {
    this.reconcile();
    const changed = this.deviceId !== deviceId;
    this.context = context; this.deviceId = deviceId; this.deviceKey = deviceKey;
    if (changed) {
      try {
        const store = preferences.getPreferencesSync(context, { name: 'shared_focus_actions' });
        this.pending = JSON.parse(store.getSync(this.storageKey(), '[]') as string) as SharedFocusRequest[];
      } catch (_) { this.pending = []; }
    }
  }
  private storageKey(): string {
    return encodeURIComponent(`${AgentApiClient.getConfig().baseUrl}|${AuthStore.getUserId()}|${this.deviceId}`);
  }
  private persist(): boolean {
    if (this.context === null) return false;
    try {
      const store = preferences.getPreferencesSync(this.context, { name: 'shared_focus_actions' });
      store.putSync(this.storageKey(), JSON.stringify(this.pending)); store.flushSync(); return true;
    } catch (_) { this.lastError = '专注操作暂未保存，请重试。'; return false; }
  }
  public getSnapshot(): SharedFocusSnapshot {
    const available = this.reconcile() && this.deviceId.length > 0;
    let session: SharedFocusSession | null = this.session === null ? null : this.copy(this.session);
    if (session !== null && session.state === 'running') {
      const elapsed = Math.max(0, Date.now() - this.receivedAt);
      const limit = session.task.timerType === 'stopwatch' ? 86400000 : session.task.plannedMinutes * 60000;
      session.elapsedMs = Math.min(limit, session.elapsedMs + elapsed);
      session.remainingMs = session.task.timerType === 'stopwatch' ? 0 : Math.max(0, limit - session.elapsedMs);
    }
    return { available: available, session: session, lastResponseAt: this.lastResponseAt,
      stale: this.lastResponseAt > 0 && (Date.now() - this.lastResponseAt > 15000 || this.lastError.length > 0),
      busy: this.busy, lastError: this.lastError, localDeviceId: this.deviceId };
  }
  private copy(value: SharedFocusSession): SharedFocusSession { return JSON.parse(JSON.stringify(value)) as SharedFocusSession; }
  private apply(response: SharedFocusResponse, identity: string): boolean {
    if (!this.reconcile() || identity !== this.identity || response.userId !== AuthStore.getUserId() || response.deviceId !== this.deviceId) return false;
    // Earlier acknowledgements must not overwrite newer queued offline intent.
    if (this.pending.length > 0) { this.lastResponseAt = Date.now(); this.lastError = ''; return true; }
    const previousId = this.session?.sessionId ?? (appState.focusRuntime?.shared === true ? appState.focusRuntime.sessionId : '');
    this.session = response.session;
    this.receivedAt = Date.now(); this.serverTime = response.serverTime;
    this.lastResponseAt = this.receivedAt; this.lastError = '';
    const session = this.session;
    if (session === null && previousId.length > 0) {
      appState.applySharedFocusRuntime(null, previousId);
      this.lastError = '共享专注已结束或设备连接已撤销，请重新连接后查看。';
    }
    if (session !== null && this.pending.length === 0) {
      const participating = session.participants.some((member) => member.deviceId === this.deviceId);
      if (participating && ['running', 'paused'].includes(session.state) &&
        appState.focusResultDraft === null &&
        (appState.focusRuntime?.sessionId === session.sessionId || session.leaderDeviceId === this.deviceId)) this.adopt(session);
      if (session.record !== undefined && session.record !== null) appState.acceptSharedFocusRecord(session.record);
      if (['completed', 'abandoned'].includes(session.state) && appState.focusRuntime?.sessionId === session.sessionId)
        appState.applySharedFocusRuntime(null, session.sessionId);
    }
    AppStorage.setOrCreate('sharedFocusRevision', (AppStorage.get<number>('sharedFocusRevision') ?? 0) + 1);
    return true;
  }
  private adopt(session: SharedFocusSession): boolean {
    if (appState.focusResultDraft !== null) return false;
    const runtime: FocusRuntime = { shared: true, sessionId: session.sessionId, ownerId: AuthStore.getUserId(),
      task: session.task, elapsedMs: session.elapsedMs, lastUpdatedAt: Date.now(), paused: session.state !== 'running',
      pauseCount: session.pauseCount ?? 0, interruptionCount: session.interruptionCount ?? 0 };
    return appState.applySharedFocusRuntime(runtime, session.sessionId);
  }
  public async refresh(): Promise<boolean> {
    if (!this.reconcile() || !this.deviceId || this.busy) return false;
    this.busy = true;
    const identity = this.identity;
    try {
      while (this.pending.length > 0) {
        const request = this.pending[0];
        const result = await AgentApiClient.sharedFocusAction(request);
        if (identity !== this.currentIdentity()) return false;
        if (!result.ok) {
          const failure = result as ApiFailure;
          if (failure.error.statusCode === 409 || failure.error.statusCode === 403 || failure.error.statusCode === 404) {
            this.pending = []; this.persist();
            await this.read(identity);
            this.lastError = failure.error.statusCode === 409 ? '已按另一台设备的状态同步，请确认后再操作。' : failure.error.message;
          } else this.lastError = '网络暂不可用，专注操作已保留，联网后自动同步。';
          return false;
        }
        this.pending.shift(); this.persist();
        this.apply(result.data, identity);
      }
      return await this.read(identity);
    } finally { this.busy = false; }
  }
  private async read(identity: string): Promise<boolean> {
    const result = await AgentApiClient.sharedFocus(this.deviceId, this.deviceKey);
    if (identity !== this.currentIdentity()) return false;
    if (!result.ok) {
      const failure = result as ApiFailure;
      this.lastError = failure.error.message;
      if ([401, 403].includes(failure.error.statusCode)) {
        const sessionId = this.session?.sessionId ?? (appState.focusRuntime?.shared === true ? appState.focusRuntime.sessionId : '');
        this.session = null;
        if (sessionId) appState.applySharedFocusRuntime(null, sessionId);
      }
      return false;
    }
    return this.apply(result.data, identity);
  }
  private async action(action: string, task?: FocusTask, assessment?: FocusSelfAssessment): Promise<boolean> {
    if (!this.reconcile() || !this.deviceId || this.busy) { this.lastError = '连接尚未就绪，请稍后重试。'; return false; }
    const current = this.getSnapshot().session;
    if (['start', 'handoff', 'join'].includes(action) &&
      ((appState.focusRuntime !== null && (action === 'start' || appState.focusRuntime.sessionId !== current?.sessionId)) ||
      appState.focusResultDraft !== null)) {
      this.lastError = '请先完成或放弃本机上次专注，再接着学习。'; return false;
    }
    if (action !== 'start' && current === null) return false;
    const request: SharedFocusRequest = { action: action, deviceId: this.deviceId, deviceKey: this.deviceKey,
      clientId: util.generateRandomUUID(true), expectedRevision: current?.revision ?? 0,
      occurredAt: this.serverTime > 0 ? this.serverTime + Math.max(0, Date.now() - this.receivedAt) : Date.now() };
    if (current !== null) request.sessionId = current.sessionId;
    if (task !== undefined) request.task = task;
    if (assessment !== undefined) request.selfAssessment = assessment;
    const requiresOnline = ['start', 'handoff', 'join'].includes(action);
    if (requiresOnline) {
      this.busy = true;
      const identity = this.identity;
      try {
        const result = await AgentApiClient.sharedFocusAction(request);
        if (identity !== this.currentIdentity()) return false;
        if (!result.ok) {
          const failure = result as ApiFailure;
          if (failure.error.statusCode === 409) await this.read(identity);
          this.lastError = failure.error.message;
          return false;
        }
        if (!this.apply(result.data, identity) || this.session === null) return false;
        return this.adopt(this.session);
      } finally { this.busy = false; }
    }
    if (this.pending.length >= 32) { this.lastError = '待同步操作较多，请联网后重试。'; return false; }
    this.pending.push(request);
    if (!this.persist()) { this.pending.pop(); return false; }
    if (current !== null) {
      if (action === 'pause') { current.state = 'paused'; current.pauseCount = (current.pauseCount ?? 0) + 1; }
      if (action === 'resume') current.state = 'running';
      if (action === 'complete') current.state = 'completed';
      if (action === 'abandon') current.state = 'abandoned';
      current.revision++;
      this.session = current; this.receivedAt = Date.now(); this.serverTime = request.occurredAt ?? this.serverTime;
      if (['pause', 'resume'].includes(action)) this.adopt(current);
    }
    const synchronized = await this.refresh();
    return synchronized || this.pending.some((item: SharedFocusRequest) => item.clientId === request.clientId);
  }
  public async start(task: FocusTask): Promise<boolean> { return this.action('start', task); }
  public async handoff(): Promise<boolean> { return this.action('handoff'); }
  public async pause(): Promise<boolean> { return this.action('pause'); }
  public async resume(): Promise<boolean> { return this.action('resume'); }
  public async finish(assessment: FocusSelfAssessment): Promise<boolean> { return this.action('complete', undefined, assessment); }
  public async abandon(): Promise<boolean> { return this.action('abandon', undefined, 'not_completed'); }
}
