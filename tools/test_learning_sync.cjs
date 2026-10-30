/* Execute the actual client queue and response guards without ArkUI. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const ts = require(process.argv[2] || 'typescript');
const root = path.resolve(__dirname, '../app/entry/src/main/ets');
const network = {};
function load(file, name) {
  const source = fs.readFileSync(path.join(root, file), 'utf8');
  const compiled = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText;
  const exports = {};
  const context = vm.createContext({ exports, require: () => ({ AgentApiClient: network }), console });
  vm.runInContext(compiled, context);
  return exports[name];
}
const Sync = load('services/LearningSync.ets', 'LearningSync');
const Validator = load('api/ApiResponseValidator.ets', 'ApiResponseValidator');
const Evidence = load('utils/LearningEvidence.ets', 'LearningEvidence');
const course = (name = 'Data structures', syncVersion = 1) => ({ courseId: 'course', courseName: name, syncVersion });
const snapshot = (courses = []) => ({ userId: 'alice', courses, homeworkDDLs: [], revision: 1 });
const success = data => ({ ok: true, data });
const plain = value => JSON.parse(JSON.stringify(value));
let passed = 0;
async function check(name, run) { await run(); passed++; console.log('PASS ' + name); }
(async () => {
  await check('new device reads cloud facts without publishing an empty snapshot', async () => {
    const sync = new Sync(); sync.restore([], [], [], true);
    network.saveLearningData = () => { throw Error('unexpected write'); };
    network.getLearningData = async () => success(snapshot([course()]));
    assert.equal((await sync.sync('alice', () => true)).courses.length, 1);
    assert.equal(sync.queue.length, 0);
  });
  await check('legacy migration sends additions only', async () => {
    const sync = new Sync(); sync.restore([course('old', undefined)], [], [], false);
    assert.equal(sync.queue[0].migration, true);
    assert.deepEqual(plain(sync.queue[0].deletedCourses), []);
  });
  await check('consecutive offline edits use versions acknowledged by their own requests', async () => {
    const sync = new Sync(); sync.restore([course()], [], [], true);
    sync.capture([course('first')], []); sync.capture([course('second')], []);
    const versions = []; let version = 1;
    network.saveLearningData = async request => {
      versions.push(request.courses[0].syncVersion);
      return success(snapshot([course(request.courses[0].courseName, ++version)]));
    };
    network.getLearningData = async () => success(snapshot([course('second', version)]));
    await sync.sync('alice', () => true);
    assert.deepEqual(versions, [1, 2]); assert.equal(sync.queue.length, 0);
  });
  await check('network failure retains the original operation identity across restart', async () => {
    const sync = new Sync(); sync.restore([course()], [], [], true); sync.capture([course('edited')], []);
    const key = sync.queue[0].idempotencyKey;
    network.saveLearningData = async () => ({ ok: false, error: { statusCode: 0 } });
    await sync.sync('alice', () => true);
    const restored = new Sync(); restored.restore([course('edited')], [], plain(sync.queue), true);
    assert.equal(restored.queue[0].idempotencyKey, key);
  });
  await check('an edit during the final refresh retains our acknowledged version', async () => {
    const sync = new Sync(); sync.restore([course()], [], [], true); sync.capture([course('first')], []);
    const versions = []; let refreshes = 0;
    network.saveLearningData = async request => { versions.push(request.courses[0].syncVersion); return success(snapshot([course(request.courses[0].courseName, request.courses[0].syncVersion + 1)])); };
    network.getLearningData = async () => {
      if (++refreshes === 1) sync.capture([course('late edit', 1)], []);
      return success(snapshot([course('server', 2)]));
    };
    await sync.sync('alice', () => true);
    assert.equal(sync.queue[0].courses[0].syncVersion, 2);
    await sync.sync('alice', () => true); assert.deepEqual(versions, [1, 2]);
  });
  await check('account switch stops a late response before the next queued request', async () => {
    const sync = new Sync(); sync.restore([course()], [], [], true);
    sync.capture([course('first')], []); sync.capture([course('second')], []);
    let current = true, calls = 0;
    network.saveLearningData = async () => { calls++; current = false; return success(snapshot([course('first', 2)])); };
    assert.equal(await sync.sync('alice', () => current), null);
    assert.equal(calls, 1); assert.equal(sync.queue.length, 2);
  });
  await check('conflicts preserve pending edits and block automatic overwrite', async () => {
    const sync = new Sync(); sync.restore([course()], [], [], true); sync.capture([course('local')], []);
    let calls = 0; network.saveLearningData = async () => { calls++; return { ok: false, error: { statusCode: 409 } }; };
    await sync.sync('alice', () => true); await sync.sync('alice', () => true);
    assert.equal(calls, 1); assert.equal(sync.queue.length, 1);
    sync.keepLocal(snapshot([course('remote', 2)]));
    assert.equal(sync.queue[0].courses[0].syncVersion, 2); assert.equal(sync.conflict, false);
  });
  await check('valid reminders accept inapplicable empty fields and empty list cursors', async () => {
    const event = { eventId: 'e', userId: 'alice', kind: 'gap', objectId: 'study', title: 'Continue',
      courseName: '', level: 'normal', status: 'pending', reason: 'Last session', planId: '', knowledgePointId: '',
      targetPage: 'pages/StudyPlan', dataTime: '2026-10-30T00:00:00Z', version: 1, sourceVersion: 1, durationMinutes: 0 };
    assert.equal(Validator.isValid('POST', '/api/v1/reminders/e/actions', { event }), true);
    assert.equal(Validator.isValid('GET', '/api/v1/reminders?after=', { events: [], cursor: '', hasMore: false }), true);
    assert.equal(Validator.isValid('POST', '/api/v1/reminders/e/actions', { event: { ...event, eventId: '' } }), false);
    assert.equal(Validator.isValid('POST', '/api/v1/reminders/e/actions', { event: { ...event, version: '1' } }), false);
  });
  await check('unassessed and genuine zero accuracy have different states', async () => {
    const unknown = { masteryScore: 0, assessmentStatus: 'unassessed', effectiveQuestionCount: 0, recentAccuracy: null };
    const zero = { masteryScore: 0, assessmentStatus: 'evidence_limited', effectiveQuestionCount: 3, correctCount: 0, recentAccuracy: 0 };
    assert.equal(Evidence.assessed(unknown, [], []), false); assert.equal(Evidence.assessed(zero, [], []), true);
    assert.notEqual(Evidence.label(unknown), Evidence.label(zero)); assert.equal(Evidence.score(zero), 0);
  });
  console.log(`${passed} client feedback checks passed.`);
})().catch(error => { console.error(error); process.exitCode = 1; });
