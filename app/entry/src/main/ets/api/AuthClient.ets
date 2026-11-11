import { common } from '@kit.AbilityKit';
import { ApiDefaults } from './ApiDefaults';
import { AuthProfileUpdateRequest } from './AuthModels';
import { AccountProfileSaver, AccountProfileTransport } from '../services/AccountProfileSaver';
import { HuaweiAccountService, HuaweiAuthOutcome } from '../services/HuaweiAccountService';
import { AgentApiClient } from './AgentApiClient';
import { ApiFailure, ApiResult } from './ApiResult';
import { AuthResult } from './AuthResult';
import { AuthStore } from './AuthStore';
import { AuthUser, ChangePasswordResult, NICKNAME_MAX_LENGTH, NICKNAME_MIN_LENGTH, StoredSession, VERIFICATION_CODE_MESSAGES, AuthChangePasswordRequest, AuthVerifyCodeRequest } from './AuthModels';

export class AuthClient {
  static async selectAccount(selectionToken: string, accountId: string, password: string): Promise<AuthResult> {
    const result = await AgentApiClient.authSelectAccount({ selectionToken: selectionToken, accountId: accountId, password: password });
    if (!result.ok) return { ok: false, user: null, source: 'local', message: AuthClient.describe(result) };
    AuthStore.save(result.data.user, result.data.token, result.data.expiresAt);
    return { ok: true, user: result.data.user, source: 'local', message: '' };
  }

  static async updateProfile(nickname: string, avatar: string): Promise<AuthResult> {
    const session: StoredSession | null = AuthStore.getSession();
    if (session === null) {
      return { ok: false, user: null, source: 'guest', message: '请先登录后再编辑资料。' };
    }
    const invalid: string = AuthClient.validateNickname(nickname);
    if (invalid.length > 0 || /[\r\n\t]/.test(nickname)) {
      return { ok: false, user: null, source: 'local', message: invalid || '昵称不能包含换行或制表符。' };
    }
    if (AgentApiClient.getConfig().useFixture) {
      return { ok: false, user: null, source: 'fixture', message: '当前离线，连接服务器后才能保存资料。' };
    }
    const request: AuthProfileUpdateRequest = { nickname: nickname.trim(), avatar: avatar };
    const transport: AccountProfileTransport = {
      write: () => AgentApiClient.authUpdateProfile(request),
      read: () => AgentApiClient.authMe(),
      isCurrent: (): boolean => {
        const active: StoredSession | null = AuthStore.getSession();
        return active !== null && active.userId === session.userId && active.token === session.token;
      }
    };
    const result = await AccountProfileSaver.save(request, session.userId, transport);
    const current: StoredSession | null = AuthStore.getSession();
    if (current === null || current.userId !== session.userId || current.token !== session.token) {
      return { ok: false, user: null, source: 'local', message: '账号已切换，请重新进入编辑资料。' };
    }
    if (!result.ok) {
      const failure = result as ApiFailure;
      const networkFailure: boolean = failure.error.code === 'NETWORK_ERROR' ||
        [408, 502, 503, 504].indexOf(failure.error.statusCode) >= 0;
      return { ok: false, user: null, source: 'local', message: networkFailure
        ? '暂时无法确认保存结果，已保留当前修改，请网络恢复后重试。'
        : failure.error.statusCode === 401 ? '登录已失效，请重新登录后保存资料。' : AuthClient.describe(result) };
    }
    const persisted: boolean = AuthStore.save(result.data.user, current.token, current.expiresAt);
    return { ok: true, user: result.data.user, source: 'local',
      message: persisted ? '资料已保存' : '资料已保存到账号，本机缓存写入失败，联网后可重新同步。' };
  }

  static continueAsGuest(): AuthResult {
    if (!ApiDefaults.ALLOW_DEMO) return { ok: false, user: null, source: 'guest', message: '请登录后使用。' };
    AuthStore.clear();
    return { ok: true, user: AuthClient.guestUser(), source: 'guest', message: '' };
  }

  static continueOffline(useFixture: boolean): AuthResult {
    if (!ApiDefaults.ALLOW_DEMO) return { ok: false, user: null, source: 'guest', message: '当前版本需要连接服务并登录。' };
    AuthStore.clear();
    const message: string = useFixture
      ? '已进入离线演示模式，全部数据由本机 Fixture 提供，判分规则与后端一致。'
      : '';
    return { ok: true, user: AuthClient.guestUser(), source: 'fixture', message: message };
  }

