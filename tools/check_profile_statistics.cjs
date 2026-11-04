// Exercise production statistics controllers and the SDK-generated reactive card.
// Run after build: node tools/check_profile_statistics.cjs <typescript/lib/typescript.js>
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2] || 'typescript');
const root = path.resolve(__dirname, '../app/entry/src/main/ets');
const source = fs.readFileSync(path.join(root, 'pages/Index.ets'), 'utf8');
const deferred = () => {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
};
function method(name, text = source) {
  const pattern = new RegExp(`^  (?:private )?(?:async )?${name}\\(`, 'm');
  const start = text.search(pattern);
  assert(start >= 0, `Missing production method: ${name}`);
  let depth = 0;
  for (let i = text.indexOf('{', start); i < text.length; i++) {
    const ch = text[i];
    if (ch === '/' && text[i + 1] === '/') i = text.indexOf('\n', i);
    else if (ch === '/' && text[i + 1] === '*') i = text.indexOf('*/', i + 2) + 1;
    else if ('\'"`'.includes(ch)) {
      while (++i < text.length) {
        if (text[i] === '\\') i++;
        else if (text[i] === ch) break;
      }
    } else if (ch === '{') depth++;
    else if (ch === '}' && --depth === 0) return text.slice(start, i + 1);
  }
  throw Error('Unclosed production method: ' + name);
}
function fixture() {
  const facts = { minutes: 25, streak: 2, progress: 50, pending: ['a', 'b'], completed: new Set() };
  const state = {
    currentUser: { userId: 'alice' }, authNickname: 'Alice', authAvatar: '', courses: [],
    focusSessions: Array.from({ length: 9 }, (_, i) => ({ taskId: String(i) })),
    getPendingDDLs: () => facts.pending,
    getUrgentDDLs: () => facts.pending,
    getPlanProgress: () => facts.progress,
    isTaskCompleted: id => facts.completed.has(id),
    getFocusSummary: () => ({ todayMinutes: facts.minutes, streakDays: facts.streak, recentSessions: state.focusSessions.slice(-7) }),
    syncLearningData: async () => true,
    syncFocusSessions: async () => {}
  };
  const settings = { environment: 'server' };
  const snapshots = new Map([['server:alice', { userId: 'alice', allTasks: [] }]]);
  const store = {
    key: owner => `${settings.environment}:${owner}`,
    read: (_, owner) => snapshots.get(store.key(owner)) || null,
    save: (_, data) => snapshots.set(store.key(data.userId), data)
  };
  const api = { getToday: async () => ({ ok: false }) };
  const context = vm.createContext({ appState: state, Promise, console,
    TodayStore: store, AgentApiClient: api, getContext: () => ({}) });
  vm.runInContext(ts.transpileModule(fs.readFileSync(path.join(root, 'utils/PendingTasks.ets'), 'utf8')
    .replace(/^import[^\n]*\n/gm, '').replace('export class', 'class'),
    { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText, context);
  const names = ['onLearningDataChanged', 'onFocusDataChanged', 'refreshLearningStatistics',
    'onPageShow', 'aboutToAppear', 'onPageHide', 'loadAgentPlan', 'switchTab',
    'updatePendingTaskCount', 'loadPendingTasks'];
  vm.runInContext(ts.transpileModule(`class Page { ${names.map(name => method(name)).join('\n')} }
    globalThis.Page = Page;`, { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText, context);
  const page = new context.Page();
  Object.assign(page, {
    activeTab: 3, isPageActive: true, hasShownOnce: false, refreshKey: 0,
    statisticsRequestVersion: 0, planRequestVersion: 0, workflowRequestVersion: 0, proactiveRequestVersion: 0,
    pendingRequestVersion: 0, pendingOverview: null, pendingOverviewKey: '', pendingTaskCount: -1,
    applyInitialTab() {}, ensurePlan() {}, loadWrongBookCount: async () => {}, loadProactiveDecision: async () => {}
  });
  const courseSource = fs.readFileSync(path.join(root, 'pages/CourseImport.ets'), 'utf8');
  vm.runInContext(ts.transpileModule(`class Course { ${method('syncUrgentCount', courseSource)} }
    globalThis.Course = Course;`, { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText, context);
  const course = new context.Course();
  Object.assign(course, { todoOverview: null, todoOverviewKey: '' });
  return { page, state, facts, api, store, settings, snapshots, course };
}
let checks = 0;
async function check(name, run) { await run(); checks++; console.log('PASS ' + name); }
(async () => {
  await check('first appearance reads local facts before network completion', async () => {
    const { page, state } = fixture();
    const waiting = deferred();
    state.syncLearningData = () => waiting.promise;
    page.loadAgentPlan = async () => {};
    page.aboutToAppear();
    assert.equal(page.planProgress, 50);
    assert.equal(page.todayMinutes, 25);
    assert.equal(page.streakDays, 2);
    assert.equal(page.pendingCount, 2);
    assert.equal(page.focusCount, 9, 'record count must not be capped at the seven-item preview');
    waiting.resolve(true);
  });
  await check('cloud data arriving after the cards are visible refreshes all numbers', async () => {
    const { page, state, facts } = fixture();
    const waiting = deferred();
    state.syncLearningData = () => waiting.promise;
    page.onLearningDataChanged();
    const loading = page.refreshLearningStatistics();
    facts.pending = ['a', 'b', 'c']; facts.minutes = 55; facts.streak = 3;
    state.focusSessions.push({ taskId: 'new' });
    waiting.resolve(true); await loading;
    assert.equal(page.todayMinutes, 55); assert.equal(page.streakDays, 3);
    assert.equal(page.pendingCount, 3); assert.equal(page.focusCount, 10);
  });
  await check('a late plan response refreshes completion without another page event', async () => {
    const { page, facts } = fixture();
    const waiting = deferred();
    page.planViewModel = { load: () => waiting.promise };
    page.onLearningDataChanged();
    const loading = page.loadAgentPlan(true);
    facts.progress = 75;
    waiting.resolve({ plan: { planId: 'current' }, kind: 'ok', errorMessage: '' });
    await loading;
    assert.equal(page.planProgress, 75);
  });
  await check('focus completion also refreshes the pending assignment count', async () => {
    const { page, facts } = fixture(); page.onLearningDataChanged();
    facts.pending = []; facts.progress = 100;
    page.onFocusDataChanged();
    assert.equal(page.pendingCount, 0); assert.equal(page.planProgress, 100);
  });
  await check('offline retries keep existing nonzero statistics', async () => {
    const { page, state } = fixture(); page.onLearningDataChanged();
    state.syncLearningData = async () => false;
    state.syncFocusSessions = async () => { throw Error('offline'); };
    await page.refreshLearningStatistics();
    assert.equal(page.pendingCount, 2); assert.equal(page.todayMinutes, 25);
    assert.equal(page.focusCount, 9); assert.equal(page.planProgress, 50);
  });
  await check('a genuinely empty account clears the previous display to zero', async () => {
    const { page, state, facts } = fixture(); page.onLearningDataChanged();
    facts.pending = []; facts.minutes = 0; facts.streak = 0; facts.progress = 0;
    state.focusSessions = []; state.authNickname = 'Bob'; state.currentUser = { userId: 'bob' };
    page.onLearningDataChanged();
    assert.equal(page.profileNickname, 'Bob');
    for (const key of ['pendingCount', 'todayMinutes', 'streakDays', 'planProgress', 'focusCount'])
      assert.equal(page[key], 0, `${key} must reflect the current account`);
  });
  await check('switching to My refreshes local data and retries both cloud sources', async () => {
    const { page, state } = fixture(); let plans = 0, learning = 0, focus = 0;
    page.activeTab = 1; page.loadAgentPlan = async () => { plans++; };
    state.syncLearningData = async () => { learning++; return true; };
    state.syncFocusSessions = async () => { focus++; };
    page.switchTab(3);
    assert.equal(page.pendingCount, 2); assert.equal(page.todayMinutes, 25);
    assert.equal(plans, 1); assert.equal(learning, 1); assert.equal(focus, 1);
    await Promise.resolve();
  });
  await check('returning from a child refreshes data and recalculates the day totals', async () => {
    const { page, facts } = fixture(); let refreshes = 0;
    page.loadAgentPlan = async () => { refreshes++; };
    page.onPageShow(); assert.equal(refreshes, 0);
    page.onPageHide(); facts.minutes = 0; facts.streak = 2;
    page.onPageShow();
    assert.equal(page.todayMinutes, 0); assert.equal(page.focusCount, 9);
    assert.equal(page.streakDays, 2); assert.equal(refreshes, 1);
  });
  await check('hidden pages and switched accounts ignore late statistics callbacks', async () => {
    for (const action of ['hide', 'switch']) {
      const { page, state } = fixture(); const waiting = deferred();
      state.syncLearningData = () => waiting.promise;
      const loading = page.refreshLearningStatistics();
      let updates = 0; page.onLearningDataChanged = () => { updates++; };
      if (action === 'hide') page.onPageHide(); else state.currentUser = { userId: 'bob' };
      waiting.resolve(true); await loading;
      assert.equal(updates, 0);
    }
  });
  const event = (id, extra = {}) => ({ eventId: id, objectId: id, kind: 'exam', status: 'pending',
    sourceType: 'exam', courseName: '数据结构', knowledgePointId: id, ...extra });
  await check('My and the pending list include four assignments and three reviews once each', async () => {
    const { page, course, facts, snapshots } = fixture();
    facts.pending = ['a', 'b', 'c', 'd'];
    snapshots.set('server:alice', { userId: 'alice', allTasks: [
      event('linked'), event('graph'), event('http', { courseName: '计算机网络' }),
      event('plan-linked', { kind: 'task', sourceType: 'plan', sourceId: 'plan-linked', knowledgePointId: 'linked' }),
      event('ddl-a', { kind: 'task', sourceType: 'ddl', sourceId: 'a' }), event('linked')
    ] });
    page.updatePendingTaskCount(); course.syncUrgentCount();
    assert.equal(page.pendingTaskCount, 7); assert.equal(course.pendingTodoCount, 7);
    assert.equal(course.otherTasks.length, 3);
  });
  await check('completed, ignored and non-task events cannot inflate the count', async () => {
    const { page, course, facts, snapshots } = fixture();
    facts.completed.add('done-local');
    snapshots.set('server:alice', { userId: 'alice', allTasks: [event('review'),
      event('done', { status: 'completed' }), event('ignored', { status: 'ignored' }), event('gap', { kind: 'gap' }),
      event('done-local', { kind: 'task', sourceType: 'plan' }),
      event('other-course', { kind: 'task', sourceType: 'plan', knowledgePointId: 'review', courseName: '另一门课' })] });
    page.updatePendingTaskCount(); course.syncUrgentCount();
    assert.equal(page.pendingTaskCount, 4); assert.equal(course.otherTasks.length, 2);
    facts.completed.add('other-course'); page.updatePendingTaskCount(); course.syncUrgentCount();
    assert.equal(page.pendingTaskCount, 3); assert.equal(course.pendingTodoCount, 3);
  });
  await check('more than twenty tasks are counted and passed to the list without truncation', async () => {
    const { page, course, snapshots } = fixture();
    snapshots.set('server:alice', { userId: 'alice', allTasks: Array.from({ length: 25 }, (_, i) => event(String(i))) });
    page.updatePendingTaskCount(); course.syncUrgentCount();
    assert.equal(page.pendingTaskCount, 27); assert.equal(course.otherTasks.length, 25);
  });
  await check('a delayed pending snapshot updates the counter and stays available offline', async () => {
    const { page, api, course, snapshots } = fixture(); const waiting = deferred();
    snapshots.clear(); page.updatePendingTaskCount(); assert.equal(page.pendingTaskCount, -1);
    api.getToday = () => waiting.promise; const loading = page.loadPendingTasks();
    waiting.resolve({ ok: true, data: { userId: 'alice', allTasks: [event('new')] } }); await loading;
    assert.equal(page.pendingTaskCount, 3); course.syncUrgentCount(); assert.equal(course.pendingTodoCount, 3);
    api.getToday = async () => ({ ok: false }); await page.loadPendingTasks();
    assert.equal(page.pendingTaskCount, 3);
  });
  await check('account and server changes cannot reuse another pending snapshot', async () => {
    for (const action of ['account', 'server', 'hide']) {
      const { page, api, state, settings } = fixture(); const waiting = deferred();
      api.getToday = () => waiting.promise; const loading = page.loadPendingTasks();
      if (action === 'account') state.currentUser = { userId: 'bob' };
      if (action === 'server') settings.environment = 'another-server';
      if (action === 'hide') page.onPageHide();
      waiting.resolve({ ok: true, data: { userId: 'alice', allTasks: [event('private')] } }); await loading;
      page.updatePendingTaskCount();
      assert.equal(page.pendingTaskCount, action === 'hide' ? 2 : -1);
    }
  });
  await check('SDK-generated card propagates changed props into visible Text', async () => {
    const file = path.resolve(root, '../../../build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/components/LearningStatCard.ts');
    assert(fs.existsSync(file), 'Build the HarmonyOS app before running the generated UI regression');
    let observer = null;
    const rendered = [];
    class ReactiveValue {
      constructor(value) { this.value = value; this.subscribers = new Set(); }
      get() { if (observer) this.subscribers.add(observer); return this.value; }
      reset(value) { this.value = value; for (const update of this.subscribers) update(); }
      set(value) { this.reset(value); }
      purgeDependencyOnElmtId() {} aboutToBeDeleted() {}
    }
    class View {
      finalizeConstruction() {} updateDirtyElements() {}
      observeComponentCreation2(update) {
        const render = () => { observer = render; update(1, true); observer = null; };
        render();
      }
    }
    const widget = new Proxy({}, { get: () => () => {} });
    const module = { exports: {} };
    const compiled = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
      compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
    }).outputText;
    vm.runInNewContext(compiled, {
      exports: module.exports, module,
      require: name => name.includes('router') ? { default: {} } : { UiTheme: {} },
      ViewPU: View, SynchedPropertySimpleOneWayPU: ReactiveValue,
      Column: widget, Text: new Proxy({}, { get: (_, key) => key === 'create' ? value => { rendered.push(value); } : () => {} }),
      FontWeight: {}, TextAlign: {}, SubscriberManager: { Get: () => ({ delete() {} }) }
    });
    const card = new module.exports.LearningStatCard(undefined, { value: '0项', label: '待处理' });
    card.initialRender();
    rendered.length = 0;
    card.updateStateVars({ value: '4项', label: '待处理', target: 'pages/CourseImport' });
    assert.equal(card.value, '4项');
    assert(rendered.includes('4项'), 'existing text must change after an asynchronous prop update');
  });
  console.log(`${checks} profile statistics regressions passed.`);
})().catch(error => { console.error(error); process.exitCode = 1; });
