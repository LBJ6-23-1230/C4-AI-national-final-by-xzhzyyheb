
export type AuthProvider = 'local' | 'guest' | 'agc_phone' | 'agc_anonymous';

export type AuthSource = 'guest' | 'local' | 'restored' | 'fixture';

export interface AuthUser {
  userId: string;
  nickname: string;
  avatar?: string;
  grade: string;
  authProvider: AuthProvider;
  createdAt: string;
  lastLoginAt: string;
  phoneMasked?: string;
  hasPhone?: boolean;
  needsPasswordSetup?: boolean;
}

export interface AuthRegisterRequest {
  nickname?: string;
  password: string;
  grade?: string;
  phone: string;
  seedDemoData?: boolean;
}

export interface AuthSeedDemoDataField {
  seedDemoData?: boolean;
}

export interface AuthHuaweiLoginRequest {
  authorizationCode: string;
}

export interface AuthLoginRequest {
  userId?: string;
  token?: string;
  nickname?: string;
  phone?: string;
  password?: string;
}

export interface AuthSendCodeRequest {
  phone: string;
}

export interface AuthSendCodeResponse {
  phoneMasked: string;
  expiresInSeconds: number;
  resendAfterSeconds: number;
  smsDelivered: boolean;
  devCode?: string;
}

export interface AuthVerifyCodeRequest extends AuthSeedDemoDataField {
  phone: string;
  code: string;
  nickname?: string;
  grade?: string;
}

export const VERIFICATION_CODE_MESSAGES: Record<string, string> = {
  'RATE_LIMITED': '发送太频繁了，请稍后再试。',
  'DAILY_LIMIT_REACHED': '今日验证码次数已用完，请明天再试。',
  'PHONE_LOCKED': '连续输错次数过多，该手机号已被临时锁定，请 15 分钟后再试。',
  'INVALID_CODE': '验证码不正确，请检查后重试。',
  'CODE_EXPIRED': '验证码已过期，请重新获取。',
  'CODE_NOT_FOUND': '请先获取验证码。',
  'SMS_NOT_CONFIGURED': '短信服务尚未配置，暂时无法发送验证码。请使用手机号和密码登录。',
  'SMS_PROVIDER_UNAVAILABLE': '短信服务暂不可用，请稍后重试。请使用手机号和密码登录。'
};

export interface AuthLoginOrRegisterRequest extends AuthSeedDemoDataField {
  nickname: string;
  password?: string;
  grade?: string;
  phone?: string;
}

export interface AuthLoginOrRegisterResponse extends AuthSessionResponse {
  created?: boolean;
}

export interface AuthSelectAccountRequest {
  selectionToken: string;
  accountId: string;
  password?: string;
}

export interface AuthSessionResponse {
  needsPasswordSetup?: boolean;
  accounts?: AuthUser[];
  selectionToken?: string;
  user: AuthUser;
  token: string;
  expiresAt: string;
  demoDataSeeded?: boolean;
}

export interface AuthUserResponse {
  user: AuthUser;
}

export interface AuthProfileUpdateRequest {
  nickname: string;
  avatar: string;
}

export interface AuthStatusResponse {
  status: string;
  userId?: string;
}

export interface AuthChangePasswordRequest {
  oldPassword?: string;
  newPassword: string;
}

export interface AuthChangePasswordResponse {
  status: string;
  hasPassword: boolean;
  wasFirstTime: boolean;
}

export interface ChangePasswordResult {
  ok: boolean;
  message: string;
}

export interface StoredSession {
  userId: string;
  token: string;
  expiresAt: string;
  nickname: string;
  avatar?: string;
  grade: string;
  authProvider: AuthProvider;
  savedAt: string;
}

export const GRADE_OPTIONS: string[] = [
  '大一', '大二', '大三', '大四', '大五', '研一', '研二', '研三', '博士'
];

export const NICKNAME_MIN_LENGTH: number = 1;
export const NICKNAME_MAX_LENGTH: number = 16;

export function maskPhone(phone: string): string {
  if (phone.length < 7) {
    return phone;
  }
  return `${phone.substring(0, 3)}****${phone.substring(phone.length - 4)}`;
}
