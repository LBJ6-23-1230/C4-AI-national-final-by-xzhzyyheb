import { authentication } from '@kit.AccountKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x5A02;
const TAG: string = 'HuaweiAccount';

export interface HuaweiAuthOutcome {
  ok: boolean;
  authorizationCode: string;
  message: string;
}

export class HuaweiAccountService {
  static async requestAuthorizationCode(context: common.UIAbilityContext): Promise<HuaweiAuthOutcome> {
    try {
      const provider = new authentication.HuaweiIDProvider();
      const request = provider.createLoginWithHuaweiIDRequest();
      const state: string = util.generateRandomUUID();
      request.forceLogin = true;
      request.state = state;

      const controller = new authentication.AuthenticationController(context);
      const response = await controller.executeRequest(request) as authentication.LoginWithHuaweiIDResponse;
      if (response.state !== state) {
        return HuaweiAccountService.failure('华为授权响应与本次请求不匹配，请重新登录。');
      }
      const authorizationCode: string = response.data?.authorizationCode ?? '';
      if (authorizationCode.length === 0) {
        return HuaweiAccountService.failure('华为未返回授权码，请重新登录。');
      }
      return { ok: true, authorizationCode: authorizationCode, message: '' };
    } catch (error) {
      const code: number = (error as BusinessError).code ?? 0;
      hilog.warn(DOMAIN, TAG, 'Huawei authorization failed: %{public}d', code);
      return HuaweiAccountService.failure(HuaweiAccountService.explain(code));
    }
  }

  private static explain(code: number): string {
    switch (code) {
      case authentication.AuthenticationErrorCode.ACCOUNT_NOT_LOGGED_IN:
        return '请先在系统设置中登录华为账号，再返回知学 Mate 重试。';
      case authentication.AuthenticationErrorCode.USER_CANCELED:
        return '你已取消华为账号授权，可以重新发起登录。';
      case authentication.AuthenticationErrorCode.NETWORK_ERROR:
        return '暂时无法连接华为账号服务，请检查网络后重试。';
      case authentication.AuthenticationErrorCode.PACKAGE_FINGERPRINT_CHECK_ERROR:
      case authentication.AuthenticationErrorCode.PARAMETER_INVALID:
        return `华为账号登录配置校验失败（${code}），请核对应用 Client ID 和安装包签名。`;
      default:
        return `华为账号授权未完成（${code}），请重试。`;
    }
  }

  private static failure(message: string): HuaweiAuthOutcome {
    return { ok: false, authorizationCode: '', message: message };
  }
}
