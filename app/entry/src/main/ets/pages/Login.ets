import { UiTheme } from '../utils/UiTheme';
import router from '@ohos.router';
import { common } from '@kit.AbilityKit';
import { AgentApiClient } from '../api/AgentApiClient';
import { ApiDefaults } from '../api/ApiDefaults';
import { ApiEnvironmentStore } from '../api/ApiEnvironmentStore';
import { AuthStore } from '../api/AuthStore';
import { AuthClient } from '../api/AuthClient';
import { AuthResult } from '../api/AuthResult';
import { AuthUser, GRADE_OPTIONS } from '../api/AuthModels';
import { appState } from '../data/AppState';

@Entry
@Component
struct Login {
  @StorageProp('layoutHeightVp') windowHeight: number = 720;
  @State mode: string = 'login';
  @State method: string = 'password';
  @State nickname: string = '';
  @State phone: string = '';
  @State password: string = '';
  @State verifyCode: string = '';
  @State resendCountdown: number = 0;
  @State codeSent: boolean = false;
  @State smsDelivered: boolean = false;
  @State devCode: string = '';
  @State grade: string = '';
  @State rememberMe: boolean = true;
  @State rememberAccount: boolean = true;
  @State busy: boolean = false;
  @State message: string = '';
  @State messageIsError: boolean = false;
  @State isHuaweiLoggingIn: boolean = false;
  @State huaweiMessage: string = '';
  @State huaweiSetupHint: string = '';

  private isActive: boolean = false;

  private resendTimer: number = -1;

  aboutToAppear(): void {
    this.isActive = true;
    this.refreshHuaweiSetupHint();
    this.rememberMe = AuthStore.getKeepSignedIn();
    this.rememberAccount = AuthStore.getRememberAccount();
    const account: string = AuthStore.getRecentAccount();
    if (/^1\d{10}$/.test(account)) this.phone = account;
    else this.nickname = account;
    const params: Record<string, Object> = router.getParams() as Record<string, Object>;
    if (params === undefined || params === null) {
      return;
    }
    const notice: Object | undefined = params['notice'];
    if (typeof notice === 'string' && notice.length > 0) {
      this.message = notice;
      this.messageIsError = false;
    }
  }

  aboutToDisappear(): void {
    this.isActive = false;
    this.stopResendTimer();
  }

  onPageShow(): void {
    this.refreshHuaweiSetupHint();
  }

  private refreshHuaweiSetupHint(): void {
    const config = AgentApiClient.getConfig();
    const hint: string = config.useFixture ? '当前为离线演示，请先切换到在线后端。' :
      (!ApiDefaults.supportsHuaweiLogin(config.baseUrl) ? (ApiDefaults.ALLOW_USB_HUAWEI_LOGIN ?
        '开发版可通过 USB 联调后端登录，也可使用设备信任的 HTTPS 后端。' :
        '华为账号登录需要设备信任的 HTTPS 后端。') : '');
    if (hint !== this.huaweiSetupHint) this.huaweiMessage = '';
    this.huaweiSetupHint = hint;
  }

  private validatePhone(): string {
    const digits: string = this.phone.replace(/[^\d]/g, '');
    const normalized: string = (digits.length === 13 && digits.startsWith('86'))
      ? digits.substring(2) : digits;
    if (normalized.length === 0) {
      return '请输入手机号';
    }
    if (!/^1[3-9]\d{9}$/.test(normalized)) {
      return '手机号格式不正确（应为 11 位中国大陆号码）';
    }
    return '';
  }

  private normalizedPhone(): string {
    const digits: string = this.phone.replace(/[^\d]/g, '');
    return (digits.length === 13 && digits.startsWith('86')) ? digits.substring(2) : digits;
  }

  private goHome(): void {
    router.replaceUrl({ url: 'pages/ChatMain' });
  }

