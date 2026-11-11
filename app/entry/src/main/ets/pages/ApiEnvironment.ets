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
  @State activeBaseUrl: string = '';
  @State useFixture: boolean = false;
  @State isChecking: boolean = false;
  @State message: string = '';
  @State saveWarning: string = '';
  private checkRequestVersion: number = 0;
  private isPageActive: boolean = false;
  private retryTimer: number = -1;
  private retryCount: number = 0;

  aboutToAppear(): void {
    if (!ApiDefaults.ALLOW_DEBUG) {
      router.back();
      return;
    }
    this.isPageActive = true;
    this.syncConfig();
    this.checkBackendConnection();
  }

  aboutToDisappear(): void {
    this.onPageHide();
  }

  onPageShow(): void {
    if (!ApiDefaults.ALLOW_DEBUG) return;
    this.isPageActive = true;
    this.checkBackendConnection();
  }

  onPageHide(): void {
    this.isPageActive = false;
    this.checkRequestVersion++;
    this.isChecking = false;
    this.cancelRetry();
  }

  private syncConfig(): void {
    const config: ApiClientConfig = AgentApiClient.getConfig();
    this.baseUrl = config.baseUrl;
    this.activeBaseUrl = config.baseUrl;
    this.useFixture = config.useFixture;
  }

  private applyConfig(baseUrl: string, useFixture: boolean, message: string): void {
    if (!ApiDefaults.ALLOW_DEBUG) return;
    this.checkRequestVersion++;
    this.isChecking = false;
    this.cancelRetry();
    this.retryCount = 0;
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
      this.saveWarning = '';
      this.message = message;
    } else {
      this.saveWarning = '当前设置已生效，但保存失败。重启应用可能恢复旧地址，请重新应用此地址。';
      this.message = message;
    }
    if (!useFixture) this.checkBackendConnection();
  }

  private useOfflineDemo(): void {
    this.applyConfig(this.activeBaseUrl, true, '已切换到 Fixture；核心流程可离线演示。');
  }

  private useEmulatorBackend(): void {
    this.applyConfig(ApiDefaults.DEFAULT_BASE_URL, false,
      '已切换到构建默认后端。');
  }

  private useCustomBackend(): void {
    const value: string = AgentApiClient.parseBackendOrigin(this.baseUrl);
    if (ApiDefaults.ALLOW_USB_HUAWEI_LOGIN && value === ApiDefaults.USB_MISTYPED_HTTPS_URL) {
      this.message = 'USB 转发的 5000 端口使用 HTTP。请点击「使用 USB 联调地址」。';
      return;
    }
    if (value.length === 0) {
      this.message = '请输入后端根地址（HTTPS 域名，或带端口的 HTTP 联调地址），无需填写 /ready 等路径。';
      return;
    }
    this.applyConfig(value, false, '已应用真机/自定义地址，并清除了旧接口缓存。');
  }

  private cancelRetry(): void {
    if (this.retryTimer !== -1) clearTimeout(this.retryTimer);
    this.retryTimer = -1;
  }

  private retryConnection(): void {
    this.retryCount = 0;
    this.checkBackendConnection();
  }

  private async checkBackendConnection(): Promise<void> {
    if (this.isChecking) {
      return;
    }
    this.cancelRetry();
    if (AgentApiClient.getConfig().useFixture) {
      this.message = '当前为离线演示，请切换到真实后端后检测。';
      return;
    }
    this.isChecking = true;
    this.message = this.retryCount > 0 ? `正在重新检测后端连接（${this.retryCount}/6）…` : '正在检测后端连接…';
    const requestVersion: number = ++this.checkRequestVersion;
    const checkedUrl: string = AgentApiClient.getConfig().baseUrl;
    const result = await AgentApiClient.checkBackendConnection();
    if (!this.isPageActive || requestVersion !== this.checkRequestVersion || checkedUrl !== AgentApiClient.getConfig().baseUrl) {
      return;
    }
    this.isChecking = false;
    if (result.ok) {
      this.retryCount = 0;
      this.message = '连接成功：真实后端与数据服务均已就绪。';
      return;
    }
    const failure: ApiFailure = result as ApiFailure;
    const localUsb: boolean = /^http:\/\/(127\.0\.0\.1|localhost):\d+$/.test(checkedUrl);
    if (failure.error.statusCode === 503) {
      this.message = '已连接后端，但数据服务暂未就绪。';
    } else if (failure.error.statusCode > 0) {
      this.message = `已连上服务（HTTP ${failure.error.statusCode}），但健康检查未通过：${failure.error.message}`;
    } else if (failure.error.code !== 'NETWORK_ERROR') {
      this.message = failure.error.message;
    } else {
      this.message = localUsb ? 'USB 后端连接暂不可达，请保持数据线连接，并确认电脑的真机联调服务正在运行。'
        : (checkedUrl.startsWith('https://') ? 'HTTPS 后端暂不可达，请检查网络、地址及设备是否信任证书。'
          : '后端暂不可达，请检查网络及电脑上的后端服务。');
    }
    if ((failure.error.code === 'NETWORK_ERROR' || failure.error.statusCode === 503) && this.retryCount < 6) {
      this.retryCount++;
      this.message += ' 3 秒后自动重试。';
      this.retryTimer = setTimeout(() => {
        this.retryTimer = -1;
        if (this.isPageActive && requestVersion === this.checkRequestVersion && checkedUrl === AgentApiClient.getConfig().baseUrl) {
          this.checkBackendConnection();
        }
      }, 3000);
    }
  }

  build() {
    Column() {
      PageHeader({ title: '接口环境（开发）', assistant: false, onBack: () => { router.back(); } })
      Scroll() {
        Column({ space: 16 }) {
          Text('数据源与联调地址').fontSize(23).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink).width('100%')
          Text('切换后会清除短期接口缓存，不会修改后端、项目代码或课程数据。')
            .fontSize(13).fontColor(UiTheme.secondary).lineHeight(20).width('100%')
          Button(this.useFixture ? '当前：离线 Fixture' : '使用离线 Fixture')
            .width('100%').height(48).fontSize(15)
            .fontColor(this.useFixture ? UiTheme.surface : UiTheme.accent)
            .backgroundColor(this.useFixture ? UiTheme.accent : UiTheme.surface)
            .border({ width: 1, color: this.useFixture ? UiTheme.accent : '#BFDBFE' })
            .borderRadius(8)
            .onClick(() => this.useOfflineDemo())
          Text('固定演示不依赖后端，可稳定展示 42 → 58 → Plan V2。').fontSize(12).fontColor(UiTheme.secondary).width('100%')
          Button(!this.useFixture && this.activeBaseUrl === ApiDefaults.DEFAULT_BASE_URL ? '当前：构建默认后端' : '使用构建默认后端')
            .width('100%').height(48).fontSize(15)
            .fontColor(!this.useFixture && this.activeBaseUrl === ApiDefaults.DEFAULT_BASE_URL ? UiTheme.surface : UiTheme.accent)
            .backgroundColor(!this.useFixture && this.activeBaseUrl === ApiDefaults.DEFAULT_BASE_URL ? UiTheme.accent : UiTheme.surface)
            .border({ width: 1, color: '#BFDBFE' })
            .borderRadius(8).onClick(() => this.useEmulatorBackend())
          Column({ space: 10 }) {
            Text('真机 / 自定义后端').fontSize(16).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink).width('100%')
            Text('USB 联调填 http://127.0.0.1:5000，并在电脑启动 USB 自动恢复服务；无线联调需连接同一 WiFi，填写电脑局域网地址。')
              .fontSize(13).fontColor(UiTheme.secondary).lineHeight(19).width('100%')
            Text(ApiDefaults.ALLOW_USB_HUAWEI_LOGIN ?
              '开发版华为登录支持 USB 联调。使用其他后端时，填写设备信任的 HTTPS 根地址。' :
              '华为账号登录请填写设备信任的 HTTPS 后端根地址。')
              .fontSize(14).fontColor(UiTheme.ink).lineHeight(21).width('100%')
            if (ApiDefaults.ALLOW_USB_HUAWEI_LOGIN) {
              Button('使用 USB 联调地址').width('100%').constraintSize({ minHeight: UiTheme.touch }).fontSize(14)
                .fontColor(UiTheme.accent).backgroundColor(UiTheme.tint).borderRadius(8)
                .onClick(() => this.applyConfig(ApiDefaults.LOCALHOST_BASE_URL, false, '已选择 USB 联调地址。'))
            }
            TextInput({ placeholder: 'http://192.168.x.x:5000', text: this.baseUrl })
              .width('100%').height(44).fontSize(14).backgroundColor(UiTheme.subtle).borderRadius(8)
              .onChange((value: string) => this.baseUrl = value)
            Button('应用此地址').width('100%').height(42).fontSize(14).fontColor(UiTheme.surface)
              .backgroundColor(UiTheme.accent).borderRadius(8).onClick(() => this.useCustomBackend())
          }.width('100%').padding(16).backgroundColor(UiTheme.surface).borderRadius(8).border({ width: 1, color: UiTheme.line })
          Column({ space: 7 }) {
            Text(`当前模式：${this.useFixture ? 'Fixture 离线演示' : '真实后端'}`).fontSize(14).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink).width('100%')
            Text(`当前地址：${this.activeBaseUrl}`).fontSize(12).fontColor(UiTheme.secondary).width('100%')
          }.width('100%').padding(14).backgroundColor(UiTheme.tint).borderRadius(8)
          if (this.saveWarning.length > 0) {
            Text(this.saveWarning).fontSize(14).fontColor('#B91C1C').lineHeight(21).width('100%')
          }
          if (this.message.length > 0) {
            Text(this.message).fontSize(13).fontColor(UiTheme.secondary).lineHeight(19).width('100%').padding(12).backgroundColor(UiTheme.subtle).borderRadius(8)
          }
          Button(this.isChecking ? '正在检测…' : '检测后端连接')
            .width('100%').height(46).fontSize(15).fontWeight(FontWeight.Bold).fontColor(UiTheme.surface)
            .backgroundColor('#0F766E').borderRadius(8).enabled(!this.isChecking).onClick(() => this.retryConnection())
        }.width('100%').constraintSize({ maxWidth: UiTheme.formWidth }).padding(16)
      }.layoutWeight(1).backgroundColor(UiTheme.canvas).align(Alignment.Top)
    }.width('100%').height('100%')
  }
}
