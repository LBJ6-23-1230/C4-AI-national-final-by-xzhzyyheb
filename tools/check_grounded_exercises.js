/* Run actual ETS exercise ViewModel/cache/validator with deterministic HTTP.
 * This verifies asynchronous state handling, not HarmonyOS device behavior.
 */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2] || 'typescript');
const root = path.resolve(__dirname, '../app/entry/src/main/ets');
const modules = new Map();
const network = {};
const appState = { currentUser: { userId: 'a' } };
function load(file) {
  file = path.resolve(file);
  if (modules.has(file)) return modules.get(file).exports;
  const module = { exports: {} };
  modules.set(file, module);
  if (file.endsWith('api/AgentApiClient.ets') || file.endsWith('api\\AgentApiClient.ets')) {
    module.exports.AgentApiClient = network;
    return module.exports;
  }
  if (file.endsWith('data/AppState.ets') || file.endsWith('data\\AppState.ets')) {
    module.exports.appState = appState;
    return module.exports;
  }
  if (file === path.join(root, 'api/AuthStore.ets')) {
    module.exports.AuthStore = { getToken: () => '' };
    return module.exports;
  }
  const compiled = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText;
  vm.runInThisContext(`(function(require,module,exports){${compiled}\n})`, { filename: file })(
    spec => spec.startsWith('@') ? {} : load(path.resolve(path.dirname(file), spec + '.ets')), module, module.exports);
  return module.exports;
}
const { ExerciseViewModel } = load(path.join(root, 'viewmodels/ExerciseViewModel.ets'));
const { ClientCache } = load(path.join(root, 'cache/ClientCache.ets'));
const { ApiResponseValidator } = load(path.join(root, 'api/ApiResponseValidator.ets'));
const set = (mode = 'general', doc = 'doc-a') => ({ setId: 'set', sourceMode: mode, kbId: 'kb-a',
  documentId: doc, knowledgePointId: 'point', exercises: [{ exerciseId: doc, knowledgePointId: 'point' }] });
