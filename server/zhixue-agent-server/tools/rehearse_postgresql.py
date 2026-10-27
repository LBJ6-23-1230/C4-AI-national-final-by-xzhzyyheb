"""Migrate synthetic legacy data, pg_dump, restore to a NEW test DB, compare every row.

Never accepts a production database; never drops an existing database or schema.
"""
import argparse
from copy import deepcopy
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pg-bin", required=True)
    parser.add_argument("--output", default=".local-postgres/rehearsal")
    args = parser.parse_args()
    from sqlalchemy import text
    from sqlalchemy.engine import make_url
    from alembic import command
    from alembic.config import Config
    from app.repositories.postgresql_repository import PostgreSQLRepository, make_engine
    from tools.migrate_postgresql import prepare, import_and_verify
    url = make_url(os.environ["ZHIXUE_TEST_DATABASE_URL"])
    if not (url.database or "").startswith("zhixue_test"):
        raise ValueError("rehearsal requires an explicitly named zhixue_test database")
    stamp = uuid.uuid4().hex[:12]
    schema, restored_db = "rehearsal_" + stamp, "zhixue_test_restore_" + stamp
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    source = {
        "users": {"u-rehearsal": {"userId": "u-rehearsal", "phone": "13900009999", "status": "active"}},
        "profiles": {"u-rehearsal": {"userId": "u-rehearsal", "profileVersion": 3, "mastery": [{"knowledgePointId": "tree", "masteryScore": 58}]}},
        "knowledge_bases": {"kb-rehearsal": {"kbId": "kb-rehearsal", "userId": "u-rehearsal"}},
        "documents": {"doc-rehearsal": {"documentId": "doc-rehearsal", "kbId": "kb-rehearsal", "userId": "u-rehearsal", "status": "ready"}},
        "chunks": {"chunk-rehearsal": {"chunkId": "chunk-rehearsal", "documentId": "doc-rehearsal", "kbId": "kb-rehearsal", "userId": "u-rehearsal", "text": "二叉树先序遍历先访问根节点。", "index": 1}},
        "submissions": {"u-rehearsal:set:once": {"response": {"userId": "u-rehearsal", "assessment": {"score": 66.67}}, "requestFingerprint": "synthetic-test"}},
    }
    history = {"u-rehearsal": [{"user_input": "复习二叉树", "bot_response": "先访问根节点", "session_id": "chat-rehearsal"}]}
    (output / "legacy.json").write_text(json.dumps(source, ensure_ascii=False), encoding="utf-8")
    (output / "history.json").write_text(json.dumps(history, ensure_ascii=False), encoding="utf-8")
    os.environ["DB_SCHEMA"] = "public"
    engine = make_engine(url)
    with engine.begin() as connection:
        connection.execute(text(f'CREATE SCHEMA "{schema}"'))
    engine.dispose()
    os.environ["DB_SCHEMA"] = schema
    os.environ["DATABASE_URL"] = url.render_as_string(hide_password=False)
    os.environ.pop("MIGRATION_DATABASE_URL", None)
    command.upgrade(Config("alembic.ini"), "head")
    data, errors = prepare(source, history)
    if errors:
        raise ValueError("synthetic fixture validation failed")
    repository = PostgreSQLRepository(url)
    dry_run = import_and_verify(repository, data)
    applied = import_and_verify(repository, data, True)
    assert dry_run["pending"] == 8 and applied["ok"]
    repository.close()
    # Password goes only in a child environment, never into command arguments.
    child_env = dict(os.environ, PGHOST=url.host or "127.0.0.1", PGPORT=str(url.port or 5432),
                     PGUSER=url.username or "postgres", PGPASSWORD=url.password or "", PGDATABASE=url.database)
    child_env.pop("PGSERVICE", None)
    for key, env_name in (("sslmode", "PGSSLMODE"), ("sslrootcert", "PGSSLROOTCERT")):
        if key in url.query:
            child_env[env_name] = url.query[key]
    binary = lambda name: str(Path(args.pg_bin) / (name + (".exe" if os.name == "nt" else "")))
    dump = output / "rehearsal.dump"
    subprocess.run([binary("pg_dump"), "--format=custom", "--no-owner", f"--schema={schema}", f"--file={dump}"], env=child_env, check=True)
    subprocess.run([binary("createdb"), restored_db], env=child_env, check=True)
    restore_env = dict(child_env, PGDATABASE=restored_db)
    subprocess.run([binary("pg_restore"), "--exit-on-error", "--no-owner", "--dbname=" + restored_db, str(dump)], env=restore_env, check=True)
    restored = PostgreSQLRepository(url.set(database=restored_db))
    try:
        verified = import_and_verify(restored, data)
        assert verified["ok"] and verified["pending"] == 0
    finally:
        restored.close()
    report = {"ok": True, "timeUTC": datetime.now(timezone.utc).isoformat(),
              "schema": schema, "restoreDatabase": restored_db, "dryRun": dry_run,
              "import": applied, "restoreVerification": verified,
              "scope": "synthetic records, local PostgreSQL; no cloud/PITR or real file-object restore"}
    (output / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False))


if __name__ == "__main__":
    main()
