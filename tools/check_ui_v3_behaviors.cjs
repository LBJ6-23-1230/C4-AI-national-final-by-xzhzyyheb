const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.argv[2] || 'typescript');
const root = 'app/entry/src/main/ets/';
function between(file, start, end) {
  const source = fs.readFileSync(root + file, 'utf8');
  const a = source.indexOf(start), b = source.indexOf(end, a + start.length);
  assert(a >= 0 && b > a, `Production method missing: ${file}: ${start}`);
  return source.slice(a, b);
}
const context = vm.createContext({
  appState: { currentUser: { userId: 'alice' } },
  AgentApiClient: {},
  router: { getParams: () => ({}), replaceUrl: () => {} },
  console
});
function execute(source) {
  vm.runInContext(ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }
  }).outputText, context);
}
execute(fs.readFileSync(root + 'utils/DateHelper.ets', 'utf8').replace(/export /g, '') +
  '\nglobalThis.DateHelper = DateHelper;');
execute('class DdlHarness {' + between('data/AppState.ets', '  public updateDDL(', '  public removeDDL(') +
  '} globalThis.DdlHarness = DdlHarness;');
execute('class InboxHarness {' + between('pages/PartnerInbox.ets', '  private async load(', '  private time(') +
  '} globalThis.InboxHarness = InboxHarness;');
execute('class TabHarness {' + between('pages/Index.ets', '  private applyInitialTab(', '  aboutToDisappear(') +
  '} globalThis.TabHarness = TabHarness;');
execute('class NavigationHarness {' + between('components/AppBottomBar.ets', '  private selectTab(', '  @Builder') +
  '} globalThis.NavigationHarness = NavigationHarness;');
execute('class AgentBridge {' + between('services/AgentBridge.ets', '  private static parseWrongAnalysis(', '  private static parseLearningContext(') +
  between('services/AgentBridge.ets', '  private static stringField(', '  private static normalizeIntent(') +
  '} globalThis.AgentBridge = AgentBridge;');
let checks = 0;
const check = (value, message) => { assert(value, message); checks++; };
const original = { id: 'ddl-1', courseId: 'course-1', syncVersion: 9, courseName: '数据结构',
  origin: 'import', completed: true, title: '原作业', dueDate: '2026-11-10', estimatedMinutes: 30,
  priority: '中', daysLeft: 6 };
