/* Execute the production ArkTS service/response validator with two installations.
 * The live mode talks to the real Flask API using disposable accounts/storage.
 */
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.argv[2] || 'typescript');
const root = path.resolve(__dirname, '..');
const serviceSource = fs.readFileSync(path.join(root, 'app/entry/src/main/ets/services/DistributedStateService.ets'), 'utf8');
const validatorSource = fs.readFileSync(path.join(root, 'app/entry/src/main/ets/api/ApiResponseValidator.ets'), 'utf8');
let checks = 0;
const check = (condition, message) => { assert(condition, message); checks++; };
function harness(api, shared = {}) {
  const state = { owner: 'alice', token: 'alice-token', fixture: false, baseUrl: 'http://test', now: Date.now(), ...shared };
  const values = new Map();
  let counter = 0;
  class Clock extends Date { static now() { return state.now; } }
  const context = vm.createContext({
    Date: Clock, console, encodeURIComponent, Set,
    setInterval: () => 1, clearInterval: () => {},
    AuthStore: { isSignedIn: () => !!state.token, getUserId: () => state.owner, getToken: () => state.token },
    AgentApiClient: { getConfig: () => ({ baseUrl: state.baseUrl, useFixture: state.fixture }),
      deviceCollaboration: body => api(body, state) },
    deviceInfo: { marketName: '', productModel: 'emulator', deviceType: 'phone' },
    util: { generateRandomUUID: () => `${state.owner}-${++counter}-${'random'.repeat(6)}` },
    preferences: { getPreferencesSync: () => ({ getSync: (k, v) => values.has(k) ? values.get(k) : v,
      putSync: (k, v) => values.set(k, v), flushSync: () => {} }) },
    FocusSessionSyncService: { getInstance: () => ({ configure() {}, refresh: async () => true }) }
  });
  for (const [source, name] of [[serviceSource, 'DistributedStateService'], [validatorSource, 'ApiResponseValidator']]) {
    const input = source.replace(/^import .*;\r?\n/gm, '').replace(/export /g, '') + `\nglobalThis.${name} = ${name};`;
    vm.runInContext(ts.transpileModule(input, { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText, context);
  }
  const service = new context.DistributedStateService();
  service.context = {}; service.label = '测试设备'; service.enabled = true;
  return { service, state, context };
}
const success = data => ({ ok: true, data, source: 'network' });
const failure = (code = 0) => ({ ok: false, error: { statusCode: code, message: '网络失败' }, source: 'network' });
function response(body, state, links = []) {
  return { userId: state.owner, deviceId: body.deviceId, serverTime: state.now,
    devices: links.map(l => ({ deviceId: l.peerDeviceId, deviceLabel: l.peerDeviceLabel,
      online: true, background: false, lastSeen: state.now })), links };
}
function link(overrides = {}) {
  return { invitationId: 'invite-1', peerDeviceId: 'tablet', peerDeviceLabel: '学习平板', state: 'connected',
    incoming: false, expiresAt: Date.now() + 60000, received: null, sentMessageId: '', acknowledgedAt: 0, ...overrides };
}
const task = { course: '操作系统', task: '进程调度算法对比', plannedMinutes: 90, mode: 'normal', timerType: 'countdown',
  source: 'collaborative', allowBackgroundTiming: false };
async function settle(service) { for (let i = 0; i < 6; i++) await service.queue; }
async function unit() {
  let links = [link()];
  let calls = [];
  let fail = false;
  const h = harness(async (body, state) => { calls.push(body); return fail ? failure() : success(response(body, state, links)); });
  await h.service.refresh();
  check(h.service.getSnapshot().onlinePeerCount === 1, 'Only a confirmed connection counts as a peer');
  links = [link({ state: 'pending', incoming: true })]; await h.service.refresh();
  check(h.service.getSnapshot().onlinePeerCount === 0 && h.service.getSnapshot().incomingCount === 1, 'Invitations do not count as connections');
  links = [link({ sentMessageId: 'task-1' })]; await h.service.refresh();
  check(h.service.getSnapshot().deliveryText.includes('等待'), 'Publishing is not proof of delivery');
  links[0].acknowledgedAt = 123; await h.service.refresh();
  check(h.service.getSnapshot().deliveryText.includes('已同步'), 'Recipient ACK is proof of delivery');
  links[0].received = { messageId: 'remote-1', task, sentAt: 100, ackedAt: 0 };
  await h.service.refresh(); await settle(h.service);
  check(h.service.getSnapshot().remoteTask.task === task.task && calls.some(c => c.action === 'ack' && c.messageId === 'remote-1'), 'Received task produces an exact-message ACK');
  const ackCount = calls.filter(c => c.action === 'ack').length;
  await h.service.refresh(); await settle(h.service);
  check(calls.filter(c => c.action === 'ack').length === ackCount, 'Pending local ACKs are not repeatedly enqueued');
  h.service.consumeRemoteTask(); await h.service.refresh();
  check(h.service.getSnapshot().remoteTask === null, 'An adopted legacy task does not reappear on the next poll');
  links[0].received = { messageId: 'clear', task: null, sentAt: 101, ackedAt: 1 };
  await h.service.refresh();
  check(h.service.getSnapshot().remoteTask === null, 'Source ending focus clears the remote task');
  h.state.now += 16000;
  check(h.service.getSnapshot().stale && h.service.getSnapshot().links.length === 1 &&
    !h.service.getSnapshot().peers[0].online, 'Stale responses preserve pairing and explicitly mark presence unknown');
  fail = true; await h.service.refresh();
  check(h.service.getSnapshot().stale && h.service.getSnapshot().links.length === 1 &&
    h.service.getSnapshot().lastError, 'Transport failure retains the last snapshot with a retryable error');
  fail = false; h.service.setForeground(false); await settle(h.service);
  check(calls.some(c => c.action === 'background') && !calls.some(c => c.action === 'offline') &&
    h.service.getSnapshot().links.length === 1, 'Moving to the background retains pairing without an offline disconnect');
  h.service.setForeground(true); await settle(h.service);
  check(!h.service.getSnapshot().stale, 'Returning to the foreground refreshes the retained pairing');
  h.state.fixture = true; calls = []; await h.service.refresh();
  check(calls.length === 0 && !h.service.getSnapshot().available, 'Offline demo cannot register or discover real devices');
  h.state.fixture = false; h.state.token = ''; await h.service.refresh();
  check(calls.length === 0 && !h.service.getSnapshot().available, 'Signed-out clients cannot register');

  // A response that arrives after an account or environment switch is discarded.
  let release;
  const race = harness((body, state) => new Promise(resolve => { release = () => resolve(success(response(body, { ...state, owner: 'alice' }, [link()]))); }));
  const pending = race.service.refresh();
  await Promise.resolve(); await Promise.resolve();
  race.state.owner = 'bob'; race.state.token = 'bob-token';
  check(race.service.getSnapshot().remoteTask === null, 'Account change clears prior task immediately');
  release(); await pending;
  check(race.service.getSnapshot().onlinePeerCount === 0, 'Old account response cannot restore a connection');

  const validate = h.context.ApiResponseValidator;
  const good = { userId: 'alice', deviceId: 'phone', serverTime: 1, devices: [], links: [link({ received: { messageId: 'm', task, sentAt: 1, ackedAt: 0 } })] };
  check(validate.isValid('POST', '/api/v1/device-collaboration', good), 'Valid collaboration snapshot passes runtime validation');
  for (const corrupt of [null, {}, { ...good, links: [{}] }, { ...good, devices: [null] },
    { ...good, links: [link({ received: { messageId: 'm', task: {}, sentAt: 1, ackedAt: 0 } })] }])
    check(!validate.isValid('POST', '/api/v1/device-collaboration', corrupt), 'Malformed collaboration data is rejected');
}
async function live() {
  const { spawn } = require('node:child_process');
  const python = path.join(root, 'server/zhixue-agent-server/.venv/Scripts/python.exe');
  const child = spawn(python, [path.join(__dirname, 'device_collaboration_test_server.py')], { cwd: root, windowsHide: true,
    env: { ...process.env, PYTHONIOENCODING: 'utf-8', PYTHON_DOTENV_DISABLED: '1', ZHIXUE_DB: 'json',
      ZHIXUE_ENV: 'development', ZHIXUE_ENABLE_DEV_TOOLS: '1', DASHSCOPE_API_KEY: '' }, stdio: ['ignore', 'pipe', 'pipe'] });
  try {
    const ready = await new Promise((resolve, reject) => {
      let output = '';
      const timeout = setTimeout(() => reject(Error('Test API startup timed out')), 20000);
      child.stdout.on('data', chunk => {
        output += chunk;
        const match = output.match(/DEVICE_TEST_READY (\{[^\n]+\})/);
        if (match) { clearTimeout(timeout); resolve(JSON.parse(match[1])); }
      });
      child.on('exit', code => { clearTimeout(timeout); reject(Error(`Test API exited ${code}`)); });
    });
    const transport = async (body, state) => {
      const res = await fetch(`${state.baseUrl}/api/v1/device-collaboration`, { method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${state.token}` }, body: JSON.stringify(body) });
      const data = await res.json();
      return res.ok ? success(data) : failure(res.status);
    };
    const account = { owner: ready.userId, token: ready.token, baseUrl: ready.url };
    const a = harness(transport, account), b = harness(transport, account);
    // Separate persistent installations must have distinct IDs, including same-form devices.
    b.service.deviceId = 'live-tablet'; b.service.deviceKey = 't'.repeat(64);
    b.service.identity = b.service.currentIdentity();
    check(await a.service.rename('手机'), 'First installation registers: ' + a.service.getSnapshot().lastError);
    check(await b.service.rename('学习平板'), 'Second installation registers: ' + b.service.getSnapshot().lastError);
    await a.service.refresh();
    const peer = a.service.getSnapshot().devices.find(d => d.deviceLabel === '学习平板');
    check(!!peer, 'Real API discovers second installation by name');
    check(await a.service.invite(peer.deviceId), 'Real API accepts invitation');
    await b.service.refresh();
    check(a.service.getSnapshot().onlinePeerCount === 0 && b.service.getSnapshot().incomingCount === 1, 'Real invitation waits for recipient consent');
    const invite = b.service.getSnapshot().links[0].invitationId;
    check(await b.service.respond(invite, true), 'Recipient accepts on second installation');
    await a.service.refresh();
    check(a.service.getSnapshot().onlinePeerCount === 1, 'Both sides confirm connection');
    check(await a.service.shareFocusTask(task), 'Sender publishes the task');
    check(a.service.getSnapshot().deliveryText.includes('等待'), 'Sender waits before actual receipt');
    await b.service.refresh(); await settle(b.service); await a.service.refresh();
    check(b.service.getSnapshot().remoteTask.task === task.task && a.service.getSnapshot().deliveryText.includes('已同步'), 'Real receiver auto-ACK reaches the sender');
    await b.service.disconnect(invite); await a.service.refresh();
    check(a.service.getSnapshot().onlinePeerCount === 0 && b.service.getSnapshot().remoteTask === null, 'Disconnect clears both peers and received task');
    console.log('Live Flask + two production ArkTS service instances: passed');
  } finally { child.kill(); }
}
(async () => { await unit(); if (process.argv.includes('--live')) await live(); console.log(`Device collaboration checks: ${checks} passed`); })()
  .catch(error => { console.error(error); process.exitCode = 1; });
