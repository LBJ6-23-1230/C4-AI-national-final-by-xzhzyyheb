"""Ordered chat turns in the shared repository, preserving the public history shape."""
from copy import deepcopy
import hashlib


def history(repository, owner):
    rows = repository.query("chat_messages", {"userId": owner})
    return [row["entry"] for row in sorted(rows, key=lambda row: row["sequence"])]


def append(repository, owner, entry, maximum=50):
    with repository.transaction():
        user = repository.get("users", owner)
        if user and user.get("status") == "deactivated":
            return False
        session = repository.get("chat_sessions", owner) or {"userId": owner, "sequence": 0}
        sequence = session["sequence"] + 1
        row = {"userId": owner, "sequence": sequence, "sessionId": entry.get("session_id", ""),
               "entry": deepcopy(entry), "createdAt": entry.get("timestamp")}
        key = hashlib.sha256(f"{owner}\0{sequence}".encode()).hexdigest()
        row["messageId"] = key
        repository.save("chat_messages", key, row)
        repository.save("chat_sessions", owner, dict(session, sequence=sequence))
        rows = sorted(repository.query("chat_messages", {"userId": owner}), key=lambda r: r["sequence"])
        expired = rows[:-maximum]
        from app.services.chat_attachments import release
        release(repository, [old["entry"] for old in expired])
        for old in expired:
            repository.delete("chat_messages", old["messageId"])
        return True


def clear(repository, owner):
    with repository.transaction():
        rows = repository.query("chat_messages", {"userId": owner})
        from app.services.chat_attachments import release
        release(repository, [row["entry"] for row in rows])
        for row in rows:
            repository.delete("chat_messages", row["messageId"])
