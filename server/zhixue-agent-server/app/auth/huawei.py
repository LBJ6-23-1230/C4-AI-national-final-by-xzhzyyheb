"""Exchange a native Account Kit authorization code on the server."""
import os
import json
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

from app.auth.service import AuthError


_TOKEN_URL = "https://oauth-login.cloud.huawei.com/oauth2/v3/token"
_TOKEN_INFO_URL = "https://oauth-api.cloud.huawei.com/rest.php?nsp_fmt=JSON&nsp_svc=huawei.oauth2.user.getTokenInfo"


def _post(url, fields):
    request = Request(url, data=urlencode(fields).encode("ascii"),
                      headers={"Content-Type": "application/x-www-form-urlencoded"})
    with urlopen(request, timeout=7) as response:
        return json.loads(response.read(65536))


def verified_identity(code):
    client_id = os.getenv("HUAWEI_ACCOUNT_CLIENT_ID", "").strip()
    secret = os.getenv("HUAWEI_ACCOUNT_CLIENT_SECRET", "").strip()
    if not client_id or not secret:
        raise AuthError("SERVICE_UNAVAILABLE", "后端尚未配置华为账号服务，请使用手机号和密码登录。", 503)
    if not isinstance(code, str) or not 1 <= len(code.strip()) <= 1024:
        raise AuthError("VALIDATION_ERROR", "缺少有效的华为账号授权码。", 400)

    try:
        payload = _post(_TOKEN_URL, {
            "grant_type": "authorization_code", "code": code.strip(),
            "client_id": client_id, "client_secret": secret,
        })
        access_token = payload.get("access_token") if isinstance(payload, dict) else None
        if not isinstance(access_token, str) or not access_token:
            raise ValueError("Invalid Account Kit token response")

        identity = _post(_TOKEN_INFO_URL, {
            "access_token": access_token, "open_id": "OPENID",
        })
    except HTTPError as error:
        if error.code == 400 and error.url == _TOKEN_URL:
            try:
                details = json.loads(error.read(65536))
            except ValueError:
                details = {}
            if isinstance(details, dict) and str(details.get("sub_error")) in {"20153", "20155", "20156", "20158"}:
                raise AuthError("UNAUTHORIZED", "华为账号授权码无效或已使用，请重新授权。", 401) from error
        raise AuthError("SERVICE_UNAVAILABLE", "暂时无法验证华为账号，请稍后重试。", 503) from error
    except (URLError, TimeoutError, ValueError) as error:
        raise AuthError("SERVICE_UNAVAILABLE", "暂时无法验证华为账号，请稍后重试。", 503) from error
    if not isinstance(identity, dict) or identity.get("error") or str(identity.get("client_id", "")) != client_id:
        raise AuthError("UNAUTHORIZED", "华为账号授权与当前应用不匹配。", 401)
    open_id = identity.get("open_id")
    if not isinstance(open_id, str) or not open_id.strip() or len(open_id) > 256:
        raise AuthError("UNAUTHORIZED", "未能验证华为账号身份，请重新授权。", 401)
    return open_id, identity.get("union_id")
