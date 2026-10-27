import { AuthProfileUpdateRequest, AuthUserResponse } from '../api/AuthModels';
import { ApiFailure, ApiResult, apiFailure } from '../api/ApiResult';

export interface AccountProfileTransport {
  write: () => Promise<ApiResult<AuthUserResponse>>;
  read: () => Promise<ApiResult<AuthUserResponse>>;
  isCurrent: () => boolean;
}

/** PUT is idempotent. Recover a lost response without asking the user to save again. */
export class AccountProfileSaver {
  private static retryable(result: ApiResult<AuthUserResponse>): boolean {
    if (result.ok) return false;
    const failure = result as ApiFailure;
    return failure.error.code === 'NETWORK_ERROR' ||
      [408, 502, 503, 504].indexOf(failure.error.statusCode) >= 0;
  }

  private static changedAccount(): ApiFailure {
    return apiFailure('ACCOUNT_CHANGED', '账号已切换，请重新进入编辑资料。', false, 'network');
  }

  private static validateOwner(result: ApiResult<AuthUserResponse>, owner: string): ApiResult<AuthUserResponse> {
    if (result.ok && result.data.user.userId !== owner) return AccountProfileSaver.changedAccount();
    return result;
  }

  static async save(request: AuthProfileUpdateRequest, owner: string,
    transport: AccountProfileTransport): Promise<ApiResult<AuthUserResponse>> {
    if (!transport.isCurrent()) return AccountProfileSaver.changedAccount();
    const first = await transport.write();
    if (!transport.isCurrent()) return AccountProfileSaver.changedAccount();
    if (!AccountProfileSaver.retryable(first)) return AccountProfileSaver.validateOwner(first, owner);

    // A timed-out PUT may already be durable; read it before deciding to write again.
    const confirmed = await transport.read();
    if (!transport.isCurrent()) return AccountProfileSaver.changedAccount();
    if (confirmed.ok) {
      if (confirmed.data.user.userId !== owner) return AccountProfileSaver.changedAccount();
      if (confirmed.data.user.nickname === request.nickname && (confirmed.data.user.avatar ?? '') === request.avatar) {
        return confirmed;
      }
    } else if (!AccountProfileSaver.retryable(confirmed)) {
      return confirmed;
    }

    const retried = await transport.write();
    if (!transport.isCurrent()) return AccountProfileSaver.changedAccount();
    return AccountProfileSaver.validateOwner(retried, owner);
  }
}
