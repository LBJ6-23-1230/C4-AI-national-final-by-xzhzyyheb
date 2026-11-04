import router from '@ohos.router';
import { DistributedSnapshot, DistributedStateService } from '../services/DistributedStateService';
import { UiTheme } from '../utils/UiTheme';

/** Reads the shared service without replacing its active page's sync listener. */
@Component
export struct DeviceSummary {
  @Prop compact: boolean = false;
  @State snapshot: DistributedSnapshot = DistributedStateService.getInstance().getSnapshot();
  private timer: number = -1;
  private signature: string = '';
  aboutToAppear(): void {
    this.refresh();
    this.timer = setInterval(() => this.refresh(), 2000);
  }
  aboutToDisappear(): void { if (this.timer !== -1) clearInterval(this.timer); this.timer = -1; }
  private refresh(): void {
    const current: DistributedSnapshot = DistributedStateService.getInstance().getSnapshot();
    const signature: string = JSON.stringify(current);
    if (signature !== this.signature) { this.signature = signature; this.snapshot = current; }
  }
  build() {
    Column({ space: 12 }) {
      Row() {
        Column({ space: 4 }) {
          Text(this.snapshot.localDeviceLabel || '本机').fontSize(14).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink)
          Text(this.snapshot.onlinePeerCount > 0 ? '协同中' : '本机学习').fontSize(12).fontColor(UiTheme.secondary)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Divider().vertical(true).height(30).color(UiTheme.line).margin({ left: 16, right: 24 })
        Column({ space: 4 }) {
          Text(this.snapshot.onlinePeerCount > 0 ? `已连接 ${this.snapshot.onlinePeerCount} 台设备` : '连接设备')
            .fontSize(14).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink)
          Text(this.snapshot.incomingCount > 0 ? `${this.snapshot.incomingCount} 个连接请求 ›` : !this.snapshot.available ? '登录后连接 ›' :
            this.snapshot.deliveryText ? `${this.snapshot.deliveryText} ›` : this.snapshot.onlinePeerCount > 0 ? '查看设备 ›' : '手机、平板接着学 ›')
            .fontSize(12).fontColor(UiTheme.secondary)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      }.width('100%')
      if (!this.compact && this.snapshot.remoteTask !== null) {
        Divider().color(UiTheme.line)
        Text('远端任务').fontSize(12).fontColor(UiTheme.secondary).width('100%')
        Row({ space: 12 }) {
          Column({ space: 4 }) {
            Text(this.snapshot.remoteTask.task).fontSize(16).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink)
            Text(`${this.snapshot.remoteTask.course} · 来自${this.snapshot.remoteDeviceLabel || '其他设备'}`)
              .fontSize(12).fontColor(UiTheme.secondary)
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Text('继续学习 ›').fontSize(13).fontColor(UiTheme.accent)
        }.width('100%')
      }
      if (this.snapshot.lastError) { Text(this.snapshot.lastError).fontSize(12).fontColor(UiTheme.danger).width('100%') }
    }.width('100%').padding({ top: 12, bottom: 16 }).accessibilityText('查看设备协同状态与接续任务')
      .onClick(() => router.pushUrl({ url: 'pages/DeviceConnect' }))
  }
}
