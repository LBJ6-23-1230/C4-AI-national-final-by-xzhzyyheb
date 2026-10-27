"""Versioned PostgreSQL tables; business IDs and JSON API payloads are preserved.

Each established domain has its own table. Frequently filtered fields are typed
columns. New/rare collections use an explicit compatibility table until promoted.
No startup DDL: only Alembic may create or alter this schema.
"""
from sqlalchemy import (MetaData, Table, Column, Text, Integer, DateTime, Index,
                        CheckConstraint, UniqueConstraint, ForeignKeyConstraint, func)
from sqlalchemy.dialects.postgresql import JSONB

REVISION = "20261027_01"
metadata = MetaData()
COLLECTIONS = {
    "users": "users", "sessions": "auth_sessions",
    "verification_codes": "verification_challenges", "profiles": "learning_profiles",
    "plans": "plans", "plan_histories": "plan_histories", "plan_adjustments": "plan_adjustments",
    "exercises": "exercises", "submissions": "submissions", "wrong_book": "wrong_book_items",
    "workflows": "workflows", "traces": "agent_traces", "evidences": "evidences",
    "knowledge_bases": "knowledge_bases", "documents": "documents", "chunks": "document_chunks",
    "chat_sessions": "chat_sessions", "chat_messages": "chat_messages",
    "jobs": "jobs", "file_objects": "file_objects", "audit_events": "audit_events",
    "focus_sessions": "focus_sessions", "exercise_usage": "exercise_usage",
    "document_tag_revisions": "document_tag_revisions", "learning_events": "learning_events",
}


def domain_table(name, compatibility=False):
    columns = [Column("item_id", Text, primary_key=True)]
    if compatibility:
        columns.insert(0, Column("collection", Text, primary_key=True))
    columns += [Column("user_id", Text), Column("status", Text),
                Column("version", Integer, nullable=False, server_default="0"),
                Column("created_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
                Column("updated_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
                Column("value", JSONB, nullable=False),
                CheckConstraint("version >= 0", name=f"ck_{name}_version")]
    if name == "users":
        columns += [Column("phone", Text, unique=True), Column("nickname_normalized", Text)]
    if name in {"documents", "document_chunks"}:
        columns += [Column("kb_id", Text), Column("document_id", Text)]
    if name == "submissions":
        columns += [Column("idempotency_key", Text), Column("request_fingerprint", Text),
                    UniqueConstraint("user_id", "idempotency_key", name="uq_submission_idempotency")]
    if name == "chat_messages":
        columns += [Column("session_id", Text), Column("sequence", Integer),
                    UniqueConstraint("user_id", "sequence", name="uq_chat_user_sequence")]
    if name == "jobs":
        columns += [Column("attempts", Integer, nullable=False, server_default="0"),
                    Column("run_after", DateTime(timezone=True), nullable=False),
                    Column("locked_until", DateTime(timezone=True)), Column("lease_token", Text),
                    CheckConstraint("attempts >= 0", name="ck_jobs_attempts"),
                    CheckConstraint("status IN ('queued','running','succeeded','failed','cancelled')", name="ck_jobs_status")]
    table = Table(name, metadata, *columns)
    Index(f"ix_{name}_user_created", table.c.user_id, table.c.created_at, table.c.item_id)
    if "kb_id" in table.c:
        Index(f"ix_{name}_kb", table.c.user_id, table.c.kb_id)
    if name == "document_chunks":
        Index("ix_chunks_document", table.c.user_id, table.c.document_id)
    if name == "users":
        Index("ix_users_nickname", table.c.nickname_normalized)
    if name == "jobs":
        Index("ix_jobs_claim", table.c.status, table.c.run_after, table.c.locked_until)
    return table


tables = {collection: domain_table(name) for collection, name in COLLECTIONS.items()}
compatibility = domain_table("compatibility_records", True)
for collection in ("knowledge_bases", "documents"):
    tables[collection].append_constraint(UniqueConstraint("user_id", "item_id", name=f"uq_{collection}_owner_id"))
tables["documents"].append_constraint(ForeignKeyConstraint(
    ["user_id", "kb_id"], ["knowledge_bases.user_id", "knowledge_bases.item_id"],
    name="fk_document_owned_kb", deferrable=True, initially="DEFERRED"))
tables["chunks"].append_constraint(ForeignKeyConstraint(
    ["user_id", "document_id"], ["documents.user_id", "documents.item_id"],
    name="fk_chunk_owned_document", deferrable=True, initially="DEFERRED"))
