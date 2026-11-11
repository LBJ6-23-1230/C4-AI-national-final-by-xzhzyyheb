import { BuildEnvironment } from './BuildEnvironment';

export class ApiDefaults {
  static readonly ALLOW_DEBUG: boolean = BuildEnvironment.ALLOW_DEBUG;
  static readonly ALLOW_DEMO: boolean = BuildEnvironment.ALLOW_DEMO;
  static readonly DEFAULT_BASE_URL: string = BuildEnvironment.API_URL;

  static readonly LOCALHOST_BASE_URL: string = 'http://127.0.0.1:5000';
  static readonly USB_MISTYPED_HTTPS_URL: string = 'https://127.0.0.1:5000';
  static readonly ALLOW_USB_HUAWEI_LOGIN: boolean = BuildEnvironment.NAME === 'development' && ApiDefaults.ALLOW_DEBUG;

  static supportsHuaweiLogin(baseUrl: string): boolean {
    return baseUrl.startsWith('https://') && baseUrl !== ApiDefaults.USB_MISTYPED_HTTPS_URL ||
      ApiDefaults.ALLOW_USB_HUAWEI_LOGIN && baseUrl === ApiDefaults.LOCALHOST_BASE_URL;
  }

  static readonly CONTRACT_VERSION: string = 'api-contract-v0.3';

  static readonly DEFAULT_TIMEOUT_MS: number = 8000;
  static readonly HUAWEI_LOGIN_READ_TIMEOUT_MS: number = 20000;
  static readonly PROFILE_SAVE_READ_TIMEOUT_MS: number = 20000;

  static readonly LLM_BOUND_READ_TIMEOUT_MS: number = 40000;
  static readonly VISION_READ_TIMEOUT_MS: number = 150000;
  static readonly CHAT_STREAM_READ_TIMEOUT_MS: number = 150000;

  static readonly DOCUMENT_PROCESSING_READ_TIMEOUT_MS: number = 60000;

  static readonly DELETE_PROCESSING_READ_TIMEOUT_MS: number = 30000;

  static readonly DEFAULT_USE_FIXTURE: boolean = false;

  static readonly DEMO_USER_ID: string = 'demo-user';

  static readonly DEMO_USER_NAME: string = '小明';
}
