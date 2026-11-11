"""HarmonyOS Push Kit notification adapter with service-account JWT renewal.

No credentials means no external sending, never a simulated success.
"""
import base64
import json
import os
import time
from functools import lru_cache
from pathlib import Path
from urllib.request import Request, urlopen
from urllib.error import HTTPError

from cryptography.exceptions import UnsupportedAlgorithm
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa


_BACKEND_DIR = Path(__file__).resolve().parents[2]
_JWT_AUDIENCE = 'https://oauth-login.cloud.huawei.com/oauth2/v3/token'
_JWT_LIFETIME = 3600
_JWT_REFRESH_WINDOW = 3300


class PushFailure(RuntimeError):
    def __init__(self, code):
        super().__init__(code)
        self.code = code


def _b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode('ascii')


@lru_cache(maxsize=1)
def _service_account_token(path, file_version, refresh_window):
    account = json.loads(path.read_text(encoding='utf-8-sig'))
    if not isinstance(account, dict):
        raise ValueError('Invalid service account')
    project = str(account.get('project_id') or '').strip()
    key_id = str(account.get('key_id') or '').strip()
    issuer = str(account.get('sub_account') or '').strip()
    pem = account.get('private_key')
    if not project.isascii() or not project.isdigit() or not key_id or not issuer or not isinstance(pem, str):
        raise ValueError('Invalid service account')
    key = serialization.load_pem_private_key(pem.replace('\\n', '\n').encode('utf-8'), password=None)
    if not isinstance(key, rsa.RSAPrivateKey):
        raise ValueError('Invalid service account key')
    now = int(time.time())
    header = {'kid': key_id, 'typ': 'JWT', 'alg': 'PS256'}
    claims = {'aud': _JWT_AUDIENCE, 'iss': issuer, 'iat': now, 'exp': now + _JWT_LIFETIME}
    message = '.'.join(_b64url(json.dumps(part, separators=(',', ':')).encode('utf-8'))
                       for part in (header, claims))
    sha256 = hashes.SHA256()
    signature = key.sign(message.encode('ascii'), padding.PSS(mgf=padding.MGF1(sha256),
                         salt_length=sha256.digest_size), sha256)
    return project, f'{message}.{_b64url(signature)}'


def _credentials():
    project = os.getenv('HUAWEI_PUSH_PROJECT_ID', '').strip()
    service_account = os.getenv('HUAWEI_PUSH_SERVICE_ACCOUNT_FILE', '').strip()
    jwt_file = os.getenv('HUAWEI_PUSH_JWT_FILE', '').strip()
    try:
        if service_account:
            path = _BACKEND_DIR / service_account
            stat = path.stat()
            account_project, jwt = _service_account_token(
                path, (stat.st_ino, stat.st_mtime_ns, stat.st_size),
                int(time.time()) // _JWT_REFRESH_WINDOW)
            if not project or project == account_project:
                return account_project, jwt
        elif project.isascii() and project.isdigit() and jwt_file:
            jwt = Path(jwt_file).read_text(encoding='utf-8').strip()
            if jwt:
                return project, jwt
    except (OSError, ValueError, TypeError, UnsupportedAlgorithm):
        pass
    return None


def configured():
    return _credentials() is not None


def send(event, device, delivery):
    credentials = _credentials()
    if not credentials:
        raise PushFailure('unconfigured')
    project, jwt = credentials
    options = dict(ttl=300, notifyId=int(delivery['deliveryId'][-7:], 16))
    if os.getenv('HUAWEI_PUSH_TEST_MESSAGE', '').strip() == '1':
        options['testMessage'] = True
    payload = dict(payload=dict(notification=dict(category=os.getenv('HUAWEI_PUSH_CATEGORY', 'MARKETING'),
        title='知学 Mate · 今日事项', body='有一项学习安排需要处理，打开查看。',
        clickAction=dict(actionType=0), foregroundShow=False)),
        target=dict(token=[device['pushToken']]), pushOptions=options)
    req = Request(f'https://push-api.cloud.huawei.com/v3/{project}/messages:send',
        data=json.dumps(payload).encode(), headers={'Content-Type': 'application/json',
        'Authorization': 'Bearer ' + jwt, 'push-type': '0'}, method='POST')
    try:
        with urlopen(req, timeout=15) as response:
            result = json.loads(response.read(65536))
    except HTTPError as error:
        raise PushFailure('authentication_failed' if error.code in (401, 403) else 'provider_http_error') from None
    if str(result.get('code')) not in ('80000000', '0'):
        raise PushFailure('provider_rejected')
    return str(result.get('requestId') or result.get('msg') or 'accepted')[:200]
