"""Read-only account audit. Does not initialize the app or write any records."""
import json
import os
from collections import Counter
from pathlib import Path
from dotenv import load_dotenv
from sqlalchemy import create_engine, text

ROOT = Path(__file__).resolve().parents[1]
load_dotenv(ROOT/'server/zhixue-agent-server/.env')
engine = create_engine(os.environ['DATABASE_URL'], connect_args={'connect_timeout': 5})
with engine.connect() as conn:
    rows = conn.execute(text("SELECT item_id, value, phone FROM users WHERE status='active'")).mappings().all()
    counts = Counter(r['phone'] for r in rows if r['phone'])
    report = []
    for row in rows:
        phone = row['phone']
        if not phone or counts[phone] < 2:
            continue
        user = row['value']
        data_counts = {}
        for table in ('learning_profiles', 'plans', 'chat_messages', 'focus_sessions', 'workflows', 'file_objects'):
            data_counts[table] = conn.execute(text(f'SELECT count(*) FROM {table} WHERE user_id=:owner'), {'owner': row['item_id']}).scalar_one()
        report.append(dict(userId=row['item_id'], nickname=user.get('nickname', ''),
            phoneMasked=phone[:3]+'****'+phone[-4:], createdAt=user.get('createdAt'),
            lastLoginAt=user.get('lastLoginAt'), dataCounts=data_counts))
print(json.dumps(dict(activeAccounts=len(rows), duplicates=report), ensure_ascii=True, indent=2))
