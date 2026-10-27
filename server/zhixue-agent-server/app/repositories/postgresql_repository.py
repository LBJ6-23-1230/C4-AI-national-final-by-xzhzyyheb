"""Pooled PostgreSQL repository with real transactions and cross-process locks."""
from __future__ import annotations

from contextlib import contextmanager
from datetime import datetime, timezone
from copy import deepcopy
import hashlib
import os
import re
import threading

from sqlalchemy import create_engine, select, text, delete, update, func, or_, and_
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.engine import make_url

from app.repositories.repository import Repository
from app.repositories.pg_schema import tables, compatibility, REVISION


def make_engine(url):
    parsed = make_url(url)
    if parsed.drivername in {"postgres", "postgresql"}:
        parsed = parsed.set(drivername="postgresql+psycopg")
    if parsed.drivername != "postgresql+psycopg":
        raise ValueError("DATABASE_URL must use PostgreSQL with Psycopg 3")
    schema = os.getenv("DB_SCHEMA", "public")
    if not re.fullmatch(r"[a-z_][a-z0-9_]*", schema):
        raise ValueError("invalid DB_SCHEMA")
    return create_engine(parsed, pool_pre_ping=True, pool_recycle=300,
                         pool_size=int(os.getenv("DB_POOL_SIZE", "5")),
                         max_overflow=int(os.getenv("DB_MAX_OVERFLOW", "2")),
                         pool_timeout=10, hide_parameters=True,
                         connect_args={"connect_timeout": 5, "options":
                                       f"-c search_path={schema} -c timezone=UTC -c statement_timeout=15000 -c lock_timeout=5000 -c idle_in_transaction_session_timeout=30000"})


def _time(value):
    if not value:
        return None
    if isinstance(value, datetime):
        return value
    try:
        result = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        return result if result.tzinfo else result.replace(tzinfo=timezone.utc)
    except ValueError:
        return None