  private static offlineUnavailable(): AuthResult {
    return {
      ok: false,
      user: null,
      source: 'fixture',
      message: '当前为离线演示。要登录或注册，请先选择「跳过登录，在线体验」切回在线，再返回登录页。'
    };
  }

  private static sessionUser(session: StoredSession): AuthUser {
    return {
      userId: session.userId,
      nickname: session.nickname,
      avatar: session.avatar ?? '',
      grade: session.grade,
      authProvider: session.authProvider,
      createdAt: '',
      lastLoginAt: ''
    };
  }

  private static guestUser(): AuthUser {
    return {
      userId: ApiDefaults.DEMO_USER_ID,
      nickname: ApiDefaults.DEMO_USER_NAME,
      grade: '',
      authProvider: 'guest',
      createdAt: '',
      lastLoginAt: ''
    };
  }

  private static registerMessage(nickname: string, created: boolean,
    demoDataSeeded: boolean): string {
    if (!created) {
      return `欢迎回来，${nickname}。`;
    }
    if (demoDataSeeded) {
      return `已为你建立账号，${nickname}。本次载入了演示数据（二叉树后序遍历等示例知识点与计划）`
        + `—— 它们是示例，不是你自己的记录；你的真实练习会逐步覆盖它们。`;
    }
    return `已为你建立账号，${nickname}。当前画像是空的（未载入任何演示数据）：`
      + `你的知识点掌握度与学习计划，将从你自己的练习与智能体对话中建立。`;
  }

  static validateNickname(nickname: string): string {
    const trimmed: string = nickname.trim();
    if (trimmed.length < NICKNAME_MIN_LENGTH) {
      return '请先填写昵称。';
    }
    if (trimmed.length > NICKNAME_MAX_LENGTH) {
      return `昵称不能超过 ${NICKNAME_MAX_LENGTH} 个字符。`;
    }
    return '';
  }

  static async register(nickname: string, phone: string, grade?: string, password?: string): Promise<AuthResult> {
    if (AgentApiClient.getConfig().useFixture) {
      return AuthClient.offlineUnavailable();
    }
    const invalid: string = nickname.trim().length > 0 ? AuthClient.validateNickname(nickname) : '';
    if (invalid.length > 0) {
      return { ok: false, user: null, source: 'local', message: invalid };
    }

    const result = await AgentApiClient.authRegister({
      nickname: nickname.trim(),
      phone: phone.trim(),
      password: password ?? '',
      grade: grade !== undefined && grade.length > 0 ? grade : undefined,
      seedDemoData: false
    });
    if (!result.ok) {
      return { ok: false, user: null, source: 'local', message: AuthClient.describe(result) };
    }

    if (result.data.accounts !== undefined && result.data.selectionToken !== undefined) {
      return { ok: false, user: null, source: 'local', message: '请选择要登录的账号',
        accounts: result.data.accounts, selectionToken: result.data.selectionToken };
    }
    AuthStore.save(result.data.user, result.data.token, result.data.expiresAt);
    const seeded: boolean = result.data.demoDataSeeded === true;
    return {
      ok: true,
      user: result.data.user,
      source: 'local',
      message: AuthClient.registerMessage(result.data.user.nickname, true, seeded),
      createdAccount: true,
      demoDataSeeded: seeded
    };
  }

  static async loginOrRegister(nickname: string, grade: string, phone?: string,
    password?: string): Promise<AuthResult> {
    if (AgentApiClient.getConfig().useFixture) {
      return AuthClient.offlineUnavailable();
    }
    const invalid: string = nickname.trim().length > 0 ? AuthClient.validateNickname(nickname) : '';
    if (invalid.length > 0) {
      return { ok: false, user: null, source: 'local', message: invalid };
    }

    const result = await AgentApiClient.authLoginOrRegister({
      nickname: nickname.trim(),
      grade: grade.length > 0 ? grade : undefined,
      phone: phone !== undefined && phone.length > 0 ? phone : undefined,
      password: password !== undefined && password.length > 0 ? password : undefined,
      seedDemoData: false
    });
    if (!result.ok) {
      return { ok: false, user: null, source: 'local', message: AuthClient.describe(result) };
    }

    if (result.data.accounts !== undefined && result.data.selectionToken !== undefined) {
      return { ok: false, user: null, source: 'local', message: '请选择要登录的账号',
        accounts: result.data.accounts, selectionToken: result.data.selectionToken };
    }
    AuthStore.save(result.data.user, result.data.token, result.data.expiresAt);
    const created: boolean = result.data.created === true;
    const seeded: boolean = created && result.data.demoDataSeeded === true;
    return {
      ok: true,
      user: result.data.user,
      source: 'local',
      message: AuthClient.registerMessage(result.data.user.nickname, created, seeded),
      needsPasswordSetup: result.data.needsPasswordSetup === true,
      createdAccount: created,
      demoDataSeeded: seeded
    };
  }

