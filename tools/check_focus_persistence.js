const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2] || 'typescript');
const root = path.resolve(__dirname, '../app/entry/src/main/ets');
const disk = new Map();
const network = { owner: 'a', online: false, submit: null, uploads: [] };
network.loadPlan = null;
network.updateBudget = null;
let failWrite = false;

function runtime() {
  const modules = new Map();
  const storage = new Map();
  const context = vm.createContext({ console, Date, JSON, Map, Set, Promise,
    AppStorage: { setOrCreate: (k, v) => storage.set(k, v), get: k => storage.get(k) } });
  function load(file) {
    file = path.resolve(file);
    if (modules.has(file)) return modules.get(file).exports;
    const module = { exports: {} };
    modules.set(file, module);
    if (file === path.join(root, 'api/AgentApiClient.ets')) {
      module.exports.AgentApiClient = {
        getConfig: () => ({ useFixture: false }),
        getLearningData: async () => ({ ok: false, error: { statusCode: 0, message: 'offline test' } }),
        getCurrentPlan: async () => network.loadPlan(),
        updatePlanBudget: async request => network.updateBudget(request),
        getFocusHistory: async () => network.online
          ? { ok: true, data: { userId: network.owner, sessions: [] } }
          : { ok: false },
        saveFocusSession: async session => {
          const owner = network.owner;
          if (network.submit) return network.submit(session, owner);
          if (!network.online) return { ok: false };
          network.uploads.push({ owner, taskId: session.taskId });
          return { ok: true, data: { userId: owner, eventId: session.taskId, planTaskMatched: false } };
        }
      };
      return module.exports;
    }
    const compiled = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
    }).outputText;
    const wrapped = vm.runInContext(`(function(require,module,exports){${compiled}\n})`, context,
      { filename: file });
    wrapped(spec => {
      if (spec === '@kit.ArkData') return { preferences: { getPreferencesSync: () => ({
        getSync: (k, fallback) => disk.has(k) ? disk.get(k) : fallback,
        putSync: (k, v) => { if (failWrite) throw Error('storage failure'); disk.set(k, v); },
        flushSync: () => {}
      }) } };
      if (spec.startsWith('@')) return {};
      return load(path.resolve(path.dirname(file), spec + '.ets'));
    }, module, module.exports);
    return module.exports;
  }
  const store = load(path.join(root, 'cache/LearningDataStore.ets')).LearningDataStore;
  store.initialize({});
  const state = load(path.join(root, 'data/AppState.ets')).appState;
  const clock = load(path.join(root, 'utils/FocusClock.ets')).FocusClock;
  const plans = new (load(path.join(root, 'viewmodels/PlanViewModel.ets')).PlanViewModel)();
  const cache = load(path.join(root, 'cache/ClientCache.ets')).ClientCache;
  return { state, store, clock, plans, cache };
}

const user = id => ({ userId: id, nickname: id, grade: '', major: '' });
const fact = id => ({ taskId: id, planTaskId: 'plan-task', course: 'course', task: 'study',
  plannedMinutes: 30, actualMinutes: 20, pauseCount: 0, interruptionCount: 0,
  completionRate: 100, selfAssessment: 'completed', status: 'completed',
  timerType: 'countdown', endedAt: new Date().toISOString() });
const settle = () => new Promise(resolve => setImmediate(resolve));