class PostgreSQLRepository(Repository):
    durable_jobs = True

    def __init__(self, url, check_schema=True):
        self.engine = make_engine(url)
        self.path = "PostgreSQL (credentials hidden)"
        self._local = threading.local()
        self._pid = os.getpid()
        if check_schema:
            self.check_ready()

    def check_ready(self):
        with self.engine.connect() as connection:
            revision = connection.execute(text("SELECT version_num FROM alembic_version")).scalar_one()
            if revision != REVISION:
                raise RuntimeError("database schema mismatch; run alembic upgrade head before starting")
            connection.execute(select(tables["jobs"].c.item_id).limit(0))

    def close(self):
        self.engine.dispose()

    def _check_pid(self):
        if self._pid != os.getpid():
            self.engine.dispose(close=False)
            self._local = threading.local()
            self._pid = os.getpid()

    @contextmanager
    def connection(self):
        self._check_pid()
        current = getattr(self._local, "connection", None)
        if current is not None:
            yield current
        else:
            with self.engine.begin() as connection:
                yield connection

    @contextmanager
    def transaction(self, user_id=None):
        """Unscoped operations keep the original serial semantics.

        Scoped operations take a shared global guard plus a per-user exclusive
        advisory lock. Legacy/global operations take the exclusive global guard,
        so they cannot race with scoped work. Locks expire with the transaction.
        """
        self._check_pid()
        current = getattr(self._local, "connection", None)
        if current is not None:
            with current.begin_nested():
                yield self
            return
        with self.engine.begin() as connection:
            self._local.connection = connection
            try:
                if user_id:
                    connection.execute(text("SELECT pg_advisory_xact_lock_shared(1087, 0)"))
                    key = int.from_bytes(hashlib.sha256(str(user_id).encode()).digest()[:4], "big", signed=True)
                    connection.execute(text("SELECT pg_advisory_xact_lock(1088, :key)"), {"key": key})
                else:
                    connection.execute(text("SELECT pg_advisory_xact_lock(1087, 0)"))
                yield self
            finally:
                self._local.connection = None

    def _table(self, collection):
        table = tables.get(collection, compatibility)
        where = table.c.collection == collection if table is compatibility else text("true")
        return table, where

    @staticmethod
    def _key(collection, key):
        if collection == "sessions" and not key.startswith("sha256:"):
            return "sha256:" + hashlib.sha256(key.encode()).hexdigest()
        return key

    def get(self, collection, item_id):
        item_id = self._key(collection, item_id)
        table, where = self._table(collection)
        with self.connection() as connection:
            return connection.execute(select(table.c.value).where(where, table.c.item_id == item_id)).scalar_one_or_none()

    def _values(self, collection, item_id, value):
        owner = value.get("userId") or value.get("response", {}).get("userId") or value.get("state", {}).get("userId")
        result = dict(item_id=item_id, user_id=owner, status=value.get("status"),
                      version=value.get("profileVersion", value.get("version", 0)) or 0,
                      updated_at=datetime.now(timezone.utc), value=deepcopy(value))
        created = _time(value.get("createdAt") or value.get("uploadedAt") or value.get("timestamp"))
        if created:
            result["created_at"] = created
        table, _ = self._table(collection)
        if table is compatibility:
            result["collection"] = collection
        if collection == "users":
            result.update(phone=value.get("phone") or None,
                          nickname_normalized=str(value.get("nickname") or "").strip().casefold())
        if "kb_id" in table.c:
            result.update(kb_id=value.get("kbId"), document_id=value.get("documentId"))
        if collection == "submissions":
            result.update(idempotency_key=value.get("idempotencyKey"), request_fingerprint=value.get("requestFingerprint"))
        if collection == "chat_messages":
            result.update(session_id=value.get("sessionId"), sequence=value.get("sequence"))
        if collection == "jobs":
            result.update(attempts=value.get("attempts", 0), run_after=_time(value["runAfter"]),
                          locked_until=_time(value.get("lockedUntil")), lease_token=value.get("leaseToken"))
        return result

    def save(self, collection, item_id, value):
        item_id = self._key(collection, item_id)
        if collection == "sessions":
            value = dict(value, token=item_id)
        table, _ = self._table(collection)
        values = self._values(collection, item_id, value)
        statement = insert(table).values(**values)
        statement = statement.on_conflict_do_update(
            index_elements=list(table.primary_key.columns),
            set_={key: getattr(statement.excluded, key) for key in values if key not in {"item_id", "collection", "created_at"}})
        with self.connection() as connection:
            connection.execute(statement)

    def list(self, collection):
        table, where = self._table(collection)
        with self.connection() as connection:
            return list(connection.execute(select(table.c.value).where(where).order_by(table.c.item_id)).scalars())

    def query(self, collection, filters=None, *, limit=None, after=None):
        table, where = self._table(collection)
        statement = select(table.c.value).where(where)
        columns = {"userId": "user_id", "kbId": "kb_id", "documentId": "document_id", "phone": "phone", "nicknameNormalized": "nickname_normalized"}
        for key, value in (filters or {}).items():
            column = columns.get(key)
            statement = statement.where(table.c[column] == value) if column and column in table.c else statement.where(table.c.value[key].astext == str(value))
        if after:
            statement = statement.where(table.c.item_id > after)
        if limit is not None:
            statement = statement.limit(max(1, min(500, limit)))
        with self.connection() as connection:
            return list(connection.execute(statement.order_by(table.c.item_id)).scalars())

    def ids(self, collection):
        table, where = self._table(collection)
        with self.connection() as connection:
            return list(connection.execute(select(table.c.item_id).where(where).order_by(table.c.item_id)).scalars())

    def delete(self, collection, item_id):
        item_id = self._key(collection, item_id)
        table, where = self._table(collection)
        with self.connection() as connection:
            connection.execute(delete(table).where(where, table.c.item_id == item_id))

    def clear(self, collection):
        table, where = self._table(collection)
        with self.connection() as connection:
            connection.execute(delete(table).where(where))

    def apply_batch(self, deletes, saves):
        with self.transaction():
            for collection, key in deletes:
                self.delete(collection, key)
            for collection, key, value in saves:
                self.save(collection, key, value)

    def compare_and_save(self, collection, item_id, expected, replacement):
        table, where = self._table(collection)
        values = self._values(collection, item_id, replacement)
        values.pop("created_at", None)
        with self.transaction():
            with self.connection() as connection:
                return connection.execute(update(table).where(where, table.c.item_id == item_id,
                    table.c.value == expected).values(**values)).rowcount == 1

    def claim_job(self, now, locked_until, token, max_attempts):
        table = tables["jobs"]
        with self.engine.begin() as connection:
            row = connection.execute(select(table.c.value).where(
                or_(and_(table.c.status == "queued", table.c.run_after <= now),
                    and_(table.c.status == "running", table.c.locked_until <= now)))
                .order_by(table.c.run_after, table.c.item_id).with_for_update(skip_locked=True).limit(1)).scalar_one_or_none()
            if not row:
                return None
            job = dict(row)
            exhausted = job["attempts"] >= max_attempts
            job.update(status="running", retryExhausted=exhausted,
                       attempts=job["attempts"] if exhausted else job["attempts"] + 1,
                       lockedUntil=locked_until.isoformat(), leaseToken=token)
            values = self._values("jobs", job["jobId"], job)
            connection.execute(update(table).where(table.c.item_id == job["jobId"]).values(**values))
            return job

    def locked_job(self, job_id):
        table = tables["jobs"]
        with self.connection() as connection:
            return connection.execute(select(table.c.value).where(table.c.item_id == job_id)
                                      .with_for_update()).scalar_one_or_none()

    def purge_user_data(self, user_id):
        """Explicit account deletion, inside the auth transaction.

        Keep an anonymous tombstone, revoke jobs, and queue file cleanup after
        removing private rows. A running worker cannot resurrect deleted rows.
        """
        from app.services.file_storage import schedule_delete
        originals = self.query("file_objects", {"userId": user_id})
        with self.connection() as connection:
            for name, table in tables.items():
                if name != "users":
                    connection.execute(delete(table).where(table.c.user_id == user_id))
            connection.execute(delete(compatibility).where(compatibility.c.user_id == user_id))
        for original in originals:
            schedule_delete(self, original)
        self.save("users", user_id, {"userId": user_id, "status": "deactivated",
                                    "deactivatedAt": datetime.now(timezone.utc).isoformat()})
