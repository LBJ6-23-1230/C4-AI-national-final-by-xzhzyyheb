import router from '@ohos.router';
import { PageHeader } from '../components/PageHeader';
import { UiTheme } from '../utils/UiTheme';
import { DistributedSnapshot, DistributedStateService } from '../services/DistributedStateService';
import { CollaborationDevice, CollaborationLink } from '../api/DeviceCollaborationModels';
import { AgentApiClient } from '../api/AgentApiClient';
import { AuthStore } from '../api/AuthStore';
import { appState } from '../data/AppState';
import { FocusSessionSyncService, SharedFocusSnapshot } from '../services/FocusSessionSyncService';
import { ConnectionDiagnostics } from '../services/ConnectionDiagnostics';

@Entry
@Component
struct DeviceConnect {
  @State snapshot: DistributedSnapshot = DistributedStateService.getInstance().getSnapshot();
  @State name: string = '';
  @State working: boolean = false;
  @State notice: string = '';
  @State shared: SharedFocusSnapshot = FocusSessionSyncService.getInstance().getSnapshot();
  @State now: number = Date.now();
  @State diagnostic: string = '';
  @State checking: boolean = false;
  private service: DistributedStateService = DistributedStateService.getInstance();
  private focusSync: FocusSessionSyncService = FocusSessionSyncService.getInstance();
  private timer: number = -1;
  private signature: string = '';
  private active: boolean = false;
  private diagnosticVersion: number = 0;
  aboutToAppear(): void {
    this.active = true;
    this.refreshView();
    this.name = this.snapshot.localDeviceLabel;
    void this.service.refresh();
    this.timer = setInterval(() => this.refreshView(), 1000);
  }
  aboutToDisappear(): void {
    this.active = false;
    this.diagnosticVersion++;
    if (this.timer !== -1) clearInterval(this.timer);
    this.timer = -1;
  }
  private refreshView(): void {
    this.now = Date.now();
    this.shared = this.focusSync.getSnapshot();
    const snapshot = this.service.getSnapshot();
    const signature: string = JSON.stringify(snapshot);
    if (signature !== this.signature) { this.snapshot = snapshot; this.signature = signature; }
  }
  private async run(action: string, id: string = ''): Promise<void> {
    if (this.working) return;
    this.working = true;
    this.notice = '';
    try {
      let ok: boolean = false;
      if (action === 'refresh') {
        ok = await this.service.refresh();
        if (ok) await this.focusSync.refresh();
      }
      else if (action === 'invite') ok = await this.service.invite(id);
      else if (action === 'accept' || action === 'reject') ok = await this.service.respond(id, action === 'accept');
      else if (action === 'disconnect') ok = await this.service.disconnect(id);
      else if (action === 'rename') ok = await this.service.rename(this.name);
      else if (action === 'handoff') ok = await this.focusSync.handoff();
      if (!this.active) return;
      this.refreshView();
      if (ok) this.notice = action === 'invite' ? '请求已发送，请在对方设备上确认。' :
        action === 'accept' ? '已连接，可以接续同一次专注。' :
        action === 'rename' ? '设备名称已保存。' : action === 'disconnect' ? '已断开连接。' : '';
      else this.notice = this.shared.lastError || this.snapshot.lastError || '操作未完成，请刷新后重试。';
      if (ok && action === 'handoff') router.pushUrl({ url: 'pages/FocusTimer' });
    } finally { this.working = false; }
  }
  private stateText(link: CollaborationLink): string {
    if (link.state === 'pending') return link.incoming ? '请求连接这台设备' : '等待对方确认（60秒内）';
    if (link.state === 'connected') {
      if (this.snapshot.stale) return '已配对 · 等待恢复同步';
      const device = this.snapshot.devices.find((item: CollaborationDevice) => item.deviceId === link.peerDeviceId);
      if (device !== undefined && !device.online) return '已配对 · 对端在后台或暂时离线';
      return link.sentMessageId ? (link.acknowledgedAt > 0 ? '已连接 · 对方已收到任务' : '已连接 · 等待对方接收确认') : '已连接';
    }
    if (link.state === 'rejected') return '对方已拒绝，可重新发起';
    if (link.state === 'expired') return '请求已过期，可重新发起';
    return '已断开，可重新发起连接';
  }
  private syncText(): string {
    if (this.snapshot.lastResponseAt === 0) return '尚未同步';
    const seconds: number = Math.max(0, Math.floor((this.now - this.snapshot.lastResponseAt) / 1000));
    return `${this.snapshot.stale ? '同步中断 · ' : ''}最近同步 ${seconds} 秒前`;
  }
  private hasActiveSession(): boolean {
    return this.shared.session !== null && (this.shared.session.state === 'running' || this.shared.session.state === 'paused');
  }
  private clockText(): string {
    const session = this.shared.session;
    if (session === null) return '';
    const seconds: number = Math.max(0, Math.floor((session.task.timerType === 'stopwatch' ? session.elapsedMs : session.remainingMs) / 1000));
    return `${Math.floor(seconds / 60)}:${(seconds % 60).toString().padStart(2, '0')}`;
  }
  private async diagnose(): Promise<void> {
    if (this.checking) return;
    this.checking = true;
    const version: number = ++this.diagnosticVersion;
    const owner: string = AuthStore.getUserId();
    const address: string = AgentApiClient.getConfig().baseUrl;
    const result = await ConnectionDiagnostics.check();
    if (!this.active || version !== this.diagnosticVersion) return;
    this.checking = false;
    if (owner !== AuthStore.getUserId() || address !== AgentApiClient.getConfig().baseUrl) return;
    this.diagnostic = result.message;
  }
  private availableDevices(): CollaborationDevice[] {
    return this.snapshot.devices.filter((device: CollaborationDevice) => device.online &&
      !this.snapshot.links.some((link: CollaborationLink) => link.peerDeviceId === device.deviceId &&
      (link.state === 'connected' || link.state === 'pending')));
  }
  private adopt(): void {
    const task = this.service.getSnapshot().remoteTask;
    if (task === null) return;
    if (appState.focusRuntime !== null || appState.focusResultDraft !== null) {
      this.notice = '请先完成或放弃本机上次专注，再接收新任务。'; return;
    }
    appState.setFocusTask(task);
    this.service.consumeRemoteTask();
    router.pushUrl({ url: 'pages/FocusSetup' });
  }
  @Builder
  LinkRow(link: CollaborationLink) {
    Column({ space: 10 }) {
      Text(link.peerDeviceLabel).fontSize(16).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%')
      Text(this.stateText(link)).fontSize(13).fontColor(link.state === 'connected' ? UiTheme.success : UiTheme.secondary).width('100%')
      if (link.state === 'pending' && link.incoming) {
        Row({ space: 12 }) {
          Button('同意连接').fontSize(14).height(44).backgroundColor(UiTheme.accent).enabled(!this.working)
            .onClick(() => { void this.run('accept', link.invitationId); })
          Button('拒绝').fontSize(14).height(44).backgroundColor(UiTheme.subtle).fontColor(UiTheme.secondary).enabled(!this.working)
            .onClick(() => { void this.run('reject', link.invitationId); })
        }.width('100%')
      }
      if (link.state === 'connected' || (link.state === 'pending' && !link.incoming)) {
        Button(link.state === 'pending' ? '取消请求' : '断开连接').fontSize(14).height(44).backgroundColor(UiTheme.subtle)
          .fontColor(UiTheme.secondary).enabled(!this.working).onClick(() => { void this.run('disconnect', link.invitationId); })
      }
    }.alignItems(HorizontalAlign.Start).width('100%').padding({ top: 16, bottom: 16 })
      .border({ width: { bottom: 1 }, color: UiTheme.line })
  }
  build() {
    Column() {
      PageHeader({ title: '连接设备' })
      Scroll() {
        Column({ space: 20 }) {
          Text('手机、平板接着学').fontSize(22).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%')
          Text('两台设备登录同一个知学账号，使用同一后端地址。在这里选择设备，由对方确认后连接。首次配对时请打开两端应用。')
            .fontSize(14).fontColor(UiTheme.secondary).lineHeight(22).width('100%')
          Text('连接后可接续同一次专注，暂停、继续和完成会同步到另一台设备。')
            .fontSize(13).fontColor(UiTheme.secondary).width('100%')
          if (!this.snapshot.available) {
            Text(AgentApiClient.getConfig().useFixture ? '离线演示模式无法连接设备，请先切换到联机模式。' : '请先登录，两台设备需要使用同一知学账号。')
              .fontSize(14).fontColor(UiTheme.secondary).width('100%')
            Button(AuthStore.isSignedIn() ? '连接设置' : '去登录').height(44).backgroundColor(UiTheme.accent)
              .onClick(() => router.pushUrl({ url: AuthStore.isSignedIn() ? 'pages/ApiEnvironment' : 'pages/Login' }))
          } else {
            Column({ space: 8 }) {
              Text(`当前账号 · ${AuthStore.getUserId().slice(-6)}`).fontSize(14).fontColor(UiTheme.ink).width('100%')
              Text(`后端地址 · ${AgentApiClient.getConfig().baseUrl}`).fontSize(12).fontColor(UiTheme.secondary).width('100%')
              Text(this.syncText()).fontSize(12).fontColor(this.snapshot.stale ? UiTheme.danger : UiTheme.secondary).width('100%')
              Button(this.checking ? '正在检查…' : '检查连接').height(44).fontSize(14).backgroundColor(UiTheme.subtle)
                .fontColor(UiTheme.accent).enabled(!this.checking).onClick(() => { void this.diagnose(); })
              if (this.diagnostic) { Text(this.diagnostic).fontSize(13).fontColor(UiTheme.secondary).width('100%') }
            }.width('100%').alignItems(HorizontalAlign.Start)
            Column({ space: 12 }) {
              Text('本机名称').fontSize(14).fontColor(UiTheme.secondary).width('100%')
              Row({ space: 12 }) {
                TextInput({ text: this.name, placeholder: '例如：我的学习平板' }).maxLength(40).layoutWeight(1).height(44)
                  .fontSize(15).backgroundColor(UiTheme.subtle).onChange((value: string) => this.name = value)
                Button('保存').height(44).fontSize(14).backgroundColor(UiTheme.accent).enabled(!this.working && this.name.trim().length > 0)
                  .onClick(() => { void this.run('rename'); })
              }.width('100%')
              Text(this.snapshot.stale ? '保留上次连接，正在重试同步' : this.snapshot.sessionReady ? '本机已就绪' : '等待连接服务')
                .fontSize(12).fontColor(UiTheme.secondary).width('100%')
            }.width('100%')
            if (this.notice || this.snapshot.lastError) {
              Text(this.notice || this.snapshot.lastError).fontSize(14).fontColor(UiTheme.secondary).width('100%')
            }
            if (this.snapshot.links.length > 0) {
              Column() {
                Text('连接与请求').fontSize(17).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%')
                ForEach(this.snapshot.links, (link: CollaborationLink) => { this.LinkRow(link) }, (link: CollaborationLink) => link.invitationId)
              }.width('100%')
            }
            if (this.hasActiveSession() && this.shared.session !== null) {
              Column({ space: 10 }) {
                Text(`${this.shared.session.leaderLabel} · ${this.shared.session.state === 'paused' ? '已暂停' : '正在专注'}`)
                  .fontSize(14).fontColor(UiTheme.secondary).width('100%')
                Text(this.shared.session.task.task).fontSize(17).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%')
                Text(`${this.shared.session.task.timerType === 'stopwatch' ? '已专注' : '剩余'} ${this.clockText()}`)
                  .fontSize(20).fontColor(UiTheme.ink).width('100%')
                Text(`会话 ${this.shared.session.sessionId.slice(-12)}`).fontSize(12).fontColor(UiTheme.secondary).width('100%')
                if (this.shared.stale || this.shared.lastError) {
                  Text(this.shared.lastError || '同步中断，恢复网络后继续同步。').fontSize(13).fontColor(UiTheme.danger).width('100%')
                }
                Button('在这台设备继续').height(44).backgroundColor(UiTheme.accent)
                  .enabled(!this.working && !this.shared.busy && !this.shared.stale).onClick(() => { void this.run('handoff'); })
              }.width('100%').alignItems(HorizontalAlign.Start).padding(16).backgroundColor(UiTheme.tint).borderRadius(8)
            } else if (this.snapshot.remoteTask !== null) {
              Column({ space: 12 }) {
                Text(`来自${this.snapshot.remoteDeviceLabel}的任务`).fontSize(14).fontColor(UiTheme.secondary).width('100%')
                Text(this.snapshot.remoteTask.task).fontSize(17).fontColor(UiTheme.ink).width('100%')
                Button('使用此任务').height(44).backgroundColor(UiTheme.accent).onClick(() => this.adopt())
              }.width('100%').alignItems(HorizontalAlign.Start).padding(16).backgroundColor(UiTheme.tint).borderRadius(8)
            }
            Column({ space: 12 }) {
              Row() {
                Text('可连接的设备').fontSize(17).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink)
                Blank()
                Button('刷新').height(44).fontSize(14).backgroundColor(UiTheme.subtle).fontColor(UiTheme.accent).enabled(!this.working)
                  .onClick(() => { void this.run('refresh'); })
              }.width('100%')
              ForEach(this.availableDevices(), (device: CollaborationDevice) => {
                Row({ space: 12 }) {
                  Text(device.deviceLabel).fontSize(15).fontColor(UiTheme.ink).layoutWeight(1)
                  Button('连接').height(44).fontSize(14).backgroundColor(UiTheme.accent).enabled(!this.working)
                    .onClick(() => { void this.run('invite', device.deviceId); })
                }.width('100%')
              }, (device: CollaborationDevice) => device.deviceId)
              if (this.availableDevices().length === 0) {
                Text(this.snapshot.stale ? '正在恢复连接，设备列表保留上次同步结果。' :
                  this.snapshot.links.some((link: CollaborationLink) => link.state === 'connected') ? '已连接当前发现的设备，可直接接续专注。' :
                  this.snapshot.incomingCount > 0 || this.snapshot.links.some((link: CollaborationLink) => link.state === 'pending') ?
                    '连接请求正在等待确认。' : '暂未发现新设备。请核对两端账号尾号与后端地址，并打开另一台设备的应用。')
                  .fontSize(14).fontColor(UiTheme.secondary).lineHeight(22).width('100%')
              }
            }.width('100%')
            Text('锁屏、切后台会保留配对和专注会话。回到前台会自动刷新；只有点击“断开连接”才会解除配对。')
              .fontSize(12).fontColor(UiTheme.secondary).lineHeight(20).width('100%')
          }
        }.width('100%').constraintSize({ maxWidth: UiTheme.contentWidth }).padding({ left: 20, right: 20, top: 16, bottom: 32 })
      }.layoutWeight(1).width('100%')
    }.width('100%').height('100%').backgroundColor(UiTheme.surface)
  }
}
