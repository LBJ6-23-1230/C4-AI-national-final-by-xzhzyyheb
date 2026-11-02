/* Execute the actual ETS navigation policy with isolated state and deferred HTTP. */
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.argv[2] || 'typescript');
let route;
let statuses = [];
let tasks = [];
let publications = 0;
let failSave = false;
let loadPlan = async () => ({ok: true, data: {tasks, unscheduledTasks: []}});
const appState = {
  currentUser: {userId: 'alice'},
  focusRuntime: null, focusResultDraft: null,
  beginFocusRuntime(task) {
    if (failSave) return false;
    this.focusRuntime = {ownerId: this.currentUser.userId, task};
    return true;
  },
  setFocusTask(task) { this.activeFocusTask = task; },
  updatePlanTaskStatus(id, status) { statuses.push({id, status}); }
};
const context = vm.createContext({appState,
  AgentApiClient: {getCurrentPlan: () => loadPlan()},
  router: {pushUrl(value) { route = value; }},
  DistributedStateService: {getInstance: () => ({publishFocusTask() { publications++; }})}
});
for (const [file, name] of [['utils/CourseLabels.ets', 'CourseLabels'], ['services/ReminderNavigation.ets', 'ReminderNavigation']]) {
  const source = fs.readFileSync('app/entry/src/main/ets/' + file, 'utf8')
    .replace(/^import[^\n]*\n/gm, '').replace('export class', 'class');
  vm.runInContext(ts.transpileModule(source + '\nglobalThis.' + name + '=' + name + ';', {
    compilerOptions: {target: ts.ScriptTarget.ES2020}
  }).outputText, context);
}
const deferred = () => {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return {promise, resolve};
};

