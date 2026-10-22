"""Conservative retention planning. Applying a plan is an explicit offline action."""
from collections import defaultdict
from datetime import datetime, timezone, timedelta

POLICIES = {"traces": (90, 1000), "submissions": (180, 1000),
            "wrong_book": (365, 1000), "exercise_usage": (7, 5000)}


def _date(value):
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        return parsed.replace(tzinfo=timezone.utc) if parsed.tzinfo is None else parsed
    except ValueError:
        return None


def plan(repository, now=None):
    now = now or datetime.now(timezone.utc)
    protected = set()
    for workflow in repository.list("workflows"):
        state = workflow.get("state", {})
        for value in (workflow.get("traceId"), state.get("boundSubmissionId"),
                      state.get("inputRefs", {}).get("submissionId")):
            if isinstance(value, str):
                protected.add(value)
    for submission in repository.list("submissions"):
        # Never strand a retained submission's trace, even when old.
        value = submission.get("response", {}).get("traceId")
        if value:
            protected.add(value)
    deletes = []
    for collection, (days, maximum) in POLICIES.items():
        buckets = defaultdict(list)
        for item_id in repository.ids(collection):
            row = repository.get(collection, item_id)
            if not isinstance(row, dict) or item_id in protected:
                continue
            # Unresolved mistakes are learning data, never silently evict them.
            if collection == "wrong_book" and int(row.get("correctCount", 0)) < 3:
                continue
            owner = row.get("userId") or row.get("response", {}).get("userId")
            if not owner:
                continue
            stamps = [row.get(k) for k in ("createdAt", "lastPracticedAt", "addedAt", "timestamp")]
            stamps.extend(e.get("timestamp") for e in row.get("events", []) if isinstance(e, dict))
            dates = [d for d in map(_date, stamps) if d]
            if dates:
                buckets[owner].append((max(dates), item_id))
        for rows in buckets.values():
            rows.sort(reverse=True)
            for index, (stamp, item_id) in enumerate(rows):
                if stamp < now - timedelta(days=days) or index >= maximum:
                    deletes.append((collection, item_id))
    return deletes


def history_plan(store, now=None):
    now = now or datetime.now(timezone.utc)
    cutoff = now - timedelta(days=90)
    return {owner: [entry for entry in rows if not _date(entry.get("timestamp")) or
                   _date(entry.get("timestamp")) >= cutoff][-50:]
            for owner, rows in store.items() if isinstance(rows, list)}
