/* Execute the actual workflow ViewModel/cache with deferred API responses. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2] || 'typescript');
const root = path.resolve(__dirname, '../app/entry/src/main/ets');
const network = {};
const appState = { currentUser: { userId: 'a', learningGoal: { goal: 'learn' } } };
const modules = new Map();
function load(file) {
  file = path.resolve(file);
  if (modules.has(file)) return modules.get(file).exports;
  const module = { exports: {} };
  modules.set(file, module);
  if (file === path.join(root, 'api/AgentApiClient.ets')) module.exports.AgentApiClient = network;
  else if (file === path.join(root, 'data/AppState.ets')) module.exports.appState = appState;
  else {
    const compiled = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
    }).outputText;
    vm.runInThisContext(`(function(require,module,exports){${compiled}\n})`, { filename: file })(
      spec => load(path.resolve(path.dirname(file), spec + '.ets')), module, module.exports);
  }
  return module.exports;
}
const { WorkflowViewModel } = load(path.join(root, 'viewmodels/WorkflowViewModel.ets'));
const { ClientCache } = load(path.join(root, 'cache/ClientCache.ets'));
const deferred = () => {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
};
const ok = data => ({ ok: true, data });
const workflow = sessionId => ({ sessionId, traceId: sessionId, status: 'running' });
const status = version => ({ status: 'running', currentAgent: 'exercise', stateVersion: version, finalAction: null });
let count = 0;
async function check(name, run) {
  ClientCache.bindIdentity('a');
  ClientCache.clearDemoData();
  appState.currentUser = { userId: 'a', learningGoal: { goal: 'learn' } };
  ClientCache.cacheWorkflow(workflow('old'));
  await run();
  console.log('PASS ' + name);
  count++;
}
(async () => {
  await check('late status cannot enter another account cache', async () => {
    const pending = deferred();
    network.getWorkflow = () => pending.promise;
    const reading = new WorkflowViewModel().refreshStatus(true);
    ClientCache.bindIdentity('b');
    ClientCache.cacheWorkflow(workflow('b'));
    pending.resolve(ok(status(9)));
    assert.equal(await reading, null);
    assert.equal(ClientCache.getWorkflowStatus(), null);
    assert.equal(ClientCache.getWorkflow().sessionId, 'b');
  });
  await check('older status cannot overwrite a newer refresh', async () => {
    const first = deferred(), second = deferred();
    const model = new WorkflowViewModel();
    network.getWorkflow = () => first.promise;
    const reading = model.refreshStatus(true);
    network.getWorkflow = () => second.promise;
    const latest = model.refreshStatus(true);
    second.resolve(ok(status(4)));
    await latest;
    first.resolve(ok(status(2)));
    assert.equal(await reading, null);
    assert.equal(ClientCache.getWorkflowStatus().stateVersion, 4);
  });
  await check('old missing-session response cannot delete newer workflow', async () => {
    const pending = deferred();
    let creates = 0;
    network.getWorkflow = () => pending.promise;
    network.createWorkflow = async () => { creates++; return ok(workflow('rebuilt')); };
    const reading = new WorkflowViewModel().refreshStatus(true);
    ClientCache.cacheWorkflow(workflow('new'));
    pending.resolve({ ok: false, error: { statusCode: 404, message: 'missing' } });
    assert.equal(await reading, null);
    assert.equal(creates, 0);
    assert.equal(ClientCache.getWorkflow().sessionId, 'new');
  });
  await check('workflow start cannot cross an account change', async () => {
    const pending = deferred();
    network.createWorkflow = () => pending.promise;
    const starting = new WorkflowViewModel().start('learn', 'a');
    ClientCache.bindIdentity('b');
    pending.resolve(ok(workflow('a-private')));
    assert.equal(await starting, null);
    assert.equal(ClientCache.getWorkflow(), null);
  });
  await check('workflow loop stops after account change', async () => {
    const pending = deferred();
    let calls = 0;
    network.runWorkflow = () => { calls++; return pending.promise; };
    const running = new WorkflowViewModel().runUntilComplete(5);
    ClientCache.bindIdentity('b');
    pending.resolve(ok(status(2)));
    assert.equal(await running, null);
    assert.equal(calls, 1);
    assert.equal(ClientCache.getWorkflowStatus(), null);
  });
  await check('missing-session rebuild cannot replace a later chosen workflow', async () => {
    const pending = deferred();
    network.getWorkflow = async () => ({ ok: false, error: { statusCode: 404 } });
    network.createWorkflow = () => pending.promise;
    const reading = new WorkflowViewModel().refreshStatus(true);
    await new Promise(done => setImmediate(done));
    ClientCache.cacheWorkflow(workflow('chosen'));
    pending.resolve(ok(workflow('rebuilt')));
    assert.equal(await reading, null);
    assert.equal(ClientCache.getWorkflow().sessionId, 'chosen');
  });
  console.log(`${count} actual workflow isolation checks passed.`);
})().catch(error => { console.error(error); process.exitCode = 1; });