(async () => {
  const nav = context.ReminderNavigation;
  const event = {kind: 'task', sourceType: 'ddl', sourceId: 'ddl-one', objectId: 'wrong-id',
    title: '指定作业', courseName: '操作系统', durationMinutes: 90, knowledgePointId: 'ddl:ddl-one',
    status: 'pending', targetPage: 'pages/CourseImport'};
  const assignment = {taskId: 'ddl-one', source: 'ddl', knowledgePointId: 'ddl:ddl-one',
    knowledgePointName: '指定作业', sourceCourse: '操作系统', durationMinutes: 90, status: 'pending'};
  let selected = null;
  const choose = task => { selected = task; return ''; };
  const confirm = (minutes = 45, mode = 'strict', active = () => true) =>
    nav.confirmFocus('ddl-one', minutes, mode, 'alice', active);
  const reset = () => {
    route = null; statuses = []; publications = 0; selected = null; failSave = false;
    appState.focusRuntime = null; appState.focusResultDraft = null; appState.activeFocusTask = null;
    appState.currentUser.userId = 'alice';
    tasks = [{...assignment}];
    loadPlan = async () => ({ok: true, data: {tasks, unscheduledTasks: []}});
  };

  reset();
  nav.open(event);
  assert.equal(route.url, 'pages/TaskDetail');
  assert.equal(route.params.taskId, 'ddl-one');
  route = null;
  assert.equal(nav.actionLabel(event), '开始任务');
  await nav.start(event, choose);
  assert.equal(selected.taskId, 'ddl-one');
  assert.equal(selected.durationMinutes, 90);
  assert.equal(appState.focusRuntime, null);
  assert.equal(appState.activeFocusTask, null);
  assert.equal(route, null);
  assert.equal(statuses.length, 0);
  assert.equal(publications, 0);
  // Cancelling the selection is just dismissal; no timer, status or sync was created.
  selected = null;
  assert.equal(await confirm(45, 'strict', () => false), '');
  assert.equal(appState.focusRuntime, null);

  await nav.start(event, choose);
  assert.equal(await confirm(), '');
  assert.equal(route.url, 'pages/FocusTimer');
  assert.equal(appState.activeFocusTask.task, '指定作业');
  assert.equal(appState.activeFocusTask.planTaskId, 'ddl-one');
  assert.equal(appState.activeFocusTask.plannedMinutes, 45);
  assert.equal(appState.activeFocusTask.mode, 'strict');
  assert.equal(statuses.length, 1);
  assert.equal(statuses[0].status, 'in_progress');
  assert.equal(publications, 1);
  assert.equal(nav.actionLabel(event), '继续专注');
  const original = appState.focusRuntime;
  selected = null;
  await nav.start(event, choose);
  assert.equal(appState.focusRuntime, original);
  assert.equal(selected, null);
  assert.equal(statuses.length, 1);
  assert.equal(publications, 1);

  reset();
  await nav.start(event, choose);
  assert.equal(await confirm(60, 'normal'), '');
  assert.equal(appState.activeFocusTask.mode, 'normal');
  assert.equal(appState.activeFocusTask.plannedMinutes, 60);
  assert.equal(appState.activeFocusTask.allowBackgroundTiming, false);
  reset();
  assert.equal(await nav.confirmFocus('ddl-one', 40, 'normal', 'alice', () => true, true), '');
  assert.equal(appState.activeFocusTask.allowBackgroundTiming, true);
  reset();
  assert.equal(await nav.confirmFocus('ddl-one', 40, 'strict', 'alice', () => true, true), '');
  assert.equal(appState.activeFocusTask.allowBackgroundTiming, false);

  for (const minutes of [0, -1, 181, 1.5, NaN, Infinity]) {
    reset();
    assert((await confirm(minutes)).includes('整数分钟'));
    assert.equal(appState.focusRuntime, null);
    assert.equal(statuses.length, 0);
  }
  for (const minutes of [1, 180]) {
    reset();
    assert.equal(await confirm(minutes), '');
    assert.equal(appState.activeFocusTask.plannedMinutes, minutes);
  }
  reset();
  assert((await confirm(30, 'unknown')).includes('模式'));
  reset(); tasks = [];
  assert((await confirm()).includes('发生变化'));
  assert.equal(appState.focusRuntime, null);
  reset(); tasks[0].status = 'completed';
  assert((await confirm()).includes('已完成'));
  assert.equal(appState.focusRuntime, null);
  reset(); failSave = true;
  assert((await confirm()).includes('未能保存'));
  assert.equal(route, null);
  assert.equal(statuses.length, 0);
  assert.equal(publications, 0);
  reset(); loadPlan = async () => ({ok: false});
  assert((await confirm()).includes('暂时无法确认'));

  reset();
  appState.focusRuntime = {ownerId: 'alice', task: {planTaskId: 'another', task: '原专注'}};
  const previous = appState.focusRuntime;
  assert((await nav.start(event, choose)).includes('另一项专注'));
  assert((await confirm()).includes('另一项专注'));
  assert.equal(appState.focusRuntime, previous);
  assert.equal(route, null);
  assert.equal(selected, null);
  reset(); appState.focusResultDraft = {task: '待保存'};
  assert((await nav.start(event, choose)).includes('尚未结算'));
  assert((await confirm()).includes('尚未结算'));
  assert.equal(appState.focusRuntime, null);

  reset(); tasks[0].sourceCourse = '待确认科目';
  await nav.start(event, choose);
  assert.equal(route.url, 'pages/KnowledgeCatalog');
  assert.equal(selected, null);
  assert((await nav.start({...event, status: 'completed'}, choose)).includes('已完成'));

  reset();
  tasks = [{taskId: 'study-one', source: 'plan', knowledgePointId: 'graph', knowledgePointName: '巩固图算法',
    sourceCourse: '数据结构', durationMinutes: 15, status: 'pending'}];
  await nav.start({...event, sourceType: 'plan', sourceId: 'study-one'}, choose);
  assert.equal(route.url, 'pages/ExercisePractice');
  assert.equal(route.params.knowledgePointId, 'graph');
  assert.equal(route.params.courseName, '数据结构');
  assert.equal(selected, null);
  assert.equal(appState.focusRuntime, null);

  reset();
  tasks = [{...assignment, taskId: 'part', parentTaskId: 'ddl-one', source: 'ddl_step',
    knowledgePointName: '指定作业 · 先完成实现', durationMinutes: 30}];
  await nav.start(event, choose);
  assert.equal(selected.taskId, 'part');
  assert.equal(await nav.confirmFocus('part', 25, 'normal', 'alice', () => true), '');
  assert.equal(appState.activeFocusTask.planTaskId, 'part');
  assert.equal(appState.activeFocusTask.plannedMinutes, 25);
  assert.equal(nav.actionLabel(event), '继续专注');
  tasks.unshift({...tasks[0], taskId: 'earlier'});
  const runningStep = appState.focusRuntime;
  selected = null;
  await nav.start(event, choose);
  assert.equal(appState.focusRuntime, runningStep);
  assert.equal(selected, null);

  reset();
  let pending = deferred();
  loadPlan = () => pending.promise;
  let active = true;
  let saving = confirm(45, 'strict', () => active);
  active = false;
  pending.resolve({ok: true, data: {tasks, unscheduledTasks: []}});
  await saving;
  assert.equal(appState.focusRuntime, null);
  assert.equal(statuses.length, 0);
  reset();
  pending = deferred(); loadPlan = () => pending.promise;
  saving = confirm();
  appState.currentUser.userId = 'bob';
  pending.resolve({ok: true, data: {tasks, unscheduledTasks: []}});
  assert((await saving).includes('账号已切换'));
  assert.equal(appState.focusRuntime, null);
  assert.equal(statuses.length, 0);
  assert.equal(publications, 0);
  // Exercise the actual sheet controller as well as the shared navigation policy.
  const sheetSource = fs.readFileSync('app/entry/src/main/ets/components/TaskFocusSheet.ets', 'utf8')
    .split('  @Builder')[0].replace(/^import[^\n]*\n/gm, '')
    .replace('@Component', '').replace('export struct', 'class')
    .replace(/@(?:State|Prop)\s*/g, '').replace(/@Watch\([^)]*\)\s*/g, '');
  vm.runInContext(ts.transpileModule(sheetSource + '\n}\nglobalThis.TaskFocusSheet = TaskFocusSheet;', {
    compilerOptions: {target: ts.ScriptTarget.ES2020}
  }).outputText, context);
  reset();
  let closed = 0;
  const sheet = new context.TaskFocusSheet();
  sheet.task = tasks[0]; sheet.onClose = () => closed++;
  sheet.aboutToAppear();
  assert.equal(sheet.minutes, '90');
  assert.equal(sheet.mode, 'normal');
  assert.equal(sheet.allowBackgroundTiming, false);
  sheet.minutes = '0';
  await sheet.start();
  assert(sheet.error.includes('整数分钟'));
  assert.equal(closed, 0);
  assert.equal(appState.focusRuntime, null);
  sheet.minutes = '45'; sheet.mode = 'strict';
  await sheet.start();
  assert.equal(appState.activeFocusTask.plannedMinutes, 45);
  assert.equal(appState.activeFocusTask.mode, 'strict');
  assert.equal(closed, 1);
  sheet.aboutToDisappear();

  reset(); closed = 0;
  sheet.task = tasks[0]; sheet.aboutToAppear();
  assert.equal(sheet.mode, 'normal');
  assert.equal(sheet.minutes, '90');
  assert.equal(sheet.error, '');
  assert.equal(sheet.allowBackgroundTiming, false);
  pending = deferred(); loadPlan = () => pending.promise;
  saving = sheet.start();
  await sheet.start(); // The second tap is ignored while confirmation is pending.
  sheet.close();
  pending.resolve({ok: true, data: {tasks, unscheduledTasks: []}});
  await saving;
  assert.equal(closed, 1);
  assert.equal(appState.focusRuntime, null);
  assert.equal(statuses.length, 0);
  reset();
  let sheetOpen = true;
  sheet.isOpen = () => sheetOpen;
  sheet.task = tasks[0]; sheet.aboutToAppear();
  pending = deferred(); loadPlan = () => pending.promise;
  saving = sheet.start();
  sheetOpen = false; // Native drag/back dismissal starts before component destruction.
  pending.resolve({ok: true, data: {tasks, unscheduledTasks: []}});
  await saving;
  assert.equal(appState.focusRuntime, null);
  assert.equal(statuses.length, 0);
  console.log('PASS: task selection without side effects; normal/strict confirmation; duration bounds; exact-task practice; resume; stale-task, cancellation, account and persistence guards.');
})().catch(error => {console.error(error); process.exitCode = 1;});
