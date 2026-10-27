"""Offline, additive import: dry-run by default; never overwrites conflicting data."""
import argparse
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import sqlite3
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))


def record_label(collection, key):
    # Legacy session IDs are bearer tokens; verification IDs are phone numbers.
    if collection == "sessions":
        key = "sha256:" + hashlib.sha256(str(key).encode()).hexdigest()[:16]
    elif collection == "verification_codes":
        key = "masked:" + str(key)[-4:]
    return f"{collection}/{key}"


def load_source(path):
    path = Path(path)
    if path.suffix in {".sqlite", ".db", ".sqlite3"}:
        connection = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True)
        try:
            result = {}
            for collection, key, raw in connection.execute("SELECT collection,item_id,value FROM records"):
                result.setdefault(collection, {})[key] = json.loads(raw)
            return result
        finally:
            connection.close()
    return json.loads(path.read_text(encoding="utf-8-sig"))


def prepare(source, history=None):
    data = deepcopy(source)
    errors = []
    if not isinstance(data, dict):
        return {}, ["source root must be an object"]
    phones = {}
    users = set(data.get("users", {})) | {"demo-user"}
    for collection, records in data.items():
        if not isinstance(records, dict):
            errors.append(f"invalid collection: {collection}")
            continue
        for key, value in records.items():
            if not isinstance(value, dict):
                errors.append(f"invalid record: {record_label(collection, key)}")
                continue
            owner = value.get("userId") or value.get("response", {}).get("userId") or value.get("state", {}).get("userId")
            if owner and owner not in users:
                errors.append(f"unknown owner: {record_label(collection, key)}")
            if collection == "users" and value.get("phone"):
                from app.auth.service import normalize_phone
                try:
                    phone = normalize_phone(value["phone"])
                    if phone in phones:
                        errors.append(f"duplicate phone: users/{key} and users/{phones[phone]}")
                    phones[phone] = key
                    value["phone"] = phone
                except Exception:
                    errors.append(f"invalid phone: users/{key}")
            if collection == "submissions":
                value.setdefault("userId", owner)
                if owner and key.startswith(owner + ":"):
                    value.setdefault("idempotencyKey", key[len(owner) + 1:])
    for key, document in data.get("documents", {}).items():
        kb = data.get("knowledge_bases", {}).get(document.get("kbId"))
        if not kb or kb.get("userId") != document.get("userId"):
            errors.append(f"document knowledge base/owner mismatch: {key}")
    for key, chunk in data.get("chunks", {}).items():
        doc = data.get("documents", {}).get(chunk.get("documentId"))
        if not doc or doc.get("userId") != chunk.get("userId") or doc.get("kbId") != chunk.get("kbId"):
            errors.append(f"chunk document/owner mismatch: {key}")
    if history is not None:
        if isinstance(history, list):
            history = {"demo-user": history}
        if not isinstance(history, dict):
            errors.append("invalid chat history")
        else:
            for owner, entries in history.items():
                if owner not in users or not isinstance(entries, list):
                    errors.append(f"invalid history owner: {owner}")
                    continue
                for sequence, entry in enumerate(entries[-50:], 1):
                    if not isinstance(entry, dict):
                        errors.append(f"invalid chat entry: {owner}/{sequence}")
                        continue
                    key = hashlib.sha256(f"{owner}\0{sequence}".encode()).hexdigest()
                    data.setdefault("chat_messages", {})[key] = {"messageId": key, "userId": owner,
                        "sequence": sequence, "sessionId": entry.get("session_id", ""), "entry": entry,
                        "createdAt": entry.get("timestamp")}
                data.setdefault("chat_sessions", {})[owner] = {"userId": owner, "sequence": min(50, len(entries))}
    return data, errors


def import_and_verify(repository, data, apply=False):
    saves, conflicts = [], []
    for collection, records in data.items():
        for key, value in records.items():
            previous = repository.get(collection, key)
            # Sessions are stored only as digests in PostgreSQL.
            normalized = dict(value, token=repository._key(collection, key)) if collection == "sessions" else value
            if previous is not None and previous != normalized:
                conflicts.append(f"target differs: {record_label(collection, key)}")
            elif previous is None:
                saves.append((collection, key, value))
    if conflicts:
        return {"ok": False, "conflicts": conflicts, "pending": len(saves)}
    if apply:
        with repository.transaction():
            # Recheck under the write lock, so a preflight race cannot overwrite.
            for collection, key, value in saves:
                if repository.get(collection, key) is not None:
                    raise RuntimeError("target changed since preflight; retry in maintenance window")
                repository.save(collection, key, value)
            for collection, records in data.items():
                for key, value in records.items():
                    normalized = dict(value, token=repository._key(collection, key)) if collection == "sessions" else value
                    if repository.get(collection, key) != normalized:
                        raise RuntimeError("verification failed; import rolled back")
    return {"ok": True, "applied": apply, "pending": len(saves),
            "counts": {name: len(rows) for name, rows in data.items()},
            "sha256": hashlib.sha256(json.dumps(data, sort_keys=True, ensure_ascii=False).encode()).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True)
    parser.add_argument("--history", help="legacy history.json")
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument("--report", default="migration-report.json")
    args = parser.parse_args()
    from app.settings import load_environment
    load_environment()
    history = json.loads(Path(args.history).read_text(encoding="utf-8-sig")) if args.history else None
    data, errors = prepare(load_source(args.source), history)
    report = {"ok": False, "errors": errors}
    if not errors:
        import os
        from app.repositories.postgresql_repository import PostgreSQLRepository
        repository = PostgreSQLRepository(os.environ["DATABASE_URL"])
        try:
            report = import_and_verify(repository, data, args.apply and not args.verify_only)
            if args.verify_only and report.get("pending"):
                report["ok"] = False
        finally:
            repository.close()
    Path(args.report).write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    # Reports contain IDs and counts only; never print credentials or full rows.
    print(json.dumps(report, ensure_ascii=False))
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
