"""Isolated real HTTP gate. Never loads developer DB/model credentials.

Every API operation is tested for rejection of an invalid bearer. Product scenarios
also check successful payloads against OpenAPI and the actual ArkTS validator.
The report distinguishes positive coverage, negative coverage and exemptions.
"""
from pathlib import Path
from copy import deepcopy
import json, os, re, socket, subprocess, sys, time
from urllib.request import Request, urlopen
from urllib.error import HTTPError

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'.local-work/http-gate-deps'))
from jsonschema import Draft7Validator, RefResolver
SERVER=ROOT/'server/zhixue-agent-server'
OUT=ROOT/'evidence/feedback3-http.json'
ROWS=[]


def nullable(node):
    if isinstance(node,dict):
        result={k:nullable(v) for k,v in node.items() if k!='nullable'}
        return {'anyOf':[result,{'type':'null'}]} if node.get('nullable') else result
    if isinstance(node,list): return [nullable(x) for x in node]
    return node


SPEC=nullable(json.loads((ROOT/'contracts/openapi.json').read_text(encoding='utf-8')))


def operation(method,path):
    path=path.split('?')[0]
    for route,methods in SPEC['paths'].items():
        if re.fullmatch(re.sub(r'\{[^}]+\}',r'[^/]+',route),path):
            return route,methods.get(method.lower())
    return None,None


def call(method,path,body=None,token=None,expected=200,frontend=False):
    headers={'Content-Type':'application/json','X-API-Contract-Version':'api-contract-v0.3'}
    if token: headers['Authorization']='Bearer '+token
    request=Request(BASE+path,data=json.dumps(body).encode() if body is not None else None,method=method,headers=headers)
    try: response=urlopen(request,timeout=25)
    except HTTPError as error: response=error
    raw=response.read(); status=response.code
    parsed=json.loads(raw) if raw else None
    route,op=operation(method,path)
    errors=[]
    if status!=expected: errors.append(f'expected {expected}, got {status}')
    response_spec=(op or {}).get('responses',{}).get(str(status),{})
    if '$ref' in response_spec:
        response_spec=SPEC['components']['responses'][response_spec['$ref'].split('/')[-1]]
    schema=response_spec.get('content',{}).get('application/json',{}).get('schema')
    if schema:
        errors.extend(e.message for e in Draft7Validator(schema,resolver=RefResolver.from_schema(SPEC)).iter_errors(parsed))
    elif op and not (token=='invalid' and status==401):
        errors.append('response schema not declared')
    ROWS.append(dict(method=method,path=path,operation=method+' '+str(route),status=status,ok=not errors,errors=errors,frontend=frontend,body=parsed))
    if errors: print('FAIL',method,path,'; '.join(errors)[:250])
    if status!=expected: raise AssertionError(ROWS[-1]['errors'])
    return parsed


def scenarios():
    a=call('POST','/api/v1/auth/register',dict(phone='13900005501',password='test-password',seedDemoData=True),expected=201,frontend=True)
    b=call('POST','/api/v1/auth/register',dict(phone='13900005502',password='test-password'),expected=201,frontend=True)
    token=a['token']; owner=a['user']['userId']
    call('POST','/api/v1/auth/register',dict(phone='+86 13900005501',password='test-password'),expected=409)
    call('POST','/api/v1/auth/login',dict(phone='13900005501',password='bad-pass'),expected=401)
    call('POST','/api/v1/auth/login',dict(phone='13900005501',password='test-password'),frontend=True)
    call('POST','/api/v1/auth/select-account',{},expected=409)
    call('POST','/api/v1/auth/login-or-register',dict(phone='13900009999',password='test-password'),expected=401)
    call('GET','/api/v1/auth/me',token=token,frontend=True)
    code=call('POST','/api/v1/auth/send-code',dict(phone='13900005503'),frontend=True)['devCode']
    sms=call('POST','/api/v1/auth/verify-code',dict(phone='13900005503',code=code),expected=201,frontend=True)
    assert sms['needsPasswordSetup']
    call('GET','/api/v1/learning-records',token=sms['token'],expected=403)
    call('POST','/api/v1/auth/change-password',dict(newPassword='test-password'),token=sms['token'],frontend=True)
    for path in ['/api/v1/profile/'+owner,'/api/v1/learning-effect','/api/v1/learning-data','/api/v1/learning-course-settings',
                 '/api/v1/learning-review-tasks','/api/v1/wrong-book','/api/v1/focus-sessions',
                 '/api/v1/reminder-preferences','/api/v1/reminder-devices','/api/v1/reminders','/api/v1/learning-records']:
        call('GET',path,token=token,frontend=True)
    p=call('GET','/api/v1/plans/current',token=token,frontend=True)
    for minutes in (30,60,90):
        changed=call('POST','/api/v1/plans/current/availability',dict(availableMinutes=minutes,expectedPlanVersion=p['version'],idempotencyKey='budget-'+str(minutes)),token=token,frontend=True)
        p=changed['plan']
        assert p['budgetSummary']['scheduledMinutes']+p['budgetSummary']['unallocatedMinutes']==minutes
    today=call('GET','/api/v1/today',token=token,frontend=True)
    event=today['highlight']
    if event:
        opened=call('POST','/api/v1/reminders/'+event['eventId']+'/actions',dict(action='open',version=event['version'],idempotencyKey='open'),token=token,frontend=True)
        assert opened['event']['status']==event['status']
        call('POST','/api/v1/reminders/'+event['eventId']+'/actions',dict(action='snooze',minutes=45,version=event['version'],idempotencyKey='snooze'),token=token,frontend=True)
    review=call('POST','/api/v1/learning-reviews',dict(courseName='数据结构'),token=token,frontend=True)
    call('POST','/api/v1/learning-reviews/'+review['reviewId']+'/accept',{},token=token,frontend=True)
    for value in ([],False,0,''):
        call('POST','/api/v1/agent/proactive',value,token=token,expected=400)
    for chat_id in ('chat-a','chat-b'):
        call('POST','/api/agent/chat',dict(message='帮我按薄弱点安排复习并诊断',sessionId=chat_id,coordinateLearning=True),token=token)
    records=call('GET','/api/v1/learning-records?limit=1',token=token,frontend=True)
    assert records['records'] and records['nextCursor']
    call('GET','/api/v1/learning-records?limit=1&cursor='+records['nextCursor'],token=token,frontend=True)
    call('GET','/api/v1/learning-records?chatSessionId=chat-a',token=token,frontend=True)
    assert not call('GET','/api/v1/learning-records',token=b['token'],frontend=True)['records']
    call('GET','/api/v1/learning-records?cursor=!bad',token=token,expected=400)


