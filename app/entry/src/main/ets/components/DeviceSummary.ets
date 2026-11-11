import router from '@ohos.router';
import { DistributedSnapshot, DistributedStateService } from '../services/DistributedStateService';
import { UiTheme } from '../utils/UiTheme';
import { FocusSessionSyncService, SharedFocusSnapshot } from '../services/FocusSessionSyncService';

@Component
export struct DeviceSummary {
  @Prop compact: boolean = false;
  @State snapshot: DistributedSnapshot = DistributedStateService.getInstance().getSnapshot();
  @State shared: SharedFocusSnapshot = FocusSessionSyncService.getInstance().getSnapshot();
  @State now: number = Date.now();
  @State working: boolean = false;
  @State notice: string = '';
  private active: boolean = false;
  private timer: number = -1;
  private signature: string = '';
  aboutToAppear(): void {
    this.active = true;
    this.refresh();
    this.timer = setInterval(() => this.refresh(), 2000);
  }
  aboutToDisappear(): void { this.active = false; if (this.timer !== -1) clearInterval(this.timer); this.timer = -1; }
  private refresh(): void {
    this.now = Date.now();
    this.shared = FocusSessionSyncService.getInstance().getSnapshot();
    const current: DistributedSnapshot = DistributedStateService.getInstance().getSnapshot();
    const signature: string = JSON.stringify(current);
    if (signature !== this.signature) { this.signature = signature; this.snapshot = current; }
  }
  private syncText(): string {
    if (this.snapshot.lastResponseAt === 0) return this.snapshot.available ? '等待首次同步' : '登录后连接';
    const seconds: number = Math.max(0, Math.floor((this.now - this.snapshot.lastResponseAt) / 1000));
    return `${this.snapshot.stale ? '同步中断 · ' : ''}${seconds} 秒前同步`;
  }
  private activeSession(): boolean {
    return this.shared.session !== null && (this.shared.session.state === 'running' || this.shared.session.state === 'paused');
  }
  private async resumeHere(): Promise<void> {
    if (this.working) return;
    this.working = true;
    const service = FocusSessionSyncService.getInstance();
    try {
      const ok: boolean = await service.handoff();
      if (!this.active) return;
      if (ok) router.pushUrl({ url: 'pages/FocusTimer' });
      else this.notice = service.getSnapshot().lastError || '暂时无法接续，请刷新后重试。';
    } finally { this.working = false; }
  }
  build() {
    Column({ space: 12 }) {
      Row() {
        Column({ space: 4 }) {
          Text(this.snapshot.localDeviceLabel || '本机').fontSize(14).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink)
          Text(this.syncText()).fontSize(12).fontColor(UiTheme.secondary)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Divider().vertical(true).height(30).color(UiTheme.line).margin({ left: 16, right: 24 })
        Column({ space: 4 }) {
          Text(this.snapshot.stale ? '等待恢复同步' : this.snapshot.onlinePeerCount > 0 ? `已连接 ${this.snapshot.onlinePeerCount} 台设备` : '连接设备')
            .fontSize(14).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink)
          Text(this.snapshot.incomingCount > 0 ? `${this.snapshot.incomingCount} 个连接请求 ›` : !this.snapshot.available ? '登录后连接 ›' :
            this.snapshot.deliveryText ? `${this.snapshot.deliveryText} ›` : this.snapshot.onlinePeerCount > 0 ? '查看设备 ›' : '手机、平板接着学 ›')
            .fontSize(12).fontColor(UiTheme.secondary)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      }.width('100%').constraintSize({ minHeight: 44 }).onClick(() => router.pushUrl({ url: 'pages/DeviceConnect' }))
      if (!this.compact && this.activeSession() && this.shared.session !== null) {
        Divider().color(UiTheme.line)
        Text(`${this.shared.session.leaderLabel} · ${this.shared.session.state === 'paused' ? '专注已暂停' : '正在专注'}`)
          .fontSize(12).fontColor(UiTheme.secondary).width('100%')
        Text(this.shared.session.task.task).fontSize(16).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%')
        Button('在这台设备继续').height(44).fontSize(14).fontColor(UiTheme.accent).backgroundColor(UiTheme.subtle)
          .enabled(!this.working && !this.shared.busy && !this.shared.stale).onClick(() => { void this.resumeHere(); })
      } else if (!this.compact && this.snapshot.remoteTask !== null) {
        Divider().color(UiTheme.line)
        Text('远端任务').fontSize(12).fontColor(UiTheme.secondary).width('100%')
        Row({ space: 12 }) {
          Column({ space: 4 }) {
            Text(this.snapshot.remoteTask.task).fontSize(16).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink)
            Text(`${this.snapshot.remoteTask.course} · 来自${this.snapshot.remoteDeviceLabel || '其他设备'}`)
              .fontSize(12).fontColor(UiTheme.secondary)
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Button('查看任务').fontSize(13).height(44).fontColor(UiTheme.accent).backgroundColor(UiTheme.subtle)
            .onClick(() => router.pushUrl({ url: 'pages/DeviceConnect' }))
        }.width('100%')
      }
      if (this.snapshot.lastError) { Text(this.snapshot.lastError).fontSize(12).fontColor(UiTheme.danger).width('100%') }
      if (this.notice) { Text(this.notice).fontSize(12).fontColor(UiTheme.danger).width('100%') }
    }.width('100%').padding({ top: 12, bottom: 16 }).accessibilityText('查看设备协同状态与接续任务')
  }
}
