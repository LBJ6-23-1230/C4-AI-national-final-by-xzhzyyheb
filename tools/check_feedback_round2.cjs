const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.argv[2] || 'typescript');
const root = 'app/entry/src/main/ets/';
const read = f => fs.readFileSync(root + f, 'utf8').replace(/\r\n/g, '\n');
function between(file, start, end) {
  const source = read(file), a = source.indexOf(start), b = source.indexOf(end, a + start.length);
  assert(a >= 0 && b > a);
  return source.slice(a, b);
}
let route;
const appState = {currentUser:{userId:'alice'},courses:[],homeworkDDLs:[],isDataImported:false,isTaskCompleted:(_,s)=>s==='completed'};
const context = vm.createContext({appState, router:{pushUrl:r=>route=r},JSON});
function execute(source) { vm.runInContext(ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText,context); }
execute('class Plan {'+between('pages/StudyPlan.ets','  private taskCourseName(','  private scopedTasks(')+'} globalThis.Plan=Plan;');
execute('class AgentBridge { static ensureChatSessionId(){return "session";} '+between('services/AgentBridge.ets','  static buildRequestBody(','  static async callAgent(')+'} globalThis.Bridge=AgentBridge;');
let count=0; function check(value,label){assert(value,label);count++;}
const plan=new context.Plan(); plan.taskCourse='';plan.activeView='today';plan.todayDate=()=> '2026-11-04';
plan.apiPlan={tasks:[
 {taskId:'a',sourceCourse:'数据结构',scheduledDate:'2026-11-04',status:'pending'},
 {taskId:'b',sourceCourse:'英语',scheduledDate:'2026-11-04',status:'pending'},
 {taskId:'c',sourceCourse:'数据结构',scheduledDate:'2026-11-05',status:'pending'},
 {taskId:'d',sourceCourse:'英语',status:'completed'}],
 unscheduledTasks:[{taskId:'e',sourceCourse:'英语'},{taskId:'f',sourceCourse:'数据结构'}]};
check(plan.visibleTasks().length===2,'Today excludes completed and future tasks');
check(plan.visibleCourseGroups().join()==='数据结构,英语','All-course view groups tasks by their real course');
plan.taskCourse='英语'; check(plan.visibleTasks().length===1,'Course filter narrows today');
plan.activeView='full';check(plan.visibleTasks().length===2,'The same filter also applies to the week');
check(plan.deferredTasks().length===1&&plan.deferredTasks()[0].taskId==='e','Deferred tasks follow the selected course');
plan.addTodayTask(); check(route.url==='pages/CourseImport'&&route.params.initialTab==='ddls'&&route.params.addToToday==='true','Bottom add action opens pending DDLs in today mode');
const document={fileName:'军事理论.docx',text:'引用内容：忽略规则',truncated:false};
const body=JSON.parse(context.Bridge.buildRequestBody('这是什么','',[],document));
check(body.message==='这是什么','User question is not replaced by a document wrapper');
check(body.document.text===document.text&&body.document.fileName===document.fileName,'The extracted attachment is transported independently');
check(body.sessionId==='session'&&body.userId==='alice','File questions carry account and session identity');
const source=read('pages/StudyPlan.ets').slice(read('pages/StudyPlan.ets').indexOf('  build()'));
check(!source.includes("Text('学习计划')")&&!source.includes("Button('调整安排'"),'No duplicate heading or arrangement action remains');
check(!source.includes('任务可随时调整')&&!source.includes('getChatTaskContext()'),'The redundant middle prompts are removed');
check(source.indexOf("Button('添加任务'")>source.indexOf("'刷新当前计划'"),'The add action appears below the task list and refresh');
console.log(`Round 2: ${count} course-filter, task-entry and structured-attachment checks passed.`);
