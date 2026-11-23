-- =====================================================================
-- 0007_company_storage_bucket.sql   (PROPOSAL - not applied, waiting for Carlos Eduardo's ok)
-- One storage bucket per company (RustFS now, AWS S3 later). The bucket name lives with the company,
-- so the n8n flow reads it from the database instead of an environment variable.
-- Oversized media (> 100 MB) is a permanent failure: it must not be retried by flow 07.
-- Undo: see the bottom of the file.
-- =====================================================================
BEGIN;

ALTER TABLE companies ADD COLUMN storage_bucket text
  CHECK (storage_bucket IS NULL OR storage_bucket ~ '^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$');   -- S3 naming rules
CREATE UNIQUE INDEX ux_companies_storage_bucket ON companies (storage_bucket) WHERE storage_bucket IS NOT NULL;

-- Seed: only Ancore exists today. In AWS bucket names are global; change this value if the name is taken.
UPDATE companies SET storage_bucket = 'revistorias-ancore' WHERE slug = 'ancore' AND storage_bucket IS NULL;

-- Permanent failure (size_exceeded, unsupported type...): retrying does not help.
ALTER TABLE inspections ADD COLUMN failure_permanent boolean NOT NULL DEFAULT false;
-- One alert per exhausted inspection: flow 07 sets alerted_at after the alert is sent.
ALTER TABLE inspections ADD COLUMN alerted_at timestamptz;
-- Retry queue of flow 07 (status = upload_failed, not permanent, attempts < 5):
DROP INDEX ix_inspections_pending;
CREATE INDEX ix_inspections_pending ON inspections (company_id, created_at)
  WHERE status IN ('received','uploading','awaiting_review')
     OR (status = 'upload_failed' AND NOT failure_permanent);
-- size_bytes has NO upper-limit CHECK on purpose: a rejected 150 MB video still records its real size.

INSERT INTO schema_migrations (version, description) VALUES ('0007', 'companies.storage_bucket, inspections.failure_permanent, inspections.alerted_at');
COMMIT;

-- UNDO (manual): DROP INDEX ix_inspections_pending;
--   CREATE INDEX ix_inspections_pending ON inspections (company_id, created_at) WHERE status IN ('received','uploading','upload_failed','awaiting_review');
--   ALTER TABLE inspections DROP COLUMN alerted_at; ALTER TABLE inspections DROP COLUMN failure_permanent;
--   DROP INDEX ux_companies_storage_bucket; ALTER TABLE companies DROP COLUMN storage_bucket;
--   DELETE FROM schema_migrations WHERE version = '0007';
