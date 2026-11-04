const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.argv[2] || 'typescript');
const source = fs.readFileSync('app/entry/src/main/ets/pages/CourseImport.ets', 'utf8').replace(/\r\n/g, '\n');
const a = source.indexOf('  private todayDate('), b = source.indexOf('  @State addToToday:', a);
assert(a >= 0 && b > a);
let dialog, writes = [], cached;
const state = { currentUser:{userId:'alice'}, isTaskCompleted:()=>false };
const api = {};
const context = vm.createContext({appState:state,AgentApiClient:api,ClientCache:{cacheCurrentPlan:p=>cached=p},
  TodayStore:{key:owner=>'server:'+owner,save:()=>{}},getContext:()=>({}),
  AlertDialog:{show:value=>dialog=value},Date,Promise});
vm.runInContext(ts.transpileModule(fs.readFileSync('app/entry/src/main/ets/utils/PendingTasks.ets','utf8')
  .replace(/^import[^\n]*\n/gm,'').replace('export class','class')+'\nglobalThis.PendingTasks=PendingTasks;',
  {compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText,context);
vm.runInContext(ts.transpileModule('class Todos {' + source.slice(a,b) + '} globalThis.Todos=Todos;',
  {compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText,context);
let count=0; const check=(value,label)=>{assert(value,label);count++;};
const item = {eventId:'exam-1',kind:'exam',status:'pending',objectId:'linked',knowledgePointId:'linked',courseName:'数据结构',title:'链表',durationMinutes:10};
const task = {taskId:'planned',knowledgePointId:'linked',sourceCourse:'数据结构',durationMinutes:10,status:'pending',scheduledDate:'2026-11-04'};
function fixture() {
  const page = new context.Todos();
  Object.assign(page,{todoActive:true,todoRevision:0,todoLoadVersion:0,addingTodo:'',todoMessage:'',todayTaskIds:[],todayPointIds:[],otherTasks:[]});
  page.syncUrgentCount=()=>{page.otherTasks=context.PendingTasks.otherTasks(page.todoOverview,()=>false);};
  page.todayDate=()=> '2026-11-04'; return page;
}
(async()=>{
  let page=fixture(); page.syncTodayMembership({tasks:[task]});
  check(page.isTodoInToday(item),'Review and plan items match by the actual knowledge point');
  check(!page.isTodoInToday({...item,courseName:'其他课程'}),'A same-named point in another course is not already joined');
  check(!page.isTodoInToday({...item,kind:'task',objectId:'another'}),'Task membership uses its own task ID');
  api.getToday=async()=>({ok:true,data:{userId:'alice',allTasks:[item,{...item,kind:'task',sourceId:'planned',eventId:'task-1'}]}});
  api.getCurrentPlan=async()=>({ok:true,data:{version:1,tasks:[task],unscheduledTasks:[]}});
  page=fixture(); await page.loadOtherTasks();
  check(page.otherTasks.length===1&&page.isTodoInToday(item),'Duplicate plan/review representations collapse and show current membership');
  let plan={version:1,tasks:[],unscheduledTasks:[],budgetSummary:{availableMinutes:0}};
  api.getCurrentPlan=async()=>({ok:true,data:plan});
  api.addTodayItem=async body=>{writes.push(body); plan={version:2,tasks:[task],unscheduledTasks:[]};return {ok:true,data:plan};};
  page=fixture(); await page.confirmTodoToday(item);
  check(writes.length===0&&dialog.title.includes('可用学习时间'),'Budget extension is confirmed before any write');
  dialog.primaryButton.action(); check(!page.addingTodo&&writes.length===0,'Cancel leaves the plan unchanged');
  await page.confirmTodoToday(item); dialog.cancel(); check(!page.addingTodo&&writes.length===0,'Dismissing the dialog also restores the add action');
  await page.confirmTodoToday(item); dialog.secondaryButton.action();
  await new Promise(resolve=>setImmediate(resolve));
  check(writes.length===1&&writes[0].eventId==='exam-1'&&writes[0].availableMinutes===10,'Confirm adds exactly the selected review duration');
  check(cached.version===2&&page.isTodoInToday(item)&&page.todoMessage.includes('已将'),'Successful write refreshes cache, membership and user feedback');
  await page.confirmTodoToday(item); check(writes.length===1,'Already-joined cards cannot submit a duplicate action');
  page=fixture();api.getCurrentPlan=async()=>{state.currentUser.userId='bob';return {ok:true,data:{version:3,tasks:[]}};};
  dialog=undefined;await page.confirmTodoToday(item);
  check(!dialog&&writes.length===1,'An account switch drops the old confirmation');
  console.log(`Todo today: ${count} membership, deduplication, budget, cancellation and account checks passed.`);
})().catch(error=>{console.error(error);process.exitCode=1;});
