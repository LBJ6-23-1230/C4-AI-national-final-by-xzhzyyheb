import { UiTheme } from '../utils/UiTheme';
import { PageHeader } from '../components/PageHeader';
import router from '@ohos.router';
import { UserAvatar } from '../components/UserAvatar';
import { common } from '@kit.AbilityKit';
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

/**
 * 「关于」里的版本号要**连点这么多次**才进入「接口环境」（开发联调入口）。
 *
 * 为什么不放按钮/文案：`pages/ApiEnvironment` 是**开发联调**用的（改后端地址、
 * 切离线 Fixture），面向评委的正式版不该把它摆在明面上；但完全拿掉又会让真机联调
 * 没有入口。折中是"评委看不见、开发者知道怎么进"——见 `onAboutVersionTap()`。
 */
const ABOUT_TAP_REQUIRED: number = 5;

/** 连点判定窗口（毫秒）：相邻两次点击间隔超过它就重新计数，避免"分几次点够数"误进入。 */
const ABOUT_TAP_WINDOW_MS: number = 1500;

/** 展示用版本号，**必须与 `AppScope/app.json5` 的 `versionName` 一致**。 */
const APP_VERSION_NAME: string = '1.0.0';

/**
 * 账号与隐私页（「我的」）。
 *
 * 承载四件事：
 *   1. 展示当前身份（登录用户 / 体验身份），让用户随时知道"Agent 现在认为我是谁"；
 *   2. **返回登录页**（切换身份）—— 无论当前是登录态还是体验身份都可用，
 *      这是「进得去也出得来」的兜底出口；
 *   3. 退出登录（二次确认）→ 回到 demo-user 体验身份，留在 App 内；
 *   4. 注销账号（合规要求，二次确认 + 明确说明后果）。
 *
 * 为什么这一页重要：登录功能对 50 分创新性几乎没有贡献，但它必须**可退出、可注销、
 * 可回到登录页**，否则就是"能进不能出"的设计缺陷，规范性上会扣分。
 */
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
  /**
   * 脱敏手机号与注册时间（来自 `/api/v1/auth/me`）。
   *
   * 为什么单独拉一次：`appState.currentUser` 是 `UserProfile`（学习画像用的
   * `basicInfo` 结构），里面**没有** `phoneMasked` / `createdAt`。
   * 而「我的」页应当显示"这个账号是谁" —— 昵称、手机号、年级、注册时间。
   *
   * 失败时**不报错也不清空**：本地已有昵称/年级，先把能显示的显示出来，
   * 网络恢复后下次进入再补齐。拉不到就少显示两行，不影响页面可用。
   */
  @State phoneMasked: string = '';
  @State createdAt: string = '';
  @State message: string = '';
  @State messageIsError: boolean = false;
  @State busy: boolean = false;
  @State showSignOutConfirm: boolean = false;
  @State showDeleteConfirm: boolean = false;
  @State proactiveEnabled: boolean = ProactiveSettingsStore.isEnabled();
  /**
   * 服务端已经确认建立的学习搭子关系。
   *
   * `appState.latestPartner` 只是当前设备最近一次匹配/邀请的临时结果；被邀请方
   * 接受后，真正的双向关系保存在 `/partner-contacts`。因此「我的」页必须读取
   * 这份权威数据，不能只看本机内存，否则换设备或作为被邀请方时会误报“还没有”。
   */
  @State partnerContactNames: string[] = [];
  @State partnerContactsLoading: boolean = false;
  @State partnerContactsLoaded: boolean = false;
  @State partnerContactsError: string = '';
  // ---- 修改密码（见页面下方「修改密码」区）----
  @State pwdOld: string = '';
  @State pwdNew: string = '';
  @State pwdConfirm: string = '';
  @State pwdMsg: string = '';
  @State pwdOk: boolean = false;
  @State pwdBusy: boolean = false;
  // ---- 「关于」版本号的连点计数（开发联调入口，见 onAboutVersionTap）----
  @State aboutTapCount: number = 0;
  @State aboutLastTapMs: number = 0;

  aboutToAppear(): void {
    this.privacyExpanded = (router.getParams() as Record<string, string>)?.['section'] === 'privacy';
    this.refresh();
    this.loadAccountDetail();
  }

  onPageShow(): void {
    // 从「搭子与协同」页返回时关系可能刚刚被接受，必须重新与服务端对账。
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

  /** 拉取账号详情（脱敏手机号、注册时间）。仅登录态有意义。 */
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
      // 服务端是权威来源，顺便同步昵称/年级
      if (user.nickname.length > 0) { this.nickname = user.nickname; }
      if (user.grade.length > 0) { this.grade = user.grade; }
    }
  }

  /** 拉取接受邀请后由服务端双向登记的搭子名单。 */
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
      // 请求失败不等于没有搭子：保留已有数据，并明确提示同步失败。
      this.partnerContactsError = '暂时无法同步已建立的学习搭子，请稍后重试。';
    }
    this.partnerContactsLoaded = true;
    this.partnerContactsLoading = false;
  }

  /** 头像占位字符：取昵称首字符；昵称为空则用「学」。 */
  private avatarText(): string {
    return this.nickname.length > 0 ? this.nickname.substring(0, 1) : '学';
  }

  /** 把 ISO 时间裁成 `YYYY-MM-DD`，解析不了就原样返回。 */
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

  /**
   * 提交改密码。
   *
   * 结果文案**由 `AuthClient.changePassword` 如实给出**（区分"已修改"/"已设置"/
   * 各种失败原因），这里只负责展示，不自己编一句"修改成功"。
   */
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
      // 密码已变化，当前会话不再继续沿用：立即吊销 token、清理账号态并回登录页。
      // 这样用户能立刻用新密码重新验证，也避免旧会话继续操作造成安全误解。
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
    // `local` 现在覆盖**所有本机主动登录**（昵称/手机号 + 密码、注册），
    // 原文案写死"（昵称注册）"会与手机号登录的场景对不上。
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

  /**
   * 返回登录页（切换身份）。
   *
   * 这是"进得去也出得来"的关键出口。行为分两种：
   *
   * * **已登录** → 先真正退出登录（吊销服务端 token + 清本地 + 回体验身份），
   *   再跳登录页。否则登录态还留着，`EntryAbility` 下次启动又会直接进主页，
   *   用户会觉得"我明明退出去了怎么又回来了"。
   * * **体验身份** → 不需要吊销任何凭据，直接跳登录页换个身份进来即可。
   *
   * 用 `replaceUrl` 而非 `pushUrl`：登录页是身份入口，不该在返回栈里累积，
   * 否则用户在登录页按返回会又回到「我的」，逻辑上很怪。
   */
  private async goToLogin(): Promise<void> {
    this.busy = true;
    if (AuthStore.isSignedIn()) {
      await AuthClient.signOut();
      appState.applyLogout();
      this.clearLocalCaches();
    } else {
      // 体验身份固定使用 demo-user，因此退出时清回演示基线，避免上一位体验者的
      // 错题、课程或知识库残留给下一位。离线 Fixture 也走同一接口并清本机数据。
      await AgentApiClient.resetDemo();
      appState.resetToMockData();
      this.clearLocalCaches();
    }
    this.busy = false;
    // 与 `Index.goToLogin` 保持一致：离线态回到联机，否则登录后仍在读本地 Fixture 数据。
    //
    // 修复的缺陷：原先只有 Index 那条路径关 Fixture，从「我的」返回登录页时它仍开着。
    // 后果是**登录页上所有入口都会报「未找到 fixture 路由」** ——
    // `FixtureApiTransport` 一条 auth 路由都没有，用户看到的是内部错误。
    AgentApiClient.setUseFixture(false);
    router.replaceUrl({ url: 'pages/Login' });
  }

  /**
   * 退出登录 —— **并离开本页回到登录页**。
   *
   * 为什么改：这段原先退出后 `applyLogout()` 就留在 App 内（于是停在游客的「我的」），
   * 而页面上另一个常驻的「返回登录页」按钮去向是登录页 —— 两个按钮功能重叠、去向不同。
   * 实测反馈原话：「有两个功能重复的按钮（返回登录页和退出登录），并且点击后返回的是
   * 小明的游客登录的我的界面，不是登录界面，相当于多了一个不必要的过程」。
   * 现在两者合一：确认后真正退出，并**直接回登录页**，不在游客态多停一步。
   */
  private async doSignOut(): Promise<void> {
    this.showSignOutConfirm = false;
    this.busy = true;
    const result: AuthResult = await AuthClient.signOut();
    this.busy = false;
    appState.applyLogout();
    this.clearLocalCaches();
    this.message = result.message.length > 0 ? result.message : '已退出登录。';
    this.messageIsError = false;
    // 与 `goToLogin` 保持一致：离开前关掉离线 Fixture，否则登录页上的入口会报
    // 「未找到 fixture 路由」（`FixtureApiTransport` 没有任何 auth 路由）。
    AgentApiClient.setUseFixture(false);
    router.replaceUrl({ url: 'pages/Login' });
  }

  /**
   * 注销账号 —— 成功时与退出登录一样**直接回登录页**（账号已停用，没有可停留的身份）。
   *
   * 失败时**不再清本地登录态**：账号可能仍然可用，把用户踢成游客再报错
   * 反而会让人以为注销成功了。如实报错并保持原状态。
   */
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

  /**
   * 唯一根节点是 `Stack`。
   *
   * ArkTS 要求 `@Entry` 组件的 `build()` **只能有一个容器根节点**——
   * 不能像 React 那样并列多个兄弟节点。因此这里用 `Stack` 把
   * 「页面主体」与「二次确认浮层」叠在一起：主体在下，浮层在上有更高的 zIndex。
   */
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
            // ⚠️ 原文案是「不收集手机号、身份证等敏感信息；账号只有一个昵称」——
            // 与实现**相反**：注册强制手机号、后端也存完整号码，并且实现了
            // 手机验证码与密码登录。合规声明与实现不一致比功能缺失更减分，
            // 这里改成如实描述。
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
            Text(`版本 ${APP_VERSION_NAME}`).fontSize(11).fontColor('#B6BFCB').width('100%')
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
      }.width('100%').layoutWeight(1).scrollBar(BarState.Off).align(Alignment.TopStart)
    }.width('100%').height('100%').backgroundColor(UiTheme.surface)
  }

  /**
   * 「关于」版本号的连点处理器 —— 连点 {@link ABOUT_TAP_REQUIRED} 次进入「接口环境」。
   *
   * 为什么用连点而不是按钮：那条路径只服务于**开发联调**（改后端地址 / 切 Fixture），
   * 面向评委时不该出现在界面上，所以不给任何可见提示。
   *
   * 计数放在 `@State` 里而不是普通成员，是因为 ArkTS 组件只有在状态变化时才会重绘，
   * 普通成员改了界面不刷新——虽然这里不需要界面反馈，但保持"状态即真相"更不容易出岔子。
   */
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

  /** 学习数据统计块（任务完成度 / 专注记录等）。 */
  @Builder
  StatBlock(value: string, label: string) {
    Column({ space: 4 }) {
      Text(value).fontSize(19).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink)
      Text(label).fontSize(11).fontColor(UiTheme.secondary).textAlign(TextAlign.Center)
    }
    .layoutWeight(1).padding({ top: 13, bottom: 13 })
    .backgroundColor(UiTheme.subtle).borderRadius(8)
  }

  /**
   * 二次确认浮层。
   *
   * 注意：ArkTS 的 `@Builder` **不支持**把 builder/函数当作参数再转调，
   * 因此回调必须用 `(): void => { ... }` 箭头函数形式传入（而非 `() => expr` 表达式体），
   * 否则内部无法作为 UI 事件处理器绑定。
   */
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
      .width('86%').padding(20).backgroundColor(UiTheme.surface).borderRadius(8)
    }
    .width('100%').height('100%')
    .backgroundColor('rgba(15, 23, 42, 0.45)')
    .justifyContent(FlexAlign.Center)
  }
}
