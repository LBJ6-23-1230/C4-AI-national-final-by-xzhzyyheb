/* Exercise production ArkTS state transitions without an emulator transport. */
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.argv[2] || 'typescript');
const root = 'app/entry/src/main/ets/';
const read = f => fs.readFileSync(root + f, 'utf8').replace(/\r\n/g, '\n');
function method(file, start, end) {
  const source = read(file), a = source.indexOf(start), b = source.indexOf(end, a + start.length);
  assert(a >= 0 && b > a, `Missing production method ${start}`);
  return source.slice(a, b);
}
const appState = { currentUser: { userId: 'alice' }, latestWrongAnalysis: null, isTaskCompleted: (_, status) => status === 'completed' };
const context = vm.createContext({ appState, Date, LearningEvidence: { score: p => p.score || 0 } });
function execute(source) {
  vm.runInContext(ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText, context);
}
execute('class Catalog {' + method('components/KnowledgePointPanel.ets', '  private groupName(', '  private beginMatch(') + '} globalThis.Catalog = Catalog;');
execute('class Diagnosis {' + method('pages/WrongQuestion.ets', '  private selectQuestion(', '  /**') + '} globalThis.Diagnosis = Diagnosis;');
execute('class NextTask {' + method('pages/Index.ets', '  private currentAgentTask(', '  private startAgentTask(') + '} globalThis.NextTask = NextTask;');
let count = 0;
function check(value, label) { assert(value, label); count++; }
const catalog = new context.Catalog();
catalog.points = [
  {knowledgePointId:'a',knowledgePointName:'栈',sourceCourse:'数据结构'},
  {knowledgePointId:'b',knowledgePointName:'图',sourceCourse:'数据结构'},
  {knowledgePointId:'c',knowledgePointName:'树',sourceCourse:'数据结构'},
  {knowledgePointId:'d',knowledgePointName:'链表',sourceCourse:'数据结构'},
  {knowledgePointId:'e',knowledgePointName:'HTTP',sourceCourse:'计算机网络'},
  {knowledgePointId:'f',knowledgePointName:'未归属',classificationRequired:true}
];
catalog.course = ''; catalog.search = ''; catalog.courseSearch = ''; catalog.expandedCourses = [];
check(catalog.groups().length === 3, 'Course groups keep unclassified points separate');
check(catalog.shownPoints('数据结构').length === 3, 'Each course previews at most three points');
catalog.expandedCourses = ['数据结构'];
check(catalog.shownPoints('数据结构').length === 4, 'Expand shows all points of the same course');
catalog.search = '计算机网络';
check(catalog.filtered().length === 1, 'Search accepts a course name');
catalog.search = ''; catalog.course = '数据结构';
check(catalog.filtered().length === 4, 'Course-scoped reports cannot mix unrelated points');
const diagnosis = new context.Diagnosis();
diagnosis.analysisResults = [
  {questionText:'第一道题',course:'数据结构',knowledge:['栈']},
  {questionText:'第二道题',course:'计算机网络',knowledge:['HTTP']}
];
diagnosis.selectQuestion(1);
check(diagnosis.analysisResult.questionText === '第二道题' && diagnosis.savePoint === 'HTTP', 'Selected question and save fields change together');
check(appState.latestWrongAnalysis === diagnosis.analysisResult, 'Practice reads the selected question');
diagnosis.selectQuestion(0);
check(diagnosis.saveStem === '第一道题' && diagnosis.saveCourse === '数据结构', 'Switching back restores the first question');
diagnosis.selectQuestion(99);
check(diagnosis.selectedQuestionIndex === 0, 'Out-of-range selection leaves the current question intact');
const next = new context.NextTask();
next.agentPlan = {tasks:[{taskId:'future',scheduledDate:'2999-01-01',status:'pending'}, {taskId:'done',status:'completed'}, {taskId:'today',status:'pending'}]};
check(next.currentAgentTask().taskId === 'today', 'Next task excludes completed and future work');
next.agentPlan.tasks.pop();
check(next.currentAgentTask() === null, 'No due work does not recommend a future task');
const chat = read('pages/ChatMain.ets');
check(chat.includes('AgentBridge.callAgent(questionText, imageForAgent, historyBeforeSend') && chat.includes('}, document);'), 'Parsed attachment content reaches the chat request');
check(chat.includes('revision !== this.fileRevision') && chat.includes('session !== appState.chatSessionId'), 'Attachment results are isolated across sessions');
check(!chat.includes("Text('选择学习功能')") && chat.includes("Button('添加文件'"), 'Composer exposes the single content/function menu');
console.log(`Screenshot feedback: ${count} production grouping, diagnosis, recommendation and attachment checks passed.`);
