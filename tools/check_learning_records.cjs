const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2] || 'typescript');
const root = 'app/entry/src/main/ets/';
const state = {currentUser: {userId: 'alice'}, chatSessionId: '', hasActiveChat: false};
const network = {};
const context = vm.createContext({ Date, Number, Promise, appState: state, AgentApiClient: network });
function compile(source) {
  const result = ts.transpileModule(source, { reportDiagnostics: true,
    compilerOptions: { target: ts.ScriptTarget.ES2020 } });
  assert.equal(result.diagnostics.length, 0);
  vm.runInContext(result.outputText, context);
}
compile(fs.readFileSync(root + 'api/ApiResponseValidator.ets', 'utf8')
  .replace('export class', 'class') + '\nglobalThis.validator = ApiResponseValidator;');
compile(fs.readFileSync(root + 'pages/LearningRecords.ets', 'utf8').split('\n  build()')[0]
  .replace(/^import[^\n]*\n/gm, '').replace(/^@(Entry|Component)\s*$/gm, '')
  .replace('struct LearningRecordsPage', 'class LearningRecordsPage').replace(/@State\s*/g, '')
  + '\n}\nglobalThis.PageController = LearningRecordsPage; globalThis.page = new LearningRecordsPage();');
const learningContext = {
  goalId: 'goal-test', sessionId: 'goal-test', traceId: 'trace-test', assessmentTraceId: '',
  goal: '复习哈希表', status: 'waiting_for_answers', currentAgent: 'exercise', waitingFor: 'answers',
  nextAction: '继续练习', decisionSource: 'rules', knowledgePointId: 'hash', knowledgePointName: '哈希表',
  planId: '', sourceMode: 'general', kbId: '', assessmentStatus: 'not_assessed', stateVersion: 1,
  profileVersion: 0, planVersion: 0, assessedQuestionCount: 0,
  action: {label: '继续练习', targetPage: 'pages/ExercisePractice'}, handoffs: []
};
const legacy = {...learningContext, recordId: 'goal-test', chatSessionId: 'chat-test',
  updatedAt: '', status: 'waiting', learningContext};
for (const url of ['/api/v1/learning-records?limit=20&chatSessionId=chat-test',
                   '/api/v1/learning-records?limit=20&chatSessionId=']) {
  assert(context.validator.isValid('GET', url, {records: [], nextCursor: null}));
  assert(context.validator.isValid('GET', url, {records: [legacy], nextCursor: null}));
  assert(context.validator.isValid('GET', url, {
    records: [legacy, {...legacy, updatedAt: '2026-11-03T02:00:00Z'}], nextCursor: 'next-page'
  }));
  for (const updatedAt of [undefined, null, 123]) {
    assert.equal(context.validator.isValid('GET', url, {records: [{...legacy, updatedAt}], nextCursor: null}), false);
  }
  assert.equal(context.validator.isValid('GET', url, {records: [{...legacy, learningContext: {}}], nextCursor: null}), false);
}
assert.equal(context.page.updatedLabel(''), '更新时间未记录');
assert.equal(context.page.updatedLabel('invalid-date'), '更新时间未记录');
assert(context.page.updatedLabel('2026-11-03T02:00:00Z').startsWith('最近更新 '));
const deferred = () => {
  let resolve;
  const promise = new Promise(done => {resolve = done;});
  return {promise, resolve};
};
(async () => {
  const page = new context.PageController();
  page.owner = 'alice';
  let args;
  network.getLearningRecords = async (...values) => {
    args = values;
    return {ok: true, data: {records: [legacy], nextCursor: 'next-page'}};
  };
  await page.load();
  assert.equal(args.length, 1);
  assert.equal(args[0], '');
  assert.equal(page.records[0].recordId, legacy.recordId);
  await page.load(true);
  assert.equal(args[0], 'next-page');

  const pending = deferred();
  network.getLearningRecords = () => pending.promise;
  const loading = page.load();
  assert.equal(page.records.length, 0);
  state.chatSessionId = 'different-chat';
  pending.resolve({ok: true, data: {records: [legacy], nextCursor: null}});
  await loading;
  assert.equal(page.records.length, 1);

  network.getLearningRecords = async () => ({ok: false, error: {message: '网络不可用'}});
  await page.load();
  assert.equal(page.records.length, 0);
  assert.equal(page.cursor, null);
  assert(page.error.includes('网络不可用'));

  const stale = deferred();
  network.getLearningRecords = () => stale.promise;
  const switching = page.load();
  state.currentUser.userId = 'bob';
  stale.resolve({ok: true, data: {records: [legacy], nextCursor: null}});
  await switching;
  assert.equal(page.records.length, 0);
  console.log('PASS: legacy dates, account history without an active chat, pagination, chat changes, failed reloads and account isolation.');
})().catch(error => {console.error(error); process.exitCode = 1;});
