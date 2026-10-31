/* Execute AuthStore against a persistent preferences substitute. No device UI. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2] || 'typescript');
const data = new Map();
const prefs = { getSync: (k, fallback) => data.has(k) ? data.get(k) : fallback,
  putSync: (k, v) => data.set(k, v), deleteSync: k => data.delete(k), flushSync() {} };
const source = ts.transpileModule(fs.readFileSync('app/entry/src/main/ets/api/AuthStore.ets', 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText;
function load(ready = true, encryptFails = false) {
  const module = { exports: {} };
  const requireMock = name => {
    if (name === '@kit.ArkData') return { preferences: { getPreferencesSync: () => prefs } };
    if (name === './ApiDefaults') return { ApiDefaults: { DEMO_USER_ID: 'demo-user' } };
    if (name === './TokenCipher') return { TokenCipher: { isReady: () => ready,
      encrypt: value => encryptFails ? null : 'encrypted:' + value, looksEncrypted: value => value.startsWith('encrypted:'),
      decrypt: value => value.slice(10) } };
    throw new Error('Unexpected import: ' + name);
  };
  vm.runInNewContext(source, { require: requireMock, exports: module.exports, module, Date });
  return module.exports.AuthStore;
}
const user = { userId: 'alice', nickname: '同学', grade: '大二', authProvider: 'local' };
let store = load();
store.initializeSync({});
store.setLoginPreferences('13900000000', true, false);
store.save(user, 'test-token', '2030-01-01');
assert.equal(store.getToken(), 'test-token');
assert.equal(data.has('token'), false, 'session-only login must not persist a credential');
store = load();
store.initializeSync({});
assert.equal(store.getSession(), null);
assert.equal(store.getRecentAccount(), '13900000000');
assert.equal(store.getKeepSignedIn(), false);
store.setLoginPreferences('13900000000', true, true);
store.save(user, 'test-token', '2030-01-01');
assert.equal(data.get('token'), 'encrypted:test-token');
store = load();
store.initializeSync({});
assert.equal(store.getToken(), 'test-token');
store.clear();
assert.equal(store.getSession(), null);
assert.equal(data.has('token'), false);
assert.equal(store.getRecentAccount(), '13900000000', 'logout preserves only explicitly remembered account');
store.setLoginPreferences('13900000000', false, false);
store = load();
store.initializeSync({});
assert.equal(store.getRecentAccount(), '');
assert.equal(store.getRememberAccount(), false);
console.log('PASS AuthStore: account memory, session-only login, encrypted persistent login, logout, opt-out');
for (const [ready, failure] of [[false, false], [true, true]]) {
  store = load(ready, failure); store.initializeSync({});
  store.setLoginPreferences('13900000000', true, true);
  store.save(user, 'must-stay-in-memory', '2030-01-01');
  assert.equal(store.getToken(), 'must-stay-in-memory');
  assert.equal(data.has('token'), false);
  assert.equal(store.encryptionDegraded(), true);
  assert.equal(store.getKeepSignedIn(), false);
}
data.set('user_id', 'alice'); data.set('token', 'legacy-plaintext');
store = load(); store.initializeSync({});
assert.equal(store.getSession(), null);
assert.equal(data.has('token'), false);
console.log('PASS unavailable encryption, encryption failure and legacy plaintext never persist a token.');
