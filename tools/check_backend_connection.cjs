const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2] || 'typescript');

function compile(file, dependencies) {
  const compiled = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: {module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020}
  });
  const module = {exports: {}};
  vm.runInNewContext(compiled.outputText, {module, exports: module.exports,
    require: name => dependencies[name] || {}, console});
  return module.exports;
}

const root = 'app/entry/src/main/ets/api/';
const resultTypes = compile(root + 'ApiResult.ets', {});
const validator = compile(root + 'ApiResponseValidator.ets', {}).ApiResponseValidator;
const build = {NAME:'development', ALLOW_DEBUG:true, API_URL:'http://127.0.0.1:5000'};
const defaults = compile(root + 'ApiDefaults.ets', {'./BuildEnvironment':{BuildEnvironment:build}}).ApiDefaults;
const sent = [];
let destroyed = 0;
let response = {responseCode:200, result:'{"status":"ready"}'};
let rejectRequest = false;
const transport = {
  RequestMethod:{GET:'GET', POST:'POST', PUT:'PUT', DELETE:'DELETE'},
  HttpDataType:{STRING:'STRING'},
  createHttp() {
    return {
      async request(url, options) {
        sent.push({url, options});
        if (rejectRequest) throw Error('disconnected');
        return response;
      },
      destroy() { destroyed++; }
    };
  }
};
const api = compile(root + 'AgentApiClient.ets', {
  '@kit.NetworkKit':{http:transport}, './ApiDefaults':{ApiDefaults:defaults},
  './ApiResult':resultTypes, './ApiResponseValidator':{ApiResponseValidator:validator},
  './ApiModels':{API_CONTRACT_VERSION:'api-contract-v0.3'},
  './AuthStore':{AuthStore:{getToken:()=>'expired-test-session'}},
  './FixtureApiTransport':{FixtureApiTransport:{request() { throw Error('Must not invent backend health'); }}}
}).AgentApiClient;

let huaweiAuthorizations = 0;
const authClient = compile(root + 'AuthClient.ets', {
  './ApiDefaults': {ApiDefaults: defaults},
  './AgentApiClient': {AgentApiClient: api},
  '../services/HuaweiAccountService': {HuaweiAccountService: {
    async requestAuthorizationCode() {
      huaweiAuthorizations++;
      return {ok:false, message:'授权已取消'};
    }
  }}
}).AuthClient;

