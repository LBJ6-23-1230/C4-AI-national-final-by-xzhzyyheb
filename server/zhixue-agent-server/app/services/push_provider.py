"""HarmonyOS Push Kit notification adapter; configured deployments supply a rotated JWT.

No credentials means no external sending, never a simulated success.
"""
import json
import os
from pathlib import Path
from urllib.request import Request, urlopen
from urllib.error import HTTPError


class PushFailure(RuntimeError):
    def __init__(self, code):
        super().__init__(code)
        self.code = code


def configured():
    return bool(os.getenv('HUAWEI_PUSH_PROJECT_ID') and os.getenv('HUAWEI_PUSH_JWT_FILE'))


def send(event, device, delivery):
    if not configured():
        raise PushFailure('unconfigured')
    project = os.environ['HUAWEI_PUSH_PROJECT_ID']
    if not project.isdigit():
        raise PushFailure('invalid_project')
    jwt = Path(os.environ['HUAWEI_PUSH_JWT_FILE']).read_text(encoding='utf-8').strip()
    # Keep notification contents minimal; no mastery scores or wrong answers.
    payload = dict(payload=dict(notification=dict(category=os.getenv('HUAWEI_PUSH_CATEGORY', 'MARKETING'),
        title='知学 Mate · 今日事项', body='有一项学习安排需要处理，打开查看。',
        clickAction=dict(actionType=0), foregroundShow=False)),
        target=dict(token=[device['pushToken']]), pushOptions=dict(ttl=300,
        notifyId=int(delivery['deliveryId'][-7:], 16)))
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
