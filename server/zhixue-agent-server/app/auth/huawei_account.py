"""Verify native Account Kit authorization codes with Huawei's OAuth APIs."""
from __future__ import annotations

import json
import os
import re
from http.client import HTTPException
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import HTTPRedirectHandler, Request, build_opener

from app.auth.service import AuthError

_TOKEN_URL = "https://oauth-login.cloud.huawei.com/oauth2/v3/token"
_TOKEN_INFO_URL = "https://oauth-api.cloud.huawei.com/rest.php?nsp_fmt=JSON&nsp_svc=huawei.oauth2.user.getTokenInfo"
_INVALID_CODE_ERRORS = {"20152", "20153", "20154", "20155", "20156", "20158"}
_INVALID_TOKEN_ERRORS = {"6", "102", "31204"}
_TIMEOUT_SECONDS = 8
_MAX_RESPONSE_BYTES = 64 * 1024


class _RejectRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


urlopen = build_opener(_RejectRedirects()).open


def _invalid_authorization() -> AuthError:
    return AuthError("AUTH_INVALID", "华为授权无效或已过期，请重新授权", 401)


def _unavailable() -> AuthError:
    return AuthError("SERVICE_UNAVAILABLE", "华为账号登录暂不可用，请稍后重试", 503)


def _exchange_error(payload: dict) -> AuthError:
    if str(payload.get("sub_error")) in _INVALID_CODE_ERRORS or payload.get("error") == "invalid_grant":
        return _invalid_authorization()
    return _unavailable()


def _post_form(url: str, fields: dict[str, str]) -> tuple[dict, str]:
    request = Request(url, data=urlencode(fields).encode("ascii"), method="POST",
                      headers={"Content-Type": "application/x-www-form-urlencoded"})
    try:
        try:
            response = urlopen(request, timeout=_TIMEOUT_SECONDS)
        except HTTPError as error:
            if url != _TOKEN_URL or error.code != 400:
                error.close()
                raise _unavailable() from None
            response = error

        with response:
            body = response.read(_MAX_RESPONSE_BYTES + 1)
            provider_status = response.headers.get("NSP_STATUS", "")
    except (OSError, HTTPException):
        raise _unavailable() from None

    if len(body) > _MAX_RESPONSE_BYTES:
        raise _unavailable()
    try:
        payload = json.loads(body)
    except (ValueError, RecursionError):
        raise _unavailable() from None
    if not isinstance(payload, dict):
        raise _unavailable()
    if isinstance(response, HTTPError):
        raise _exchange_error(payload)
    return payload, provider_status


def verify_authorization_code(authorization_code: str) -> tuple[str, str]:
    """Return the verified app-scoped OpenID and optional UnionID."""
    client_id = os.getenv("HUAWEI_ACCOUNT_CLIENT_ID", "").strip()
    client_secret = os.getenv("HUAWEI_ACCOUNT_CLIENT_SECRET", "").strip()
    if not re.fullmatch(r"[0-9]{1,64}", client_id) or not client_secret:
        raise AuthError("SERVICE_UNAVAILABLE", "后端尚未配置华为账号登录", 503)

    token, _ = _post_form(_TOKEN_URL, {"grant_type": "authorization_code",
                                      "code": authorization_code,
                                      "client_id": client_id, "client_secret": client_secret})
    if "error" in token or "sub_error" in token:
        raise _exchange_error(token)
    access_token = token.get("access_token")
    if not isinstance(access_token, str) or not access_token:
        raise _unavailable()

    identity, provider_status = _post_form(_TOKEN_INFO_URL, {"access_token": access_token, "open_id": "OPENID"})
    if provider_status in _INVALID_TOKEN_ERRORS:
        raise _invalid_authorization()
    if provider_status or "error" in identity:
        raise _unavailable()
    token_type = identity.get("type")
    expires_in = identity.get("expire_in")
    open_id = identity.get("open_id")
    if (identity.get("client_id") != client_id or type(token_type) is not int or token_type != 0
            or type(expires_in) is not int or expires_in <= 0
            or not isinstance(open_id, str) or not re.fullmatch(r"[\x21-\x7e]{1,256}", open_id)):
        raise _invalid_authorization()

    union_id = identity.get("union_id")
    if not isinstance(union_id, str) or not re.fullmatch(r"[\x21-\x7e]{1,256}", union_id):
        union_id = ""
    return open_id, union_id
