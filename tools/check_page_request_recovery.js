/* Execute actual page methods with deferred HTTP; strip only ArkUI builders.
 * This checks lifecycle/race behavior and real response guards, not device UI.
 * node tools/check_page_request_recovery.js <typescript/lib/typescript.js>
 */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2] || 'typescript');
const root = path.resolve(__dirname, '../app/entry/src/main/ets');
let passed = 0;
const network = {};
const appState = { currentUser: { userId: 'alice' }, chatSessionId: '', chatMessages: '', hasActiveChat: false };
const snapshot = { EXERCISE_SET_ID: 'set', EXERCISE_COUNT: 1, EXERCISE_KNOWLEDGE_POINT_ID: 'point',
  USER_ID: 'demo-user', getResetVersion: () => 0 };
const deferred = () => {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
};

// Match braces while ignoring strings and comments. Templates in extracted
// controller methods are ordinary strings; their ${...} braces are not blocks.
function endOfMethod(source, start) {
  let depth = 0;
  for (let i = start; i < source.length; i++) {
    const c = source[i];
    if (c === '/' && source[i + 1] === '/') {
      i = source.indexOf('\n', i);
      if (i < 0) break;
    } else if (c === '/' && source[i + 1] === '*') {
      i = source.indexOf('*/', i + 2) + 1;
    } else if (c === '"' || c === "'" || c === '`') {
      const quote = c;
      while (++i < source.length) {
        if (source[i] === '\\') i++;
        else if (source[i] === quote) break;
      }
    } else if (c === '{') depth++;
    else if (c === '}' && --depth === 0) return i + 1;
  }
  throw Error('unclosed method');
}

