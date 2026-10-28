"""Validate generated lecture inputs through the actual pure document processor."""
import base64
import hashlib
import importlib.util
import json
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / '演示测试数据/指导老师预演-20261028'
spec = importlib.util.spec_from_file_location('demo_knowledge', ROOT / 'server/zhixue-agent-server/app/agent/knowledge.py')
knowledge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(knowledge)

results = []
for file in sorted((OUT / '03-上传讲义').glob('*.txt')):
    result = knowledge.process_document(file.name, base64.b64encode(file.read_bytes()).decode(), scope='fictional-demo:' + file.stem)
    assert result['status'] == 'ready', result
    assert result['chunks'] and result['knowledgePoints'], result
    results.append({'file': file.name, 'status': result['status'], 'charCount': result['charCount'], 'chunks': len(result['chunks']), 'knowledgePoints': result['knowledgePoints']})
for file in sorted((OUT / '01-图片').glob('*.png')):
    with Image.open(file) as im:
        im.verify()
    assert file.stat().st_size < 4 * 1024 * 1024, file.name
(OUT / '讲义处理预检.json').write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding='utf-8')
manifest = [{'file': str(p.relative_to(OUT)), 'bytes': p.stat().st_size, 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()} for p in sorted(OUT.rglob('*')) if p.is_file() and p.name != '素材清单.json']
(OUT / '素材清单.json').write_text(json.dumps({'date':'2026-10-28', 'fictional':True, 'files':manifest}, ensure_ascii=False, indent=2), encoding='utf-8')
print(json.dumps({'lectures': results, 'images':4, 'manifestFiles':len(manifest)}, ensure_ascii=False))
