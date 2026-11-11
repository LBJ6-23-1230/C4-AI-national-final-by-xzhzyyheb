import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { deviceInfo } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { AuthStore } from '../api/AuthStore';
import { AgentApiClient } from '../api/AgentApiClient';
import { ApiFailure } from '../api/ApiResult';
import { CollaborationDevice, CollaborationLink, CollaborationRequest, CollaborationResponse } from '../api/DeviceCollaborationModels';
import { FocusTask } from '../models/AgentModels';
import { FocusSessionSyncService } from './FocusSessionSyncService';

export interface DistributedPeer {
  networkId: string;
  deviceLabel: string;
  online: boolean;
}
export interface DistributedSnapshot {
  sessionReady: boolean;
  permissionGranted: boolean;
  localJoined: boolean;
  sessionId: string;
  localDeviceLabel: string;
  onlinePeerCount: number;
  peers: DistributedPeer[];
  remoteTask: FocusTask | null;
  remoteDeviceLabel: string;
  lastSyncedAt: number;
  lastError: string;
  devices: CollaborationDevice[];
  links: CollaborationLink[];
  incomingCount: number;
  available: boolean;
  busy: boolean;
  deliveryText: string;
  stale: boolean;
  lastResponseAt: number;
  localDeviceId: string;
}
export type DistributedSnapshotListener = (snapshot: DistributedSnapshot) => void;

export class DistributedStateService {
  private static instance: DistributedStateService | null = null;
  private context: common.UIAbilityContext | null = null;
  private listener: DistributedSnapshotListener | null = null;
  private timer: number = -1;
  private foreground: boolean = true;
  private enabled: boolean = false;
  private identity: string = '';
  private generation: number = 0;
  private deviceId: string = '';
  private deviceKey: string = '';
  private label: string = '';
  private registered: boolean = false;
  private response: CollaborationResponse | null = null;
  private lastResponseAt: number = 0;
  private lastError: string = '';
  private queue: Promise<void> = Promise.resolve();
  private queued: number = 0;
  private remoteTask: FocusTask | null = null;
  private remoteLabel: string = '';
  private lastSyncedAt: number = 0;
  private acknowledgements: Set<string> = new Set<string>();
  private consumedMessages: Set<string> = new Set<string>();

