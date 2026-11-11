import { UiTheme } from '../utils/UiTheme';
import { PageHeader } from '../components/PageHeader';
import router from '@ohos.router';
import { UserAvatar } from '../components/UserAvatar';
import { bundleManager, common } from '@kit.AbilityKit';
import { AgentApiClient } from '../api/AgentApiClient';
import { ApiDefaults } from '../api/ApiDefaults';
import { PartnerContact } from '../api/ApiModels';
import { AuthClient } from '../api/AuthClient';
import { AuthUser, ChangePasswordResult } from '../api/AuthModels';
import { AuthResult } from '../api/AuthResult';
import { AuthStore } from '../api/AuthStore';
import { ClientCache } from '../cache/ClientCache';
import { WorkflowSessionStore } from '../cache/WorkflowSessionStore';
import { appState } from '../data/AppState';
import { ProactiveSettingsStore } from '../services/ProactiveSettingsStore';
import { ProactiveSurfaceService } from '../services/ProactiveSurfaceService';

const ABOUT_TAP_REQUIRED: number = 5;

const ABOUT_TAP_WINDOW_MS: number = 1500;

@Entry
@Component
struct Account {
  @State privacyExpanded: boolean = false;
  @State passwordExpanded: boolean = true;
  @State signedIn: boolean = false;
  @State nickname: string = '';
  @State avatar: string = '';
  @State userId: string = '';
  @State grade: string = '';
  @State sourceLabel: string = '';
  @State phoneMasked: string = '';
  @State createdAt: string = '';
  @State message: string = '';
  @State messageIsError: boolean = false;
  @State busy: boolean = false;
  @State showSignOutConfirm: boolean = false;
  @State showDeleteConfirm: boolean = false;
  @State proactiveEnabled: boolean = ProactiveSettingsStore.isEnabled();
  @State partnerContactNames: string[] = [];
  @State partnerContactsLoading: boolean = false;
  @State partnerContactsLoaded: boolean = false;
  @State partnerContactsError: string = '';
  @State pwdOld: string = '';
  @State pwdNew: string = '';
  @State pwdConfirm: string = '';
  @State pwdMsg: string = '';
  @State pwdOk: boolean = false;
  @State pwdBusy: boolean = false;
  @State aboutTapCount: number = 0;
  @State aboutLastTapMs: number = 0;

  @State private versionName: string = '—';

