/* Execute actual ETS controllers using isolated state, a fake clock and deferred HTTP. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2] || 'typescript');
const root = 'app/entry/src/main/ets/';
let now = 1700000000000;
const timers = new Map();
const timeouts = new Map();
let screenOn = true;
let screenEvent;
let timerId = 0;
let backs = 0;
let route = null;
let timePicker;
const network = {};
const state = {currentUser: {userId: 'alice'}, focusRuntime: null, activeFocusTask: null, focusResultDraft: null,
  beginFocusRuntime(task) { this.focusRuntime = context.FocusClock.create('alice', task); return true; },
  setFocusTask(task) { this.activeFocusTask = task; },
  checkpointFocusRuntime(runtime) { this.focusRuntime = runtime; return true; },
  pauseFocusOnDeparture() {
    if (this.focusRuntime) this.focusRuntime = context.FocusClock.depart(this.focusRuntime, 'navigation');
    return true;
  },
  handleFocusDeparture(reason, at) {
    if (this.focusRuntime) this.focusRuntime = context.FocusClock.depart(this.focusRuntime, reason, at);
    return true;
  },
  setFocusResultDraft(draft) { this.focusResultDraft = draft; this.focusRuntime = null; return true; }
};
const context = vm.createContext({console, Promise, Number, Math,
  Date: class extends Date { static now() { return now; } },
  setInterval(fn) { timers.set(++timerId, fn); return timerId; },
  clearInterval(id) { timers.delete(id); },
  setTimeout(fn) { timeouts.set(++timerId, fn); return timerId; },
  clearTimeout(id) { timeouts.delete(id); },
  power: {isActive: () => screenOn},
  commonEventManager: {
    Support: {COMMON_EVENT_SCREEN_OFF: 'off', COMMON_EVENT_SCREEN_ON: 'on', COMMON_EVENT_SCREEN_LOCKED: 'locked', COMMON_EVENT_SCREEN_UNLOCKED: 'unlocked'},
    createSubscriberSync: () => ({}), subscribe: (_, callback) => { screenEvent = callback; }, unsubscribe: () => {}
  },
  appState: state, AgentApiClient: network,
  router: {back() { backs++; }, pushUrl(value) { route = value; }},
  notificationManager: {isNotificationEnabled: async () => false},
  TimePickerDialog: {show(options) { timePicker = options; }},
  ReminderDeviceService: {sync: async () => {}, lastSync: ''},
  getContext: () => ({}),
  ProactiveSurfaceService: {requestPermission: async () => false, refresh: async () => {}}
});
function compile(source) {
  const result = ts.transpileModule(source, {reportDiagnostics: true,
    compilerOptions: {target: ts.ScriptTarget.ES2020}});
  assert.equal(result.diagnostics.length, 0);
  vm.runInContext(result.outputText, context);
}
compile(fs.readFileSync(root + 'utils/FocusClock.ets', 'utf8').replace(/^import[^\n]*\n/gm, '')
  .replace('export class', 'class') + '\nglobalThis.FocusClock = FocusClock;');
compile(fs.readFileSync(root + 'services/FocusLifecycleService.ets', 'utf8').replace(/^import[^\n]*\n/gm, '')
  .replace('export class', 'class') + '\nglobalThis.FocusLifecycleService = FocusLifecycleService;');
function controller(name, boundary) {
  const source = fs.readFileSync(root + 'pages/' + name + '.ets', 'utf8').split(boundary)[0]
    .replace(/^import[^\n]*\n/gm, '').replace(/^@(Entry|Component)\s*$/gm, '')
    .replace('struct ' + name, 'class ' + name).replace(/@State\s*/g, '');
  compile('(function(){\n' + source + '\n}\nglobalThis.' + name + 'Controller = ' + name + ';\n})();');
  return new context[name + 'Controller']();
}
const deferred = () => {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return {promise, resolve};
};
function focus(mode = 'normal', timerType = 'countdown', allowBackgroundTiming = false) {
  timers.clear();
  now = 1700000000000;
  state.currentUser.userId = 'alice';
  state.focusRuntime = null; state.focusResultDraft = null;
  context.FocusLifecycleService.destroy();
  context.FocusLifecycleService.initialize();
  context.FocusLifecycleService.onForeground();
  timeouts.clear(); screenOn = true;
  state.activeFocusTask = {course: '课程', task: '任务', plannedMinutes: timerType === 'stopwatch' ? 0 : 60,
    mode, source: 'manual', timerType, allowBackgroundTiming};
  const page = controller('FocusTimer', '\n  build()');
  page.aboutToAppear(); page.onPageShow();
  return page;
}