  private useOnlineSource(): void {
    AgentApiClient.setUseFixture(false);
    try {
      const context: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext;
      ApiEnvironmentStore.save(context, AgentApiClient.getConfig());
    } catch (error) {
    }
  }

  private enterAsGuest(): void {
    if (!ApiDefaults.ALLOW_DEMO) return;
    this.useOnlineSource();
    const result: AuthResult = AuthClient.continueAsGuest();
    appState.applyLogin(result.user, 'guest');
    this.goHome();
  }

  private enterOffline(): void {
    if (!ApiDefaults.ALLOW_DEMO) return;
    AgentApiClient.setUseFixture(true);
    try {
      const context: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext;
      ApiEnvironmentStore.save(context, AgentApiClient.getConfig());
    } catch (error) {
    }
    const result: AuthResult = AuthClient.continueOffline(true);
    appState.applyLogin(result.user, 'fixture');
    this.goHome();
  }

  private async onSubmit(): Promise<void> {
    AuthStore.setLoginPreferences(this.normalizedPhone(), this.rememberAccount, this.rememberMe);
    if (this.busy) {
      return;
    }

    if (this.method === 'code' && this.mode === 'login') {
      await this.onVerifyCodeLogin();
      return;
    }

    if (this.mode === 'register' && this.nickname.trim().length > 0 && AuthClient.validateNickname(this.nickname).length > 0) {
      this.message = AuthClient.validateNickname(this.nickname); this.messageIsError = true; return;
    }
    if (this.password.length < 6) {
      this.message = '密码至少需要 6 位。';
      this.messageIsError = true;
      return;
    }

    const phoneError: string = this.validatePhone();
    if (phoneError.length > 0) {
      this.message = phoneError;
      this.messageIsError = true;
      return;
    }
    if (this.mode === 'login' && this.phone.trim().length > 0 && phoneError.length > 0) {
      this.message = phoneError;
      this.messageIsError = true;
      return;
    }

    this.busy = true;
    this.message = '';
    const phone: string = this.normalizedPhone();

    let result: AuthResult;
    if (this.mode === 'register') {
      result = await AuthClient.register(this.nickname, phone, this.grade, this.password);
    } else {
      result = await AuthClient.loginByPhone(phone, this.password);

    }
    if (!this.isActive) {
      return;
    }
    this.busy = false;

    if (!result.ok) {
      if (this.mode === 'login'
        && (result.message.indexOf('还没有账号') >= 0 || result.message.indexOf('请先注册') >= 0)) {
        this.message = '还没有账号。已为你切到「注册」，补上手机号再点一次即可建立。';
        this.messageIsError = true;
        this.mode = 'register';
        return;
      }
      this.message = result.message;
      this.messageIsError = true;
      return;
    }
    this.useOnlineSource();
    appState.applyLogin(result.user, result.source,
      result.createdAccount === true ? result.message : '');
    if (result.needsPasswordSetup === true) { router.replaceUrl({ url: 'pages/PasswordSetup' }); return; }
    this.goHome();
  }

  private async onHuaweiLogin(): Promise<void> {
    if (this.busy) {
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!context) {
      this.huaweiMessage = '暂时无法打开华为授权，请重新进入登录页后重试。';
      return;
    }
    AuthStore.setLoginPreferences(AuthStore.getRecentAccount(), this.rememberAccount, this.rememberMe);
    this.busy = true;
    this.isHuaweiLoggingIn = true;
    this.message = '';
    this.huaweiMessage = '';
    let result: AuthResult;
    try {
      result = await AuthClient.loginWithHuaweiAccount(context, () => this.isActive);
    } catch (error) {
      result = { ok: false, user: null, source: 'local', message: '暂时无法完成华为账号登录，请重试。' };
    }
    if (!this.isActive) {
      return;
    }
    this.busy = false;
    this.isHuaweiLoggingIn = false;
    if (!result.ok) {
      this.huaweiMessage = result.message;
      return;
    }
    appState.applyLogin(result.user, result.source,
      result.createdAccount === true ? result.message : '');
    this.goHome();
  }

