const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2] || 'typescript');
const source = fs.readFileSync('app/entry/src/main/ets/pages/FocusSetup.ets', 'utf8');
const start = source.indexOf('  private courseAssignments(');
const end = source.indexOf('  /**', source.indexOf('  private selectTask(', start));
const durationStart = source.indexOf('  private durationKey(');
const durationEnd = source.indexOf('  private selectCountdown(', durationStart);
assert(start >= 0 && end > start && durationStart > end);
const state = { currentUser: { userId: 'alice' }, homeworkDDLs: [], isTaskCompleted: () => false, notifyLearningDataChanged() {} };
const cache = { cacheProfile() {}, invalidateProfile() {} };
const api = {};
const context = vm.createContext({ appState: state, ClientCache: cache, AgentApiClient: api });
vm.runInContext(ts.transpileModule('class Setup {' + source.slice(start, end) + source.slice(durationStart, durationEnd) +
  '} globalThis.Setup = Setup;', { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText, context);
function page() {
  const instance = new context.Setup();
  Object.assign(instance, { active: true, course: 'Math', task: '', planTaskId: undefined, planTasks: [],
    knowledgePoints: [], newPointOpen: false, newPointName: '', newPointCourse: '', newPointError: '',
    savingPoint: false, pointRequestVersion: 0, minutes: 30, selectedDuration: '30', timerType: 'countdown', source: 'manual' });
  return instance;
}
const point = { knowledgePointId: 'manual-1', knowledgePointName: 'Integrals', sourceCourse: 'Math', classificationRequired: false };
function deferred() {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
}
(async () => {
  let setup = page();
  setup.planTasks = [{ taskId: 'plan-1', sourceCourse: 'Math', knowledgePointName: 'Algebra', durationMinutes: 45, source: 'plan' }];
  setup.knowledgePoints = [point, { ...point, knowledgePointId: 'same', knowledgePointName: 'Algebra' },
    { ...point, knowledgePointId: 'other', sourceCourse: 'Networks' }];
  assert.deepEqual(Array.from(setup.taskChoices(), choice => choice.title), ['Algebra', 'Integrals']);
  setup.selectTaskChoice(0);
  assert.equal(setup.planTaskId, 'plan-1');
  assert.equal(setup.minutes, 45);
  setup.selectTaskChoice(1);
  assert.equal(setup.task, 'Integrals');
  assert.equal(setup.planTaskId, undefined);
  assert.equal(setup.minutes, 45);
  const originalTask = setup.task;
  setup.selectTaskChoice(setup.taskChoices().length);
  assert.equal(setup.newPointOpen, true);
  assert.equal(setup.newPointCourse, 'Math');
  setup.newPointOpen = false;
  assert.equal(setup.task, originalTask);
  setup.selectCourse('Networks');
  assert.equal(setup.task, '');
  assert.equal(setup.planTaskId, undefined);
  assert.equal(setup.taskChoices().length, 1);
  setup = page(); setup.newPointOpen = true; setup.newPointCourse = 'Math';
  let writes = 0;
  api.createKnowledgePoint = async () => { writes++; return { ok: false, error: { message: 'offline' } }; };
  setup.newPointName = ' ';
  await setup.saveKnowledgePoint();
  assert.equal(writes, 0);
  setup.newPointName = 'Integrals';
  await setup.saveKnowledgePoint();
  assert.equal(setup.newPointName, 'Integrals');
  assert.equal(setup.newPointError, 'offline');
  assert.equal(setup.newPointOpen, true);
  assert.equal(setup.savingPoint, false);
  const loading = deferred();
  api.getProfile = () => loading.promise;
  const request = setup.loadKnowledgePoints();
  const saving = deferred();
  api.createKnowledgePoint = () => { writes++; return saving.promise; };
  const save = setup.saveKnowledgePoint();
  await setup.saveKnowledgePoint();
  assert.equal(writes, 2);
  saving.resolve({ ok: true, data: point }); await save;
  assert.equal(setup.task, 'Integrals');
  assert.equal(setup.newPointOpen, false);
  assert.equal(setup.knowledgePoints.length, 1);
  loading.resolve({ ok: true, data: { mastery: [] } }); await request;
  assert.equal(setup.knowledgePoints.length, 1);
  for (const interruption of ['account', 'page']) {
    setup = page(); setup.newPointOpen = true; setup.newPointCourse = 'Math'; setup.newPointName = 'Integrals';
    const pending = deferred(); api.createKnowledgePoint = () => pending.promise;
    const savePending = setup.saveKnowledgePoint();
    if (interruption === 'account') state.currentUser.userId = 'bob';
    else setup.active = false;
    pending.resolve({ ok: true, data: point }); await savePending;
    assert.equal(setup.task, '');
    assert.equal(setup.knowledgePoints.length, 0);
    state.currentUser.userId = 'alice';
  }
  console.log('PASS: focus choices, course scoping, plan association, duration, cancel, validation, retry, duplicate clicks, stale loads, and interrupted saves.');
})().catch(error => { console.error(error); process.exitCode = 1; });