  static async loginByPhone(phone: string, password?: string): Promise<AuthResult> {
    if (AgentApiClient.getConfig().useFixture) {
      return AuthClient.offlineUnavailable();
    }
    const trimmed: string = phone.trim();
    if (trimmed.length === 0) {
      return { ok: false, user: null, source: 'local', message: '请输入手机号。' };
    }
    const result = await AgentApiClient.authLogin({
      phone: trimmed,
      password: password !== undefined && password.length > 0 ? password : undefined
    });
    if (!result.ok) {
      return { ok: false, user: null, source: 'local', message: AuthClient.describe(result) };
    }
    if (result.data.accounts !== undefined && result.data.selectionToken !== undefined) {
      return { ok: false, user: null, source: 'local', message: '请选择要登录的账号',
        accounts: result.data.accounts, selectionToken: result.data.selectionToken };
    }
    AuthStore.save(result.data.user, result.data.token, result.data.expiresAt);
    return {
      ok: true,
      user: result.data.user,
      source: 'local',
      message: `欢迎回来，${result.data.user.nickname}。`
    };
  }

  static async sendVerificationCode(phone: string): Promise<AuthResult> {
    if (AgentApiClient.getConfig().useFixture) {
      return AuthClient.offlineUnavailable();
    }
    const trimmed: string = phone.trim();
    if (trimmed.length === 0) {
      return { ok: false, user: null, source: 'local', message: '请输入手机号。' };
    }
    const result = await AgentApiClient.authSendCode({ phone: trimmed });
    if (!result.ok) {
      return { ok: false, user: null, source: 'local', message: AuthClient.describe(result) };
    }
    const data = result.data;
    const devCode: string = data.devCode !== undefined && data.devCode.length > 0
      ? data.devCode : '';
    let message: string;
    if (data.smsDelivered) {
      message = `验证码已发送至 ${data.phoneMasked}，${AuthClient.describeSeconds(data.expiresInSeconds)}内有效。`;
    } else if (devCode.length > 0) {
      message = `短信服务未接入，当前为开发模式回显：验证码是 ${devCode}（${AuthClient.describeSeconds(data.expiresInSeconds)}内有效）。`;
    } else {
      message = `短信服务未接入，未能真实下发验证码。可改用「昵称登录」或「一键体验」。`;
    }
    return {
      ok: true,
      user: null,
      source: 'local',
      message: message,
      resendAfterSeconds: data.resendAfterSeconds,
      devCode: devCode,
      smsDelivered: data.smsDelivered
    };
  }

  static async verifyCode(phone: string, code: string,
    nickname?: string, grade?: string): Promise<AuthResult> {
    if (AgentApiClient.getConfig().useFixture) {
      return AuthClient.offlineUnavailable();
    }
    const trimmedPhone: string = phone.trim();
    const trimmedCode: string = code.trim();
    if (trimmedPhone.length === 0) {
      return { ok: false, user: null, source: 'local', message: '请输入手机号。' };
    }
    if (!/^\d{6}$/.test(trimmedCode)) {
      return { ok: false, user: null, source: 'local', message: '请输入 6 位数字验证码。' };
    }
    const request: AuthVerifyCodeRequest = { phone: trimmedPhone, code: trimmedCode };
    if (nickname !== undefined && nickname.trim().length > 0) {
      request.nickname = nickname.trim();
    }
    if (grade !== undefined && grade.length > 0) {
      request.grade = grade;
    }
    request.seedDemoData = false;

    const result = await AgentApiClient.authVerifyCode(request);
    if (!result.ok) {
      return { ok: false, user: null, source: 'local', message: AuthClient.describe(result) };
    }
    if (result.data.accounts !== undefined && result.data.selectionToken !== undefined) {
      return { ok: false, user: null, source: 'local', message: '请选择要登录的账号',
        accounts: result.data.accounts, selectionToken: result.data.selectionToken };
    }
    AuthStore.save(result.data.user, result.data.token, result.data.expiresAt);
    const created: boolean = result.data.created === true;
    const seeded: boolean = created && result.data.demoDataSeeded === true;
    return {
      ok: true,
      user: result.data.user,
      source: 'local',
      message: AuthClient.registerMessage(result.data.user.nickname, created, seeded),
      needsPasswordSetup: result.data.needsPasswordSetup === true,
      createdAccount: created,
      demoDataSeeded: seeded
    };
  }

