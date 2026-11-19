-- =====================================================================
-- 0003_roles.sql - Least privilege. Run with: psql -v pw_app="'...'" -v pw_readonly="'...'" -f 0003_roles.sql
-- (passwords passed as variables; do NOT write a password in this file or in the repository)
--   bot_app      : n8n/bot. DML on the tables, no DDL, no DROP/TRUNCATE.
--   bot_readonly : panel/BI. SELECT only, WITHOUT company_sga and WITHOUT message_payloads (personal data / secret).
-- Roles belong to the cluster: if they already exist we only update the password.
-- =====================================================================
SELECT NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bot_app')      AS create_app      \gset
SELECT NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bot_readonly') AS create_readonly \gset
\if :create_app
  CREATE ROLE bot_app LOGIN;
\endif
\if :create_readonly
  CREATE ROLE bot_readonly LOGIN;
\endif
ALTER ROLE bot_app      PASSWORD :pw_app;
ALTER ROLE bot_readonly PASSWORD :pw_readonly;

BEGIN;
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO bot_app, bot_readonly;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO bot_app;
REVOKE INSERT, UPDATE, DELETE ON schema_migrations FROM bot_app;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO bot_app;

GRANT SELECT ON ALL TABLES IN SCHEMA public TO bot_readonly;
REVOKE SELECT ON company_sga, message_payloads FROM bot_readonly;

-- Future tables created by the owner inherit the same rights
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO bot_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO bot_readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO bot_app;

-- Defensive limits: a stuck query/worker does not hold a lock forever
ALTER ROLE bot_app      SET statement_timeout = '30s';
ALTER ROLE bot_app      SET lock_timeout = '5s';
ALTER ROLE bot_app      SET idle_in_transaction_session_timeout = '60s';
ALTER ROLE bot_readonly SET statement_timeout = '60s';

INSERT INTO schema_migrations (version, description) VALUES ('0003', 'roles bot_app and bot_readonly');
COMMIT;
