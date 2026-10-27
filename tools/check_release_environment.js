/* Execute the actual client environment controls with stale development settings. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2] || 'typescript');

function compile(path, dependencies) {
  const result = ts.transpileModule(fs.readFileSync(path, 'utf8'), {
    compilerOptions: {module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020}
  }).outputText;
  const module = {exports: {}};
  vm.runInNewContext(result, {module, exports: module.exports,
    require: name => dependencies[name] || {}, console});
  return module.exports;
}
const defaults = {DEFAULT_BASE_URL: 'https://api.test-school.cn', DEFAULT_TIMEOUT_MS: 8000,
  DEFAULT_USE_FIXTURE: false, ALLOW_DEBUG: false, ALLOW_DEMO: false};
const api = compile('app/entry/src/main/ets/api/AgentApiClient.ets', {
  './ApiDefaults': {ApiDefaults: defaults},
  './ApiResult': compile('app/entry/src/main/ets/api/ApiResult.ets', {})
}).AgentApiClient;
api.configure({baseUrl: 'http://192.168.1.2:5000', useFixture: true, timeoutMs: 1});
api.setBaseUrl('http://127.0.0.1:5000');
api.setUseFixture(true);
assert.equal(api.getConfig().baseUrl, defaults.DEFAULT_BASE_URL);
assert.equal(api.getConfig().useFixture, false);
let readPreferences = false;
const store = compile('app/entry/src/main/ets/api/ApiEnvironmentStore.ets', {
  './ApiDefaults': {ApiDefaults: defaults}, './AgentApiClient': {AgentApiClient: api},
  '@kit.ArkData': {preferences: {getPreferencesSync() {readPreferences = true; throw Error('must not restore debug settings');}}}
}).ApiEnvironmentStore;
assert.equal(store.restore({}), true);
assert.equal(readPreferences, false);
assert.equal(api.getConfig().useFixture, false);
assert.match(api.parseServerError('', 401).error.message, /登录/);
assert.match(api.parseServerError('', 503).error.message, /维护/);
console.log('PASS production API address lock, stale preference isolation, Fixture prohibition and user-facing errors');