function loadPage(name) {
  const file = path.join(root, 'pages', name + '.ets');
  const source = fs.readFileSync(file, 'utf8');
  const declaration = /struct (\w+)\s*\{/.exec(source);
  const first = source.indexOf('  aboutToAppear()');
  const fields = source.slice(declaration.index + declaration[0].length, first)
    .replace(/^\s*@(?:State|StorageLink\([^\n]+?\)|Watch\([^\n]+?\))\s*/gm, '\n  ')
    .replace(/@Watch\([^)]*\)\s*/g, '');
  const methods = [];
  const pattern = /^  (?:(?:private|async)\s+)*(\w+)\(/gm;
  let match;
  while ((match = pattern.exec(source))) {
    if (match[1] === 'build' || /^[A-Z]/.test(match[1])) continue;
    const brace = source.indexOf('{', match.index);
    const end = endOfMethod(source, brace);
    methods.push(source.slice(match.index, end));
    pattern.lastIndex = end;
  }
  const generated = `class ${declaration[1]} {${fields}\n${methods.join('\n')}\n}\nglobalThis.Page = ${declaration[1]};`;
  const compiled = ts.transpileModule(generated, { reportDiagnostics: true,
    compilerOptions: { target: ts.ScriptTarget.ES2020 } });
  assert.equal(compiled.diagnostics.length, 0, 'controller extraction must compile');
  const context = vm.createContext({ console, Date, JSON, Promise, Map, Set,
    // Scrolling and device services do not participate in request decisions.
    setTimeout: () => 0, clearTimeout: () => {}, setInterval: () => 0, clearInterval: () => {},
    appState, DemoSnapshot: snapshot, AgentApiClient: network,
    ApiDefaults: { DEMO_USER_ID: 'demo-user' },
    router: { getParams: () => ({ knowledgePointId: 'point' }) },
    Scroller: class {}, Edge: {},
    ExerciseViewModel: class {
      load(...args) { return network.load(...args); }
      submit(...args) { return network.submit(...args); }
      getErrorMessage() { return 'offline'; }
      getWarningMessage() { return ''; }
      getSubmissionFailure() { return network.submissionFailure ?? null; }
    },
    ProfileViewModel: class { load(...args) { return network.profile(...args); } },
    WorkflowViewModel: class {
      refreshStatus(...args) { return network.workflowStatus(...args); }
      getErrorMessage() { return 'offline'; }
    }, VoiceInputService: class { async dispose() {} },
    ClientCache: { getWorkflow: () => ({ sessionId: 'workflow' }), getWorkflowStatus: () => null },
    AgentBridge: { callAgent: (...args) => network.chat(...args), loadHistory: () => network.history() }
  });
  vm.runInContext(compiled.outputText, context, { filename: file });
  return new context.Page();
}

const exerciseSet = { setId: 'set', exercises: [{ exerciseId: 'e', knowledgePointId: 'point' }] };
const result = { review: [{ inWrongBook: true }], assessment: {} };
const doc = (kbId, documentId) => ({ kbId, documentId, fileName: documentId, status: 'ready', chunkCount: 1 });
const ok = data => ({ ok: true, data });

async function check(name, run) {
  appState.currentUser = { userId: 'alice' };
  await run();
  passed++;
  console.log('PASS ' + name);
}

(async () => {
  await check('workflow refresh can be retried after completing while hidden', async () => {
    const pending = deferred();
    network.workflowStatus = () => pending.promise;
    const page = loadPage('ChatMain');
    page.syncWorkflowSummary = () => {};
    page.isPageActive = true;
    const refreshing = page.refreshWorkflowStatus();
    page.onPageHide();
    pending.resolve({ status: 'running' });
    await refreshing;
    assert.equal(page.isWorkflowLoading, false);
    page.isPageActive = true;
    let retried = false;
    network.workflowStatus = async () => { retried = true; return { status: 'completed' }; };
    await page.refreshWorkflowStatus();
    assert.equal(retried, true);
  });
  await check('switching history while sending unlocks new conversation', async () => {
    const pending = deferred();
    network.chat = () => pending.promise;
    const page = loadPage('ChatMain');
    page.refreshLearningContext = () => {};
    page.inputText = 'old question';
    const sending = page.sendMessage();
    page.restoreHistory({ sessionId: 'history', turns: [] });
    pending.resolve({ reply: 'old answer', intent: 'free_chat' });
    await sending;
    assert.equal(page.isSending, false);
    assert.equal(page.messages.length, 0);
  });
  await check('late history request cannot expose previous account records', async () => {
    const pending = deferred();
    network.history = () => pending.promise;
    const page = loadPage('ChatMain');
    const loading = page.openHistory();
    appState.currentUser = { userId: 'bob' };
    pending.resolve([{ sessionId: 'alice-private', userInput: 'private', timestamp: '2026', botResponse: 'private' }]);
    await loading;
    assert.equal(page.historySessions.length, 0);
  });
  await check('history request completes while page is covered', async () => {
    const pending = deferred();
    network.history = () => pending.promise;
    const page = loadPage('ChatMain');
    const loading = page.openHistory();
    page.onPageHide();
    pending.resolve([{ sessionId: 'own-history', userInput: 'question', timestamp: '2026', botResponse: 'answer' }]);
    await loading;
    assert.equal(page.historyLoading, false);
    assert.equal(page.historySessions[0].sessionId, 'own-history');
  });
  await check('uncertain submit freezes original answers for an identical retry', async () => {
    const page = loadPage('ExercisePractice');
    page.exercises = exerciseSet.exercises;
    page.answers = ['A'];
    page.submissionKey = 'uncertain';
    network.submissionFailure = { error: { code: 'NETWORK_ERROR', statusCode: 0 } };
    network.submit = async () => null;
    await page.submit();
    page.selectAnswer(0, 'B. changed');
    network.submit = async (_, submission) => {
      assert.equal(submission.answers[0].answer, 'A');
      assert.equal(submission.idempotencyKey, 'uncertain');
      return result;
    };
    await page.submit();
    network.submissionFailure = null;
  });
  await check('definite server rejection permits corrected answers', async () => {
    const page = loadPage('ExercisePractice');
    page.exercises = exerciseSet.exercises;
    page.answers = ['A'];
    page.submissionKey = 'rejected';
    network.submissionFailure = { error: { code: 'BAD_REQUEST', statusCode: 400 } };
    network.submit = async () => null;
    await page.submit();
    assert.equal(page.submissionUnconfirmed, false);
    page.selectAnswer(0, 'B. corrected');
    network.submit = async (_, submission) => {
      assert.equal(submission.answers[0].answer, 'B');
      return result;
    };
    await page.submit();
    network.submissionFailure = null;
  });
  await check('exercise load completes while page is covered', async () => {
    const pending = deferred();
    network.load = () => pending.promise;
    const page = loadPage('ExercisePractice');
    page.isPageActive = true;
    const loading = page.loadExercises();
    page.onPageHide();
    pending.resolve(exerciseSet);
    await loading;
    assert.equal(page.isLoading, false);
    assert.equal(page.exercises[0].exerciseId, 'e');
    assert.ok(page.submissionKey);
  });
  await check('covered submit keeps one idempotency key and adopts result', async () => {
    const pending = deferred();
    const page = loadPage('ExercisePractice');
    page.exercises = exerciseSet.exercises;
    page.answers = ['A'];
    page.submissionKey = 'stable-key';
    let requests = 0;
    network.submit = (setId, payload) => {
      requests++;
      assert.equal(payload.idempotencyKey, 'stable-key');
      return pending.promise;
    };
    const submitting = page.submit();
    page.onPageHide();
    page.backToPicker();
    assert.equal(page.isSubmitting, true);
    assert.equal(page.showPicker, false);
    await page.submit();
    pending.resolve(result);
    await submitting;
    assert.equal(requests, 1);
    assert.equal(page.isSubmitting, false);
    assert.equal(page.result, result);
    assert.equal(page.submissionKey, 'stable-key');
  });
  await check('failed covered submission is retryable with original key', async () => {
    const page = loadPage('ExercisePractice');
    page.exercises = exerciseSet.exercises;
    page.answers = ['A'];
    page.submissionKey = 'retry-key';
    network.submit = async (_, payload) => { assert.equal(payload.idempotencyKey, 'retry-key'); return null; };
    page.onPageHide();
    await page.submit();
    assert.equal(page.isSubmitting, false);
    assert.match(page.errorMessage, /offline/);
    assert.equal(page.submissionUnconfirmed, true);
    network.submit = async (_, payload) => { assert.equal(payload.idempotencyKey, 'retry-key'); return result; };
    await page.submit();
    assert.equal(page.result, result);
  });
  await check('destroyed exercise page ignores its old load', async () => {
    const pending = deferred();
    network.load = () => pending.promise;
    const page = loadPage('ExercisePractice');
    const loading = page.loadExercises();
    page.aboutToDisappear();
    pending.resolve(exerciseSet);
    await loading;
    assert.equal(page.exercises.length, 0);
  });
  await check('picker completes while hidden and cannot overwrite a newer flow', async () => {
    const pending = deferred();
    network.profile = () => pending.promise;
    const page = loadPage('ExercisePractice');
    const loading = page.loadPickerOptions();
    page.onPageHide();
    pending.resolve({ mastery: [], errorMessage: '' });
    await loading;
    assert.equal(page.pickerLoading, false);
    assert.equal(page.showPicker, true);
    const older = deferred();
    network.profile = () => older.promise;
    const picking = page.loadPickerOptions();
    network.load = async () => exerciseSet;
    page.chooseKnowledgePoint({ knowledgePointId: 'new' });
    older.resolve({ mastery: [], errorMessage: '' });
    await picking;
    assert.equal(page.showPicker, false);
  });
  await check('identity change rejects old exercise result', async () => {
    const pending = deferred();
    network.load = () => pending.promise;
    const page = loadPage('ExercisePractice');
    const loading = page.loadExercises();
    appState.currentUser = { userId: 'bob' };
    pending.resolve(exerciseSet);
    await loading;
    assert.equal(page.exercises.length, 0);
  });
  await check('chat response replaces sending bubble while covered', async () => {
    const pending = deferred();
    network.chat = () => pending.promise;
    const page = loadPage('ChatMain');
    page.inputText = 'hello';
    const sending = page.sendMessage();
    page.onPageHide();
    assert.equal(page.isSending, true);
    pending.resolve({ reply: 'reply', intent: 'free_chat' });
    await sending;
    assert.equal(page.isSending, false);
    assert.equal(page.messages.some(m => m.status === 'sending'), false);
    assert.equal(page.messages.at(-1).text, 'reply');
    assert.match(appState.chatMessages, /reply/);
  });
  await check('destroyed chat persists interrupted message and rejects old response', async () => {
    const pending = deferred();
    network.chat = () => pending.promise;
    const page = loadPage('ChatMain');
    page.inputText = 'destroy';
    const sending = page.sendMessage();
    page.aboutToDisappear();
    assert.equal(JSON.parse(appState.chatMessages).some(m => m.status === 'sending'), false);
    pending.resolve({ reply: 'stale', intent: 'free_chat' });
    await sending;
    assert.equal(page.messages.some(m => m.text === 'stale'), false);
  });
  await check('new chat invalidates previous response', async () => {
    const pending = deferred();
    network.chat = () => pending.promise;
    const page = loadPage('ChatMain');
    page.inputText = 'old';
    const sending = page.sendMessage();
    page.resetChat();
    pending.resolve({ reply: 'old reply', intent: 'free_chat' });
    await sending;
    assert.equal(page.messages.length, 0);
  });
  await check('out-of-order document responses keep selected library', async () => {
    const a = deferred(), b = deferred();
    network.getKnowledgeBase = id => id === 'a' ? a.promise : b.promise;
    const page = loadPage('KnowledgeBase');
    page.selectKnowledgeBase('a');
    const first = page.loadDocuments();
    page.selectKnowledgeBase('b');
    const second = page.loadDocuments();
    b.resolve(ok({ kbId: 'b', documents: [doc('b', 'b-doc')] }));
    await second;
    a.resolve(ok({ kbId: 'a', documents: [doc('a', 'a-doc')] }));
    await first;
    assert.equal(page.documents[0].documentId, 'b-doc');
  });
  await check('switching library invalidates search without clearing newer busy flag', async () => {
    const a = deferred(), b = deferred();
    network.searchKnowledgeBase = id => id === 'a' ? a.promise : b.promise;
    const page = loadPage('KnowledgeBase');
    page.selectKnowledgeBase('a');
    page.searchQuery = 'query';
    const first = page.runSearch();
    page.selectKnowledgeBase('b');
    const second = page.runSearch();
    a.resolve(ok({ hits: ['stale'] }));
    await first;
    assert.equal(page.isSearching, true);
    assert.equal(page.hits.length, 0);
    b.resolve(ok({ hits: ['current'], retrievalMode: 'lexical', totalScanned: 1 }));
    await second;
    assert.equal(page.hits[0], 'current');
    assert.equal(page.isSearching, false);
  });
  await check('upload into previous library cannot pollute current documents or tab', async () => {
    const pending = deferred();
    network.uploadKnowledgeDocument = () => pending.promise;
    network.listKnowledgeBases = async () => ok({ knowledgeBases: [{ kbId: 'a' }, { kbId: 'b' }] });
    network.getKnowledgeBase = async id => ok({ kbId: id, documents: [doc(id, id + '-doc')] });
    const page = loadPage('KnowledgeBase');
    page.selectKnowledgeBase('a');
    const upload = page.uploadEncoded('new', 'encoded', 1, 'text/plain');
    page.selectKnowledgeBase('b');
    page.activeTab = 'search';
    pending.resolve(ok(doc('a', 'new')));
    await upload;
    // showUploadSuccess is asynchronous; drain its list/details continuation.
    await new Promise(done => setImmediate(done));
    assert.equal(page.isUploading, false);
    assert.equal(page.documents[0].documentId, 'b-doc');
    assert.equal(page.activeTab, 'search');
  });
  await check('old-account library response cannot enter new account page', async () => {
    const pending = deferred();
    network.getKnowledgeBase = () => pending.promise;
    const page = loadPage('KnowledgeBase');
    page.selectKnowledgeBase('a');
    const loading = page.loadDocuments();
    appState.currentUser = { userId: 'bob' };
    pending.resolve(ok({ documents: [doc('a', 'private')] }));
    await loading;
    assert.equal(page.documents.length, 0);
  });
  await check('actual API validator accepts focus GET/POST and rejects invalid payloads', async () => {
    const source = fs.readFileSync(path.join(root, 'api/ApiResponseValidator.ets'), 'utf8');
    const compiled = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS } }).outputText;
    const module = { exports: {} };
    vm.runInNewContext('(function(module,exports){' + compiled + '\n})')(module, module.exports);
    const validator = module.exports.ApiResponseValidator;
    assert.equal(validator.isValid('GET', '/api/v1/focus-sessions?x=1', { userId: 'alice', sessions: [] }), true);
    assert.equal(validator.isValid('POST', '/api/v1/focus-sessions', { userId: 'alice', eventId: 'e', planTaskMatched: true }), true);
    assert.equal(validator.isValid('GET', '/api/v1/focus-sessions', { userId: 'alice' }), false);
    assert.equal(validator.isValid('POST', '/api/v1/focus-sessions', { userId: 'alice', eventId: 'e' }), false);
    assert.equal(validator.isValid('GET', '/api/v1/missing', {}), false);
  });
  await check('late diagnosis confirmation cannot overwrite a newer goal request', async () => {
    appState.currentUser.userId = 'alice'; appState.chatSessionId = 'goals-chat';
    const pending = deferred(); network.manageChatGoal = () => pending.promise;
    const page = loadPage('ChatMain'); page.loadGoalHistory = async () => {};
    const confirming = page.confirmDiagnosis({ id: 'message', wrongAnalysis: { diagnosisId: 'd', knowledgePoint: 'trees' } });
    page.goalRequestVersion++; page.learningContext = { goalId: 'newer' }; page.isGoalLoading = false;
    pending.resolve({ ok: true, data: { status: 'created', learningContext: { goalId: 'late' } } });
    await confirming; assert.equal(page.learningContext.goalId, 'newer');
  });
  await check('goal switching serializes mutations and preserves a collapsed summary', async () => {
    appState.currentUser.userId = 'alice'; appState.chatSessionId = 'goals-chat';
    const pending = deferred(); let calls = 0;
    network.manageChatGoal = () => { calls++; return pending.promise; };
    const page = loadPage('ChatMain'); page.loadGoalHistory = async () => {};
    const selecting = page.changeGoal('select', 'one'); await page.changeGoal('select', 'two');
    assert.equal(calls, 1);
    pending.resolve({ ok: true, data: { status: 'selected', learningContext: { goalId: 'one' } } });
    await selecting; assert.equal(page.learningContext.goalId, 'one');
    assert.equal(page.showLearningGoalCard, false); assert.equal(page.isGoalLoading, false);
  });
  await check('intent switching clears stale image prompt without adding another', async () => {
    const page = loadPage('ChatMain'); let pickCount = 0;
    page.pickImage = async () => { pickCount++; };
    for (const intent of ['get_suggestion', 'analyze_weakness', 'match_partner', 'query_tasks', 'update_profile', 'analyze_wrong']) {
      page.voiceMessage = 'old image hint'; page.showGoalSummary = true;
      page.chooseIntent({ intent, prompt: 'prompt' });
      assert.equal(page.voiceMessage, ''); assert.equal(page.showGoalSummary, false);
    }
    assert.equal(pickCount, 1);
  });
  await check('only an explicitly started learning reply displays a goal summary', async () => {
    const page = loadPage('ChatMain');
    network.chat = async () => ({ reply: 'start', intent: 'get_suggestion', learningContext: { goalId: 'one' } });
    page.inputText = 'start practice'; await page.sendMessage();
    assert.equal(page.showGoalSummary, true);
    network.chat = async () => ({ reply: 'profile', intent: 'update_profile' });
    page.inputText = 'view profile'; await page.sendMessage();
    assert.equal(page.showGoalSummary, false);
  });
  console.log(`${passed} request recovery checks passed (actual controller methods; device UI not exercised).`);
})().catch(error => { console.error(error); process.exit(1); });