(async () => {
  let page = focus();
  now += 60000;
  [...timers.values()][0]();
  assert.equal(page.remainingSeconds, 3540);
  page.onPageHide(); page.aboutToDisappear();
  context.FocusLifecycleService.resolvePending();
  assert.equal(state.focusRuntime.paused, true);
  assert.equal(state.focusRuntime.pauseCount, 1);
  assert.equal(state.focusRuntime.interruptionCount, 0);
  assert.equal(timers.size, 0);
  now += 35 * 60000;
  page.onPageShow();
  assert.equal(page.remainingSeconds, 3540);
  assert.equal(page.paused, true);
  assert(page.statusText().includes('自动暂停'));
  assert.equal(state.focusResultDraft, null);
  page.togglePause();
  now += 10000;
  [...timers.values()][0]();
  assert.equal(page.remainingSeconds, 3530);
  assert.equal(page.paused, false);
  page.goBackToSetup();
  assert.equal(backs, 1);
  assert.equal(state.focusRuntime.paused, true);

  page = focus('normal', 'stopwatch');
  now += 120000;
  page.onPageHide();
  context.FocusLifecycleService.resolvePending();
  now += 3600000;
  page.onPageShow();
  assert.equal(page.elapsedSeconds, 120);
  assert.equal(page.paused, true);

  page = focus();
  now += 30000;
  page.togglePause();
  const manualPauses = state.focusRuntime.pauseCount;
  page.onPageHide(); page.aboutToDisappear();
  context.FocusLifecycleService.resolvePending();
  assert.equal(state.focusRuntime.pauseCount, manualPauses);
  assert.equal(state.focusRuntime.autoPaused, false);

  page = focus('strict');
  assert.equal(page.onBackPress(), true);
  assert.equal(page.showExitConfirm, true);
  now += 60000;
  page.onPageHide(); page.aboutToDisappear();
  context.FocusLifecycleService.resolvePending();
  assert.equal(state.focusRuntime.paused, false);
  assert.equal(state.focusRuntime.interruptionCount, 1);
  now += 60000;
  page.onPageShow();
  assert.equal(page.remainingSeconds, 3480);

  // Default-off focus still continues while the phone is sleeping/locked.
  page = focus();
  now += 60000;
  screenOn = false;
  page.onPageHide(); context.FocusLifecycleService.onBackground();
  context.FocusLifecycleService.resolvePending();
  assert.equal(state.focusRuntime.paused, false);
  assert.equal(state.focusRuntime.backgroundReason, 'screenOff');
  now += 120000;
  screenOn = true; screenEvent(null, {event: 'unlocked'});
  context.FocusLifecycleService.onForeground(); page.onPageShow();
  assert.equal(page.remainingSeconds, 3420);
  assert.equal(page.paused, false);
  assert.equal(state.focusRuntime.backgroundReason, undefined);

  // A screen event arriving after page/background callbacks is still classified as sleep.
  page = focus(); now += 60000;
  page.onPageHide(); context.FocusLifecycleService.onBackground();
  now += 100; screenEvent(null, {event: 'off'});
  screenEvent(null, {event: 'on'}); // Even a fast wake before classification keeps the sleep observation.
  context.FocusLifecycleService.resolvePending();
  assert.equal(state.focusRuntime.paused, false);
  assert.equal(state.focusRuntime.backgroundReason, 'screenOff');

  // The classification delay must never count as studying when switching apps.
  page = focus(); now += 60000;
  page.onPageHide(); context.FocusLifecycleService.onBackground();
  now += 300;
  context.FocusLifecycleService.resolvePending();
  assert.equal(state.focusRuntime.paused, true);
  assert.equal(state.focusRuntime.elapsedMs, 60000);
  screenEvent(null, {event: 'off'});
  assert.equal(state.focusRuntime.paused, true); // Sleeping later cannot resume a paused task.

  page = focus('normal', 'countdown', true); now += 60000;
  page.onPageHide(); context.FocusLifecycleService.onBackground();
  context.FocusLifecycleService.resolvePending();
  assert.equal(state.focusRuntime.paused, false);
  assert.equal(state.focusRuntime.backgroundReason, 'background');
  now += 120000;
  context.FocusLifecycleService.onForeground(); page.onPageShow();
  assert.equal(page.remainingSeconds, 3420);
  page.togglePause();
  screenOn = false; page.onPageHide(); context.FocusLifecycleService.resolvePending();
  now += 60000; screenOn = true; page.onPageShow();
  assert.equal(page.paused, true);
  assert.equal(page.remainingSeconds, 3420);

  page = focus('strict'); now += 60000; screenOn = false;
  page.onPageHide(); context.FocusLifecycleService.onBackground(); context.FocusLifecycleService.resolvePending();
  assert.equal(state.focusRuntime.interruptionCount, 0); // Locking the screen is not a strict-mode interruption.

  // Merely lighting the lock screen keeps timing; unlocking to another app pauses by default.
  page = focus(); now += 60000; screenOn = false;
  page.onPageHide(); context.FocusLifecycleService.onBackground(); context.FocusLifecycleService.resolvePending();
  now += 60000; screenOn = true; screenEvent(null, {event: 'on'});
  assert.equal(state.focusRuntime.paused, false);
  screenEvent(null, {event: 'unlocked'});
  now += 300;
  context.FocusLifecycleService.resolvePending();
  assert.equal(state.focusRuntime.paused, true);
  assert.equal(state.focusRuntime.elapsedMs, 120000);

  page = focus();
  state.currentUser.userId = 'bob';
  const old = state.focusRuntime;
  page.onPageHide();
  assert.equal(state.focusRuntime, old);
  assert.equal(state.focusRuntime.paused, false);

  state.currentUser.userId = 'alice';
  page = controller('Reminders', '\n  @Builder');
  page.settingsReady = true;
  const original = {...page.settings};
  let pending = deferred();
  let request;
  network.saveReminderSettings = value => { request = value; return pending.promise; };
  let saving = page.chooseHour(12);
  assert.equal(page.busy, true);
  assert.equal(page.pendingHour, 12);
  assert.equal(page.selectedHour, 9);
  assert.equal(request.summaryHour, 12);
  pending.resolve({ok: true, data: {preferences: request}});
  await saving;
  assert.equal(page.selectedHour, 12);
  assert.equal(page.pendingHour, -1);
  assert.equal(page.saved, true);
  assert(page.message.includes('已保存') && page.message.includes('12:00'));

  // The native time picker persists arbitrary minutes; a failed save leaves the
  // previous interval intact, and a picker opened by another account cannot save.
  network.saveReminderSettings = async value => ({ok: true, data: {preferences: value}});
  page.editQuiet(true);
  timePicker.onAccept({hour: 21, minute: 35});
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(page.settings.quietStart, 21);
  assert.equal(page.settings.quietStartMinute, 35);
  assert(page.quietLabel().includes('21:35') && page.quietLabel().includes('次日'));
  page.editQuiet(false);
  timePicker.onAccept({hour: 22, minute: 45});
  await new Promise(resolve => setImmediate(resolve));
  assert(!page.quietLabel().includes('次日'));
  page.chooseQuiet(10, 10, 30, 30);
  assert(page.message.includes('不能相同'));
  page.editQuiet(true);
  state.currentUser.userId = 'bob';
  timePicker.onAccept({hour: 20, minute: 15});
  assert.equal(page.settings.quietStart, 21);
  state.currentUser.userId = 'alice';

  network.saveReminderSettings = async () => ({ok: false, error: {message: '网络异常'}});
  await page.chooseHour(18);
  assert.equal(page.selectedHour, 12);
  assert.equal(page.settings.summaryHour, 12);
  assert.equal(page.pendingHour, -1);
  assert.equal(page.saved, false);
  assert(page.message.includes('保存失败'));
  page.chooseQuiet(23, 8, 55, 10);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(page.settings.quietStartMinute, 35);
  network.saveReminderSettings = async () => { throw Error('offline'); };
  await page.chooseHour(9);
  assert.equal(page.selectedHour, 12);
  assert.equal(page.busy, false);

  pending = deferred();
  network.saveReminderSettings = () => pending.promise;
  saving = page.chooseHour(18);
  state.currentUser.userId = 'bob';
  pending.resolve({ok: true, data: {preferences: {...original, summaryHour: 18}}});
  await saving;
  assert.equal(page.selectedHour, 12);
  assert.equal(page.settings.summaryHour, 12);

  state.currentUser.userId = 'alice';
  page = controller('Reminders', '\n  @Builder');
  page.settingsReady = true;
  pending = deferred(); network.saveReminderSettings = () => pending.promise;
  saving = page.chooseHour(18);
  page.aboutToDisappear();
  pending.resolve({ok: true, data: {preferences: {...original, summaryHour: 18}}});
  await saving;
  assert.equal(page.selectedHour, 9);
  console.log('PASS: actual lifecycle/clock/controllers distinguish navigation, app switching and screen-off in either event order; background opt-in, manual pause, strict mode and account guards hold; reminder save feedback and rollback pass.');
})().catch(error => {console.error(error); process.exitCode = 1;});
