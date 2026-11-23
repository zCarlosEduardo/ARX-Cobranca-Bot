-- =====================================================================
-- 0005_queue_skip_non_support.sql
-- Problem: close_batches() scanned the messages of members of groups WITHOUT the 'support' role
-- (registration, outsourced, alert), which never get a batch, so the queue grew forever.
-- Fix: messages that will never get a batch are born with handled_at set (trigger), the queue index
-- only holds real candidates, and close_batches filters on handled_at IS NULL.
-- Undo: see the bottom of the file.
-- =====================================================================
BEGIN;

CREATE FUNCTION messages_skip_non_support() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.author_type = 'member' AND NEW.handled_at IS NULL AND NOT EXISTS (
       SELECT 1 FROM wa_groups g
        WHERE g.company_id = NEW.company_id AND g.id = NEW.group_id AND 'support' = ANY(g.roles)) THEN
    NEW.handled_at := now();   -- no batch will ever be built for this message
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_messages_skip_non_support BEFORE INSERT ON messages
  FOR EACH ROW EXECUTE FUNCTION messages_skip_non_support();

-- backfill what already exists
UPDATE messages m SET handled_at = now()
 WHERE m.batch_id IS NULL AND m.author_type = 'member' AND m.handled_at IS NULL
   AND NOT EXISTS (SELECT 1 FROM wa_groups g WHERE g.company_id = m.company_id AND g.id = m.group_id AND 'support' = ANY(g.roles));

DROP INDEX ix_messages_queue;
CREATE INDEX ix_messages_queue ON messages (company_id, group_id, participant_id)
  WHERE batch_id IS NULL AND author_type = 'member' AND handled_at IS NULL;

CREATE OR REPLACE FUNCTION close_batches(p_window interval DEFAULT '15 seconds', p_limit integer DEFAULT 200)
RETURNS SETOF bigint LANGUAGE plpgsql AS $$
DECLARE r record; v_batch bigint;
BEGIN
  IF NOT pg_try_advisory_xact_lock(hashtext('close_batches')) THEN RETURN; END IF;
  FOR r IN
    SELECT m.company_id, m.group_id, m.participant_id, max(m.created_at) AS last_at, g.mode
      FROM messages m
      JOIN wa_groups g ON g.company_id = m.company_id AND g.id = m.group_id AND 'support' = ANY(g.roles) AND g.active
     WHERE m.batch_id IS NULL AND m.author_type = 'member' AND m.handled_at IS NULL
     GROUP BY m.company_id, m.group_id, m.participant_id, g.mode
    HAVING max(m.created_at) <= now() - p_window
     ORDER BY min(m.id) LIMIT p_limit
  LOOP
    INSERT INTO batches (company_id, group_id, participant_id, mode) VALUES (r.company_id, r.group_id, r.participant_id, r.mode)
    RETURNING id INTO v_batch;
    UPDATE messages m SET batch_id = v_batch
     WHERE m.company_id = r.company_id AND m.group_id = r.group_id AND m.participant_id = r.participant_id
       AND m.batch_id IS NULL AND m.author_type = 'member' AND m.handled_at IS NULL AND m.created_at <= r.last_at;
    RETURN NEXT v_batch;
  END LOOP;
END $$;

INSERT INTO schema_migrations (version, description) VALUES ('0005', 'messages of non-support groups are born handled; close_batches ignores them');
COMMIT;

-- UNDO (manual): DROP TRIGGER trg_messages_skip_non_support ON messages; DROP FUNCTION messages_skip_non_support();
--   DROP INDEX ix_messages_queue; CREATE INDEX ix_messages_queue ON messages (company_id, group_id, participant_id) WHERE batch_id IS NULL AND author_type='member';
--   and restore close_batches from 0002_functions.sql.