function ddlFixture(saved = true) {
  const state = new context.DdlHarness();
  state.homeworkDDLs = [{ ...original }];
  state.persistCalls = 0; state.notifications = 0;
  state.persistLearningData = () => { state.persistCalls++; return saved; };
  state.notifyLearningDataChanged = () => state.notifications++;
  return state;
}
(async () => {
  const tabs = new context.TabHarness();
  tabs.activeTab = 1; tabs.lastRequestedTab = -1;
  let params = { initialTab: 2 };
  context.router.getParams = () => params;
  tabs.applyInitialTab(); check(tabs.activeTab === 2, 'Numeric route selects Study');
  tabs.activeTab = 3; tabs.applyInitialTab();
  check(tabs.activeTab === 3, 'Returning from a child cannot reset a locally selected tab');
  params = { initialTab: '1' }; tabs.applyInitialTab();
  check(tabs.activeTab === 1, 'Reused page consumes a new string route parameter');
  params = { initialTab: 99 }; tabs.applyInitialTab();
  check(tabs.activeTab === 1, 'Invalid route cannot select an absent tab');
  const navigation = new context.NavigationHarness(); let routed;
  context.router.replaceUrl = value => { routed = value; };
  navigation.selectTab(2);
  check(routed.url === 'pages/Index' && routed.params.initialTab === 2, 'Secondary page retains the requested tab');
  navigation.selectTab(0);
  check(routed.url === 'pages/ChatMain', 'Chat has its own root route');
  navigation.onSelect = index => { routed = index; }; navigation.selectTab(3);
  check(routed === 3, 'Root callback switches locally');
  let state = ddlFixture();
  check(state.updateDDL('ddl-1', ' 新名称 ', '2026-11-12 18:00', 45, '高'), 'Valid edit saves');
  for (const key of ['id', 'courseId', 'courseName', 'syncVersion', 'origin', 'completed'])
    check(state.homeworkDDLs[0][key] === original[key], `Preserves ${key}`);
  check(state.homeworkDDLs[0].title === '新名称' && state.notifications === 1 && state.persistCalls === 1,
    'Edit notifies after persistence');
  for (const [title, date, minutes] of [['', '2026-11-12', 30], ['ok', 'invalid', 30],
    ['ok', '2026-11-12', 0], ['ok', '2026-11-12', 1441], ['ok', '2026-11-12', 1.5]]) {
    state = ddlFixture(); const previous = state.homeworkDDLs;
    check(!state.updateDDL('ddl-1', title, date, minutes, '中') && state.homeworkDDLs === previous &&
      state.persistCalls === 0 && state.notifications === 0, 'Invalid edit leaves data untouched');
  }
  state = ddlFixture(false); const previous = state.homeworkDDLs;
  check(!state.updateDDL('ddl-1', 'ok', '2026-11-12', 30, '中') && state.homeworkDDLs === previous &&
    state.notifications === 0, 'Failed persistence rolls back');
  check(!state.updateDDL('missing', 'ok', '2026-11-12', 30, '中'), 'Missing assignment cannot be created by editing');
  const item = id => ({ partnerUserId: id, partnerName: id });
  const ok = (conversations, hasMore, nextOffset) => ({ ok: true, data: { conversations, hasMore, nextOffset } });
  function inboxFixture(pages) {
    const inbox = new context.InboxHarness();
    Object.assign(inbox, { owner: 'alice', active: true, loading: false, items: [item('old')], nextPageOffset: 0, notice: '' });
    const offsets = [];
    context.appState.currentUser.userId = 'alice';
    context.AgentApiClient.partnerInbox = async offset => {
      offsets.push(offset); const page = pages[offsets.length - 1];
      return typeof page === 'function' ? page(inbox) : page;
    };
    return { inbox, offsets };
  }
  let f = inboxFixture([ok([item('a'), item('b')], true, 2), ok([item('b'), item('c')], false, 4)]);
  await f.inbox.load();
  check(JSON.stringify(f.offsets) === '[0,2]' && f.inbox.items.map(i => i.partnerUserId).join() === 'a,b,c',
    'All pages load sequentially with deduplication');
  check(!f.inbox.loading && !f.inbox.hasMore && !f.inbox.notice, 'Complete list needs no load-more button');
  f = inboxFixture([ok([item('a')], true, 1), { ok: false, error: { message: 'offline' } }]);
  await f.inbox.load();
  check(f.inbox.items[0].partnerUserId === 'old' && f.inbox.notice.includes('重试') && !f.inbox.loading,
    'Later failure preserves visible conversations and retry');
  f = inboxFixture([ok([item('a')], true, 0)]); await f.inbox.load();
  check(f.offsets.length === 1 && f.inbox.items[0].partnerUserId === 'old' && f.inbox.notice.includes('完整'),
    'Nonadvancing cursor is never reported as a complete inbox');
  f = inboxFixture([() => { context.appState.currentUser.userId = 'bob'; return ok([item('alice-private')], false, 1); }]);
  await f.inbox.load();
  check(f.inbox.items[0].partnerUserId === 'old' && !f.inbox.loading, 'Stale account response is ignored');
  f = inboxFixture([inbox => { inbox.active = false; return ok([item('hidden')], false, 1); }]);
  await f.inbox.load();
  check(f.inbox.items[0].partnerUserId === 'old', 'Hidden page cannot replace its list');
  const parse = value => context.AgentBridge.parseWrongAnalysis(value);
  let result = parse({ questionText: 'Q', answer: 'D、E、B、C、A', explanation: '完整步骤' });
  check(result.answer === 'D、E、B、C、A' && result.explanation === '完整步骤', 'Answers and steps survive response parsing');
  result = parse({ questions: [{ questionText: 'Q1', correctAnswer: 'B', solution: '步骤1' }, { questionText: 'Q2', answer: 'D' }] });
  check(result.questions.length === 2 && result.questions[0].answer === 'B' && result.questions[0].explanation === '步骤1',
    'Multiquestion aliases retain each complete solution');
  check(parse({ wrongType: '概念错误' }).answer === '' && parse(null) === undefined,
    'Older or incomplete responses cannot invent an answer');
  console.log(`V3 functional regressions: ${checks} assignment, inbox and diagnosis checks passed.`);
})().catch(error => { console.error(error); process.exitCode = 1; });
