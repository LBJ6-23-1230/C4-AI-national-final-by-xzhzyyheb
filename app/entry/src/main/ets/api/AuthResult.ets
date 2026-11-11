import { AuthSource, AuthUser } from './AuthModels';

export interface AuthResult {
  needsPasswordSetup?: boolean;
  accounts?: AuthUser[];
  selectionToken?: string;
  ok: boolean;
  user: AuthUser | null;
  source: AuthSource;
  message: string;
  resendAfterSeconds?: number;
  devCode?: string;
  smsDelivered?: boolean;
  createdAccount?: boolean;
  demoDataSeeded?: boolean;
}
