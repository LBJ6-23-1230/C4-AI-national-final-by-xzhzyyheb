"""Read-only backend/database connectivity example. Credentials stay in server/.env.

Run from any directory: python examples/backend_connection.py
Optionally check an already running server: --api http://127.0.0.1:5000
"""
from pathlib import Path
import argparse, json, os, sys
from urllib.request import urlopen
from dotenv import load_dotenv
from sqlalchemy import text

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'server/zhixue-agent-server'))
from app.repositories.postgresql_repository import make_engine


def connect_database():
    load_dotenv(ROOT/'server/zhixue-agent-server/.env',encoding='utf-8-sig')
    # Psycopg 3 + SQLAlchemy pool_pre_ping / bounded connection timeout.
    # DATABASE_URL=postgresql+psycopg://USER:PASSWORD@HOST:5432/DATABASE
    return make_engine(os.environ['DATABASE_URL'])


def get_backend_json(base_url, path='/ready'):
    with urlopen(base_url.rstrip('/')+path,timeout=10) as response:
        return json.load(response)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--api')
    args=parser.parse_args()
    engine=connect_database()
    try:
        with engine.connect() as connection:
            assert connection.execute(text('SELECT 1')).scalar_one()==1
            revision=connection.execute(text('SELECT version_num FROM alembic_version')).scalar_one()
        print('PostgreSQL connected; schema='+revision)
        if args.api: print('Backend ready: '+json.dumps(get_backend_json(args.api)))
    finally:
        engine.dispose()