def main():
    global BASE
    work=ROOT/'.local-work/feedback3-http'; work.mkdir(parents=True,exist_ok=True)
    with socket.socket() as probe: probe.bind(('127.0.0.1',0)); port=probe.getsockname()[1]
    BASE=f'http://127.0.0.1:{port}'
    env=dict(os.environ,PYTHON_DOTENV_DISABLED='1',ZHIXUE_DB='json',DATABASE_URL='',MIGRATION_DATABASE_URL='',DASHSCOPE_API_KEY='',
        ZHIXUE_REPOSITORY=str(work/f'repo-{time.time_ns()}.json'),DEMO_ENABLED='true',ZHIXUE_ENV='development',ZHIXUE_ENABLE_DEV_TOOLS='1',ZHIXUE_QUIET='1',ZHIXUE_CHAT_DIR=str(work/'chat'))
    with (work/'server.log').open('w',encoding='utf-8') as log:
        server=subprocess.Popen([sys.executable,'run.py','--port',str(port),'--quiet'],cwd=SERVER,env=env,stdout=log,stderr=log)
        try:
            for attempt in range(80):
                try:
                    with urlopen(BASE+'/health',timeout=.5): break
                except OSError:
                    if server.poll() is not None: raise RuntimeError('isolated backend failed; inspect .local-work/feedback3-http/server.log')
                    time.sleep(.15)
            else: raise RuntimeError('isolated HTTP listener unavailable')
            # Negative authorization coverage is recorded separately from successful workflows.
            for route,methods in SPEC['paths'].items():
                if not route.startswith('/api/'): continue
                for method in methods:
                    if method not in ('get','post','put','delete','patch'): continue
                    path=re.sub(r'\{[^}]+\}','missing',route)
                    call(method.upper(),path,{} if method in ('post','put','patch') else None,token='invalid',expected=401)
            scenarios()
        finally:
            server.terminate(); server.wait(timeout=10)
            def redact(value):
                if isinstance(value,dict):
                    return {k: '<isolated-test-token>' if k in ('token','devCode') else redact(v) for k,v in value.items()}
                if isinstance(value,list): return [redact(v) for v in value]
                return value
            OUT.write_text(json.dumps(redact(ROWS),ensure_ascii=False,indent=2),encoding='utf-8')
    result=subprocess.run(['node','integration/validate_http_responses.cjs',str(OUT)],cwd=ROOT)
    positive={r['operation'] for r in ROWS if 200<=r['status']<300}
    negative={r['operation'] for r in ROWS if r['status']>=400}
    report=dict(requestCount=len(ROWS),positiveOperations=sorted(positive),negativeOperations=sorted(negative),
        negativeOnlyOperations=sorted(negative-positive),failureCount=sum(not r['ok'] for r in ROWS),
        exemptions=['No model key is loaded; live model probes are recorded separately.',
                    'This isolated HTTP gate does not exercise HarmonyOS UI or distributed device synchronization.'],
        operationExemptions={op: {
            'reason': 'This gate focuses on the changed feedback workflows. Other business scenarios have not yet been ported to independent HTTP fixtures; authorization rejection alone is not business acceptance.',
            'missingScenarios': ['successful business response', 'cross-account ownership', 'invalid parameters', 'repeat request']
        } for op in sorted(negative-positive)})
    (ROOT/'evidence/feedback3-http-coverage.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps({k:v for k,v in report.items() if not isinstance(v,list)}))
    return int(result.returncode!=0 or report['failureCount']!=0)


if __name__=='__main__': raise SystemExit(main())
