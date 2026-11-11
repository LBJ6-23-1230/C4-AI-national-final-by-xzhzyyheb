import base64
import json

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa

from app.services import push_provider


def _decode(segment):
    return base64.urlsafe_b64decode(segment + '=' * (-len(segment) % 4))


def test_push_signs_and_renews_service_account_jwt(tmp_path, monkeypatch):
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                            serialization.NoEncryption()).decode()
    account = dict(project_id='123456', key_id='test-key', sub_account='test-account', private_key=pem)
    credential = tmp_path / 'account.json'
    credential.write_text(json.dumps(account), encoding='utf-8')
    monkeypatch.setattr(push_provider, '_BACKEND_DIR', tmp_path)
    monkeypatch.setenv('HUAWEI_PUSH_SERVICE_ACCOUNT_FILE', 'account.json')
    monkeypatch.delenv('HUAWEI_PUSH_PROJECT_ID', raising=False)
    requests = []

    class Response:
        def __enter__(self):
            return self

        def __exit__(self, *args):
            pass

        def read(self, limit):
            return b'{"code":"80000000","requestId":"test-request"}'

    def urlopen(request, timeout):
        requests.append(request)
        return Response()

    monkeypatch.setattr(push_provider, 'urlopen', urlopen)

    def send():
        assert push_provider.send({}, {'pushToken': 'test-device'},
                                  {'deliveryId': 'test0000001'}) == 'test-request'
        return requests[-1].get_header('Authorization').removeprefix('Bearer ')

    now = 1_800_000_000
    monkeypatch.setattr(push_provider.time, 'time', lambda: now)
    assert push_provider.configured()
    initial = send()
    assert send() == initial
    assert requests[-1].full_url == 'https://push-api.cloud.huawei.com/v3/123456/messages:send'
    header, payload, signature = initial.split('.')
    assert json.loads(_decode(header)) == {'alg': 'PS256', 'typ': 'JWT', 'kid': 'test-key'}
    claims = json.loads(_decode(payload))
    assert claims['iss'] == 'test-account'
    assert claims['aud'] == 'https://oauth-login.cloud.huawei.com/oauth2/v3/token'
    assert claims['iat'] == now and claims['exp'] == now + 3600
    sha256 = hashes.SHA256()
    key.public_key().verify(_decode(signature), f'{header}.{payload}'.encode(),
                            padding.PSS(mgf=padding.MGF1(sha256), salt_length=32), sha256)
    now += 3300
    assert json.loads(_decode(send().split('.')[1]))['iat'] == now
    assert now < claims['exp']
    account['key_id'] = 'test-key-replaced'
    credential.write_text(json.dumps(account), encoding='utf-8')
    assert json.loads(_decode(send().split('.')[0]))['kid'] == 'test-key-replaced'
    monkeypatch.setenv('HUAWEI_PUSH_PROJECT_ID', '654321')
    assert not push_provider.configured()
    monkeypatch.delenv('HUAWEI_PUSH_PROJECT_ID')
    credential.write_text('broken JSON', encoding='utf-8')
    assert not push_provider.configured()