const query = { sourceMode: 'materials', kbId: 'kb-a', documentId: 'doc-a', knowledgePointId: 'point', count: 1 };
const failure = { ok: false, error: { message: 'offline' } };
(async () => {
  ClientCache.bindIdentity('a');
  const view = new ExerciseViewModel();
  ClientCache.cacheExerciseSet(set());
  network.getExerciseSet = async () => ({ ok: true, data: set('materials') });
  assert.equal((await view.load('set', false, query)).sourceMode, 'materials');
  // Material requests revalidate availability; neither bank nor stale material
  // cache may mask deletion, offline, or a mismatched server scope.
  network.getExerciseSet = async () => failure;
  assert.equal(await view.load('set', false, query), null);
  network.getExerciseSet = async () => ({ ok: true, data: set('general') });
  assert.equal(await view.load('set', false, query), null);
  network.getExerciseSet = async () => ({ ok: true, data: set('materials', 'other-doc') });
  assert.equal(await view.load('set', true, query), null);
  network.getExerciseSet = async () => ({ ok: true, data: { ...set('materials'), exercises: [],
    generationFailed: true, message: 'insufficient' } });
  assert.equal((await view.load('set', true, query)).generationFailed, true);
  ClientCache.clearDemoData();
  let release;
  network.getExerciseSet = () => new Promise(resolve => { release = resolve; });
  const pending = view.load('set', true, query);
  ClientCache.bindIdentity('b');
  release({ ok: true, data: set('materials') });
  assert.equal(await pending, null);
  assert.equal(ClientCache.getExerciseSet(), null);
  ClientCache.bindIdentity('a');
  const older = view.load('set', true, query);
  const releaseOld = release;
  const newer = view.load('set', true, { ...query, documentId: 'new' });
  release({ ok: true, data: set('materials', 'new') });
  await newer;
  releaseOld({ ok: true, data: set('materials') });
  assert.equal(await older, null);
  assert.equal(ClientCache.getExerciseSet().documentId, 'new');
  ClientCache.clearDemoData();
  network.submitExercise = () => new Promise(resolve => { release = resolve; });
  const submitting = view.submit('set', { idempotencyKey: 'test', answers: [] });
  ClientCache.bindIdentity('b');
  release({ ok: true, data: { needReplan: false, review: [] } });
  assert.equal(await submitting, null);
  assert.equal(ClientCache.getAssessment(), null);
  assert.equal(ApiResponseValidator.isValid('GET', '/api/v1/exercises/q/sources', {
    exerciseId: 'q', sources: [] }), true);
  assert.equal(ApiResponseValidator.isValid('GET', '/api/v1/exercises/q/sources', {
    setId: 'set', exercises: [] }), false);
  // Goal submissions must advance the explicit goal, even when the generic
  // workflow cache still points to another session.
  ClientCache.bindIdentity('a');
  appState.currentUser.userId = 'a';
  ClientCache.cacheWorkflow({ sessionId: 'legacy-other', traceId: 'legacy-trace' });
  let submitted;
  let advanced;
  const goal = { goalId: 'goal-a', sessionId: 'goal-a', traceId: 'trace-goal', assessmentTraceId: '',
    goal: 'learn', stateVersion: 4, status: 'completed', currentAgent: 'finish', waitingFor: '',
    nextAction: 'view plan', decisionSource: 'rules', knowledgePointId: 'point', knowledgePointName: 'point',
    planId: 'plan', profileVersion: 2, planVersion: 2, sourceMode: 'general', kbId: '',
    assessmentStatus: 'assessed', assessedQuestionCount: 1, action: { label: 'view', targetPage: 'pages/StudyPlan' }, handoffs: [] };
  network.submitExercise = async (set, request) => {
    submitted = request;
    return { ok: true, data: { submissionId: 'sub-goal', needReplan: false, review: [] } };
  };
  network.runWorkflow = async (sessionId, request) => {
    advanced = { sessionId, request };
    return { ok: true, data: { sessionId, traceId: 'trace-goal', status: 'completed',
      currentStep: 'finish', currentAgent: 'finish', stateVersion: 4, finalAction: 'done', learningContext: goal } };
  };
  const bound = await view.submit('set', { goalId: 'goal-a', goalStateVersion: 2,
    idempotencyKey: 'goal', answers: [] });
  assert.equal(submitted.goalId, 'goal-a');
  assert.equal(submitted.goalStateVersion, 2);
  assert.equal(submitted.sessionId, 'goal-a');
  assert.equal(advanced.sessionId, 'goal-a');
  assert.equal(bound.learningContext.goalId, 'goal-a');
  assert.equal(ClientCache.getWorkflow().sessionId, 'goal-a');
  advanced = null;
  await view.submit('set', { idempotencyKey: 'ordinary', answers: [] });
  assert.equal(submitted.sessionId, undefined);
  assert.equal(advanced, null, 'Ordinary practice must not consume a cached goal');
  assert.equal(ApiResponseValidator.isValid('GET', '/api/v1/workflows/chat/chat-a', goal), true);
  assert.equal(ApiResponseValidator.isValid('GET', '/api/v1/workflows/chat/chat-a', { ...goal, action: {} }), false);
  const { AgentBridge } = load(path.join(root, 'services/AgentBridge.ets'));
  const parsed = AgentBridge.parseResponse({ reply: 'ok', intent: 'get_suggestion', card: null, learningContext: goal });
  assert.equal(parsed.learningContext.goalId, 'goal-a');
  assert.equal(AgentBridge.parseResponse({ reply: 'ok', intent: 'get_suggestion', card: null,
    learningContext: { ...goal, handoffs: [null] } }).learningContext, undefined);
  appState.chatSessionId = 'stable-chat';
  const body = JSON.parse(AgentBridge.buildRequestBody('learn', '', []));
  assert.equal(body.coordinateLearning, true);
  assert.equal(body.sessionId, 'stable-chat');
  const { TraceViewModel } = load(path.join(root, 'viewmodels/TraceViewModel.ets'));
  network.getTrace = () => new Promise(resolve => { release = resolve; });
  const traceLoading = new TraceViewModel().load('trace-goal', true);
  ClientCache.bindIdentity('b');
  release({ ok: true, data: { traceId: 'trace-goal', events: [] } });
  assert.equal(await traceLoading, null);
  assert.equal(ClientCache.getTrace(), null);
  console.log('PASS: actual ETS exercise modules enforce material scope, fresh retrieval, explicit failures, async request order and account isolation.');
  console.log('PASS: actual ETS goal DTO parsing, chat request, explicit submission binding and trace account isolation.');
})().catch(error => { console.error(error); process.exitCode = 1; });
