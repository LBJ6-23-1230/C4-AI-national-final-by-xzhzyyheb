-- Run once as the database owner; create credentials through your secret manager.
-- Assumes this is a dedicated database and all migration objects use public.
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
CREATE ROLE zhixue_api NOLOGIN;
CREATE ROLE zhixue_worker NOLOGIN;
CREATE ROLE zhixue_readonly NOLOGIN;
GRANT USAGE ON SCHEMA public TO zhixue_api, zhixue_worker, zhixue_readonly;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO zhixue_api;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO zhixue_worker;
GRANT INSERT, UPDATE, DELETE ON jobs, submissions, wrong_book_items, documents,
    document_chunks, knowledge_bases, file_objects TO zhixue_worker;
-- Reminder events/deliveries/devices are new collections in the compatibility table.
GRANT INSERT, UPDATE, DELETE ON compatibility_records TO zhixue_worker;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO zhixue_readonly;
REVOKE INSERT, UPDATE, DELETE ON alembic_version FROM zhixue_api, zhixue_worker;
-- Grant these roles to separate LOGIN roles. Do not grant the migration role.
-- Review grants for each future migration. No application role gets CREATE.