  private async onSendCode(): Promise<void> {
    if (this.busy || this.resendCountdown > 0) {
      return;
    }
    const phoneError: string = this.validatePhone();
    if (phoneError.length > 0) {
      this.message = phoneError;
      this.messageIsError = true;
      return;
    }

    this.busy = true;
    this.message = '';
    const result: AuthResult = await AuthClient.sendVerificationCode(this.normalizedPhone());
    if (!this.isActive) {
      return;
    }
    this.busy = false;

    if (!result.ok) {
      this.message = result.message;
      this.messageIsError = true;
      return;
    }

    this.codeSent = true;
    this.smsDelivered = result.smsDelivered === true;
    this.devCode = result.devCode !== undefined ? result.devCode : '';
    this.message = result.message;
    this.messageIsError = false;
    this.startResendTimer(result.resendAfterSeconds !== undefined ? result.resendAfterSeconds : 60);
  }

  private async onVerifyCodeLogin(): Promise<void> {
    AuthStore.setLoginPreferences(this.phone.trim(), this.rememberAccount, this.rememberMe);
    const phoneError: string = this.validatePhone();
    if (phoneError.length > 0) {
      this.message = phoneError;
      this.messageIsError = true;
      return;
    }
    if (!/^\d{6}$/.test(this.verifyCode.trim())) {
      this.message = '请输入 6 位数字验证码。';
      this.messageIsError = true;
      return;
    }

    this.busy = true;
    this.message = '';
    const result: AuthResult = await AuthClient.verifyCode(
      this.normalizedPhone(), this.verifyCode.trim(),
      this.nickname.length > 0 ? this.nickname : undefined,
      this.grade.length > 0 ? this.grade : undefined);
    if (!this.isActive) {
      return;
    }
    this.busy = false;

    if (!result.ok) {
      this.message = result.message;
      this.messageIsError = true;
      return;
    }
    this.useOnlineSource();
    appState.applyLogin(result.user, result.source,
      result.createdAccount === true ? result.message : '');
    if (result.needsPasswordSetup === true) { router.replaceUrl({ url: 'pages/PasswordSetup' }); return; }
    this.goHome();
  }

  private startResendTimer(seconds: number): void {
    this.stopResendTimer();
    this.resendCountdown = seconds > 0 ? seconds : 60;
    this.resendTimer = setInterval(() => {
      if (!this.isActive) {
        this.stopResendTimer();
        return;
      }
      this.resendCountdown = this.resendCountdown - 1;
      if (this.resendCountdown <= 0) {
        this.resendCountdown = 0;
        this.stopResendTimer();
      }
    }, 1000);
  }

  private stopResendTimer(): void {
    if (this.resendTimer !== -1) {
      clearInterval(this.resendTimer);
      this.resendTimer = -1;
    }
  }

  private canSubmit(): boolean {
    if (this.busy) {
      return false;
    }
    if (this.mode === 'register' && this.nickname.trim().length > 0 && AuthClient.validateNickname(this.nickname).length > 0) {
      return false;
    }
    if (this.validatePhone().length > 0 || this.password.length < 6 || this.password.length > 72) {
      return false;
    }
    return true;
  }

