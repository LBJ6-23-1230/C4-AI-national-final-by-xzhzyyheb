import router from '@ohos.router';
import { PageHeader } from '../components/PageHeader';
import { UiTheme } from '../utils/UiTheme';
import { DistributedSnapshot, DistributedStateService } from '../services/DistributedStateService';
import { CollaborationDevice, CollaborationLink } from '../api/DeviceCollaborationModels';
import { AgentApiClient } from '../api/AgentApiClient';
import { AuthStore } from '../api/AuthStore';
import { appState } from '../data/AppState';

@Entry
@Component
struct DeviceConnect {
  @State snapshot: DistributedSnapshot = DistributedStateService.getInstance().getSnapshot();
  @State name: string = '';
  @State working: boolean = false;
  @State notice: string = '';
  private service: DistributedStateService = DistributedStateService.getInstance();
  private timer: number = -1;
  private signature: string = '';
  aboutToAppear(): void {
    this.refreshView();
    this.name = this.snapshot.localDeviceLabel;
    void this.service.refresh();
    this.timer = setInterval(() => this.refreshView(), 1000);
  }
  aboutToDisappear(): void { if (this.timer !== -1) clearInterval(this.timer); this.timer = -1; }
  private refreshView(): void {
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
      if (action === 'refresh') ok = await this.service.refresh();
      else if (action === 'invite') ok = await this.service.invite(id);
      else if (action === 'accept' || action === 'reject') ok = await this.service.respond(id, action === 'accept');
      else if (action === 'disconnect') ok = await this.service.disconnect(id);
      else if (action === 'rename') ok = await this.service.rename(this.name);
      else if (action === 'share' && appState.focusRuntime !== null) ok = await this.service.shareFocusTask(appState.focusRuntime.task);
      this.refreshView();
      if (ok) this.notice = action === 'invite' ? '请求已发送，请在对方设备上确认。' :
        action === 'accept' ? '已连接，可以同步专注任务。' : action === 'share' ? '任务已发送，正在等待对方接收确认。' :
        action === 'rename' ? '设备名称已保存。' : action === 'disconnect' ? '已断开连接。' : '';
      else this.notice = this.snapshot.lastError || '操作未完成，请刷新后重试。';
    } finally { this.working = false; }
  }
  private stateText(link: CollaborationLink): string {
    if (link.state === 'pending') return link.incoming ? '请求连接这台设备' : '等待对方确认（60秒内）';
    if (link.state === 'connected') return link.sentMessageId ? (link.acknowledgedAt > 0 ? '任务已收到' : '任务已发送，等待接收确认') : '已连接，尚未发送任务';
    if (link.state === 'rejected') return '对方已拒绝，可重新发起';
    if (link.state === 'expired') return '请求已过期，可重新发起';
    return '已断开，请确认两端应用均在前台';
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
          Text('两台设备登录同一个知学账号并联网，保持应用在前台。在这里选择设备，由对方确认后连接。无需连接同一 Wi-Fi。')
            .fontSize(14).fontColor(UiTheme.secondary).lineHeight(22).width('100%')
          Text('当前同步课程、任务名称和专注设置；接收后需要手动开始，计时进度不会接续。')
            .fontSize(13).fontColor(UiTheme.secondary).width('100%')
          if (!this.snapshot.available) {
            Text(AgentApiClient.getConfig().useFixture ? '离线演示模式无法连接设备，请先切换到联机模式。' : '请先登录，两台设备需要使用同一知学账号。')
              .fontSize(14).fontColor(UiTheme.secondary).width('100%')
            Button(AuthStore.isSignedIn() ? '连接设置' : '去登录').height(44).backgroundColor(UiTheme.accent)
              .onClick(() => router.pushUrl({ url: AuthStore.isSignedIn() ? 'pages/ApiEnvironment' : 'pages/Login' }))
          } else {
            Column({ space: 12 }) {
              Text('本机名称').fontSize(14).fontColor(UiTheme.secondary).width('100%')
              Row({ space: 12 }) {
                TextInput({ text: this.name, placeholder: '例如：我的学习平板' }).maxLength(40).layoutWeight(1).height(44)
                  .fontSize(15).backgroundColor(UiTheme.subtle).onChange((value: string) => this.name = value)
                Button('保存').height(44).fontSize(14).backgroundColor(UiTheme.accent).enabled(!this.working && this.name.trim().length > 0)
                  .onClick(() => { void this.run('rename'); })
              }.width('100%')
              Text(this.snapshot.sessionReady ? '本机已就绪' : '正在连接服务…').fontSize(12).fontColor(UiTheme.secondary).width('100%')
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
            if (this.snapshot.remoteTask !== null) {
              Column({ space: 12 }) {
                Text(`来自${this.snapshot.remoteDeviceLabel}的任务`).fontSize(14).fontColor(UiTheme.secondary).width('100%')
                Text(this.snapshot.remoteTask.task).fontSize(17).fontColor(UiTheme.ink).width('100%')
                Button('使用此任务').height(44).backgroundColor(UiTheme.accent).onClick(() => this.adopt())
              }.width('100%').alignItems(HorizontalAlign.Start).padding(16).backgroundColor(UiTheme.tint).borderRadius(8)
            }
            if (this.snapshot.onlinePeerCount > 0 && appState.focusRuntime !== null) {
              Button('发送当前专注任务').height(44).width('100%').backgroundColor(UiTheme.accent).enabled(!this.working)
                .onClick(() => { void this.run('share'); })
            }
            Column({ space: 12 }) {
              Row() {
                Text('同账号在线设备').fontSize(17).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink)
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
                Text('没有可连接的新设备。请在另一台设备登录同一账号，并打开此页面；设备列表约每5秒更新。')
                  .fontSize(14).fontColor(UiTheme.secondary).lineHeight(22).width('100%')
              }
            }.width('100%')
            Text('离开应用会断开协同。网络异常或设备关闭后，在线状态最长约25秒失效；重新打开后需再次确认连接。')
              .fontSize(12).fontColor(UiTheme.secondary).lineHeight(20).width('100%')
          }
        }.width('100%').constraintSize({ maxWidth: UiTheme.contentWidth }).padding({ left: 20, right: 20, top: 16, bottom: 32 })
      }.layoutWeight(1).width('100%')
    }.width('100%').height('100%').backgroundColor(UiTheme.surface)
  }
}