  private static describeSeconds(seconds: number): string {
    if (seconds >= 60 && seconds % 60 === 0) {
      return `${seconds / 60} 分钟`;
    }
    return `${seconds} 秒`;
  }

  static async loginWithHuaweiAccount(context: common.UIAbilityContext, isCurrent: () => boolean): Promise<AuthResult> {
    const config = AgentApiClient.getConfig();
    if (config.useFixture) {
      return { ok: false, user: null, source: 'local', message: '当前处于离线演示。请切换到在线后端后重试。' };
    }
    if (!ApiDefaults.supportsHuaweiLogin(config.baseUrl)) {
      return { ok: false, user: null, source: 'local',
        message: '当前连接无法用于华为账号登录。请使用设备信任的 HTTPS 后端。' };
    }

    const interrupted: AuthResult = { ok: false, user: null, source: 'local', message: '本次华为账号登录已中断，请重试。' };
    const isSameEnvironment = (): boolean => {
      const active = AgentApiClient.getConfig();
      return isCurrent() && active.baseUrl === config.baseUrl && !active.useFixture;
    };
    const readiness = await AgentApiClient.checkBackendConnection();
    if (!isSameEnvironment()) {
      return interrupted;
    }
    if (!readiness.ok) {
      const failure = readiness as ApiFailure;
      let message: string = '后端未通过就绪检查，请确认知学 Mate 后端已启动。';
      if (failure.error.code === 'NETWORK_ERROR') {
        message = config.baseUrl === ApiDefaults.LOCALHOST_BASE_URL ?
          '无法连接 USB 联调后端。请检查数据线和电脑上的 USB 转发服务。' :
          '无法连接 HTTPS 后端。请检查网络、后端地址和设备是否信任证书。';
      }
      return { ok: false, user: null, source: 'local', message: message };
    }
    const authorized: HuaweiAuthOutcome = await HuaweiAccountService.requestAuthorizationCode(context);
    if (!isSameEnvironment()) {
      return interrupted;
    }
    if (!authorized.ok) {
      return { ok: false, user: null, source: 'local', message: authorized.message };
    }
    const result = await AgentApiClient.authLoginWithHuawei({ authorizationCode: authorized.authorizationCode });
    if (!isSameEnvironment()) {
      return interrupted;
    }
    if (!result.ok) {
      return { ok: false, user: null, source: 'local', message: AuthClient.describe(result) };
    }
    AuthStore.save(result.data.user, result.data.token, result.data.expiresAt);
    const created: boolean = result.data.created === true;
    return { ok: true, user: result.data.user, source: 'local',
      message: AuthClient.registerMessage(result.data.user.nickname, created, false), createdAccount: created };
  }

  static async loginByNickname(nickname: string, password?: string): Promise<AuthResult> {
    if (AgentApiClient.getConfig().useFixture) {
      return AuthClient.offlineUnavailable();
    }
    const invalid: string = nickname.trim().length > 0 ? AuthClient.validateNickname(nickname) : '';
    if (invalid.length > 0) {
      return { ok: false, user: null, source: 'local', message: invalid };
    }

    const result = await AgentApiClient.authLogin({
      nickname: nickname.trim(),
      password: password !== undefined && password.length > 0 ? password : undefined
    });
    if (!result.ok) {
      return { ok: false, user: null, source: 'local', message: AuthClient.describe(result) };
    }

    if (result.data.accounts !== undefined && result.data.selectionToken !== undefined) {
      return { ok: false, user: null, source: 'local', message: '请选择要登录的账号',
        accounts: result.data.accounts, selectionToken: result.data.selectionToken };
    }
    AuthStore.save(result.data.user, result.data.token, result.data.expiresAt);
    return {
      ok: true,
      user: result.data.user,
      source: 'local',
      message: `欢迎回来，${result.data.user.nickname}。`
    };
  }

