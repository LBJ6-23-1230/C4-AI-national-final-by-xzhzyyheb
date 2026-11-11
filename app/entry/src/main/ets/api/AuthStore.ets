import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { ApiDefaults } from './ApiDefaults';
import { AuthProvider, AuthUser, StoredSession } from './AuthModels';
import { TokenCipher } from './TokenCipher';

export class AuthStore {
  private static readonly STORE_NAME: string = 'auth_session';
  private static readonly KEY_USER_ID: string = 'user_id';
  private static readonly KEY_TOKEN: string = 'token';
  private static readonly KEY_EXPIRES_AT: string = 'expires_at';
  private static readonly KEY_NICKNAME: string = 'nickname';
  private static readonly KEY_GRADE: string = 'grade';
  private static readonly KEY_PROVIDER: string = 'auth_provider';
  private static readonly KEY_SAVED_AT: string = 'saved_at';

  private static context: common.UIAbilityContext | null = null;
  private static session: StoredSession | null = null;
  private static degraded: boolean = false;
  private static keepSignedIn: boolean = true;
  private static recentAccount: string = '';
  private static rememberAccount: boolean = true;

  static getRecentAccount(): string { return AuthStore.recentAccount; }
  static getRememberAccount(): boolean { return AuthStore.rememberAccount; }
  static getKeepSignedIn(): boolean { return AuthStore.keepSignedIn; }
  static setLoginPreferences(account: string, remember: boolean, keep: boolean): void {
    AuthStore.recentAccount = remember ? account.trim() : '';
    AuthStore.rememberAccount = remember;
    AuthStore.keepSignedIn = keep;
    AuthStore.persist();
  }

  static async initialize(context: common.UIAbilityContext): Promise<boolean> {
    AuthStore.context = context;
    try {
      await TokenCipher.initialize();
    } catch (error) {
    }
    AuthStore.degraded = !TokenCipher.isReady();
    return AuthStore.loadFromPreferences(context);
  }

  private static loadFromPreferences(context: common.UIAbilityContext): boolean {
    try {
      const store: preferences.Preferences = preferences.getPreferencesSync(context, {
        name: AuthStore.STORE_NAME
      });
      AuthStore.recentAccount = store.getSync('recent_account', '') as string;
      AuthStore.rememberAccount = store.getSync('remember_account', true) as boolean;
      AuthStore.keepSignedIn = store.getSync('keep_signed_in', true) as boolean;
      const userId: string = store.getSync(AuthStore.KEY_USER_ID, '') as string;
      const storedToken: string = store.getSync(AuthStore.KEY_TOKEN, '') as string;
      if (userId.length === 0 || storedToken.length === 0) {
        AuthStore.session = null;
        return true;
      }
      const token: string = AuthStore.decodeToken(storedToken);
      if (token.length === 0) {
        AuthStore.session = null;
        AuthStore.persist();
        return true;
      }
      AuthStore.session = {
        userId: userId,
        token: token,
        expiresAt: store.getSync(AuthStore.KEY_EXPIRES_AT, '') as string,
        nickname: store.getSync(AuthStore.KEY_NICKNAME, '') as string,
        avatar: store.getSync('avatar', '') as string,
        grade: store.getSync(AuthStore.KEY_GRADE, '') as string,
        authProvider: store.getSync(AuthStore.KEY_PROVIDER, 'local') as AuthProvider,
        savedAt: store.getSync(AuthStore.KEY_SAVED_AT, '') as string
      };
      return true;
    } catch (error) {
      AuthStore.session = null;
      return false;
    }
  }

  static initializeSync(context: common.UIAbilityContext): boolean {
    AuthStore.context = context;
    AuthStore.degraded = !TokenCipher.isReady();
    return AuthStore.loadFromPreferences(context);
  }

  static encryptionDegraded(): boolean {
    return AuthStore.degraded;
  }

  private static decodeToken(stored: string): string {
    if (TokenCipher.isReady() && TokenCipher.looksEncrypted(stored)) {
      const plain: string | null = TokenCipher.decrypt(stored);
      return plain !== null ? plain : '';
    }
    return '';
  }

  private static encodeToken(plain: string): string {
    if (!TokenCipher.isReady()) {
      AuthStore.degraded = true;
      return '';
    }
    const encoded: string | null = TokenCipher.encrypt(plain);
    if (encoded === null) {
      AuthStore.degraded = true;
      return '';
    }
    AuthStore.degraded = false;
    return encoded;
  }

  static getSession(): StoredSession | null {
    return AuthStore.session;
  }

  static getToken(): string {
    return AuthStore.session === null ? '' : AuthStore.session.token;
  }

  static getUserId(): string {
    return AuthStore.session === null ? ApiDefaults.DEMO_USER_ID : AuthStore.session.userId;
  }

  static isSignedIn(): boolean {
    return AuthStore.session !== null;
  }

  static save(user: AuthUser, token: string, expiresAt: string): boolean {
    const session: StoredSession = {
      userId: user.userId,
      token: token,
      expiresAt: expiresAt,
      nickname: user.nickname,
      avatar: user.avatar ?? '',
      grade: user.grade,
      authProvider: user.authProvider,
      savedAt: new Date().toISOString()
    };
    AuthStore.session = session;
    return AuthStore.persist();
  }

  static clear(): boolean {
    AuthStore.session = null;
    return AuthStore.persist();
  }

  private static persist(): boolean {
    const context: common.UIAbilityContext | null = AuthStore.context;
    if (context === null) {
      return true;
    }
    try {
      const store: preferences.Preferences = preferences.getPreferencesSync(context, {
        name: AuthStore.STORE_NAME
      });
      store.putSync('recent_account', AuthStore.recentAccount);
      store.putSync('remember_account', AuthStore.rememberAccount);
      store.putSync('keep_signed_in', AuthStore.keepSignedIn);
      const encodedToken: string = AuthStore.session !== null && AuthStore.keepSignedIn ? AuthStore.encodeToken(AuthStore.session.token) : '';
      if (AuthStore.session !== null && AuthStore.keepSignedIn && encodedToken.length === 0) {
        AuthStore.keepSignedIn = false;
        store.putSync('keep_signed_in', false);
      }
      const session: StoredSession | null = AuthStore.keepSignedIn ? AuthStore.session : null;
      if (session === null) {
        store.deleteSync(AuthStore.KEY_USER_ID);
        store.deleteSync(AuthStore.KEY_TOKEN);
        store.deleteSync(AuthStore.KEY_EXPIRES_AT);
        store.deleteSync(AuthStore.KEY_NICKNAME);
        store.deleteSync('avatar');
        store.deleteSync(AuthStore.KEY_GRADE);
        store.deleteSync(AuthStore.KEY_PROVIDER);
        store.deleteSync(AuthStore.KEY_SAVED_AT);
      } else {
        store.putSync(AuthStore.KEY_USER_ID, session.userId);
        store.putSync(AuthStore.KEY_TOKEN, encodedToken);
        store.putSync(AuthStore.KEY_EXPIRES_AT, session.expiresAt);
        store.putSync(AuthStore.KEY_NICKNAME, session.nickname);
        store.putSync('avatar', session.avatar ?? '');
        store.putSync(AuthStore.KEY_GRADE, session.grade);
        store.putSync(AuthStore.KEY_PROVIDER, session.authProvider);
        store.putSync(AuthStore.KEY_SAVED_AT, session.savedAt);
      }
      store.flushSync();
      return true;
    } catch (error) {
      return false;
    }
  }
}
