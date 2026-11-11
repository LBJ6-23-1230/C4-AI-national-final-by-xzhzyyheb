const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.argv[2] || 'typescript');
const source = fs.readFileSync('app/entry/src/main/ets/services/FocusSessionSyncService.ets', 'utf8');
let now = 1700000000000;
let server = null;
let sequence = 0;
const records = new Map();
const seen = new Map();
const task = {course: '操作系统', task: '共享进程调度-唯一任务', plannedMinutes: 30,
  mode: 'normal', source: 'collaborative', timerType: 'countdown', allowBackgroundTiming: false, planTaskId: 'plan-one'};
const clone = value => JSON.parse(JSON.stringify(value));
const response = id => ({ok: true, data: {userId: 'alice', deviceId: id, serverTime: now, session: clone(server)}});
const failure = status => ({ok: false, error: {statusCode: status, message: status === 409 ? '状态冲突' : '网络失败'}});
function elapsed(at = now) {
  return server.elapsedMs + (server.state === 'running' ? Math.max(0, at - server.runningAt) : 0);
}
function output(id) {
  const result = response(id);
  if (result.data.session) {
    result.data.session.elapsedMs = elapsed();
    result.data.session.remainingMs = Math.max(0, 1800000 - elapsed());
  }
  return result;
}
async function action(request, state) {
  if (state.offline || state.failNextAction) { state.failNextAction = false; return failure(0); }
  if (state.revoked) return failure(403);
  if (seen.has(request.clientId)) return output(request.deviceId);
  if (request.action === 'start') {
    if (server && ['running', 'paused'].includes(server.state)) return failure(409);
    server = {sessionId: 'session-one', revision: 1, state: 'running', task: clone(task),
      leaderDeviceId: request.deviceId, leaderLabel: request.deviceId, elapsedMs: 0, remainingMs: 1800000,
      startedAt: now, updatedAt: now, runningAt: now, pauseCount: 0, interruptionCount: 0, record: null,
      participants: [{deviceId: request.deviceId, deviceLabel: request.deviceId, role: 'leader', online: true, background: false, lastSeen: now}],
      lastEvent: {action: 'start', by: request.deviceId, deviceLabel: request.deviceId, at: now, clientId: request.clientId}};
  } else {
    if (!server || request.expectedRevision !== server.revision || request.sessionId !== server.sessionId) return failure(409);
    const at = Math.min(now, Math.max(server.updatedAt, request.occurredAt ?? now));
    if (request.action === 'handoff') {
      server.leaderDeviceId = request.deviceId;
      server.leaderLabel = request.deviceId;
      if (!server.participants.some(p => p.deviceId === request.deviceId)) server.participants.push({deviceId: request.deviceId,
        deviceLabel: request.deviceId, role: 'leader', online: true, background: false, lastSeen: now});
    }
    if (request.action === 'pause') { server.elapsedMs = elapsed(at); server.state = 'paused'; server.pauseCount++; }
    if (request.action === 'resume') { server.state = 'running'; server.runningAt = at; }
    if (['complete', 'abandon'].includes(request.action)) {
      server.elapsedMs = elapsed(at); server.state = request.action === 'complete' ? 'completed' : 'abandoned';
      server.record = {taskId: server.sessionId, task: task.task, actualMinutes: server.elapsedMs / 60000,
        selfAssessment: request.selfAssessment, endedAt: new Date(at).toISOString()};
      records.set(server.sessionId, server.record);
    }
    server.revision++; server.updatedAt = at;
  }
  seen.set(request.clientId, true);
  if (state.dropResponse) { state.dropResponse = false; return failure(0); }
  if (state.failAfterAction) { state.failAfterAction = false; state.failNextAction = true; }
  return output(request.deviceId);
}
function client(id, disk = new Map(), transport = null, identity = {}) {
  const state = {owner: 'alice', token: 'alice-token', offline: false, revoked: false, ...identity};
  const local = {focusRuntime: null, focusResultDraft: null, records: [],
    applySharedFocusRuntime(runtime, sessionId) {
      if (this.focusRuntime && this.focusRuntime.sessionId !== sessionId) return false;
      this.focusRuntime = runtime; return true;
    },
    acceptSharedFocusRecord(record) { this.records = this.records.filter(r => r.taskId !== record.taskId).concat([record]); }};
  const context = vm.createContext({Date: class extends Date {static now() {return now;}}, console, Promise, JSON, Math, encodeURIComponent,
    AgentApiClient: {getConfig: () => ({baseUrl: 'http://test', useFixture: false}),
      sharedFocus: async device => state.offline ? failure(0) : state.revoked ? failure(403) :
        transport ? transport('GET', null, device, state) : output(device),
      sharedFocusAction: request => transport ? transport('POST', request, id, state) : action(request, state)},
    AuthStore: {isSignedIn: () => !!state.token, getUserId: () => state.owner, getToken: () => state.token},
    preferences: {getPreferencesSync: () => ({getSync: (k, value) => disk.has(k) ? disk.get(k) : value,
      putSync: (k, value) => disk.set(k, value), flushSync() {}})},
    util: {generateRandomUUID: () => `action-${++sequence}`}, appState: local,
    AppStorage: {setOrCreate() {}, get() {return 0;}}});
  const input = source.replace(/^import .*;\r?\n/gm, '').replace(/export /g, '') + '\nglobalThis.Service=FocusSessionSyncService;';
  vm.runInContext(ts.transpileModule(input, {compilerOptions: {target: ts.ScriptTarget.ES2020}}).outputText, context);
  const service = new context.Service(); service.configure({}, id, id + '-key');
  return {service, state, local, disk};
}
(async () => {
  const phone = client('phone'); const tablet = client('tablet');
  assert(await phone.service.start(task));
  now += 24100;
  assert(await tablet.service.refresh());
  assert.equal(tablet.service.getSnapshot().session.elapsedMs, 24100);
  assert(await tablet.service.handoff());
  assert.equal(tablet.local.focusRuntime.sessionId, phone.local.focusRuntime.sessionId);
  assert.equal(tablet.local.focusRuntime.elapsedMs, 24100);
  assert(await phone.service.refresh());
  assert.equal(phone.service.getSnapshot().session.remainingMs, tablet.service.getSnapshot().session.remainingMs);
  assert(await tablet.service.pause());
  assert(await phone.service.refresh());
  assert.equal(phone.local.focusRuntime.paused, true);
  now += 60000;
  assert.equal(phone.service.getSnapshot().session.elapsedMs, 24100);
  assert(await phone.service.resume());
  now += 10000;
  await tablet.service.refresh();
  assert.equal(tablet.service.getSnapshot().session.elapsedMs, 34100);
  phone.state.offline = true;
  assert(await phone.service.pause());
  now += 10000;
  assert(await phone.service.resume());
  now += 10000;
  assert.equal(phone.service.getSnapshot().session.elapsedMs, 44100);
  phone.state.offline = false; phone.state.failAfterAction = true;
  assert.equal(await phone.service.refresh(), false);
  assert.equal(phone.service.getSnapshot().session.state, 'running');
  assert.equal(phone.service.getSnapshot().session.elapsedMs, 44100);
  assert(await phone.service.refresh());
  assert.equal(phone.service.getSnapshot().session.elapsedMs, 44100);
  phone.state.dropResponse = true;
  assert(await phone.service.finish('completed'));
  assert.equal(records.size, 1);
  assert(await phone.service.refresh());
  assert.equal(records.size, 1);
  assert.equal(phone.local.records.length, 1);
  await tablet.service.refresh();
  assert.equal(tablet.local.focusRuntime, null);
  assert.equal(tablet.service.getSnapshot().session.state, 'completed');
  server = null; seen.clear();
  phone.local.focusRuntime = null; tablet.local.focusRuntime = null;
  assert(await phone.service.start(task));
  assert.equal(await tablet.service.start(task), false);
  assert.equal(tablet.local.focusRuntime, null);
  await tablet.service.handoff();
  tablet.state.revoked = true;
  assert.equal(await tablet.service.refresh(), false);
  assert.equal(tablet.local.focusRuntime, null);
  assert.equal(tablet.service.getSnapshot().session, null);
  phone.state.owner = 'bob'; phone.state.token = 'bob-token';
  assert.equal(phone.service.getSnapshot().session, null);
  assert.equal(phone.service.getSnapshot().available, false);
  console.log('PASS: production shared-focus service: continuous handoff, shared pause/resume, ordered offline projection, idempotent completion, conflict, revoked access and identity fences.');
  if (process.argv.includes('--live')) await live();
})().catch(error => {console.error(error); process.exitCode = 1;});