(async () => {
  const healthy = await api.checkBackendConnection();
  assert.equal(healthy.ok, true);
  assert.equal(sent[0].url, 'http://127.0.0.1:5000/ready');
  assert.equal(sent[0].options.header.Authorization, undefined);
  assert.equal(sent[0].options.usingCache, false);
  assert.equal(destroyed, 1);
  assert.equal(validator.isValid('GET','/ready',{status:'ready'}), true);
  assert.equal(validator.isValid('GET','/ready',{status:'unavailable'}), false);
  assert.equal(validator.isValid('POST','/ready',{status:'ready'}), false);
  response = {responseCode:503,result:'{"status":"unavailable"}'};
  const unavailable = await api.checkBackendConnection();
  assert.equal(unavailable.ok, false); assert.equal(unavailable.error.statusCode, 503);
  response = {responseCode:200,result:'{"status":"unavailable"}'};
  assert.equal((await api.checkBackendConnection()).error.code, 'INVALID_RESPONSE');
  rejectRequest = true;
  const before = sent.length;
  assert.equal((await api.checkBackendConnection()).error.code, 'NETWORK_ERROR');
  assert.equal(sent.length, before + 1);
  assert.equal(destroyed, sent.length);
  api.configure({...api.getConfig(), useFixture:true});
  assert.equal((await api.checkBackendConnection()).error.code, 'OFFLINE_MODE');
  assert.equal(sent.length, before + 1);
  api.configure({...api.getConfig(), useFixture:false});
  const beforeSubmit = sent.length;
  await api.submitExercise('set', {idempotencyKey:'one',answers:[]});
  assert.equal(sent.length, beforeSubmit + 1);
  assert.equal(sent.at(-1).options.method, 'POST');
  assert.equal(sent.at(-1).options.header.Authorization, 'Bearer expired-test-session');

  assert.equal(api.parseBackendOrigin(' https://api.example.test/ '), 'https://api.example.test');
  assert.equal(api.parseBackendOrigin('https://api.example.test/ready'), '');
  assert.equal(api.parseBackendOrigin('https://api.example.test:99999'), '');
  assert.equal(api.parseBackendOrigin('http://127.0.0.1:5000'), 'http://127.0.0.1:5000');

  const beforeHuawei = sent.length;
  api.configure({...api.getConfig(), baseUrl:'http://192.168.1.2:5000'});
  assert.match((await authClient.loginWithHuaweiAccount({}, () => true)).message, /当前连接无法用于/);
  assert.equal((await api.authLoginWithHuawei({authorizationCode:'test-code'})).error.code, 'HUAWEI_LOGIN_UNAVAILABLE');
  assert.equal(sent.length, beforeHuawei);
  api.configure({...api.getConfig(), baseUrl:'https://api.example.test', useFixture:true});
  assert.match((await authClient.loginWithHuaweiAccount({}, () => true)).message, /离线演示/);
  assert.equal(sent.length, beforeHuawei);
  api.configure({...api.getConfig(), useFixture:false});
  assert.match((await authClient.loginWithHuaweiAccount({}, () => true)).message, /无法连接 HTTPS/);
  rejectRequest = false;
  response = {responseCode:503, result:'{"status":"unavailable"}'};
  assert.match((await authClient.loginWithHuaweiAccount({}, () => true)).message, /未通过就绪检查/);
  response = {responseCode:200, result:'{"status":"ready"}'};
  assert.match((await authClient.loginWithHuaweiAccount({}, () => false)).message, /已中断/);
  assert.equal(huaweiAuthorizations, 0);
  assert.equal((await authClient.loginWithHuaweiAccount({}, () => true)).message, '授权已取消');
  assert.equal(huaweiAuthorizations, 1);
  assert.equal(sent.at(-1).url, 'https://api.example.test/ready');

  const stored = new Map([['base_url', defaults.USB_MISTYPED_HTTPS_URL], ['use_fixture', false]]);
  const environmentStore = compile(root + 'ApiEnvironmentStore.ets', {
    './ApiDefaults':{ApiDefaults:defaults}, './AgentApiClient':{AgentApiClient:api},
    '@kit.ArkData':{preferences:{getPreferencesSync:() => ({
      getSync:(key, fallback) => stored.get(key) ?? fallback,
      putSync:(key, value) => stored.set(key, value),
      flushSync() {}
    })}}
  }).ApiEnvironmentStore;
  assert.equal(environmentStore.restore({}), true);
  assert.equal(stored.get('base_url'), defaults.LOCALHOST_BASE_URL);
  assert.equal((await authClient.loginWithHuaweiAccount({}, () => true)).message, '授权已取消');
  assert.equal(sent.at(-1).url, defaults.LOCALHOST_BASE_URL + '/ready');
  await api.authLoginWithHuawei({authorizationCode:'test-code'});
  assert.equal(sent.at(-1).url, defaults.LOCALHOST_BASE_URL + '/api/v1/auth/login-with-huawei');
  assert.equal(sent.at(-1).options.maxRedirects, 0);
  assert.equal(sent.at(-1).options.usingProxy, false);
  assert.equal(api.getConfig().baseUrl, defaults.LOCALHOST_BASE_URL);
  stored.set('base_url', 'https://api.example.test');
  assert.equal(environmentStore.restore({}), true);
  assert.equal(api.getConfig().baseUrl, 'https://api.example.test');
  for (const name of ['demo', 'production']) {
    const environment = {...build, NAME:name, ALLOW_DEBUG:name !== 'production'};
    const restricted = compile(root + 'ApiDefaults.ets', {'./BuildEnvironment':{BuildEnvironment:environment}}).ApiDefaults;
    assert.equal(restricted.supportsHuaweiLogin(defaults.LOCALHOST_BASE_URL), false);
    assert.equal(restricted.supportsHuaweiLogin('https://api.example.test'), true);
  }

  console.log('PASS real client readiness, invalid sessions, Fixture isolation, cleanup and no duplicate writes');
})().catch(error => { console.error(error); process.exitCode = 1; });
