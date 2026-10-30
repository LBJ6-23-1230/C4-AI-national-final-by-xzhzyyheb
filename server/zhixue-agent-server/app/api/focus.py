"""Durable focus facts: execution time and self-report never imply mastery."""

from copy import deepcopy
from datetime import datetime, timezone
import hashlib
import math

from flask import Blueprint, jsonify, request

from app.api.identity import resolve_user_id
from app.api.plans import plan_belongs_to
from app.api.validation import bounded_str, json_object, MAX_ID_CHARS, MAX_TEXT_CHARS
from app.tools.profile_merge import PROFILE_LOCK

focus_api = Blueprint("focus", __name__)
_repository = None


def configure_focus_repository(repository):
    global _repository
    _repository = repository


def _error(message, status=400):
    return jsonify({"errorCode": "CONFLICT" if status == 409 else "BAD_REQUEST",
                    "message": message, "details": None}), status


def _validated(data):
    result = {}
    for field in ("taskId", "course", "task", "endedAt"):
        value, guard = bounded_str(data.get(field), field,
                                  MAX_ID_CHARS if field == "taskId" else MAX_TEXT_CHARS)
        if guard is not None:
            return None, guard
        result[field] = value
    if data.get("planTaskId") is not None:
        value, guard = bounded_str(data["planTaskId"], "planTaskId", MAX_ID_CHARS)
        if guard is not None:
            return None, guard
        result["planTaskId"] = value
    for field, maximum in (("plannedMinutes", 1440), ("actualMinutes", 1440),
                           ("pauseCount", 10000), ("interruptionCount", 10000), ("completionRate", 100)):
        value = data.get(field)
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
            return None, _error(f"{field} must be a finite number")
        if not 0 <= value <= maximum or (field.endswith("Count") and int(value) != value):
            return None, _error(f"{field} is outside its valid range")
        result[field] = value
    for field, choices in (("selfAssessment", {"completed", "partial", "not_completed"}),
                           ("timerType", {"countdown", "stopwatch"}),
                           ("status", {"completed", "not_completed", "interrupted"})):
        value = data.get(field)
        if not isinstance(value, str) or value not in choices:
            return None, _error(f"invalid {field}")
        result[field] = value
    try:
        ended = datetime.fromisoformat(result["endedAt"].replace("Z", "+00:00"))
        if ended.tzinfo is None:
            raise ValueError
        if ended > datetime.now(timezone.utc):
            # Small device clock skew is accepted; far-future events would
            # otherwise win permanently over later legitimate state updates.
            from datetime import timedelta
            if ended - datetime.now(timezone.utc) > timedelta(minutes=10):
                raise ValueError
        result["endedAt"] = ended.astimezone(timezone.utc).isoformat()
    except ValueError:
        return None, _error("endedAt must be an ISO timestamp with timezone and not in the far future")
    return result, None


def _status(session):
    return {"completed": "completed", "partial": "partial", "not_completed": "deferred"}[
        session["selfAssessment"]]


@focus_api.get("/api/v1/focus-sessions")
def list_focus_sessions():
    owner = resolve_user_id(request.args.get("userId"))
    with PROFILE_LOCK, _repository.transaction():
        records = [r for r in _repository.list("focus_sessions") if r.get("userId") == owner]
        records.sort(key=lambda r: (r["session"]["endedAt"], r["session"]["taskId"]))
        statuses = {}
        for record in records:
            session = record["session"]
            task = session.get("planTaskId")
            if task and statuses.get(task) != "completed":
                statuses[task] = _status(session)
        return jsonify({"userId": owner, "sessions": [r["session"] for r in records],
                        "taskStatuses": statuses})


@focus_api.post("/api/v1/focus-sessions")
def submit_focus_session():
    data, guard = json_object()
    if guard is not None:
        return guard
    owner = resolve_user_id(data.get("userId"))
    session, guard = _validated(data)
    if guard is not None:
        return guard
    key = hashlib.sha256(f"{owner}\0{session['taskId']}".encode()).hexdigest()
    with PROFILE_LOCK, _repository.transaction():
        previous = _repository.get("focus_sessions", key)
        if previous is not None:
            if previous["session"] != session:
                return _error("this focus event ID was already used for different facts", 409)
            return jsonify(previous["response"])
        saves = []
        matched = False
        for plan in _repository.list("plans"):
            if not plan_belongs_to(plan, owner):
                continue
            updated = deepcopy(plan)
            changed = False
            for task in [*updated.get("tasks", []), *updated.get("unscheduledTasks", [])]:
                if task.get("taskId") == session.get("planTaskId"):
                    matched = True
                    if session["selfAssessment"] == "completed" and task.get("status") != "completed":
                        task["status"] = "completed"
                        changed = True
            if changed:
                completed_deferred = [t for t in updated.get("unscheduledTasks", []) if t.get("status") == "completed"]
                updated["tasks"] = [*updated.get("tasks", []), *completed_deferred]
                updated["unscheduledTasks"] = [t for t in updated.get("unscheduledTasks", []) if t.get("status") != "completed"]
                if "budgetSummary" in updated:
                    summary = dict(updated["budgetSummary"])
                    summary["scheduledMinutes"] = sum(t["durationMinutes"] for t in updated["tasks"] if t.get("status") != "completed")
                    summary["unallocatedMinutes"] = summary["availableMinutes"] - summary["scheduledMinutes"]
                    summary["unscheduledMinutes"] = sum(t["durationMinutes"] for t in updated["unscheduledTasks"])
                    updated["budgetSummary"] = summary
                # Task progress changes state, not the schedule's plan version.
                # Later plan writers must preserve these task IDs and statuses.
                saves.append(("plans", updated["planId"], updated))
        event_id = f"focus-{key}"
        response = {"userId": owner, "eventId": event_id, "session": session,
                    "planTaskMatched": matched}
        saves.extend([
            ("focus_sessions", key, {"userId": owner, "session": session, "response": response}),
            ("learning_events", event_id, {"eventId": event_id, "userId": owner,
                "type": "FocusCompleted", "objectId": session["taskId"],
                "occurredAt": session["endedAt"], "planTaskId": session.get("planTaskId"),
                "selfAssessment": session["selfAssessment"], "status": "recorded"}),
        ])
        _repository.apply_batch([], saves)
        from app.services.reminders import reconcile
        reconcile(_repository, owner)
        return jsonify(response)
