"""Durable jobs. External work runs outside transactions; result and ack commit together."""
from copy import deepcopy
from datetime import datetime, timedelta, timezone
import hashlib
import logging
import os
import threading
import uuid

logger = logging.getLogger("zhixue.jobs")


def now():
    return datetime.now(timezone.utc)


def enqueue(repository, kind, user_id, payload, key):
    job_id = "job-" + hashlib.sha256(f"{kind}\0{user_id}\0{key}".encode()).hexdigest()
    if repository.get("jobs", job_id):
        return job_id
    stamp = now().isoformat()
    repository.save("jobs", job_id, {"jobId": job_id, "userId": user_id,
                    "type": kind, "payload": deepcopy(payload), "status": "queued", "attempts": 0,
                    "runAfter": stamp, "lockedUntil": None, "leaseToken": None,
                    "lastError": None, "createdAt": stamp, "finishedAt": None})
    return job_id


def claim(repository, lease_seconds=120, max_attempts=4):
    stamp, token = now(), uuid.uuid4().hex
    expiry = stamp + timedelta(seconds=lease_seconds)
    if hasattr(repository, "claim_job"):
        return repository.claim_job(stamp, expiry, token, max_attempts)
    with repository.transaction():
        for row in sorted(repository.list("jobs"), key=lambda j: (j["runAfter"], j["jobId"])):
            due = row["status"] == "queued" and row["runAfter"] <= stamp.isoformat()
            expired = row["status"] == "running" and (row.get("lockedUntil") or "") <= stamp.isoformat()
            if not (due or expired):
                continue
            job = dict(row)
            exhausted = job["attempts"] >= max_attempts
            job.update(status="running", retryExhausted=exhausted,
                       attempts=job["attempts"] if exhausted else job["attempts"] + 1,
                       lockedUntil=expiry.isoformat(), leaseToken=token)
            repository.save("jobs", job["jobId"], job)
            return job
    return None


def owns_lease(current, job):
    return bool(current and current["status"] == "running" and
                current.get("leaseToken") == job.get("leaseToken") and
                (current.get("lockedUntil") or "") > now().isoformat())


def locked_job(repository, job_id):
    if hasattr(repository, "locked_job"):
        return repository.locked_job(job_id)
    return repository.get("jobs", job_id)


def heartbeat(repository, job, lease_seconds=120):
    with repository.transaction():
        current = locked_job(repository, job["jobId"])
        if not owns_lease(current, job):
            return False
        current["lockedUntil"] = (now() + timedelta(seconds=lease_seconds)).isoformat()
        repository.save("jobs", job["jobId"], current)
        return True


def execute(repository, job):
    """Returns a pure result. No long-lived connection while calling a provider."""
    if job["type"] == "review":
        from app.agent.exercise_gen import generate_review_explanations
        payload = job["payload"]
        result, ids = generate_review_explanations(payload["questions"], payload["answers"], payload["keys"])
        if not ids:
            raise RuntimeError("review_provider_unavailable")
        return result, ids
    if job["type"] == "parse_document":
        from app.services.file_storage import storage
        from app.agent import knowledge
        import base64
        payload = job["payload"]
        raw = storage().read(payload["file"])
        return knowledge.process_document(payload["fileName"], base64.b64encode(raw).decode(),
                                          payload["vocabulary"], scope=payload["scope"])
    if job["type"] == "delete_file":
        from app.services.file_storage import storage
        storage().delete(job["payload"]["file"])
        return None
    raise ValueError("unknown_job_type")


def finish(repository, job, result):
    with repository.transaction():
        current = locked_job(repository, job["jobId"])
        if not owns_lease(current, job):
            return False
        payload = job["payload"]
        if job["type"] == "review":
            from app.services.review_jobs import apply_result
            apply_result(repository, payload["submissionId"], payload["expected"],
                         payload["wrongSnapshots"], *result)
        elif job["type"] == "parse_document":
            from app.api.knowledge import complete_document_job
            complete_document_job(repository, payload, result)
        elif job["type"] == "delete_file":
            repository.delete("file_objects", payload["file"]["fileId"])
        current.update(status="succeeded", finishedAt=now().isoformat(), lockedUntil=None, leaseToken=None)
        repository.save("jobs", job["jobId"], current)
        return True


def fail(repository, job, max_attempts=4):
    with repository.transaction():
        current = locked_job(repository, job["jobId"])
        if not owns_lease(current, job):
            return False
        exhausted = current["attempts"] >= max_attempts
        current.update(status="failed" if exhausted else "queued", lockedUntil=None, leaseToken=None,
                       lastError="processing_failed", finishedAt=now().isoformat() if exhausted else None,
                       runAfter=(now() + timedelta(seconds=min(300, 2 ** current["attempts"]))).isoformat())
        repository.save("jobs", job["jobId"], current)
        if exhausted:
            terminal_failure(repository, job)
        return True


def terminal_failure(repository, job):
    payload = job["payload"]
    if job["type"] == "review":
        expected = payload["expected"]
        replacement = deepcopy(expected)
        replacement["response"]["reviewStatus"] = "failed"
        repository.compare_and_save("submissions", payload["submissionId"], expected, replacement)
    elif job["type"] == "parse_document":
        record = repository.get("documents", payload["documentId"])
        if record and record.get("parseToken") == payload["parseToken"]:
            repository.save("documents", payload["documentId"], dict(record, status="failed",
                statusMessage="资料处理失败，请稍后重新上传", parseSource="failed"))


def run_once(repository, lease_seconds=120):
    job = claim(repository, lease_seconds)
    if not job:
        return False
    if job.get("retryExhausted"):
        # Keep a reclaimable lease until BOTH terminal effects and job state commit.
        # A crash before/during this transaction can then be retried by another worker.
        with repository.transaction():
            current = locked_job(repository, job["jobId"])
            if owns_lease(current, job):
                terminal_failure(repository, current)
                current.update(status="failed", lastError="retry_limit", lockedUntil=None,
                               leaseToken=None, finishedAt=now().isoformat())
                repository.save("jobs", job["jobId"], current)
        return True
    stop = threading.Event()
    def renew():
        while not stop.wait(max(1, lease_seconds / 3)):
            try:
                if not heartbeat(repository, job, lease_seconds):
                    return
            except Exception:
                logger.warning("job_heartbeat_failed job_id=%s", job["jobId"])
                return
    thread = threading.Thread(target=renew, daemon=True)
    thread.start()
    try:
        result = execute(repository, job)
        finish(repository, job, result)
    except Exception:
        fail(repository, job)
        logger.warning("job_failed job_id=%s type=%s", job["jobId"], job["type"])
    finally:
        stop.set()
        thread.join(timeout=5)
    return True
