import { UiTheme } from '../utils/UiTheme';
import { PageHeader } from '../components/PageHeader';
import router from '@ohos.router';
import { common } from '@kit.AbilityKit';
import { AgentApiClient, ApiClientConfig } from '../api/AgentApiClient';
import { ApiDefaults } from '../api/ApiDefaults';
import { ApiEnvironmentStore } from '../api/ApiEnvironmentStore';
import { FixtureDemoStateStore } from '../api/FixtureDemoStateStore';
import { ApiFailure } from '../api/ApiResult';
import { ClientCache } from '../cache/ClientCache';
import { WorkflowSessionStore } from '../cache/WorkflowSessionStore';

@Entry
@Component
struct ApiEnvironment {
  @State baseUrl: string = '';
  @State useFixture: boolean = false;
  @State isChecking: boolean = false;
  @State message: string = '';
  private checkRequestVersion: number = 0;
  private isPageActive: boolean = false;

  aboutToAppear(): void {
    if (!ApiDefaults.ALLOW_DEBUG) {
      router.back();
      return;
    }
    this.isPageActive = true;
    this.syncConfig();
  }

  aboutToDisappear(): void {
    this.isPageActive = false;
    this.checkRequestVersion++;
  }

  private syncConfig(): void {
    const config: ApiClientConfig = AgentApiClient.getConfig();
    this.baseUrl = config.baseUrl;
    this.useFixture = config.useFixture;
  }

  private applyConfig(baseUrl: string, useFixture: boolean, message: string): void {
    if (!ApiDefaults.ALLOW_DEBUG) return;
    this.checkRequestVersion++;
    this.isChecking = false;
    const current: ApiClientConfig = AgentApiClient.getConfig();
    const enteringFixture: boolean = useFixture && !current.useFixture;
    AgentApiClient.configure({ baseUrl: baseUrl, useFixture: useFixture, timeoutMs: current.timeoutMs });
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    ClientCache.clearDemoData();
    WorkflowSessionStore.clear(context);
    if (enteringFixture) {
      FixtureDemoStateStore.reset();
    }
    this.syncConfig();
    if (ApiEnvironmentStore.save(context, AgentApiClient.getConfig())) {
      this.message = `${message} 此选择会在下次启动时保留。`;
    } else {
      this.message = `${message} 当前已生效，但暂时无法保存到下次启动。`;
    }
  }

  private useOfflineDemo(): void {
    this.applyConfig(this.baseUrl, true, '已切换到 Fixture；核心流程可离线演示。');
  }

  private useEmulatorBackend(): void {
    this.applyConfig(ApiDefaults.DEFAULT_BASE_URL, false,
      `已切换到真 Agent 后端（${ApiDefaults.DEFAULT_BASE_URL}），请确认电脑 5000 端口服务已启动。`);
  }