  public static getInstance(): DistributedStateService {
    if (DistributedStateService.instance === null) DistributedStateService.instance = new DistributedStateService();
    return DistributedStateService.instance;
  }
  public async init(context: common.UIAbilityContext): Promise<void> {
    this.context = context;
    this.label = this.resolveLabel();
    this.enabled = true;
    this.setForeground(true);
  }
  public setForeground(foreground: boolean): void {
    this.foreground = foreground;
    if (this.timer !== -1) clearInterval(this.timer);
    this.timer = -1;
    if (!this.enabled) return;
    if (foreground) {
      void this.refresh();
      this.timer = setInterval(() => { if (this.queued === 0) void this.refresh(); }, 5000);
    } else {
      void this.send('background');
      this.notify();
    }
  }
  private currentIdentity(): string {
    const config = AgentApiClient.getConfig();
    return !AuthStore.isSignedIn() || config.useFixture ? '' :
      `${config.baseUrl}|${AuthStore.getUserId()}|${AuthStore.getToken()}`;
  }
  private reconcileIdentity(): boolean {
    const identity: string = this.currentIdentity();
    if (identity === this.identity) return identity.length > 0;
    this.identity = identity;
    this.generation++;
    this.registered = false;
    this.response = null;
    this.lastResponseAt = 0;
    this.lastError = '';
    this.deviceId = '';
    this.deviceKey = '';
    this.acknowledgements.clear();
    this.consumedMessages.clear();
    this.clearRemote();
    return identity.length > 0;
  }
  private loadInstallation(): boolean {
    if (this.deviceId && this.deviceKey) return true;
    if (this.context === null) return false;
    try {
      const store = preferences.getPreferencesSync(this.context, { name: 'collaboration_installation' });
      const scope: string = encodeURIComponent(`${AgentApiClient.getConfig().baseUrl}|${AuthStore.getUserId()}`);
      this.deviceId = store.getSync(`${scope}_id`, '') as string;
      this.deviceKey = store.getSync(`${scope}_key`, '') as string;
      if (!this.deviceId || !this.deviceKey) {
        this.deviceId = util.generateRandomUUID(true);
        this.deviceKey = util.generateRandomUUID(true) + util.generateRandomUUID(true);
        store.putSync(`${scope}_id`, this.deviceId);
        store.putSync(`${scope}_key`, this.deviceKey);
        store.flushSync();
      }
      this.label = store.getSync('label', this.label) as string;
      return true;
    } catch (_) {
      this.lastError = '无法保存本机设备信息，请重试。';
      return false;
    }
  }
  public async rename(label: string): Promise<boolean> {
    if (!label.trim() || label.trim().length > 40 || this.context === null) return false;
    try {
      const store = preferences.getPreferencesSync(this.context, { name: 'collaboration_installation' });
      store.putSync('label', label.trim()); store.flushSync();
      this.label = label.trim();
      this.registered = false;
      return await this.refresh();
    } catch (_) { this.lastError = '设备名称保存失败，请重试。'; this.notify(); return false; }
  }
  public isReady(): boolean { return this.getSnapshot().sessionReady; }
  public setListener(listener: DistributedSnapshotListener | null): void { this.listener = listener; }
  public async refresh(): Promise<boolean> { return this.send('heartbeat'); }
  public consumeRemoteTask(): void {
    if (this.response !== null) this.response.links.forEach((link: CollaborationLink) => {
      if (link.received !== null) {
        this.consumedMessages.add(link.received.messageId);
        void this.send('consume', '', link.invitationId, undefined, link.received.messageId);
      }
    });
    this.clearRemote(); this.notify();
  }
  public async invite(id: string): Promise<boolean> { return this.send('invite', id); }
  public async respond(invitation: string, accept: boolean): Promise<boolean> {
    return this.send(accept ? 'accept' : 'reject', '', invitation);
  }
  public async disconnect(invitation: string): Promise<boolean> { return this.send('disconnect', '', invitation); }
  public publishFocusTask(task: FocusTask): void {
    if (this.getSnapshot().onlinePeerCount > 0) void this.send('publish', '', '', task);
  }
  public async shareFocusTask(task: FocusTask): Promise<boolean> { return this.send('publish', '', '', task); }
  public clearFocusTask(): void {
    if (this.getSnapshot().onlinePeerCount > 0) void this.send('clear');
  }
  public async leave(): Promise<void> {
    if (this.timer !== -1) clearInterval(this.timer);
    this.timer = -1;
    this.foreground = false;
    this.enabled = false;
    await this.send('background');
    this.registered = false;
    this.notify();
  }
  private async send(action: string, target: string = '', invitation: string = '', task?: FocusTask,
    message: string = ''): Promise<boolean> {
    this.reconcileIdentity();
    const generation: number = this.generation;
    this.queued++;
    const operation: Promise<boolean> = this.queue.then(() =>
      this.perform(generation, action, target, invitation, task, message));
    this.queue = operation.then(() => { this.queued--; this.notify(); }, () => { this.queued--; this.notify(); });
    return operation;
  }
  private async perform(generation: number, action: string, target: string, invitation: string,
    task?: FocusTask, message: string = ''): Promise<boolean> {
    if (!this.reconcileIdentity() || generation !== this.generation || (!this.foreground && !['offline', 'background'].includes(action))) return false;
    if (!this.loadInstallation()) { this.notify(); return false; }
    const identity: string = this.identity;
    const owner: string = AuthStore.getUserId();
    try {
      if (!this.registered) {
        if (action === 'offline' || action === 'background') return true;
        const registration = await AgentApiClient.deviceCollaboration({ action: 'register', deviceId: this.deviceId,
          deviceKey: this.deviceKey, deviceLabel: this.label });
        if (!this.isCurrent(identity, generation)) return false;
        if (!registration.ok) { this.fail(registration as ApiFailure); return false; }
        if (registration.data.userId !== owner || registration.data.deviceId !== this.deviceId) return false;
        this.registered = true;
        if (this.context !== null) FocusSessionSyncService.getInstance().configure(this.context, this.deviceId, this.deviceKey);
        this.apply(registration.data);
        if (action === 'heartbeat') { await FocusSessionSyncService.getInstance().refresh(); return true; }
      }
      const request: CollaborationRequest = { action: action, deviceId: this.deviceId, deviceKey: this.deviceKey };
      if (target) request.targetDeviceId = target;
      if (invitation) request.invitationId = invitation;
      if (task !== undefined) request.task = task;
      if (action === 'publish' || action === 'clear') request.messageId = util.generateRandomUUID(true);
      if (message) request.messageId = message;
      const result = await AgentApiClient.deviceCollaboration(request);
      if (!this.isCurrent(identity, generation)) return false;
      if (!result.ok) { this.fail(result as ApiFailure); return false; }
      if (result.data.userId !== owner || result.data.deviceId !== this.deviceId) return false;
      this.apply(result.data);
      if (action !== 'background' && action !== 'offline') await FocusSessionSyncService.getInstance().refresh();
      return true;
    } catch (_) {
      if (this.isCurrent(identity, generation)) { this.lastError = '连接服务暂时不可用，请检查网络后重试。'; this.notify(); }
      return false;
    }
  }
  private isCurrent(identity: string, generation: number): boolean {
    return identity === this.currentIdentity() && generation === this.generation;
  }
  private fail(failure: ApiFailure): void {
    this.lastError = failure.error.statusCode === 404 && failure.error.code !== 'DEVICE_COLLABORATION'
      ? '连接服务尚未更新，请更新后端后重试。' : failure.error.message;
    if ([401, 403, 404].includes(failure.error.statusCode)) this.registered = false;
    if ([401, 403].includes(failure.error.statusCode)) { this.response = null; this.clearRemote(); }
    this.notify();
  }
  private apply(response: CollaborationResponse): void {
    this.response = response;
    this.lastResponseAt = Date.now();
    this.lastError = '';
    this.clearRemote();
    for (let i: number = 0; i < response.links.length; i++) {
      const link: CollaborationLink = response.links[i];
      if (link.state !== 'connected' || link.received === null) continue;
      const received = link.received;
      if (received.task !== null && !this.consumedMessages.has(received.messageId) && received.sentAt * 1000 >= this.lastSyncedAt) {
        this.remoteTask = received.task;
        this.remoteLabel = link.peerDeviceLabel;
        this.lastSyncedAt = received.sentAt * 1000;
      }
      const ackKey: string = `${link.invitationId}:${received.messageId}`;
      if (received.ackedAt === 0 && !this.acknowledgements.has(ackKey)) {
        this.acknowledgements.add(ackKey);
        void this.send('ack', '', link.invitationId, undefined, received.messageId).then((ok: boolean) => {
          if (!ok) this.acknowledgements.delete(ackKey);
        });
      }
    }
    this.notify();
  }
  private clearRemote(): void { this.remoteTask = null; this.remoteLabel = ''; this.lastSyncedAt = 0; }
  public getSnapshot(): DistributedSnapshot {
    const available: boolean = this.reconcileIdentity();
    const response: CollaborationResponse | null = this.response;
    const stale: boolean = response !== null && (Date.now() - this.lastResponseAt >= 15000 || this.lastError.length > 0);
    const links: CollaborationLink[] = response !== null ? response.links : [];
    const devices: CollaborationDevice[] = response !== null ? response.devices : [];
    const connected: CollaborationLink[] = links.filter((link: CollaborationLink) => link.state === 'connected');
    const peers: DistributedPeer[] = connected.map((link: CollaborationLink) => {
      const peer: DistributedPeer = { networkId: link.peerDeviceId, deviceLabel: link.peerDeviceLabel,
        online: !stale && devices.some((device: CollaborationDevice) => device.deviceId === link.peerDeviceId && device.online) };
      return peer;
    });
    const sent: CollaborationLink[] = connected.filter((link: CollaborationLink) => link.sentMessageId.length > 0);
    const delivered: number = sent.filter((link: CollaborationLink) => link.acknowledgedAt > 0).length;
    const delivery: string = sent.length === 0 ? '' : delivered === sent.length ? `已同步至 ${delivered} 台设备` :
      `等待接收确认（${delivered}/${sent.length}）`;
    return { sessionReady: response !== null, permissionGranted: available, localJoined: response !== null,
      sessionId: '', localDeviceLabel: this.label || '本机', onlinePeerCount: peers.length, peers: peers,
      remoteTask: response !== null ? this.remoteTask : null, remoteDeviceLabel: response !== null ? this.remoteLabel : '',
      lastSyncedAt: response !== null ? this.lastSyncedAt : 0, lastError: this.lastError, devices: devices, links: links,
      incomingCount: links.filter((link: CollaborationLink) => link.state === 'pending' && link.incoming).length,
      available: available, busy: this.queued > 0, deliveryText: delivery, stale: stale,
      lastResponseAt: this.lastResponseAt, localDeviceId: this.deviceId };
  }
  private notify(): void {
    if (this.listener !== null) { try { this.listener(this.getSnapshot()); } catch (_) {} }
  }
  private resolveLabel(): string {
    try {
      const model: string = deviceInfo.marketName || deviceInfo.productModel;
      if (model && model.toLowerCase() !== 'emulator') return model.slice(0, 40);
      return deviceInfo.deviceType === 'tablet' ? '我的平板' : deviceInfo.deviceType === '2in1' ? '我的电脑' : '我的手机';
    } catch (_) { return '我的设备'; }
  }
}