async function live() {
  const {spawn} = require('node:child_process');
  const child = spawn('server/zhixue-agent-server/.venv/Scripts/python.exe', ['-u', 'tools/device_collaboration_test_server.py'],
    {stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true,
      env: {...process.env, PYTHONIOENCODING: 'utf-8', PYTHON_DOTENV_DISABLED: '1', ZHIXUE_DB: 'json',
        ZHIXUE_ENV: 'development', ZHIXUE_ENABLE_DEV_TOOLS: '1', DASHSCOPE_API_KEY: ''}});
  let stderr = ''; child.stderr.on('data', data => {stderr += data;});
  try {
    const ready = await new Promise((resolve, reject) => {
      let output = '';
      const timer = setTimeout(() => reject(Error('HTTP test server did not start: ' + stderr.slice(-1000))), 30000);
      child.stdout.on('data', data => {
        output += data;
        const match = output.match(/DEVICE_TEST_READY (.+)\r?\n/);
        if (match) {clearTimeout(timer); resolve(JSON.parse(match[1]));}
      });
      child.on('exit', code => {clearTimeout(timer); reject(Error('HTTP test server exited ' + code + ': ' + stderr.slice(-1000)));});
    });
    async function request(route, body, headers = {}) {
      const response = await fetch(ready.url + route, {method: body ? 'POST' : 'GET',
        headers: {'Authorization': 'Bearer ' + ready.token, 'Content-Type': 'application/json', ...headers},
        body: body ? JSON.stringify(body) : undefined});
      const data = await response.json();
      return response.ok ? {ok: true, data} : {ok: false, error: {statusCode: response.status, message: data.message}};
    }
    async function device(action, id, values = {}) {
      const result = await request('/api/v1/device-collaboration', {action, deviceId: id, deviceKey: id + '-key',
        deviceLabel: id, ...values});
      assert(result.ok, result.error?.message); return result.data;
    }
    await device('register', 'shared-phone'); await device('register', 'shared-tablet');
    const invitation = (await device('invite', 'shared-phone', {targetDeviceId: 'shared-tablet'})).links[0].invitationId;
    await device('accept', 'shared-tablet', {invitationId: invitation});
    async function transport(method, body, id, state) {
      if (state.offline) return failure(0);
      const result = method === 'POST' ? await request('/api/v1/focus-session/actions', body) :
        await request('/api/v1/focus-session', null, {'X-Device-Id': id, 'X-Device-Key': id + '-key'});
      if (state.dropResponse) {state.dropResponse = false; return failure(0);}
      return result;
    }
    const identity = {owner: ready.userId, token: ready.token};
    const phone = client('shared-phone', new Map(), transport, identity);
    const tablet = client('shared-tablet', new Map(), transport, identity);
    assert(await phone.service.start(task));
    await tablet.service.refresh(); assert(await tablet.service.handoff());
    await phone.service.refresh();
    assert.equal(phone.local.focusRuntime.sessionId, tablet.local.focusRuntime.sessionId);
    assert(Math.abs(phone.service.getSnapshot().session.elapsedMs - tablet.service.getSnapshot().session.elapsedMs) < 1000);
    assert(await tablet.service.pause()); await phone.service.refresh();
    assert.equal(phone.local.focusRuntime.paused, true);
    assert(await phone.service.resume()); await tablet.service.refresh();
    assert.equal(tablet.local.focusRuntime.paused, false);
    phone.state.dropResponse = true; assert(await phone.service.finish('completed'));
    await phone.service.refresh(); await tablet.service.refresh();
    assert.equal(tablet.local.focusRuntime, null);
    const history = await request('/api/v1/focus-sessions');
    assert(history.ok); assert.equal(history.data.sessions.length, 1);
    assert.equal(history.data.sessions[0].taskId, phone.service.getSnapshot().session.sessionId);
    console.log('PASS: two production ArkTS shared-focus service instances + real disposable Flask API: pairing, continuous handoff, pause/resume, lost-response retry, one durable record.');
  } finally {child.kill();}
}