  private useCustomBackend(): void {
    const value: string = this.baseUrl.trim();
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      this.message = '请输入以 http:// 或 https:// 开头的完整地址。';
      return;
    }
    this.applyConfig(value, false, '已应用真机/自定义地址，并清除了旧接口缓存。');
  }

  private async checkCurrentPlan(): Promise<void> {
    if (this.isChecking) {
      return;
    }
    this.isChecking = true;
    this.message = '';
    const requestVersion: number = ++this.checkRequestVersion;
    const result = await AgentApiClient.getCurrentPlan();
    if (!this.isPageActive || requestVersion !== this.checkRequestVersion) {
      return;
    }
    this.isChecking = false;
    if (result.ok) {
      this.message = `连接成功：${result.source === 'fixture' ? 'Fixture' : '真实后端'}返回 Plan V${result.data.version}。`;
      return;
    }
    const failure: ApiFailure = result as ApiFailure;
    //  区分「连不上」与「连上了、但服务端返回了错误」。
    // `statusCode > 0` 说明**已经拿到 HTTP 响应** —— 例如账号还没有计划时的
    // 404 `current plan not found`，那恰恰证明地址与网络都是通的。
    // 原来一律写成"连接失败：<服务端 message>"，把**业务错误说成网络问题**，
    // 会把排查方向带偏（与审计里记过的"响应体解析错误被改写成连接超时"同类）。
    this.message = failure.error.statusCode > 0
      ? `已连上服务（HTTP ${failure.error.statusCode}），但接口返回错误：${failure.error.message}`
      : `连接失败：${failure.error.message}`;
  }

  build() {
    Column() {
      PageHeader({ title: '接口环境（开发）', assistant: false, onBack: () => { router.back(); } })
      Scroll() {
        Column({ space: 16 }) {
          Text('数据源与联调地址').fontSize(23).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink).width('100%')
          Text('切换后会清除短期接口缓存，不会修改后端、项目代码或课程数据。')
            .fontSize(13).fontColor(UiTheme.secondary).lineHeight(20).width('100%')
          //  两个按钮的**配色必须由选中状态驱动**。
          //
          // 修复的缺陷：原先"离线 Fixture"按钮写死 `.backgroundColor(UiTheme.accent)`（蓝底白字）、
          // "真 Agent 后端"按钮写死 `.backgroundColor(UiTheme.surface)`（白底蓝字），
          // 只有**文字**随 `useFixture` 变。后果是切到联机后，**离线按钮看起来仍然是被选中的那个**
          // ——用户反馈的"怎么调，按钮始终是离线（加重）"就是这个。
          // 现在选中方为实心蓝，未选中方为白底描边，与真实状态一致。
          Button(this.useFixture ? '当前：离线 Fixture' : '使用离线 Fixture')
            .width('100%').height(48).fontSize(15)
            .fontColor(this.useFixture ? UiTheme.surface : UiTheme.accent)
            .backgroundColor(this.useFixture ? UiTheme.accent : UiTheme.surface)
            .border({ width: 1, color: this.useFixture ? UiTheme.accent : '#BFDBFE' })
            .borderRadius(8)
            .onClick(() => this.useOfflineDemo())
          Text('固定演示不依赖后端，可稳定展示 42 → 58 → Plan V2。').fontSize(12).fontColor(UiTheme.secondary).width('100%')
          Button(!this.useFixture ? '当前：真 Agent 后端' : '使用真 Agent 后端（5000）')
            .width('100%').height(48).fontSize(15)
            .fontColor(!this.useFixture ? UiTheme.surface : UiTheme.accent)
            .backgroundColor(!this.useFixture ? UiTheme.accent : UiTheme.surface)
            .border({ width: 1, color: !this.useFixture ? UiTheme.accent : '#BFDBFE' })
            .borderRadius(8).onClick(() => this.useEmulatorBackend())
          Column({ space: 10 }) {
            Text('真机 / 自定义后端').fontSize(16).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink).width('100%')
            // 真机联调：手机与本机需在同一 WiFi，用 ipconfig 取本机 IPv4 地址后按
            // http://<本机IP>:5000 填写（详见项目根 README.md 的「联调地址速查」）。
            Text('真机联调：手机与电脑需在同一 WiFi，填入电脑的局域网地址（含 5000 端口）。')
              .fontSize(13).fontColor(UiTheme.secondary).lineHeight(19).width('100%')
            TextInput({ placeholder: 'http://192.168.x.x:5000', text: this.baseUrl })
              .width('100%').height(44).fontSize(14).backgroundColor(UiTheme.subtle).borderRadius(8)
              .onChange((value: string) => this.baseUrl = value)
            Button('应用此地址').width('100%').height(42).fontSize(14).fontColor(UiTheme.surface)
              .backgroundColor(UiTheme.accent).borderRadius(8).onClick(() => this.useCustomBackend())
          }.width('100%').padding(16).backgroundColor(UiTheme.surface).borderRadius(8).border({ width: 1, color: UiTheme.line })
          Column({ space: 7 }) {
            Text(`当前模式：${this.useFixture ? 'Fixture 离线演示' : '真实后端'}`).fontSize(14).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink).width('100%')
            Text(`当前地址：${this.baseUrl}`).fontSize(12).fontColor(UiTheme.secondary).width('100%')
          }.width('100%').padding(14).backgroundColor(UiTheme.tint).borderRadius(8)
          if (this.message.length > 0) {
            Text(this.message).fontSize(13).fontColor(UiTheme.secondary).lineHeight(19).width('100%').padding(12).backgroundColor(UiTheme.subtle).borderRadius(8)
          }
          Button(this.isChecking ? '正在检测…' : '检测当前计划接口')
            .width('100%').height(46).fontSize(15).fontWeight(FontWeight.Bold).fontColor(UiTheme.surface)
            .backgroundColor('#0F766E').borderRadius(8).enabled(!this.isChecking).onClick(() => this.checkCurrentPlan())
        }.width('100%').padding(16)
      }.layoutWeight(1).backgroundColor(UiTheme.canvas).align(Alignment.TopStart)
    }.width('100%').height('100%')
  }
}