(async () => {
  let { state, store } = runtime();
  store.save('a', { courses: [], homeworkDDLs: [], isDataImported: false });
  state.applyLogin(user('a'), 'restored');
  await settle();
  assert.equal(state.focusSessions.length, 0);
  const first = fact('first');
  assert.equal(state.saveFocusSession(first), 'saved');
  assert.equal(state.saveFocusSession(first), 'duplicate');
  assert.equal(store.load('a').pendingFocusSessions.length, 1);
  await state.syncFocusSessions();
  assert.equal(store.load('a').pendingFocusSessions.length, 1);

  ({ state, store } = runtime());
  state.applyLogin(user('a'), 'restored');
  await settle();
  assert.equal(state.focusSessions[0].taskId, 'first');
  assert.equal(state.isTaskCompleted('plan-task', 'pending'), true);
  failWrite = true;
  assert.equal(state.saveFocusSession(fact('failed')), 'failed');
  assert.equal(state.focusSessions.length, 1);
  failWrite = false;
  network.owner = 'b';
  state.applyLogin(user('b'), 'restored');
  await settle();
  assert.equal(state.focusSessions.length, 0);
  assert.equal(state.isTaskCompleted('plan-task', 'pending'), false);
  assert.equal(store.load('a').pendingFocusSessions.length, 1);

  network.owner = 'a';
  network.online = true;
  state.applyLogin(user('a'), 'restored');
  await settle();
  assert.equal(store.load('a').pendingFocusSessions.length, 0);
  assert.equal(network.uploads.length, 1);
  await state.syncFocusSessions();
  assert.equal(network.uploads.length, 1);

  const late = fact('late');
  assert.equal(state.saveFocusSession(late), 'saved');
  let release;
  network.submit = (_session, owner) => new Promise(resolve => {
    release = () => resolve({ ok: true, data: { userId: owner, eventId: 'late' } });
  });
  const pending = state.syncFocusSessions();
  network.owner = 'b';
  state.applyLogin(user('b'), 'restored');
  release();
  await pending;
  await settle();
  assert.equal(state.focusSessions.length, 0);
  assert.equal(store.load('a').pendingFocusSessions.length, 1);
  assert.equal((store.load('b').focusSessions || []).length, 0);
  network.submit = null;
  network.online = false;
  network.owner = 'a';
  state.applyLogin(user('a'), 'restored');
  await settle();
  assert.equal(state.focusSessions.length, 2);
  assert.equal(store.load('a').pendingFocusSessions.length, 1);
  const task = { course: 'course', task: 'recoverable', plannedMinutes: 30,
    source: 'manual', mode: 'normal', timerType: 'countdown', planTaskId: 'recovery-task' };
  assert.equal(state.beginFocusRuntime(task), true);
  assert.equal(state.beginFocusRuntime(task), false);
  const savedClock = state.focusRuntime;
  const clock = runtime().clock;
  const advanced = clock.advance(savedClock, savedClock.lastUpdatedAt + 60000);
  assert.equal(advanced.elapsedMs, 60000);
  advanced.paused = true;
  advanced.pauseCount = 1;
  assert.equal(state.checkpointFocusRuntime(advanced), true);
  ({ state, store } = runtime());
  state.applyLogin(user('a'), 'restored');
  await settle();
  assert.equal(state.focusRuntime.sessionId, savedClock.sessionId);
  assert.equal(state.focusRuntime.paused, true);
  assert.equal(clock.advance(state.focusRuntime, advanced.lastUpdatedAt + 3600000).elapsedMs, 60000);
  assert.equal(clock.advance(savedClock, savedClock.lastUpdatedAt + 3600000).elapsedMs, 1800000);
  assert.equal(clock.advance(savedClock, savedClock.lastUpdatedAt + 3600000).finishedAt,
    savedClock.lastUpdatedAt + 1800000);
  assert.equal(clock.advance(savedClock, savedClock.lastUpdatedAt - 1000).elapsedMs, 0);
  const departing = clock.pauseOnDeparture(savedClock, savedClock.lastUpdatedAt + 120000);
  assert.equal(departing.elapsedMs, 120000);
  assert.equal(departing.paused, true);
  assert.equal(departing.autoPaused, true);
  assert.equal(clock.advance(departing, departing.lastUpdatedAt + 3600000).elapsedMs, 120000);
  assert.equal(clock.pauseOnDeparture(departing).pauseCount, departing.pauseCount);

  const running = clock.advance(savedClock, savedClock.lastUpdatedAt + 90000);
  assert.equal(state.checkpointFocusRuntime(running), true);
  ({ state, store } = runtime());
  state.applyLogin(user('a'), 'restored');
  await settle();
  assert.equal(state.focusRuntime.paused, true);
  assert.equal(state.focusRuntime.autoPaused, true);
  assert.equal(state.focusRuntime.elapsedMs, 90000);
  assert.equal(clock.advance(state.focusRuntime, Date.now() + 3600000).elapsedMs, 90000);
  const pausedCount = state.focusRuntime.pauseCount;
  assert.equal(state.pauseFocusOnDeparture(), true);
  assert.equal(state.focusRuntime.pauseCount, pausedCount);
  const resumed = {...state.focusRuntime, paused: false, autoPaused: false, lastUpdatedAt: Date.now()};
  assert.equal(state.checkpointFocusRuntime(resumed), true);
  failWrite = true;
  assert.equal(state.handleFocusDeparture('background'), false);
  assert.equal(state.focusRuntime.paused, true);
  assert.equal(clock.advance(state.focusRuntime, Date.now() + 3600000).elapsedMs, state.focusRuntime.elapsedMs);
  failWrite = false;
  assert.equal(state.handleFocusDeparture('background'), true);
  assert.equal(store.load('a').focusRuntime.paused, true);
  const checkpoint = state.checkpointFocusRuntime;
  const currentRuntime = state.focusRuntime;
  state.checkpointFocusRuntime = () => { state.focusRuntime = null; return false; };
  assert.equal(state.handleFocusDeparture('background'), false);
  assert.equal(state.focusRuntime, null);
  state.checkpointFocusRuntime = checkpoint;
  state.focusRuntime = currentRuntime;
  const screenRuntime = {...currentRuntime, task: {...task, allowBackgroundTiming: false}, paused: false,
    autoPaused: false, backgroundReason: 'screenOff', elapsedMs: 120000, lastUpdatedAt: Date.now() - 60000};
  assert.equal(state.checkpointFocusRuntime(screenRuntime), true);
  ({ state, store } = runtime()); state.applyLogin(user('a'), 'restored'); await settle();
  assert.equal(state.focusRuntime.paused, false);
  assert.equal(state.focusRuntime.backgroundReason, 'screenOff');
  assert(clock.advance(state.focusRuntime).elapsedMs >= 180000);
  assert.equal(state.handleFocusDeparture('background'), true);
  assert.equal(state.focusRuntime.paused, true);
  assert.equal(state.focusRuntime.backgroundReason, undefined);

  const backgroundRuntime = {...screenRuntime, task: {...task, allowBackgroundTiming: true}, backgroundReason: 'background'};
  assert.equal(state.checkpointFocusRuntime(backgroundRuntime), true);
  ({ state, store } = runtime()); state.applyLogin(user('a'), 'restored'); await settle();
  assert.equal(state.focusRuntime.task.allowBackgroundTiming, true);
  assert.equal(state.focusRuntime.paused, false);
  assert(clock.advance(state.focusRuntime).elapsedMs >= 180000);
  const manuallyPaused = clock.pauseOnDeparture(state.focusRuntime);
  manuallyPaused.autoPaused = false;
  assert.equal(state.checkpointFocusRuntime(manuallyPaused), true);
  ({ state, store } = runtime()); state.applyLogin(user('a'), 'restored'); await settle();
  assert.equal(state.focusRuntime.paused, true);
  assert.equal(state.focusRuntime.autoPaused, false);
  network.owner = 'b';
  state.applyLogin(user('b'), 'restored');
  await settle();
  assert.equal(state.focusRuntime, null);
  assert.equal(store.load('a').focusRuntime.sessionId, savedClock.sessionId);
  network.owner = 'a';
  state.applyLogin(user('a'), 'restored');
  await settle();
  const draft = { ...fact(savedClock.sessionId), selfAssessment: 'partial', completionRate: 50 };
  failWrite = true;
  assert.equal(state.setFocusResultDraft(draft), false);
  assert.equal(state.focusRuntime.sessionId, savedClock.sessionId);
  failWrite = false;
  assert.equal(state.setFocusResultDraft(draft), true);
  assert.equal(state.focusRuntime, null);
  ({ state, store } = runtime());
  state.applyLogin(user('a'), 'restored');
  await settle();
  assert.equal(state.focusResultDraft.taskId, savedClock.sessionId);
  assert.equal(state.focusResultDraft.selfAssessment, 'partial');
  assert.equal(state.beginFocusRuntime(task), false);
  assert.equal(state.saveFocusSession(state.focusResultDraft), 'saved');
  ({ state, store } = runtime());
  state.applyLogin(user('a'), 'restored');
  await settle();
  assert.equal(state.focusResultDraft, null);
  assert.equal(state.saveFocusSession(draft), 'duplicate');
  assert.equal(state.beginFocusRuntime(task), true);
  failWrite = true;
  assert.equal(state.discardFocusRecovery(), false);
  assert.notEqual(state.focusRuntime, null);
  failWrite = false;
  assert.equal(state.discardFocusRecovery(), true);
  assert.equal(store.load('a').focusRuntime, undefined);
  const planRuntime = runtime();
  const view = planRuntime.plans;
  const cache = planRuntime.cache;
  cache.bindIdentity('a');
  const plan = version => ({ planId: 'plan-a', version, tasks: [], generatedFromProfileVersion: 1 });
  let releasePlan;
  network.loadPlan = () => new Promise(resolve => { releasePlan = resolve; });
  const loading = view.load(true);
  cache.bindIdentity('b');
  releasePlan({ ok: true, data: plan(1) });
  assert.equal((await loading).plan, null);
  assert.equal(cache.getCurrentPlan(), null);
  cache.bindIdentity('a');
  cache.cacheCurrentPlan(plan(3));
  network.loadPlan = async () => ({ ok: true, data: plan(2) });
  assert.equal((await view.load(true)).plan.version, 3);
  assert.equal(cache.getCurrentPlan().version, 3);
  network.updateBudget = async () => ({ ok: true, data: { plan: plan(2) } });
  assert.equal((await view.updateBudget({ availableMinutes: 30, expectedPlanVersion: 1, idempotencyKey: 'old' })).ok, false);
  assert.equal(cache.getCurrentPlan().version, 3);
  let releaseBudget;
  network.updateBudget = () => new Promise(resolve => { releaseBudget = resolve; });
  const changing = view.updateBudget({ availableMinutes: 30, expectedPlanVersion: 3, idempotencyKey: 'change' });
  cache.bindIdentity('b');
  releaseBudget({ ok: true, data: { plan: plan(4) } });
  assert.equal((await changing).ok, false);
  assert.equal(cache.getCurrentPlan(), null);
  console.log('PASS: real ETS state/store modules cover legacy data, restart, deduplication, write failure, offline queue, sync acknowledgement and account switching.');
  console.log('PASS: active timer ID, pause facts, elapsed-time cap, unsaved draft, failure rollback and recovery account isolation.');
  console.log('PASS: real plan ViewModel rejects late results for another account and older plan versions.');
})().catch(error => { console.error(error); process.exitCode = 1; });
