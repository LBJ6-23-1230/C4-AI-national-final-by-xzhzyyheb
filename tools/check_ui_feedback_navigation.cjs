const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.argv[2] || 'typescript');
const root = 'app/entry/src/main/ets/';
const read = f => fs.readFileSync(root + f, 'utf8').replace(/\r\n/g, '\n');
function between(file, start, end) {
  const s = read(file), a = s.indexOf(start), b = s.indexOf(end, a + start.length);
  assert(a >= 0 && b > a, `Cannot find actual method in ${file}`);
  return s.slice(a, b);
}
let dialog, routes = [], writes = [], focused = [], sent = 0;
const appState = { currentUser: { userId: 'alice' }, homeworkDDLs: [],
  isTaskCompleted: () => false,
  markPlanTaskStatus: (...args) => writes.push(args),
  setFocusTask: value => focused.push(value)
};
const context = vm.createContext({ appState,
  AlertDialog: { show: value => { dialog = value; } },
  router: { pushUrl: route => routes.push(route) }, console
});
function execute(source) {
  vm.runInContext(ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText, context);
}
execute(read('utils/PlanScope.ets').replace(/^import[^\n]*\n/gm, '').replace('export class', 'class') + '\nglobalThis.PlanScope = PlanScope;');
execute('class DdlActions {' + between('pages/CourseImport.ets', '  private requestDdlCompletion(', '  @Builder\n  DdlFilter(') + '} globalThis.DdlActions = DdlActions;');
execute('class MasteryList {' + between('pages/StudyTags.ets', '  private visibleMastery(', '  private weakMasteryCount(') + '} globalThis.MasteryList = MasteryList;');
execute(between('pages/ChatMain.ets', 'const INTENT_CHIPS:', 'interface DiagnosisEdit'));
execute('class Functions {' + between('pages/ChatMain.ets', '  private chooseIntent(', '  @Builder\n  private FunctionWorkspace(') + '} globalThis.Functions = Functions;');
execute('class Collaboration {' + between('pages/CollaborativeTasks.ets', '  private start(task:', '  @Builder') + '} globalThis.Collaboration = Collaboration;');
let count = 0;
const check = (value, label) => { assert(value, label); count++; };
const tasks = [{ taskId: 'en', sourceCourse: '大学英语' }, { taskId: 'os', sourceCourse: '操作系统' },
  { taskId: 'legacy-ddl' }, { taskId: 'unknown' }, { taskId: 'conflicting', sourceCourse: '操作系统' }];
const assignments = [{ id: 'legacy-ddl', courseName: '大学英语' }, { id: 'conflicting', courseName: '大学英语' }];
check(context.PlanScope.courseTasks(tasks, '大学英语', assignments).map(t => t.taskId).join() === 'en,legacy-ddl',
  'English plan excludes other courses and unknown ownership');
check(context.PlanScope.courseTasks(tasks, '不存在的课程', assignments).length === 0, 'Absent course does not fall back to the global plan');
check(context.PlanScope.courseTasks(tasks, '', assignments).length === 0, 'Empty scope cannot leak all tasks');
check(context.PlanScope.collaborativeTasks([{ id: 'mine', source: 'agent' }, { id: 'joint', source: 'partner_match' },
  { id: 'ddl', source: 'ddl' }]).map(t => t.id).join() === 'joint', 'Collaborative list excludes personal and assignment tasks');
const ddl = new context.DdlActions(); ddl.refreshLearningData = () => {};
ddl.requestDdlCompletion({ id: 'one', title: '实验报告' });
check(writes.length === 0, 'Opening completion confirmation does not complete the assignment');
dialog.primaryButton.action(); check(writes.length === 0, 'Cancel preserves assignment status');
dialog.secondaryButton.action(); check(writes[0][0] === 'one' && writes[0][1] === 'completed', 'Explicit confirmation completes the intended assignment');
appState.isTaskCompleted = () => true; ddl.requestDdlCompletion({ id: 'two', title: '已完成作业' });
dialog.secondaryButton.action(); check(writes[1][1] === 'todo', 'Confirmed restore returns the assignment to pending');
ddl.requestDdlCompletion({ id: 'private', title: '旧账号作业' }); appState.currentUser.userId = 'bob';
dialog.secondaryButton.action(); check(writes.length === 2, 'Account switch invalidates the pending confirmation');
appState.currentUser.userId = 'alice';
const mastery = new context.MasteryList();
mastery.sortedMastery = () => [1, 2, 3, 4, 5]; mastery.showAllMastery = false;
check(mastery.visibleMastery().length === 3, 'Mastery initially previews three points');
mastery.showAllMastery = true; check(mastery.visibleMastery().join() === '1,2,3,4,5', 'View-all expands the same mastery list');
const source = read('pages/StudyTags.ets');
const viewAll = source.slice(source.indexOf("Button(this.showAllMastery ? '收起"), source.indexOf("Button(this.showAllMastery ? '收起") + 500);
check(viewAll.includes('this.showAllMastery = !this.showAllMastery') && !viewAll.includes('KnowledgeCatalog'), 'View-all cannot navigate into course assignment');
const functions = new context.Functions(); functions.sendMessage = () => sent++;
const cases = [['analyze_wrong', 'pages/WrongQuestion'], ['analyze_weakness', 'pages/StudyTags'],
  ['match_partner', 'pages/PartnerMatch'], ['query_tasks', 'pages/StudyPlan']];
for (const [intent, route] of cases) {
  functions.chooseIntent({ intent, prompt: 'prompt' });
  check(functions.showFunctionWorkspace && functions.inputText === 'prompt', 'Selecting a function changes the workspace and preserves its draft');
  functions.openFunction(); check(routes.at(-1).url === route, `Primary action reaches ${route}`);
}
functions.chooseIntent({ intent: 'get_suggestion', prompt: '建议' }); functions.openFunction();
functions.chooseIntent({ intent: 'update_profile', prompt: '变化' }); functions.openFunction();
check(sent === 2, 'Suggestion and update retain the actual chat flow');
const collaboration = new context.Collaboration(); collaboration.owner = 'alice'; collaboration.owns = () => true;
collaboration.start({ taskId: 'joint', status: 'accepted', myStatus: 'pending', courseName: '数据结构', title: '与搭子互测', myPart: '互测', durationMinutes: 30 });
check(focused[0].source === 'collaborative' && focused[0].planTaskId === 'joint' && routes.at(-1).url === 'pages/FocusSetup', 'Collaborative start retains its own task and opens setup');
collaboration.start({ taskId: 'unconfirmed', status: 'pending', myStatus: 'pending' });
check(focused.length === 1, 'Unconfirmed shared arrangements cannot start focus');
check(!read('pages/PartnerMatch.ets').includes("'pages/StudyPlan'"), 'Every collaborative entry avoids the personal study plan');
const routesConfig = JSON.parse(fs.readFileSync('app/entry/src/main/resources/base/profile/main_pages.json', 'utf8'));
check(routesConfig.src.includes('pages/CollaborativeTasks') && routesConfig.src.length >= 33, 'Dedicated collaborative page is registered alongside the original routes');
console.log(`UI feedback navigation: ${count} scope, confirmation, mastery and function-entry checks passed.`);
