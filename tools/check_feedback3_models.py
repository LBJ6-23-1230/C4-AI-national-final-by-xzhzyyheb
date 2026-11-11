"""Live probes using synthetic facts only. No account, question or credential output."""
from pathlib import Path
import json, os, sys, time
from dotenv import load_dotenv

ROOT=Path(__file__).resolve().parents[1]
load_dotenv(ROOT/'server/zhixue-agent-server/.env',encoding='utf-8-sig')
sys.path.insert(0,str(ROOT/'server/zhixue-agent-server'))
from app.services.review_actions import generate
from app.tools.time_budget import fit_plan_to_budget

report=[]
start=time.perf_counter()
review,source,reason=generate(dict(measuredPoints=[dict(knowledgePointId='synthetic-tree',knowledgePointName='树的遍历',masteryScore=40)],
    daysUntilExam=3,evidenceCount=1,evidence=[dict(id='synthetic-evidence',sourceType='assessment')]))
report.append(dict(path='structured_review',model=os.getenv('LLM_MODEL','qwen-plus'),
    seconds=round(time.perf_counter()-start,2),llmUsed=source=='model',source=source,fallbackReason=reason,
    valid=bool(review['actions'] and all(a['steps'] and a['doneWhen'] for a in review['actions']))))
start=time.perf_counter()
result=fit_plan_to_budget(dict(tasks=[dict(taskId='synthetic-task',knowledgePointId='synthetic-tree',knowledgePointName='树的遍历',status='pending',durationMinutes=30)]),60)['plan']
summary=result['budgetSummary']
report.append(dict(path='surplus_budget',model=os.getenv('LLM_MODEL','qwen-plus'),seconds=round(time.perf_counter()-start,2),
    llmUsed=summary['allocationMode']=='surplus_model',mode=summary['allocationMode'],fallbackReason=summary['allocationReason'],
    valid=summary['scheduledMinutes']==60 and summary['unallocatedMinutes']==0))
(ROOT/'evidence/feedback3-live-features.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
history=ROOT/'evidence/feedback3-live-feature-history.json'
previous=json.loads(history.read_text(encoding='utf-8')) if history.exists() else []
previous.append(report)
history.write_text(json.dumps(previous,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps(report,ensure_ascii=True,indent=2))
raise SystemExit(0 if all(r['llmUsed'] and r['valid'] for r in report) else 1)