  static async restore(): Promise<AuthResult> {
    const session: StoredSession | null = AuthStore.getSession();
    if (session === null) {
      return { ok: false, user: null, source: 'guest', message: '' };
    }

    if (AgentApiClient.getConfig().useFixture) {
      return {
        ok: true,
        user: AuthClient.sessionUser(session),
        source: 'restored',
        message: '当前为离线 Fixture 模式，正在使用本地保存的登录信息。'
      };
    }

    const result = await AgentApiClient.authMe();
    const active: StoredSession | null = AuthStore.getSession();
    if (active === null || active.token !== session.token || active.userId !== session.userId) {
      return { ok: false, user: null, source: 'guest', message: '账号已切换，请重新登录。' };
    }
    if (result.ok) {
      AuthStore.save(result.data.user, session.token, session.expiresAt);
      return { ok: true, user: result.data.user, source: 'restored', message: '',
        needsPasswordSetup: result.data.user.needsPasswordSetup === true };
    }

    const failure = result as ApiFailure;
    if (failure.error.statusCode === 401) {
      AuthStore.clear();
      return {
        ok: false,
        user: null,
        source: 'guest',
        message: '登录已失效，已切换为体验身份。可在「我的」里重新登录。'
      };
    }
    const statusCode: number | undefined = (result as ApiFailure).error.statusCode;
    const offlineLike: boolean = statusCode === undefined || statusCode === 0;
    return {
      ok: true,
      user: AuthClient.sessionUser(session),
      source: 'restored',
      message: offlineLike
        ? '当前处于离线状态，正在使用本地保存的登录信息。'
        : `服务端校验返回 HTTP ${statusCode}，已按本地保存的登录信息继续。`
    };
  }

  static async changePassword(oldPassword: string, newPassword: string): Promise<ChangePasswordResult> {
    if (!AuthStore.isSignedIn()) {
      return { ok: false, message: '请先登录后再修改密码。' };
    }
    if (AgentApiClient.getConfig().useFixture) {
      return { ok: false,
        message: '当前是「离线 Fixture」模式，修改密码需要联机。'
          + '请先到「我的 → 接口环境」切回联机模式。' };
    }
    if (newPassword.length < 6) {
      return { ok: false, message: '新密码至少 6 位。' };
    }
    if (newPassword.length > 72) {
      return { ok: false, message: '新密码不能超过 72 位。' };
    }
    const request: AuthChangePasswordRequest = { newPassword: newPassword };
    if (oldPassword.length > 0) {
      request.oldPassword = oldPassword;
    }
    const result = await AgentApiClient.authChangePassword(request);
    if (!result.ok) {
      return { ok: false, message: AuthClient.describe(result) };
    }
    return {
      ok: true,
      message: result.data.wasFirstTime
        ? '密码已设置。下次可以用手机号（或昵称）+ 密码登录。'
        : '密码已修改。'
    };
  }

  static async signOut(): Promise<AuthResult> {
    if (AuthStore.isSignedIn()) {
      await AgentApiClient.authLogout();
    }
    AuthStore.clear();
    return { ok: true, user: AuthClient.guestUser(), source: 'guest', message: '已退出登录。' };
  }

  static async deleteAccount(): Promise<AuthResult> {
    if (!AuthStore.isSignedIn()) {
      return { ok: false, user: null, source: 'guest', message: '当前未登录，无需注销。' };
    }
    if (AgentApiClient.getConfig().useFixture) {
      AuthStore.clear();
      return {
        ok: true,
        user: AuthClient.guestUser(),
        source: 'fixture',
        message: '当前是「离线 Fixture」模式：已清除本机登录态并回到体验身份，'
          + '但**服务器上的账号未被停用**（离线联系不上服务端）。'
          + '要真正注销，请先到「我的 → 接口环境」切回联机模式。'
      };
    }
    const result = await AgentApiClient.authDeleteAccount();
    AuthStore.clear();
    if (!result.ok) {
      return { ok: false, user: null, source: 'guest', message: AuthClient.describe(result) };
    }
    return {
      ok: true,
      user: AuthClient.guestUser(),
      source: 'guest',
      message: '账号已注销，全部登录会话已失效。'
    };
  }

  private static describe(result: ApiResult<Object>): string {
    const failure = result as ApiFailure;
    if (failure.error.code === 'NETWORK_ERROR') {
      return '连接不上后端服务。请检查服务地址，或直接使用「一键体验」离线进入。';
    }
    const mapped: string | undefined = VERIFICATION_CODE_MESSAGES[failure.error.code];
    if (mapped !== undefined && mapped.length > 0) {
      return mapped;
    }
    return failure.error.message;
  }
}
