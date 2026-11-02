/* Execute the actual ETS navigation policy, without starting a user's timer. */
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.argv[2] || 'typescript');
let route;
let statuses = [];
let tasks = [];
const appState = {
  currentUser: {userId:"alice"},
  focusRuntime: null, focusResultDraft: null,
  beginFocusRuntime(task) { this.focusRuntime = { task }; return true; },
  setFocusTask(task) { this.activeFocusTask = task; },
  updatePlanTaskStatus(id, status) { statuses.push({id, status}); }
};
const context = vm.createContext({appState, AgentApiClient:{getCurrentPlan:async()=>({ok:true,data:{tasks,unscheduledTasks:[]}})}, router:{pushUrl(value){route=value;}},
  DistributedStateService:{getInstance:()=>({publishFocusTask(){}})}});
for (const [file, name] of [['utils/CourseLabels.ets','CourseLabels'],['services/ReminderNavigation.ets','ReminderNavigation']]) {
  const source = fs.readFileSync('app/entry/src/main/ets/'+file,'utf8').replace(/^import[^\n]*\n/gm,'').replace('export class','class');
  vm.runInContext(ts.transpileModule(source+'\nglobalThis.'+name+'='+name+';', {compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText,context);
}
(async()=>{
const nav = context.ReminderNavigation;
const event = {kind:'task',sourceType:'ddl',sourceId:'ddl-one',objectId:'wrong-id',title:'指定作业',courseName:'操作系统',durationMinutes:90,knowledgePointId:'ddl:ddl-one',status:'pending',targetPage:'pages/CourseImport'};
nav.open(event);
assert.equal(route.url,'pages/TaskDetail');
assert.equal(route.params.taskId,'ddl-one');
tasks=[{taskId:'ddl-one',source:'ddl',knowledgePointId:'ddl:ddl-one',knowledgePointName:'指定作业',sourceCourse:'操作系统',durationMinutes:90,status:'pending'}];
await nav.start(event);
assert.equal(route.url,'pages/FocusTimer');
assert.equal(appState.activeFocusTask.task,'指定作业');
assert.equal(appState.activeFocusTask.planTaskId,'ddl-one');
assert.equal(appState.activeFocusTask.plannedMinutes,90);
assert.equal(statuses.length,1);
assert.equal(statuses[0].status,'in_progress');
appState.focusRuntime=null;
tasks=[{taskId:'study-one',source:'plan',knowledgePointId:'graph',knowledgePointName:'巩固图算法',sourceCourse:'数据结构',durationMinutes:15,status:'pending'}];
await nav.start({...event,sourceType:'plan',sourceId:'study-one'});
assert.equal(route.url,'pages/ExercisePractice');
assert.equal(route.params.knowledgePointId,'graph');
assert.equal(route.params.courseName,'数据结构');
const previous={task:{planTaskId:'another',task:'原专注'}};
appState.focusRuntime=previous;route=null;
tasks=[{taskId:'ddl-one',source:'ddl',knowledgePointId:'ddl:ddl-one',knowledgePointName:'指定作业',sourceCourse:'操作系统',durationMinutes:90,status:'pending'}];
assert((await nav.start(event)).includes('另一项专注'));
assert.equal(route,null);
assert.equal(appState.focusRuntime,previous);
appState.focusRuntime=null;appState.focusResultDraft={task:'待保存'};
assert((await nav.start(event)).includes('尚未结算'));
appState.focusResultDraft=null;
tasks[0].sourceCourse='待确认科目'; await nav.start(event);
assert.equal(route.url,'pages/KnowledgeCatalog');
assert((await nav.start({...event,status:'completed'})).includes('已完成'));
appState.focusRuntime=null;
tasks=[{taskId:'part',parentTaskId:'ddl-one',source:'ddl_step',knowledgePointId:'ddl:ddl-one',knowledgePointName:'指定作业 · 先完成实现',sourceCourse:'操作系统',durationMinutes:30,status:'pending'}];
await nav.start(event);assert.equal(appState.activeFocusTask.planTaskId,'part');assert.equal(appState.activeFocusTask.plannedMinutes,30);
console.log('PASS: exact-task details, immediate start, exact-point practice, placeholder matching, and active-timer/draft protection.');

})().catch(error=>{console.error(error);process.exitCode=1;});
