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

function loadPage(name, directory = 'pages') {
  const file = path.join(root, directory, name + '.ets');
  const source = fs.readFileSync(file, 'utf8');
  const declaration = /struct (\w+)\s*\{/.exec(source);
  const first = source.indexOf('  aboutToAppear()');
  const fieldSource = source.slice(declaration.index + declaration[0].length, first);
  const fieldMethods = /^  (?:(?:private|async)\s+)*(\w+)\(/gm;
  const fieldParts = []; let previous = 0, fieldMatch;
  while ((fieldMatch = fieldMethods.exec(fieldSource))) {
    fieldParts.push(fieldSource.slice(previous, fieldMatch.index));
    previous = endOfMethod(fieldSource, fieldSource.indexOf('{', fieldMatch.index));
    fieldMethods.lastIndex = previous;
  }
  fieldParts.push(fieldSource.slice(previous));
  const fields = fieldParts.join('')
    .replace(/^\s*@Builder\s*$/gm, '')
    .replace(/^\s*@(?:State|Prop|StorageLink\([^\n]+?\)|Watch\([^\n]+?\))\s*/gm, '\n  ')
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
    getContext: () => ({}),
    TodayStore: { save: () => {}, firstDisplay: () => false },
    LearningCardService: { saveOverview: async () => {} },
    ApiDefaults: { DEMO_USER_ID: 'demo-user', ALLOW_DEBUG: true, ALLOW_DEMO: true },
    router: {
      getParams: () => Object.hasOwn(network, 'routeParams') ? network.routeParams : ({ knowledgePointId: 'point' }),
      pushUrl: route => { network.lastRoute = route; },
      back: () => { network.backCalls = (network.backCalls || 0) + 1; }
    },
    LearningEvidence: { assessed: point => point.assessed === true, score: point => point.recentAccuracy ?? point.masteryScore, hasAccuracy: point => typeof point.recentAccuracy === 'number' },
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
    ClientCache: { getWorkflow: () => ({ sessionId: 'workflow' }), getWorkflowStatus: () => null,
      currentOwnerUserId: () => appState.currentUser.userId },
    AgentBridge: { callAgent: (...args) => network.chat(...args), loadHistory: () => network.history(), loadChatImage: (...args) => network.chatImage(...args) }
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
  await check('reminder reason stays attached to the same task during an unrelated refresh', async () => {
    const panel = loadPage('TodayPanel', 'components');
    panel.displayOwner = 'alice';
    panel.data = { userId: 'alice', highlight: { eventId: 'tcp', version: 1, title: 'TCP', reason: 'TCP deadline' }, tasks: [] };
    panel.toggleReason();
    network.getToday = async () => ok({ ...panel.data, tasks: [{ eventId: 'calculus', title: 'Calculus' }] });
    await panel.refresh();
    assert.equal(panel.expanded, true);
    assert.equal(panel.data.highlight.title, 'TCP');
    assert.equal(panel.data.highlight.reason, 'TCP deadline');
  });
  await check('changing the highlighted task closes its old reason before displaying a new task', async () => {
    const panel = loadPage('TodayPanel', 'components');
    panel.displayOwner = 'alice';
    panel.data = { userId: 'alice', highlight: { eventId: 'tcp', version: 1, title: 'TCP', reason: 'TCP deadline' }, tasks: [] };
    panel.toggleReason();
    network.getToday = async () => ok({ userId: 'alice', highlight: { eventId: 'report', version: 1, title: 'Report', reason: 'Report deadline' }, tasks: [] });
    await panel.refresh();
    assert.equal(panel.expanded, false);
    assert.equal(panel.data.highlight.eventId, 'report');
    panel.toggleReason();
    assert.equal(panel.data.highlight.reason, 'Report deadline');
  });
  await check('a newer version of the same reminder closes a previously expanded reason', async () => {
    const panel = loadPage('TodayPanel', 'components');
    panel.displayOwner = 'alice';
    panel.data = { userId: 'alice', highlight: { eventId: 'tcp', version: 1, title: 'TCP', reason: 'Old deadline' }, tasks: [] };
    panel.toggleReason();
    network.getToday = async () => ok({ ...panel.data, highlight: { ...panel.data.highlight, version: 2, reason: 'New deadline' } });
    await panel.refresh();
    assert.equal(panel.expanded, false);
    assert.equal(panel.data.highlight.reason, 'New deadline');
  });
  await check('wrong-book selection starts empty and applies only explicitly selected questions', async () => {
    const page = loadPage('WrongBook');
    const items = [{ exerciseId: 'a' }, { exerciseId: 'b' }, { exerciseId: 'c' }];
    page.beginAssignment();
    assert.equal(page.selecting, true);
    assert.equal(page.assigningIds.length, 0);
    page.toggleSelection(items[1]);
    assert.equal(page.assigningIds.join(','), 'b');
    page.selectAll(items);
    assert.equal(page.assigningIds.join(','), 'a,b,c');
    page.selectAll(items);
    assert.equal(page.assigningIds.length, 0);
    page.toggleSelection(items[2]);
    network.getConfig = () => ({ useFixture: false });
    let submitted;
    network.classifyWrongBook = async (ids, course) => {
      submitted = { ids: [...ids], course }; return ok({ courseName: course, updatedCount: ids.length });
    };
    network.getWrongBook = async () => ok({ total: 1, courses: [] });
    page.isPageActive = true;
    page.assignmentCourse = '算法专题';
    page.assignmentOpen = true;
    await page.assignCourse();
    assert.equal(submitted.ids.join(','), 'c');
    assert.equal(submitted.course, '算法专题');
    assert.equal(page.selecting, false);
    assert.equal(page.assignmentOpen, false);
  });
  await check('wrong-book group includes photos and unlocks fresh similar practice only after every question', async () => {
    const page = loadPage('WrongBook');
    const items = [
      { exerciseId: 'photo', courseName: '数据结构', knowledgePointId: 'tree', knowledgePointName: '树', options: [], canAutoGrade: false },
      { exerciseId: 'choice', courseName: '数据结构', knowledgePointId: 'tree', knowledgePointName: '树', options: ['A. a'], canAutoGrade: true }
    ];
    page.courses = [{ courseName: '数据结构', items }];
    page.startPractice(items[0]);
    assert.equal(page.practiceItems.length, 2);
    page.openSimilarPractice();
    const before = network.lastRoute;
    page.continuePractice();
    assert.equal(page.practiceIndex, 0);
    page.selectedAnswer = '我的解题过程';
    await page.submitAttempt();
    assert.equal(page.referenceReviewed, true);
    assert.equal(page.attempt, null, 'Unverified answers must not manufacture a grade');
    page.continuePractice();
    assert.equal(page.practiceItem.exerciseId, 'choice');
    page.openSimilarPractice();
    assert.equal(network.lastRoute, before);
    page.attempt = { correct: true };
    page.continuePractice();
    assert.equal(page.practiceCompleted, true);
    page.openSimilarPractice();
    assert.equal(network.lastRoute.params.forceGenerate, true);
    assert.equal(network.lastRoute.params.excludeExerciseIds.join(','), 'photo,choice');
    assert.equal(network.lastRoute.params.courseName, '数据结构');
    assert.equal(network.lastRoute.params.knowledgePointId, 'tree');
  });
  await check('leaving wrong-book practice rejects a late answer response', async () => {
    const page = loadPage('WrongBook');
    const pending = deferred();
    network.attemptWrongBook = () => pending.promise;
    network.getWrongBook = async () => ok({ total: 0, courses: [] });
    page.practiceItem = { exerciseId: 'choice', options: ['A. a'] };
    page.isPageActive = true;
    page.selectedAnswer = 'A';
    const sending = page.submitAttempt();
    page.leavePractice();
    pending.resolve(ok({ correct: true, removed: false }));
    await sending;
    assert.equal(page.attempt, null);
    assert.equal(page.isSubmitting, false);
  });
  await check('similar-practice route preserves force generation and initial exclusions', async () => {
    network.routeParams = { courseName: '数据结构', knowledgePointId: 'tree', forceGenerate: true, excludeExerciseIds: ['photo'] };
    const page = loadPage('ExercisePractice');
    page.readRouteParams();
    page.selectedCourse = '数据结构';
    let query;
    network.load = async (_set, _refresh, q) => { query = q; return exerciseSet; };
    await page.loadExercises();
    assert.equal(query.forceGenerate, true);
    assert.equal(query.generate, true);
    assert.equal(query.excludeExerciseIds.join(','), 'photo');
    delete network.routeParams;
  });
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
    assert.equal(validator.isValid('POST', '/api/v1/wrong-book/classify', { courseName: '数学', updatedCount: 2 }), true);
    assert.equal(validator.isValid('POST', '/api/v1/wrong-book/classify', { added: true, removed: false, exerciseId: 'x' }), false);
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
  await check('goal history selection serializes mutations and opens the selected task', async () => {
    appState.currentUser.userId = 'alice'; appState.chatSessionId = 'goals-chat';
    const pending = deferred(); let calls = 0;
    network.manageChatGoal = () => { calls++; return pending.promise; };
    const page = loadPage('ChatMain'); page.loadGoalHistory = async () => {};
    const selecting = page.changeGoal('select', 'one'); await page.changeGoal('select', 'two');
    assert.equal(calls, 1);
    pending.resolve({ ok: true, data: { status: 'selected', learningContext: { goalId: 'one' } } });
    await selecting; assert.equal(page.learningContext.goalId, 'one');
    assert.equal(page.showLearningGoalCard, true); assert.equal(page.isGoalLoading, false);
  });
  await check('intent switching clears stale image prompt and leaves image selection explicit', async () => {
    const page = loadPage('ChatMain'); let pickCount = 0;
    page.pickImage = async () => { pickCount++; };
    for (const intent of ['get_suggestion', 'analyze_weakness', 'match_partner', 'query_tasks', 'update_profile', 'analyze_wrong']) {
      page.voiceMessage = 'old image hint'; page.showGoalSummary = true;
      page.chooseIntent({ intent, prompt: 'prompt' });
      assert.equal(page.voiceMessage, ''); assert.equal(page.showGoalSummary, false);
    }
    assert.equal(pickCount, 0, 'switching intent must not open the picker without a camera action');
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
  await check('late document poll cannot restore a deleted document', async () => {
    const pending = deferred();
    network.getKnowledgeDocument = () => pending.promise;
    const page = loadPage('KnowledgeBase');
    page.waitFor = async () => {};
    page.loadKnowledgeBases = async () => {};
    page.selectedKbId = 'a'; page.documents = [{ ...doc('a', 'deleted'), status: 'processing' }];
    const polling = page.pollDocument('deleted', 'alice', 0);
    await Promise.resolve(); await Promise.resolve();
    await page.finishDelete('document', 'deleted', false);
    pending.resolve(ok(doc('a', 'deleted'))); await polling;
    assert.equal(page.documents.length, 0);
    assert.equal(page.uploadResultVisible, false);
  });
  await check('document poll stops after server reports deletion', async () => {
    let calls = 0;
    network.getKnowledgeDocument = async () => {
      calls++; return { ok: false, error: { code: 'NOT_FOUND' } };
    };
    const page = loadPage('KnowledgeBase'); page.waitFor = async () => {};
    page.selectedKbId = 'a'; page.documents = [{ ...doc('a', 'gone'), status: 'processing' }];
    await page.pollDocument('gone', 'alice', 0);
    assert.equal(calls, 1);
  });
  await check('partner matching ignores an older response after a newer match', async () => {
    const first = deferred(), second = deferred(); let calls = 0;
    network.matchPartner = () => (++calls === 1 ? first.promise : second.promise);
    const page = loadPage('PartnerMatch');
    const a = page.loadOnlineMatch(), b = page.loadOnlineMatch();
    const candidate = id => ({ candidate: { userId: id }, sharedCourses: [] });
    second.resolve(ok({ matchedCandidate: candidate('new'), candidates: [] })); await b;
    first.resolve(ok({ matchedCandidate: candidate('old'), candidates: [] })); await a;
    assert.equal(page.onlineBest.candidate.userId, 'new');
  });
  await check('partner contacts and invites cannot cross an account change', async () => {
    const contacts = deferred(), invites = deferred();
    network.listPartnerContacts = () => contacts.promise;
    network.listPartnerInvitations = () => invites.promise;
    const page = loadPage('PartnerMatch');
    const a = page.loadContacts(), b = page.loadInvitations();
    appState.currentUser = { userId: 'bob' };
    contacts.resolve(ok({ contacts: [{ partnerName: 'private' }] }));
    invites.resolve(ok({ invitations: [{ invitationId: 'private' }] }));
    await Promise.all([a, b]);
    assert.equal(page.contactNames.length, 0);
    assert.equal(page.incomingInvitations.length, 0);
  });
  await check('partner preference conflict refreshes version and permits retry', async () => {
    const page = loadPage('PartnerMatch');
    appState.currentUser.learningGoal = {};
    page.loadOnlineMatch = async () => {};
    page.targetCourses = ['edited']; page.targetGoal = 'draft';
    network.getProfile = async () => ok({ profileVersion: 7, profile: { targetCourses: ['server'] } });
    let expected;
    network.saveLearningPreferences = async (_, request) => {
      expected = request.expectedProfileVersion;
      return { ok: false, error: { code: 'CONFLICT', message: 'refresh' } };
    };
    await page.savePreferences();
    assert.equal(page.targetGoal, 'draft', 'conflict must retain the unsaved form');
    network.saveLearningPreferences = async (_, request) => {
      expected = request.expectedProfileVersion;
      return ok({ profileVersion: 8 });
    };
    await page.savePreferences();
    assert.equal(expected, 7);
  });
  await check('restored history keeps its image preview and original identifier', async () => {
    const page = loadPage('ChatMain');
    page.refreshLearningContext = () => {};
    page.restoreHistory({ sessionId: 'photos', turns: [{ userInput: 'question', botResponse: 'answer',
      timestamp: '2026-10-27T10:00:00', image: 'data:image/jpeg;base64,preview', imageFileId: 'photo-1' }] });
    assert.equal(page.messages[0].image, 'data:image/jpeg;base64,preview');
    assert.equal(page.messages[0].imageFileId, 'photo-1');
  });
  await check('closing image preview rejects a late original response', async () => {
    const pending = deferred(); network.chatImage = () => pending.promise;
    const page = loadPage('ChatMain'); page.isPageActive = true;
    const request = page.openImagePreview({ image: 'preview', imageFileId: 'photo-1' });
    page.closeImagePreview(); pending.resolve('private-original'); await request;
    assert.equal(page.previewImage, '');
  });
  await check('old account cannot populate an open image preview', async () => {
    const pending = deferred(); network.chatImage = () => pending.promise;
    const page = loadPage('ChatMain'); page.isPageActive = true;
    const request = page.openImagePreview({ image: 'preview', imageFileId: 'photo-1' });
    appState.currentUser = { userId: 'bob' }; page.onPageHide();
    pending.resolve('alice-original'); await request;
    assert.equal(page.previewImage, '');
  });
  await check('document reading joins adjacent fragments without repeating overlap', async () => {
    const page = loadPage('KnowledgeBase');
    page.detailChunks = [{ chunkId: '1', index: 1, headingPath: 'page 1', text: 'definition and complete sentence.', knowledgePoints: [] },
      { chunkId: '2', index: 2, headingPath: 'page 1', text: 'complete sentence. next definition.', knowledgePoints: [] },
      { chunkId: '3', index: 3, headingPath: 'page 2', text: 'another page', knowledgePoints: [] }];
    const sections = page.readingSections();
    assert.equal(sections.length, 2);
    assert.equal(sections[0].text, 'definition and complete sentence. next definition.');
    assert.equal(page.detailChunks[0].text, 'definition and complete sentence.');
  });
  await check('whole-page diagnosis keeps every question and changes practice selection', async () => {
    network.chat = async () => ({ reply: '整页结果', wrongAnalysis: { recognitionStatus: 'recognized',
      questions: [1, 2, 3].map(n => ({ questionNumber: String(n), questionText: `题目${n}`,
        knowledgePoint: `知识点${n}`, reply: `解析${n}`, recognitionStatus: 'recognized' })) } });
    const page = loadPage('WrongQuestion'); page.isPageActive = true;
    await page.runOnlineAnalysis('image', 'photo');
    assert.equal(page.analysisResults.length, 3);
    page.selectQuestion(2);
    assert.equal(page.analysisResult.reason, '解析3');
    assert.equal(page.analysisResult.knowledge[0], '知识点3');
    assert.equal(appState.latestWrongAnalysis.questionNumber, '3');
    appState.selectedImageUri = '';
    const restored = loadPage('WrongQuestion'); restored.aboutToAppear();
    assert.equal(restored.analysisResults.length, 3);
    assert.equal(restored.selectedQuestionIndex, 2);
  });
  await check('late page diagnosis cannot overwrite a newly selected image', async () => {
    const old = deferred(), current = deferred(); let count = 0;
    network.chat = () => (++count === 1 ? old.promise : current.promise);
    const page = loadPage('WrongQuestion'); page.isPageActive = true;
    const first = page.runOnlineAnalysis('old', 'old-photo');
    page.analysisRequestVersion++;
    const second = page.runOnlineAnalysis('new', 'new-photo');
    current.resolve({ reply: 'new', wrongAnalysis: { knowledgePoint: 'new-point', recognitionStatus: 'recognized' } });
    await second;
    old.resolve({ reply: 'old', wrongAnalysis: { knowledgePoint: 'old-point', recognitionStatus: 'recognized' } });
    await first;
    assert.equal(page.analysisResult.knowledge[0], 'new-point');
    assert.equal(page.analysisResult.imageUri, 'new-photo');
  });
  await check('chat confirmation uses the selected page question diagnosis', async () => {
    let sent;
    network.manageChatGoal = async (id, payload) => { sent = payload; return ok({ learningContext: null }); };
    const page = loadPage('ChatMain'); page.loadGoalHistory = () => {};
    page.diagnosisEdits = [{ id: 'diagnosis-3', point: '第三题修订知识点' }];
    await page.confirmDiagnosis({ id: 'message', wrongAnalysis: { diagnosisId: 'diagnosis-1', knowledgePoint: '第一题' } },
      { diagnosisId: 'diagnosis-3', knowledgePoint: '第三题' });
    assert.equal(sent.diagnosisId, 'diagnosis-3');
    assert.equal(sent.knowledgePoint, '第三题修订知识点');
  });
  await check('empty page recognition cannot create a phantom question', async () => {
    network.chat = async () => ({ reply: '未识别到题目', wrongAnalysis: { recognitionStatus: 'unreadable', questions: [] } });
    const page = loadPage('WrongQuestion'); page.isPageActive = true;
    await page.runOnlineAnalysis('image', 'photo');
    assert.equal(page.analysisResults.length, 0);
    assert.equal(page.showAnalysis, false);
    assert.equal(page.analysisMessage, '未识别到题目');
  });
  await check('actual response parser preserves all diagnoses and legacy single-question results', async () => {
    const source = fs.readFileSync(path.join(root, 'services/AgentBridge.ets'), 'utf8')
      .replace(/^import[^\n]+\n/gm, '').replace('export class AgentBridge', 'class AgentBridge');
    const code = ts.transpileModule(source + '\nglobalThis.Bridge = AgentBridge;', {
      compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText;
    const context = vm.createContext({ console, ApiDefaults: { LLM_BOUND_READ_TIMEOUT_MS: 40000 } });
    vm.runInContext(code, context);
    const parse = wrongAnalysis => context.Bridge.parseResponse({ reply: '整页解析', intent: 'analyze_wrong', card: null, wrongAnalysis });
    const response = parse({ recognitionStatus: 'recognized', questionCount: 2, complete: true,
      questions: [1, 2].map(n => ({ questionNumber: String(n), questionText: `题${n}`, diagnosisId: `d${n}`, reply: `解析${n}` })) });
    assert.equal(response.wrongAnalysis.questions.length, 2);
    assert.equal(response.wrongAnalysis.questions[1].diagnosisId, 'd2');
    assert.equal(response.wrongAnalysis.questions[1].reply, '解析2');
    assert.equal(parse({ knowledgePoint: 'legacy' }).wrongAnalysis.knowledgePoint, 'legacy');
    assert.equal(parse({}).wrongAnalysis, undefined);
    assert.equal(parse({ recognitionStatus: 'unreadable', questions: [] }).wrongAnalysis.questions.length, 0);
  });
  await check('review back returns to the same diagnosis without popping its route', async () => {
    const page = loadPage('ExercisePractice');
    page.result = { submissionId: 'original', review: [] };
    page.answers = ['A', 'B']; page.isPageActive = true;
    page.pageScroller = { currentOffset: () => ({ yOffset: 250 }), scrollEdge: () => {} };
    network.backCalls = 0;
    page.openReview(); assert.equal(page.showReview, true); assert.equal(page.resultOffset, 250);
    assert.equal(page.onBackPress(), true);
    assert.equal(page.showReview, false); assert.equal(network.backCalls, 0);
    assert.equal(page.result.submissionId, 'original'); assert.deepEqual(Array.from(page.answers), ['A', 'B']);
    page.goBack(); assert.equal(network.backCalls, 1);
  });
  await check('source overlay takes precedence over review when returning', async () => {
    const page = loadPage('ExercisePractice'); network.backCalls = 0;
    page.sourceVisible = true; page.showReview = true;
    const version = page.sourceRequestVersion;
    page.goBack(); assert.equal(page.sourceVisible, false); assert.equal(page.showReview, true);
    assert.equal(page.sourceRequestVersion, version + 1); assert.equal(network.backCalls, 0);
  });
  await check('course next step accepts null, undefined and empty route parameters', async () => {
    const course = { courseName: '数据结构', goal: '期末 85 分', examDate: '2026-11-10' };
    network.courseSettings = async () => ok({ courses: [course] });
    for (const params of [null, undefined, {}]) {
      network.routeParams = params;
      const page = loadPage('LearningSetup');
      assert.doesNotThrow(() => page.aboutToAppear());
      await new Promise(resolve => setImmediate(resolve));
      assert.equal(page.course, course.courseName);
      assert.equal(page.goal, course.goal);
      assert.equal(page.exam, course.examDate);
      assert.equal(page.addingCourse, false);
    }
    delete network.routeParams;
  });
  await check('course setup keeps named-course and new-course navigation', async () => {
    const courses = [
      { courseName: '数据结构', goal: '85 分', examDate: '2026-11-10' },
      { courseName: '操作系统', goal: '90 分', examDate: '2026-11-12' }
    ];
    network.courseSettings = async () => ok({ courses });
    network.routeParams = { courseName: '操作系统' };
    const named = loadPage('LearningSetup');
    named.aboutToAppear();
    network.routeParams = null; // Loading must use the parameters from page entry.
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(named.course, '操作系统');
    assert.equal(named.exam, '2026-11-12');
    network.routeParams = { newCourse: 'true' };
    const adding = loadPage('LearningSetup');
    adding.aboutToAppear();
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(adding.addingCourse, true);
    assert.equal(adding.course, '');
    delete network.routeParams;
  });
  await check('portrait practice opens the weakest assessed point in the selected course', async () => {
    const page = loadPage('StudyTags');
    page.mastery = [
      { knowledgePointId: 'unassessed', masteryScore: 0, assessed: false },
      { knowledgePointId: 'strong', masteryScore: 80, assessed: true },
      { knowledgePointId: 'weak', knowledgePointName: '线性表与链表', masteryScore: 20, assessed: true },
      { knowledgePointId: 'a-tied', knowledgePointName: '栈', masteryScore: 20, assessed: true }
    ];
    assert.equal(page.hasAssessment(), true);
    page.openRecommendedPractice();
    assert.equal(network.lastRoute.url, 'pages/ExercisePractice');
    assert.equal(network.lastRoute.params.knowledgePointId, 'weak');
    assert.ok(page.weaknessSummary().includes('线性表与链表'));
    page.mastery = [{ knowledgePointId: 'new', masteryScore: 0, assessed: false }];
    assert.equal(page.hasAssessment(), false);
    page.openRecommendedPractice();
    assert.equal(network.lastRoute.url, 'pages/ExercisePractice');
    assert.equal(network.lastRoute.params, undefined);
  });
  console.log(`${passed} request recovery checks passed (actual controller methods; device UI not exercised).`);
})().catch(error => { console.error(error); process.exit(1); });