  aboutToAppear(): void {
    try {
      this.versionName = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT).versionName;
    } catch (_) {
      this.versionName = '—';
    }
    this.privacyExpanded = (router.getParams() as Record<string, string>)?.['section'] === 'privacy';
    this.refresh();
    this.loadAccountDetail();
  }

  onPageShow(): void {
    this.refresh();
    this.loadPartnerContacts();
  }

  private refresh(): void {
    this.signedIn = appState.isSignedIn;
    this.nickname = appState.authNickname;
    this.avatar = appState.authAvatar;
    this.userId = appState.currentUser.userId;
    this.grade = appState.currentUser.basicInfo.grade;
    this.sourceLabel = Account.sourceText(appState.authSource);
    this.proactiveEnabled = ProactiveSettingsStore.isEnabled();
  }

  private async loadAccountDetail(): Promise<void> {
    if (!this.signedIn) {
      this.phoneMasked = '';
      this.createdAt = '';
      return;
    }
    const result = await AgentApiClient.authMe();
    if (result.ok) {
      const user: AuthUser = result.data.user;
      this.phoneMasked = user.phoneMasked ?? '';
      this.createdAt = Account.friendlyDate(user.createdAt);
      if (user.nickname.length > 0) { this.nickname = user.nickname; }
      if (user.grade.length > 0) { this.grade = user.grade; }
    }
  }

  private async loadPartnerContacts(): Promise<void> {
    if (AgentApiClient.getConfig().useFixture || !this.signedIn) {
      this.partnerContactNames = [];
      this.partnerContactsError = '';
      this.partnerContactsLoaded = true;
      return;
    }
    this.partnerContactsLoading = true;
    this.partnerContactsError = '';
    const result = await AgentApiClient.listPartnerContacts();
    if (result.ok) {
      this.partnerContactNames = result.data.contacts.map((item: PartnerContact) => item.partnerName);
    } else {
      this.partnerContactsError = '暂时无法同步已建立的学习搭子，请稍后重试。';
    }
    this.partnerContactsLoaded = true;
    this.partnerContactsLoading = false;
  }

  private avatarText(): string {
    return this.nickname.length > 0 ? this.nickname.substring(0, 1) : '学';
  }

  private static friendlyDate(iso: string): string {
    if (iso.length >= 10 && iso.charAt(4) === '-' && iso.charAt(7) === '-') {
      return iso.substring(0, 10);
    }
    return iso;
  }

  private context(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private async updateProactiveSetting(enabled: boolean): Promise<void> {
    if (!enabled) {
      ProactiveSettingsStore.save(this.context(), false);
      this.proactiveEnabled = false;
      this.message = '主动提醒已关闭。';
      this.messageIsError = false;
      return;
    }
    const granted: boolean = await ProactiveSurfaceService.requestPermission(this.context());
    if (!granted) {
      ProactiveSettingsStore.save(this.context(), false);
      this.proactiveEnabled = false;
      this.message = '未获得系统通知权限，主动提醒保持关闭。可稍后在系统设置中开启。';
      this.messageIsError = true;
      return;
    }
    const saved: boolean = ProactiveSettingsStore.save(this.context(), true);
    this.proactiveEnabled = saved;
    this.message = saved ? '主动提醒已开启。Agent 仅在后端判定需要提醒时投递通知。' : '主动提醒设置保存失败。';
    this.messageIsError = !saved;
  }

  private async doChangePassword(): Promise<void> {
    if (this.pwdBusy) {
      return;
    }
    if (this.pwdNew !== this.pwdConfirm) {
      this.pwdOk = false;
      this.pwdMsg = '两次输入的新密码不一致，请重新确认。';
      return;
    }
    this.pwdBusy = true;
    this.pwdMsg = '';
    const result: ChangePasswordResult = await AuthClient.changePassword(this.pwdOld, this.pwdNew);
    this.pwdBusy = false;
    this.pwdOk = result.ok;
    this.pwdMsg = result.message;
    if (result.ok) {
      this.pwdOld = '';
      this.pwdNew = '';
      this.pwdConfirm = '';
      await AuthClient.signOut();
      appState.applyLogout();
      this.clearLocalCaches();
      AgentApiClient.setUseFixture(false);
      router.replaceUrl({ url: 'pages/Login', params: { notice: '密码已修改，请使用新密码重新登录。' } });
    }
  }

  private static sourceText(source: string): string {
    if (source === 'local') return '本机账号 · 本次登录';
    if (source === 'restored') return '已恢复的登录态';
    if (source === 'fixture') return '离线 Fixture 演示';
    return '体验身份（演示数据）';
  }

  private clearLocalCaches(): void {
    const context: common.UIAbilityContext = this.context();
    ClientCache.clearDemoData();
    WorkflowSessionStore.clear(context);
  }

  private async goToLogin(): Promise<void> {
    this.busy = true;
    if (AuthStore.isSignedIn()) {
      await AuthClient.signOut();
      appState.applyLogout();
      this.clearLocalCaches();
    } else {
      await AgentApiClient.resetDemo();
      appState.resetToMockData();
      this.clearLocalCaches();
    }
    this.busy = false;
    AgentApiClient.setUseFixture(false);
    router.replaceUrl({ url: 'pages/Login' });
  }

  private async doSignOut(): Promise<void> {
    this.showSignOutConfirm = false;
    this.busy = true;
    const result: AuthResult = await AuthClient.signOut();
    this.busy = false;
    appState.applyLogout();
    this.clearLocalCaches();
    this.message = result.message.length > 0 ? result.message : '已退出登录。';
    this.messageIsError = false;
    AgentApiClient.setUseFixture(false);
    router.replaceUrl({ url: 'pages/Login' });
  }

  private async doDeleteAccount(): Promise<void> {
    this.showDeleteConfirm = false;
    this.busy = true;
    const result: AuthResult = await AuthClient.deleteAccount();
    this.busy = false;
    if (!result.ok) {
      this.message = `注销未在服务端完成：${result.message}`;
      this.messageIsError = true;
      this.refresh();
      return;
    }
    appState.applyLogout();
    this.clearLocalCaches();
    AgentApiClient.setUseFixture(false);
    router.replaceUrl({ url: 'pages/Login' });
  }

  build() {
    Stack() {
      this.pageContent()
      if (this.showSignOutConfirm) {
        this.confirmOverlay(this.signedIn ? '退出登录？' : '返回登录页？',
          this.signedIn
            ? '退出后会回到登录页，学习记录会保留。下次登录可继续使用。'
            : '将回到登录页。你可以用昵称建立自己的账号，或再次以演示身份进入。',
          this.signedIn ? '退出并返回登录页' : '返回登录页', UiTheme.accent,
          (): void => { this.doSignOut(); },
          (): void => { this.showSignOutConfirm = false; })
      }
      if (this.showDeleteConfirm) {
        this.confirmOverlay('注销账号？',
          '注销后，这个账号将无法再登录，所有设备上的登录也会失效。账号中的学习记录、聊天和资料会被清除，已上传的原文件会安排删除。此操作无法撤销。',
          '确认注销', '#EF4444',
          (): void => { this.doDeleteAccount(); },
          (): void => { this.showDeleteConfirm = false; })
      }
    }
    .width('100%').height('100%').alignContent(Alignment.TopStart)
  }

  @Builder
  AccountField(label: string, value: string) {
    Row({ space: 12 }) {
      Text(label).fontSize(14).fontColor(UiTheme.ink).width(72)
      Text(value || '未填写').fontSize(14).fontColor(UiTheme.secondary).layoutWeight(1).copyOption(CopyOptions.InApp)
    }.width('100%').constraintSize({ minHeight: 42 })
  }
  @Builder
  PrivacyContent() {
          Column({ space: 8 }) {
            Text('隐私说明').fontSize(15).fontWeight(FontWeight.Bold)
              .fontColor('#1F2937').width('100%')
            Text('登录与账号').fontSize(14).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%')
            Text('手机号用于登录，展示时会隐藏中间几位。密码经过安全处理后保存，不会以原文保存。')
              .fontSize(13).fontColor(UiTheme.secondary).lineHeight(21).width('100%')
            Text('学习记录与 AI 功能').fontSize(14).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%').margin({ top: 8 })
            Text('学习记录、计划、练习结果、聊天和上传的资料会保存在云端，方便下次登录继续使用。使用 AI 时，相关问题、资料内容或图片会发送给 AI 服务进行分析。')
              .fontSize(13).fontColor(UiTheme.secondary).lineHeight(21).width('100%')
            Text('位置与提醒').fontSize(14).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%').margin({ top: 8 })
            Text('学习情境只使用“图书馆”等场所描述，不上传具体坐标。允许通知后，会保存接收提醒所需的设备信息，你可以在提醒设置中关闭通知。')
              .fontSize(13).fontColor(UiTheme.secondary).lineHeight(21).width('100%')
            Text('退出与注销').fontSize(14).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%').margin({ top: 8 })
            Text('退出登录会保留学习记录。注销后，账号中的学习记录、聊天和资料会被清除，已上传的原文件会安排删除，所有设备上的登录会失效；注销无法撤销。')
              .fontSize(13).fontColor(UiTheme.secondary).lineHeight(21).width('100%')
          }
          .width('100%').padding(16).backgroundColor(UiTheme.subtle).borderRadius(8)
  }
  @Builder
  VersionContent() {
          Column({ space: 3 }) {
            Text('知学 Mate').fontSize(12).fontColor('#B6BFCB').width('100%')
              .textAlign(TextAlign.Center)
            Text(`版本 ${this.versionName}`).fontSize(11).fontColor('#B6BFCB').width('100%')
              .textAlign(TextAlign.Center)
              .onClick(() => { this.onAboutVersionTap(); })
          }
          .width('100%').padding({ top: 14, bottom: 2 })
  }

  @Builder
  pageContent() {
    Column() {
      PageHeader({ title: '账号、安全与隐私' })
      Scroll() {
        Column({ space: 16 }) {
          Row() {
            Blank()
            Text(this.signedIn ? '编辑资料 ›' : '去登录 ›').fontSize(13).fontColor(UiTheme.accent).padding({ top: 10, bottom: 10 })
              .onClick(() => { if (this.signedIn) router.pushUrl({ url: 'pages/EditProfile' }); else void this.goToLogin(); })
          }.width('100%')
          Column() {
            this.AccountField('昵称', this.nickname)
            this.AccountField('手机号', this.phoneMasked)
            this.AccountField('账号', this.userId)
            this.AccountField('年级', this.grade)
            this.AccountField('注册时间', this.createdAt)
          }.width('100%')
          if (this.message) { Text(this.message).fontSize(13).fontColor(this.messageIsError ? UiTheme.danger : UiTheme.secondary).lineHeight(21).width('100%') }
          if (!this.signedIn) {
            Text(this.sourceLabel).fontSize(13).fontColor(UiTheme.secondary).width('100%')
            Button('登录或建立我的账号', { type: ButtonType.Normal }).height(44).fontSize(14).width('100%')
              .fontColor('#FFFFFF').backgroundColor(UiTheme.accent).borderRadius(8).onClick(() => this.goToLogin())
          }
          if (this.signedIn) {
            Divider().color(UiTheme.line)
            Row() {
              Text('修改密码').fontSize(16).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).layoutWeight(1)
              Text(this.passwordExpanded ? '⌃' : '›').fontSize(22).fontColor(UiTheme.secondary)
            }.width('100%').constraintSize({ minHeight: 44 }).onClick(() => this.passwordExpanded = !this.passwordExpanded)
            if (this.passwordExpanded) {
              TextInput({ text: this.pwdOld, placeholder: '原密码（从未设置可留空）' }).type(InputType.Password).showPasswordIcon(true)
                .height(44).fontSize(14).borderRadius(8).backgroundColor(UiTheme.subtle).enabled(!this.pwdBusy).onChange((value: string) => this.pwdOld = value)
              TextInput({ text: this.pwdNew, placeholder: '新密码（6至72位）' }).type(InputType.Password).showPasswordIcon(true)
                .height(44).fontSize(14).borderRadius(8).backgroundColor(UiTheme.subtle).enabled(!this.pwdBusy).onChange((value: string) => this.pwdNew = value)
              TextInput({ text: this.pwdConfirm, placeholder: '再次输入新密码' }).type(InputType.Password).showPasswordIcon(true)
                .height(44).fontSize(14).borderRadius(8).backgroundColor(UiTheme.subtle).enabled(!this.pwdBusy).onChange((value: string) => this.pwdConfirm = value)
              Button(this.pwdBusy ? '提交中…' : '确认修改', { type: ButtonType.Normal }).height(44).width('100%').fontSize(14)
                .fontColor(UiTheme.accent).backgroundColor(UiTheme.tint).borderRadius(8).enabled(!this.pwdBusy)
                .onClick(() => this.doChangePassword())
              if (this.pwdMsg) { Text(this.pwdMsg).fontSize(13).fontColor(this.pwdOk ? UiTheme.success : UiTheme.danger).lineHeight(20).width('100%') }
            }
          }
          Divider().color(UiTheme.line)
          Row() {
            Text('我的学习搭子').fontSize(15).fontColor(UiTheme.ink).layoutWeight(1)
            Text(this.partnerContactsLoading ? '同步中' : this.partnerContactNames.length > 0 ? `已添加${this.partnerContactNames.length}位 ›` : '查看 ›').fontSize(13).fontColor(UiTheme.secondary)
          }.width('100%').height(48).onClick(() => router.pushUrl({ url: 'pages/PartnerMatch' }))
          if (this.partnerContactsError) { Text(this.partnerContactsError).fontSize(12).fontColor(UiTheme.danger).width('100%').onClick(() => this.loadPartnerContacts()) }
          this.PrivacyContent()
          this.VersionContent()
          Text('学习决策记录 ›').fontSize(14).fontColor(UiTheme.secondary).width('100%').padding({ top: 12, bottom: 12 })
            .onClick(() => router.pushUrl({ url: 'pages/AgentTrace' }))
          if (AuthStore.encryptionDegraded()) { Text('本机加密服务不可用，本次登录仅在内存中保留，重启后请重新登录。').fontSize(12).fontColor(UiTheme.secondary).width('100%') }
          Row({ space: 12 }) {
            Button(this.busy ? '处理中…' : this.signedIn ? '退出登录' : '返回登录页', { type: ButtonType.Normal })
              .height(44).layoutWeight(1).fontSize(14).fontColor(UiTheme.accent).backgroundColor(UiTheme.surface)
              .border({ width: 1, color: UiTheme.line }).borderRadius(8).enabled(!this.busy).onClick(() => this.showSignOutConfirm = true)
            if (this.signedIn) {
              Button('注销账号', { type: ButtonType.Normal }).height(44).layoutWeight(1).fontSize(14).fontColor(UiTheme.danger)
                .backgroundColor(UiTheme.surface).border({ width: 1, color: UiTheme.line }).borderRadius(8).enabled(!this.busy)
                .onClick(() => this.showDeleteConfirm = true)
            }
          }.width('100%')
        }.width('100%').constraintSize({ maxWidth: UiTheme.contentWidth }).padding(20).alignItems(HorizontalAlign.Start)
      }.width('100%').layoutWeight(1).scrollBar(BarState.Off).align(Alignment.Top)
    }.width('100%').height('100%').backgroundColor(UiTheme.surface)
  }

  private onAboutVersionTap(): void {
    if (!ApiDefaults.ALLOW_DEBUG) return;
    const now: number = Date.now();
    const withinWindow: boolean = now - this.aboutLastTapMs <= ABOUT_TAP_WINDOW_MS;
    this.aboutTapCount = withinWindow ? this.aboutTapCount + 1 : 1;
    this.aboutLastTapMs = now;
    if (this.aboutTapCount >= ABOUT_TAP_REQUIRED) {
      this.aboutTapCount = 0;
      this.aboutLastTapMs = 0;
      router.pushUrl({ url: 'pages/ApiEnvironment' });
    }
  }

  @Builder
  StatBlock(value: string, label: string) {
    Column({ space: 4 }) {
      Text(value).fontSize(19).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink)
      Text(label).fontSize(11).fontColor(UiTheme.secondary).textAlign(TextAlign.Center)
    }
    .layoutWeight(1).padding({ top: 13, bottom: 13 })
    .backgroundColor(UiTheme.subtle).borderRadius(8)
  }

  @Builder
  confirmOverlay(title: string, body: string, confirmLabel: string, confirmColor: string,
                 onConfirm: () => void, onCancel: () => void) {
    Column() {
      Column({ space: 12 }) {
        Text(title).fontSize(17).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink).width('100%')
        Text(body).fontSize(13).fontColor(UiTheme.secondary).lineHeight(20).width('100%')
        Row({ space: 10 }) {
          Button('取消')
            .layoutWeight(1).height(44).fontSize(14).fontColor(UiTheme.secondary)
            .backgroundColor(UiTheme.subtle).borderRadius(8)
            .onClick(() => onCancel())
          Button(confirmLabel)
            .layoutWeight(1).height(44).fontSize(14).fontColor(UiTheme.surface)
            .backgroundColor(confirmColor).borderRadius(8)
            .onClick(() => onConfirm())
        }.width('100%').margin({ top: 4 })
      }
      .width('86%').constraintSize({ maxWidth: UiTheme.dialogWidth }).padding(20).backgroundColor(UiTheme.surface).borderRadius(8)
    }
    .width('100%').height('100%')
    .backgroundColor('rgba(15, 23, 42, 0.45)')
    .justifyContent(FlexAlign.Center)
  }
}
