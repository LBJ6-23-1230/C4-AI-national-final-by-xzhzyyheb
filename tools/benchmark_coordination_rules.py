import json,time,sys
from pathlib import Path
sys.path.insert(0,'server/zhixue-agent-server')
from app.agents.planner import PlannerAgent
rows=[]
for i in range(30):
 b=[20,40,60][i%3]; minutes=20+(i%5)*5
 tasks=[dict(taskId='practice',knowledgePointId='linear',knowledgePointName='线性表基础巩固',durationMinutes=30,status='pending'),dict(taskId='ddl',knowledgePointId='ddl:homework',knowledgePointName='操作系统实验',source='ddl',sourceCourse='操作系统',dueDate='2026-10-31',durationMinutes=minutes,status='pending')]
 t=time.perf_counter(); result=PlannerAgent().run(dict(plan=dict(version=1,constraints=dict(availableMinutes=b),tasks=tasks),needReplan=True,replanState=dict(knowledgePointId='linear',masteryScore=20,assessmentScore=40,repeatedError=True)))
 elapsed=(time.perf_counter()-t)*1000; updated=result.output['plan']; baseline=[]; remaining=b
 for task in tasks:
  if task['durationMinutes']<=remaining: baseline.append(task); remaining-=task['durationMinutes']
 rows.append(dict(scenario=i+1,input=dict(budget=b,assignmentMinutes=minutes),baseline=dict(type='weakness-first whole-task rule',modelCalls=0,assignmentScheduled=any(t['taskId']=='ddl' for t in baseline)),coordinated=dict(modelCalls=0,tokens=None,elapsedMs=round(elapsed,3),toolCalls=list(result.tool_calls),scheduledMinutes=sum(t['durationMinutes'] for t in updated['tasks']),assignmentScheduled=any(t['taskId']=='ddl' and t['durationMinutes']==minutes for t in updated['tasks']),budgetViolation=sum(t['durationMinutes'] for t in updated['tasks'])>b,plan=updated)))
report=dict(scope='Deterministic rule comparison; not a single-LLM versus multi-LLM experiment',sampleSize=30,environment='Python 3.12 local warm process, no external calls',manualReview='pending',scenarios=rows,summary=dict(budgetViolations=sum(x['coordinated']['budgetViolation'] for x in rows),baselineAssignmentsScheduled=sum(x['baseline']['assignmentScheduled'] for x in rows),coordinatedAssignmentsScheduled=sum(x['coordinated']['assignmentScheduled'] for x in rows),p95Ms=sorted(x['coordinated']['elapsedMs'] for x in rows)[28]))
Path('evidence/coordination-rules-20261030.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps(report['summary']))