  build() {
    Column() {
      Scroll() {
        Column({ space: 0 }) {
          Column({ space: 6 }) {
            Text('知学 Mate').fontSize(26).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%').textAlign(TextAlign.Center)
            Text('你的智能学习伙伴')
              .fontSize(14).fontColor(UiTheme.secondary).width('100%').textAlign(TextAlign.Center)
              .margin({ top: 2 })
          }
          .width('100%').alignItems(HorizontalAlign.Start)
          .padding({ top: this.windowHeight < 480 ? 16 : 36, bottom: 26 })

          this.ModeSegment()

          Column({ space: 16 }) {
            if (this.mode === 'register') {
            Column({ space: 8 }) {
              Text('昵称（注册选填）').fontSize(14).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%')
              Row({ space: 10 }) {

                TextInput({ placeholder: '选填，留空自动生成昵称', text: this.nickname })
                  .layoutWeight(1).height(48).fontSize(15)
                  .backgroundColor(Color.Transparent).padding(0)
                  .maxLength(16).enabled(!this.busy)
                  .onChange((value: string) => {
                    this.nickname = value;
                    if (this.messageIsError) {
                      this.message = '';
                      this.messageIsError = false;
                    }
                  })
              }
              .width('100%').padding({ left: 14, right: 14 })
              .backgroundColor(UiTheme.subtle).borderRadius(8)
              .border({ width: 1, color: UiTheme.line })
            }.width('100%')

            }
            Column({ space: 8 }) {
              Row({ space: 6 }) {
                Text('手机号').fontSize(14).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink)
                Text('必填')
                  .fontSize(11)
                  .fontColor(this.mode === 'register' ? '#B91C1C' : UiTheme.muted)
                  .backgroundColor(this.mode === 'register' ? '#FEF2F2' : UiTheme.subtle)
                  .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                  .borderRadius(6)
                Blank()
              }.width('100%')
              Row({ space: 10 }) {

                TextInput({ placeholder: '11 位手机号', text: this.phone })
                  .type(InputType.PhoneNumber)
                  .layoutWeight(1).height(48).fontSize(15)
                  .backgroundColor(Color.Transparent).padding(0)
                  .maxLength(20).enabled(!this.busy)
                  .onChange((value: string) => {
                    this.phone = value;
                    if (this.messageIsError) {
                      this.message = '';
                      this.messageIsError = false;
                    }
                  })
              }
              .width('100%').padding({ left: 14, right: 14 })
              .backgroundColor(UiTheme.subtle).borderRadius(8)
              .border({ width: 1, color: UiTheme.line })
              Text(this.mode === 'register'
                ? '手机号是账号的唯一标识，用于登录与找回。'
                : (this.method === 'code'
                  ? '手机号验证：已有账号进入原账号，首次验证后请设置密码。'
                  : '请填写手机号和密码，一个手机号对应一个账号。'))
                .fontSize(11).fontColor(UiTheme.muted).lineHeight(17).width('100%')
            }.width('100%')

            if (this.mode === 'login' && this.method === 'code') {
              Column({ space: 8 }) {
                Text('短信验证码').fontSize(14).fontWeight(FontWeight.Medium)
                  .fontColor(UiTheme.ink).width('100%')
                Row({ space: 10 }) {

                  TextInput({ placeholder: '6 位数字验证码', text: this.verifyCode })
                    .type(InputType.Number)
                    .maxLength(6)
                    .layoutWeight(1).height(48).fontSize(15)
                    .backgroundColor(Color.Transparent).padding(0)
                    .enabled(!this.busy)
                    .onChange((value: string) => { this.verifyCode = value; })
                  Button(this.resendCountdown > 0
                    ? `${this.resendCountdown} 秒后可重发`
                    : (this.codeSent ? '重新获取' : '获取验证码'))
                    .fontSize(13).height(36).borderRadius(8)
                    .backgroundColor(this.resendCountdown > 0 ? UiTheme.line : '#DBEAFE')
                    .fontColor(this.resendCountdown > 0 ? UiTheme.muted : UiTheme.accent)
                    .enabled(!this.busy && this.resendCountdown === 0)
                    .onClick(() => { this.onSendCode(); })
                }
                .width('100%').padding({ left: 14, right: 14 })
                .backgroundColor(UiTheme.subtle).borderRadius(8)
                .border({ width: 1, color: UiTheme.line })

                if (!this.smsDelivered && this.devCode.length > 0) {
                  Column({ space: 4 }) {
                    Text('开发模式回显（短信未真实下发）')
                      .fontSize(12).fontWeight(FontWeight.Medium).fontColor('#B45309').width('100%')
                    Text(`验证码：${this.devCode}`)
                      .fontSize(15).fontWeight(FontWeight.Bold).fontColor('#B45309').width('100%')
                    Text('后端未配置短信服务商，此码仅用于联调与演示。')
                      .fontSize(11).fontColor('#B45309').lineHeight(16).width('100%')
                  }
                  .width('100%').padding(12).backgroundColor('#FFFBEB')
                  .borderRadius(8).border({ width: 1, color: '#FDE68A' })
                } else if (this.codeSent) {
                  Text('验证码已发送。收不到可改用「密码登录」或「一键体验」。')
                    .fontSize(11).fontColor(UiTheme.secondary).lineHeight(17).width('100%')
                }
              }.width('100%')
            }

            if (!(this.mode === 'login' && this.method === 'code')) {
              Column({ space: 8 }) {
                Text('密码').fontSize(14).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%')
                Row() {
                  TextInput({ placeholder: '请输入密码', text: this.password })
                    .type(InputType.Password).showPasswordIcon(true)
                    .layoutWeight(1).height(48).fontSize(15)
                    .backgroundColor(Color.Transparent).padding(0)
                    .enabled(!this.busy)
                    .onChange((value: string) => { this.password = value; })
                }
                .width('100%').padding({ left: 14, right: 14 })
                .backgroundColor(UiTheme.subtle).borderRadius(8)
                .border({ width: 1, color: UiTheme.line })

                Text(this.mode === 'register'
                  ? '至少 6 位；服务端仅保存加盐哈希，不保存明文。'
                  : '密码会提交到后端校验；服务端只保存加盐哈希。')
                  .fontSize(11).fontColor(UiTheme.muted).lineHeight(17).width('100%')
            }.width('100%')
            }

            if (this.mode === 'login') {
              Row() {
                Blank()
                Text('忘记密码？').fontSize(13).fontColor(UiTheme.accent)
                  .onClick(() => {
                    this.message = '暂未接入短信找回。请联系管理员核验账号后重置。请勿重复注册，以免生成新账号。';
                    this.messageIsError = false;
                  })
              }.width('100%')
            }

            if (this.mode === 'register') {
              Column({ space: 8 }) {
                Text('在读年级（可跳过）').fontSize(14).fontWeight(FontWeight.Medium)
                  .fontColor(UiTheme.ink).width('100%')
                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(GRADE_OPTIONS, (item: string) => {
                    Text(item)
                      .fontSize(13)
                      .fontColor(this.grade === item ? UiTheme.surface : UiTheme.accent)
                      .backgroundColor(this.grade === item ? UiTheme.accent : UiTheme.tint)
                      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                      .borderRadius(8).margin({ right: 8, bottom: 8 })
                      .onClick(() => { this.grade = this.grade === item ? '' : item; })
                  })
                }.width('100%')
              }.width('100%')
            }

            if (this.mode === 'register') {
              Text('新账号将从零开始：不预置课程、知识点或学习计划，内容由你导入的资料、练习和智能体操作逐步建立。')
                .fontSize(11).fontColor(UiTheme.accent).lineHeight(17).width('100%')
              .width('100%').padding(12)
              .backgroundColor(UiTheme.subtle)
              .borderRadius(8)
              .border({ width: 1, color: UiTheme.line })
            }

            Row({ space: 8 }) {
              Checkbox().select(this.rememberMe).hitTestBehavior(HitTestMode.None)
                .width(20).height(20).selectedColor(UiTheme.accent)
              Text('保持登录（下次自动进入）').fontSize(13).fontColor(UiTheme.secondary)
            }
            .width('100%')
            .onClick(() => { this.rememberMe = !this.rememberMe; })

            Row({ space: 8 }) {
              Checkbox().select(this.rememberAccount).hitTestBehavior(HitTestMode.None)
              Text('记住账号').fontSize(13).fontColor(UiTheme.secondary)
            }.width('100%').onClick(() => { this.rememberAccount = !this.rememberAccount; })

            Button(this.busy ? '处理中…'
              : (this.mode === 'login' ? '登录  →' : '注册并进入  →'))
              .width('100%').height(50).fontSize(16).fontWeight(FontWeight.Bold)
              .fontColor(UiTheme.surface)
              .backgroundColor(this.busy ? '#93C5FD' : UiTheme.accent)
              .borderRadius(8)
              .enabled(!this.busy)
              .onClick(() => { this.onSubmit(); })
          }
          .width('100%').padding({ top: 22 })

          if (this.message.length > 0) {
            Text(this.message)
              .fontSize(13).lineHeight(20).width('100%').padding(12).borderRadius(8)
              .fontColor(this.messageIsError ? '#EF4444' : UiTheme.secondary)
              .backgroundColor(this.messageIsError ? '#FEF2F2' : UiTheme.subtle)
              .margin({ top: 14 })
          }

          Row({ space: 12 }) {
            Divider().color(UiTheme.line).layoutWeight(1)
            Text('或').fontSize(12).fontColor(UiTheme.muted)
            Divider().color(UiTheme.line).layoutWeight(1)
          }.width('100%').margin({ top: 28, bottom: 18 })

          Button(this.isHuaweiLoggingIn ? '正在进行华为账号登录…' : '使用华为账号登录', { type: ButtonType.Normal })
            .width('100%').constraintSize({ minHeight: 48 }).fontSize(15).fontWeight(FontWeight.Medium)
            .fontColor(UiTheme.ink).backgroundColor(UiTheme.surface)
            .borderRadius(8).border({ width: 1, color: UiTheme.line })
            .enabled(!this.busy)
            .onClick(() => { this.onHuaweiLogin(); })

          if (this.huaweiMessage.length > 0 || this.huaweiSetupHint.length > 0) {
            Column({ space: 6 }) {
              Text(this.huaweiMessage.length > 0 ? this.huaweiMessage : this.huaweiSetupHint)
                .fontSize(14).lineHeight(21).width('100%')
                .fontColor(this.huaweiMessage.length > 0 ? '#B91C1C' : UiTheme.secondary)
              if (ApiDefaults.ALLOW_DEBUG) {
                Button('查看连接设置', { type: ButtonType.Normal })
                  .width('100%').constraintSize({ minHeight: UiTheme.touch }).fontSize(14)
                  .fontColor(UiTheme.accent).backgroundColor(UiTheme.surface).borderRadius(8)
                  .enabled(!this.busy).onClick(() => {
                    this.huaweiMessage = '';
                    router.pushUrl({ url: 'pages/ApiEnvironment' });
                  })
              }
            }.width('100%').padding(12).backgroundColor(UiTheme.subtle).borderRadius(8).margin({ top: 8 })
          }

          if (ApiDefaults.ALLOW_DEMO) {
            Column({ space: 8 }) {
              Text('免登录体验').fontSize(13).fontWeight(FontWeight.Medium)
                .fontColor(UiTheme.secondary).width('100%')
              Button('跳过登录，在线体验', { type: ButtonType.Normal })
                .width('100%').constraintSize({ minHeight: UiTheme.touch }).fontSize(14)
                .fontColor(UiTheme.accent).backgroundColor(UiTheme.tint).borderRadius(8)
                .enabled(!this.busy).onClick(() => this.enterAsGuest())
              Button('离线演示（无需网络）', { type: ButtonType.Normal })
                .width('100%').constraintSize({ minHeight: UiTheme.touch }).fontSize(14)
                .fontColor(UiTheme.secondary).backgroundColor(UiTheme.surface)
                .border({ width: 1, color: UiTheme.line }).borderRadius(8)
                .enabled(!this.busy).onClick(() => this.enterOffline())
            }.width('100%').margin({ top: 24 }).padding({ top: 16 })
              .border({ width: { top: 1 }, color: UiTheme.line })
          }

          Blank().height(28)

          Text('手机号仅用于登录与账号识别；密码由服务端加盐哈希保存，不存明文。')
            .fontSize(11).fontColor('#B0B7C3').lineHeight(17).width('100%')

          Blank().height(24)
        }
        .width('100%')
        .constraintSize({ maxWidth: UiTheme.formWidth })
        .padding({ left: 24, right: 24 })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%').height('100%').backgroundColor(UiTheme.surface)

  }

