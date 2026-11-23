-- =====================================================================
-- 0006_inspections.sql
-- Vehicle re-inspection (revistoria): photo OR video goes to object storage (RustFS in dev, AWS S3 in prod),
-- the ticket goes to the panel for human validation. The table records every step of the process.
-- Only the object key + hash live in the database, never the file.
-- Retention: 180 days (objects are deleted by the flow, then marked purged here).
-- Undo: see the bottom of the file.
-- =====================================================================
BEGIN;

CREATE TABLE inspections (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id       bigint NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  ticket_id        bigint NOT NULL,
  message_id       bigint NOT NULL,                       -- WhatsApp message that carried the media
  media_kind       text   NOT NULL CHECK (media_kind IN ('image','video')),
  status           text   NOT NULL DEFAULT 'received'
                   CHECK (status IN ('received','uploading','stored','upload_failed','awaiting_review','approved','rejected','sent_to_sga')),
  storage_provider text   CHECK (storage_provider IN ('rustfs','s3')),
  storage_bucket   text,
  storage_key      text,                                  -- object key only, never the file
  sha256           text   CHECK (sha256 IS NULL OR sha256 ~ '^[0-9a-f]{64}$'),
  mimetype         text,
  size_bytes       bigint CHECK (size_bytes IS NULL OR size_bytes >= 0),
  duration_seconds integer CHECK (duration_seconds IS NULL OR duration_seconds >= 0),   -- videos
  attempts         integer NOT NULL DEFAULT 0,
  last_error       text,
  stored_at        timestamptz,                           -- when it reached the storage
  reviewed_by      text,
  reviewed_at      timestamptz,
  review_note      text,
  purged_at        timestamptz,                           -- object deleted from storage (retention)
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (company_id, message_id),                        -- idempotency: a resend does not duplicate
  UNIQUE (company_id, id),
  FOREIGN KEY (company_id, ticket_id)  REFERENCES tickets  (company_id, id) ON DELETE CASCADE,
  FOREIGN KEY (company_id, message_id) REFERENCES messages (company_id, id),
  CHECK (status NOT IN ('stored','awaiting_review','approved','rejected','sent_to_sga')
         OR (storage_bucket IS NOT NULL AND storage_key IS NOT NULL AND stored_at IS NOT NULL) OR purged_at IS NOT NULL),
  CHECK (status NOT IN ('approved','rejected') OR reviewed_at IS NOT NULL)
);
CREATE INDEX ix_inspections_ticket  ON inspections (company_id, ticket_id);
CREATE INDEX ix_inspections_pending ON inspections (company_id, created_at)
  WHERE status IN ('received','uploading','upload_failed','awaiting_review');
CREATE INDEX ix_inspections_purge   ON inspections (stored_at)
  WHERE stored_at IS NOT NULL AND purged_at IS NULL;
CREATE TRIGGER trg_inspections_updated BEFORE UPDATE ON inspections FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Audit: each status change becomes an event on the ticket.
ALTER TABLE ticket_events DROP CONSTRAINT ticket_events_type_check;
ALTER TABLE ticket_events ADD CONSTRAINT ticket_events_type_check
  CHECK (type IN ('opening','complement','attendant_reply','bot_reply','state_change','forwarded','error','note','inspection'));

CREATE FUNCTION inspections_log_event() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' OR NEW.status IS DISTINCT FROM OLD.status THEN
    INSERT INTO ticket_events (company_id, ticket_id, type, author, message_id, detail)
    VALUES (NEW.company_id, NEW.ticket_id, 'inspection', 'system', NEW.message_id,
            jsonb_build_object('inspection_id', NEW.id, 'media_kind', NEW.media_kind,
                               'status_from', CASE WHEN TG_OP = 'UPDATE' THEN OLD.status END,
                               'status_to', NEW.status, 'attempts', NEW.attempts));
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_inspections_event AFTER INSERT OR UPDATE ON inspections
  FOR EACH ROW EXECUTE FUNCTION inspections_log_event();

-- Retention (180 days). The database cannot delete from RustFS/S3: flow 07 asks for the list,
-- deletes the objects, then confirms here.
CREATE FUNCTION inspections_due_for_purge(p_days integer DEFAULT 180, p_limit integer DEFAULT 200)
RETURNS TABLE (id bigint, storage_provider text, storage_bucket text, storage_key text)
LANGUAGE sql STABLE AS $$
  SELECT i.id, i.storage_provider, i.storage_bucket, i.storage_key
    FROM inspections i
   WHERE i.stored_at IS NOT NULL AND i.purged_at IS NULL
     AND i.stored_at < now() - make_interval(days => p_days)
   ORDER BY i.stored_at
   LIMIT p_limit;
$$;

CREATE FUNCTION inspections_mark_purged(p_ids bigint[])
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE n integer;
BEGIN
  UPDATE inspections SET purged_at = now(), storage_key = NULL WHERE id = ANY(p_ids) AND purged_at IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

GRANT SELECT, INSERT, UPDATE ON inspections TO bot_app;
GRANT EXECUTE ON FUNCTION inspections_due_for_purge(integer, integer), inspections_mark_purged(bigint[]) TO bot_app;
GRANT SELECT ON inspections TO bot_readonly;

INSERT INTO schema_migrations (version, description) VALUES ('0006', 'inspections (revistoria photo/video in storage), purge helpers, ticket_events type inspection');
COMMIT;

-- UNDO (manual): DROP FUNCTION inspections_mark_purged(bigint[]); DROP FUNCTION inspections_due_for_purge(integer, integer);
--   DROP TABLE inspections; DROP FUNCTION inspections_log_event();
--   (restore the ticket_events_type_check without 'inspection', only if no 'inspection' event exists)
--   DELETE FROM schema_migrations WHERE version = '0006';
