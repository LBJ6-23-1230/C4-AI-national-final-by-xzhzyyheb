"""Offline retention; dry-run by default. Stop JSON service before running."""
import argparse
from collections import Counter
import json
import os
from pathlib import Path
import sys
import tempfile

SERVER = Path(__file__).resolve().parents[1] / "server" / "zhixue-agent-server"
sys.path.insert(0, str(SERVER))
from app.repositories.json_repository import JsonRepository
from app.repositories.sqlite_repository import SQLiteRepository
from app.services import retention


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path, required=True)
    parser.add_argument("--backend", choices=("json", "sqlite"), default="sqlite")
    parser.add_argument("--history", type=Path)
    parser.add_argument("--apply", action="store_true", help="Apply after reviewing dry-run and backing up")
    args = parser.parse_args()
    if not args.repository.is_file():
        parser.error("repository must already exist")
    repo = (SQLiteRepository if args.backend == "sqlite" else JsonRepository)(args.repository)
    try:
        with repo.transaction():
            deletes = retention.plan(repo)
            report = {"applied": args.apply, "deletions": dict(Counter(c for c, _ in deletes)),
                      "policies": retention.POLICIES, "unresolvedWrongBook": "preserved"}
            if args.apply:
                repo.apply_batch(deletes, [])
        if args.history:
            store = json.loads(args.history.read_text(encoding="utf-8"))
            if not isinstance(store, dict):
                parser.error("history must use the per-user object format")
            updated = retention.history_plan(store)
            report["historyDeleted"] = sum(len(v) for v in store.values() if isinstance(v, list)) - sum(map(len, updated.values()))
            if args.apply:
                handle, temporary = tempfile.mkstemp(dir=args.history.parent, prefix="history-", suffix=".tmp")
                try:
                    with os.fdopen(handle, "w", encoding="utf-8") as stream:
                        json.dump(updated, stream, ensure_ascii=False)
                    os.replace(temporary, args.history)
                finally:
                    if os.path.exists(temporary):
                        os.unlink(temporary)
        print(json.dumps(report, ensure_ascii=False, indent=2))
    finally:
        repo.close()


if __name__ == "__main__":
    main()