  @Builder
  ModeSegment() {
    Row({ space: 0 }) {
      ForEach(MODE_OPTIONS, (item: SegOption) => {
        Row({ space: 6 }) {
          Text(item.icon).fontSize(13)
          Text(item.label).fontSize(14)
            .fontWeight(this.mode === item.key ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(this.mode === item.key ? UiTheme.accent : UiTheme.secondary)
        }
        .layoutWeight(1).height(44)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.mode === item.key ? UiTheme.surface : UiTheme.subtle)
        .borderRadius(8)
        .onClick(() => {
          if (this.busy || this.isHuaweiLoggingIn || this.mode === item.key) return;
          if (item.key === 'register') {
            this.phone = '';
            this.nickname = '';
            this.password = '';
            this.grade = '';
            this.verifyCode = '';
            this.devCode = '';
            this.smsDelivered = false;
            this.stopResendTimer();
          }
          this.mode = item.key;
          this.message = '';
          this.messageIsError = false;
        })
      }, (item: SegOption) => item.key)
    }
    .width('100%').padding(4).backgroundColor(UiTheme.subtle).borderRadius(8)
    .margin({ bottom: 12 })
  }

  @Builder
  MethodSegment() {
    Row({ space: 0 }) {
      ForEach(METHOD_OPTIONS, (item: SegOption) => {
        Row({ space: 6 }) {
          Text(item.icon).fontSize(13)
          Text(item.label).fontSize(14)
            .fontWeight(this.method === item.key ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(this.method === item.key ? UiTheme.accent : UiTheme.secondary)
        }
        .layoutWeight(1).height(44)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.method === item.key ? UiTheme.surface : UiTheme.subtle)
        .borderRadius(8)
        .onClick(() => {
          this.method = item.key;
          this.message = '';
          this.messageIsError = false;
        })
      }, (item: SegOption) => item.key)
    }
    .width('100%').padding(4).backgroundColor(UiTheme.subtle).borderRadius(8)
    .margin({ bottom: 12 })
  }

  @Builder
  Segmented(options: SegOption[], activeKey: string, onPick: (key: string) => void) {
    Row({ space: 0 }) {
      ForEach(options, (item: SegOption) => {
        Row({ space: 6 }) {
          Text(item.icon).fontSize(13)
          Text(item.label).fontSize(14)
            .fontWeight(activeKey === item.key ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(activeKey === item.key ? UiTheme.accent : UiTheme.secondary)
        }
        .layoutWeight(1).height(44)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(activeKey === item.key ? UiTheme.surface : UiTheme.subtle)
        .borderRadius(8)
        .onClick(() => onPick(item.key))
      }, (item: SegOption) => item.key)
    }
    .width('100%').padding(4).backgroundColor(UiTheme.subtle).borderRadius(8)
    .margin({ bottom: 12 })
  }
}

const MODE_OPTIONS: SegOption[] = [
  { key: 'login', label: '登录', icon: '' },
  { key: 'register', label: '注册', icon: '' }
];

const METHOD_OPTIONS: SegOption[] = [
  { key: 'password', label: '密码登录', icon: '' },
  { key: 'code', label: '验证码登录', icon: '' }
];

interface SegOption {
  key: string;
  label: string;
  icon: string;
}
