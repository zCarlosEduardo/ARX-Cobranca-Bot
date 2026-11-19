-- =====================================================================
-- 0002_functions.sql - Ingestion, queue and retention functions (n8n calls these, it does not build loose SQL)
-- All idempotent and safe for several workers in parallel (SKIP LOCKED / advisory lock).
-- =====================================================================
BEGIN;

-- ---------------------------------------------------------------------
-- ingest_message(payload jsonb): the ONLY entry door for a message.
-- Contract (names of the agreed payload):
--   tenant_id, group_id, contact_id, sender_name, message_id, text, timestamp
--   required: tenant_id, group_id, message_id, timestamp
-- Optional: contact_alt (the other form of the same contact, e.g. the phone when contact_id is @lid), from_me,
--   type, caption, quoted_message_id, mentions, raw (original Evolution payload).
-- timestamp accepts ISO-8601 or epoch (seconds or milliseconds).
-- Returns 1 row:
--   status = new | duplicate | ignored_company | ignored_group | invalid
-- ---------------------------------------------------------------------
CREATE FUNCTION ingest_message(p jsonb)
RETURNS TABLE (status text, message_id bigint, company_id bigint, group_id bigint,
               participant_id bigint, author_type text, mode text, roles text[])
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
  v_tenant  text := nullif(btrim(p->>'tenant_id'), '');
  v_wa      text := nullif(btrim(p->>'message_id'), '');
  v_gjid    text := nullif(btrim(p->>'group_id'), '');
  v_co      bigint;
  v_grp     bigint;
  v_roles   text[];
  v_mode    text;
  v_lid     text;
  v_jid     text;
  v_part    bigint;
  v_from_me boolean := coalesce((p->>'from_me')::boolean, false);
  v_author  text;
  v_type    text := coalesce(nullif(p->>'type', ''), 'text');
  v_ts      timestamptz;
  v_msg     bigint;
  v_id      text;
  v_name    text := nullif(btrim(p->>'sender_name'), '');
BEGIN
  IF v_tenant IS NULL OR v_wa IS NULL OR v_gjid IS NULL OR p->>'timestamp' IS NULL THEN
    RETURN QUERY SELECT 'invalid'::text, NULL::bigint, NULL::bigint, NULL::bigint, NULL::bigint, NULL::text, NULL::text, NULL::text[];
    RETURN;
  END IF;
  BEGIN
    v_ts := CASE WHEN p->>'timestamp' ~ '^[0-9]{9,13}$'
                 THEN to_timestamp((CASE WHEN length(p->>'timestamp') > 11 THEN (p->>'timestamp')::numeric / 1000 ELSE (p->>'timestamp')::numeric END))
                 ELSE (p->>'timestamp')::timestamptz END;
  EXCEPTION WHEN others THEN
    RETURN QUERY SELECT 'invalid'::text, NULL::bigint, NULL::bigint, NULL::bigint, NULL::bigint, NULL::text, NULL::text, NULL::text[];
    RETURN;
  END;

  SELECT c.id INTO v_co FROM companies c WHERE c.slug = v_tenant AND c.active;
  IF v_co IS NULL THEN
    RETURN QUERY SELECT 'ignored_company'::text, NULL::bigint, NULL::bigint, NULL::bigint, NULL::bigint, NULL::text, NULL::text, NULL::text[];
    RETURN;
  END IF;

  SELECT g.id, g.roles, g.mode INTO v_grp, v_roles, v_mode
    FROM wa_groups g WHERE g.company_id = v_co AND g.group_jid = v_gjid AND g.active;
  IF v_grp IS NULL THEN   -- unregistered group: nothing is stored
    RETURN QUERY SELECT 'ignored_group'::text, NULL::bigint, v_co, NULL::bigint, NULL::bigint, NULL::text, NULL::text, NULL::text[];
    RETURN;
  END IF;

  SELECT m.id, m.participant_id, m.author_type INTO v_msg, v_part, v_author
    FROM messages m WHERE m.company_id = v_co AND m.wa_message_id = v_wa;
  IF v_msg IS NOT NULL THEN
    RETURN QUERY SELECT 'duplicate'::text, v_msg, v_co, v_grp, v_part, v_author, v_mode, v_roles;
    RETURN;
  END IF;

  -- contact identifier: @lid or phone number (contact_alt carries the other form)
  FOREACH v_id IN ARRAY ARRAY[nullif(btrim(p->>'contact_id'), ''), nullif(btrim(p->>'contact_alt'), '')] LOOP
    CONTINUE WHEN v_id IS NULL;
    IF v_id LIKE '%@lid' THEN v_lid := coalesce(v_lid, v_id);
    ELSIF v_id ~ '^[0-9]+$' THEN v_jid := coalesce(v_jid, v_id || '@s.whatsapp.net');
    ELSE v_jid := coalesce(v_jid, v_id);
    END IF;
  END LOOP;

  IF v_lid IS NOT NULL OR v_jid IS NOT NULL THEN
    SELECT pa.id INTO v_part FROM participants pa
     WHERE pa.company_id = v_co AND ((v_lid IS NOT NULL AND pa.lid = v_lid) OR (v_jid IS NOT NULL AND pa.jid = v_jid))
     ORDER BY (pa.lid = v_lid) DESC NULLS LAST LIMIT 1;
    IF v_part IS NULL THEN
      INSERT INTO participants (company_id, lid, jid, display_name)
      VALUES (v_co, v_lid, v_jid, CASE WHEN v_from_me THEN NULL ELSE v_name END)
      ON CONFLICT DO NOTHING RETURNING id INTO v_part;
      IF v_part IS NULL THEN   -- another worker created it at the same instant
        SELECT pa.id INTO v_part FROM participants pa
         WHERE pa.company_id = v_co AND ((v_lid IS NOT NULL AND pa.lid = v_lid) OR (v_jid IS NOT NULL AND pa.jid = v_jid)) LIMIT 1;
      END IF;
    ELSE
      BEGIN
        UPDATE participants pa SET lid = coalesce(pa.lid, v_lid), jid = coalesce(pa.jid, v_jid),
               display_name = CASE WHEN v_from_me THEN pa.display_name ELSE coalesce(v_name, pa.display_name) END,
               last_seen_at = now()
         WHERE pa.id = v_part AND pa.anonymized_at IS NULL;
      EXCEPTION WHEN unique_violation THEN   -- the other form already belongs to another row: only touch last_seen_at
        UPDATE participants pa SET last_seen_at = now() WHERE pa.id = v_part;
      END;
    END IF;
  END IF;

  IF v_from_me THEN
    v_author := CASE WHEN EXISTS (SELECT 1 FROM outbox o WHERE o.company_id = v_co AND o.wa_message_id = v_wa)
                     THEN 'bot' ELSE 'bot_device' END;
  ELSIF EXISTS (SELECT 1 FROM attendants a WHERE a.company_id = v_co AND a.participant_id = v_part AND a.active) THEN
    v_author := 'attendant';
  ELSE
    v_author := 'member';
  END IF;

  IF v_type NOT IN ('text','image','audio','video','document','sticker','reaction','location','contact','other') THEN v_type := 'other'; END IF;
  IF v_author = 'member' AND v_part IS NULL THEN   -- without contact_id the author cannot be tied
    RETURN QUERY SELECT 'invalid'::text, NULL::bigint, v_co, v_grp, NULL::bigint, NULL::text, v_mode, v_roles;
    RETURN;
  END IF;

  INSERT INTO messages (company_id, group_id, participant_id, wa_message_id, from_me, author_type, type,
                        text, caption, quoted_wa_id, mentions, message_timestamp)
  VALUES (v_co, v_grp, v_part, v_wa, v_from_me, v_author, v_type,
          p->>'text', p->>'caption', nullif(p->>'quoted_message_id', ''),
          CASE WHEN jsonb_typeof(p->'mentions') = 'array' THEN p->'mentions' ELSE '[]'::jsonb END, v_ts)
  ON CONFLICT ON CONSTRAINT messages_wa_uq DO NOTHING
  RETURNING id INTO v_msg;

  IF v_msg IS NULL THEN   -- race between two identical webhooks
    SELECT m.id, m.author_type INTO v_msg, v_author FROM messages m WHERE m.company_id = v_co AND m.wa_message_id = v_wa;
    RETURN QUERY SELECT 'duplicate'::text, v_msg, v_co, v_grp, v_part, v_author, v_mode, v_roles;
    RETURN;
  END IF;

  IF p ? 'raw' AND jsonb_typeof(p->'raw') = 'object' THEN
    INSERT INTO message_payloads (message_id, company_id, payload) VALUES (v_msg, v_co, p->'raw');
  END IF;

  RETURN QUERY SELECT 'new'::text, v_msg, v_co, v_grp, v_part, v_author, v_mode, v_roles;
END $$;

-- ---------------------------------------------------------------------
-- close_batches(window, limit): merges members' messages without a batch, same author in the same group,
-- once the author has been silent for `window`. Only groups that have the role 'support'. Returns the created ids.
-- Short global lock: two simultaneous runs never duplicate a batch.
-- ---------------------------------------------------------------------
CREATE FUNCTION close_batches(p_window interval DEFAULT '15 seconds', p_limit integer DEFAULT 200)
RETURNS SETOF bigint LANGUAGE plpgsql AS $$
DECLARE r record; v_batch bigint;
BEGIN
  IF NOT pg_try_advisory_xact_lock(hashtext('close_batches')) THEN RETURN; END IF;
  FOR r IN
    SELECT m.company_id, m.group_id, m.participant_id, max(m.created_at) AS last_at, g.mode
      FROM messages m
      JOIN wa_groups g ON g.company_id = m.company_id AND g.id = m.group_id AND 'support' = ANY(g.roles) AND g.active
     WHERE m.batch_id IS NULL AND m.author_type = 'member'
     GROUP BY m.company_id, m.group_id, m.participant_id, g.mode
    HAVING max(m.created_at) <= now() - p_window
     ORDER BY min(m.id) LIMIT p_limit
  LOOP
    INSERT INTO batches (company_id, group_id, participant_id, mode) VALUES (r.company_id, r.group_id, r.participant_id, r.mode)
    RETURNING id INTO v_batch;
    UPDATE messages m SET batch_id = v_batch
     WHERE m.company_id = r.company_id AND m.group_id = r.group_id AND m.participant_id = r.participant_id
       AND m.batch_id IS NULL AND m.author_type = 'member' AND m.created_at <= r.last_at;
    RETURN NEXT v_batch;
  END LOOP;
END $$;

-- Reserves pending batches for ONE worker (several workers in parallel never take the same one)
CREATE FUNCTION reserve_batches(p_qty integer DEFAULT 10)
RETURNS SETOF batches LANGUAGE sql AS $$
  UPDATE batches b SET state = 'processing', reserved_at = now(), attempts = b.attempts + 1
   WHERE b.id IN (SELECT x.id FROM batches x WHERE x.state = 'pending' ORDER BY x.id LIMIT p_qty FOR UPDATE SKIP LOCKED)
  RETURNING b.*;
$$;

CREATE FUNCTION complete_batch(p_batch bigint, p_decision jsonb DEFAULT NULL)
RETURNS void LANGUAGE sql AS $$
  UPDATE batches SET state = 'done', decision = p_decision, completed_at = now(), error = NULL WHERE id = p_batch;
$$;

CREATE FUNCTION fail_batch(p_batch bigint, p_error text, p_max integer DEFAULT 5)
RETURNS void LANGUAGE sql AS $$
  UPDATE batches SET state = CASE WHEN attempts >= p_max THEN 'error' ELSE 'pending' END, error = left(p_error, 2000), reserved_at = NULL
   WHERE id = p_batch;
$$;

-- ---------------------------------------------------------------------
-- Outbox
-- ---------------------------------------------------------------------
-- Enqueues. In 'shadow' mode the row is born 'simulated' (recorded, never sent).
-- Calling again with the same key does not duplicate (returns the existing id).
CREATE FUNCTION enqueue_outbox(p_company bigint, p_destination_jid text, p_type text, p_text text, p_key text,
                               p_mode text, p_group bigint DEFAULT NULL, p_ticket bigint DEFAULT NULL,
                               p_batch bigint DEFAULT NULL, p_quote text DEFAULT NULL,
                               p_send_at timestamptz DEFAULT now())
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE v_id bigint;
BEGIN
  INSERT INTO outbox (company_id, group_id, destination_jid, ticket_id, batch_id, type, text, quote_wa_id, mode, state, key, send_at)
  VALUES (p_company, p_group, p_destination_jid, p_ticket, p_batch, p_type, p_text, p_quote, p_mode,
          CASE WHEN p_mode = 'shadow' THEN 'simulated' ELSE 'pending' END, p_key, p_send_at)
  ON CONFLICT (company_id, key) DO NOTHING RETURNING id INTO v_id;
  IF v_id IS NULL THEN SELECT o.id INTO v_id FROM outbox o WHERE o.company_id = p_company AND o.key = p_key; END IF;
  RETURN v_id;
END $$;

CREATE FUNCTION reserve_outbox(p_qty integer DEFAULT 20)
RETURNS SETOF outbox LANGUAGE sql AS $$
  UPDATE outbox o SET state = 'reserved', reserved_at = now(), attempts = o.attempts + 1
   WHERE o.id IN (SELECT x.id FROM outbox x WHERE x.state = 'pending' AND x.send_at <= now()
                   ORDER BY x.send_at, x.id LIMIT p_qty FOR UPDATE SKIP LOCKED)
  RETURNING o.*;
$$;

-- Marks as sent and also fixes the bot's message if the webhook classified it as 'bot_device' because it arrived first.
CREATE FUNCTION mark_outbox_sent(p_outbox bigint, p_wa_message_id text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_co bigint;
BEGIN
  UPDATE outbox SET state = 'sent', wa_message_id = p_wa_message_id, sent_at = now(), error = NULL
   WHERE id = p_outbox RETURNING company_id INTO v_co;
  UPDATE messages SET author_type = 'bot' WHERE company_id = v_co AND wa_message_id = p_wa_message_id AND author_type = 'bot_device';
END $$;

CREATE FUNCTION fail_outbox(p_outbox bigint, p_error text, p_max integer DEFAULT 5, p_wait interval DEFAULT '30 seconds')
RETURNS void LANGUAGE sql AS $$
  UPDATE outbox SET state = CASE WHEN attempts >= p_max THEN 'failed' ELSE 'pending' END,
         error = left(p_error, 2000), reserved_at = NULL, send_at = now() + p_wait * attempts
   WHERE id = p_outbox;
$$;

-- Puts back in the queue whatever stayed stuck in 'processing'/'reserved' (worker died). Call every minute.
CREATE FUNCTION recover_stuck(p_minutes integer DEFAULT 10, p_max integer DEFAULT 5)
RETURNS TABLE (batches_recovered integer, outbox_recovered integer) LANGUAGE plpgsql AS $$
DECLARE a integer; b integer;
BEGIN
  UPDATE batches SET state = CASE WHEN attempts >= p_max THEN 'error' ELSE 'pending' END, reserved_at = NULL,
         error = coalesce(error, 'stuck in processing')
   WHERE state = 'processing' AND reserved_at < now() - make_interval(mins => p_minutes);
  GET DIAGNOSTICS a = ROW_COUNT;
  UPDATE outbox SET state = CASE WHEN attempts >= p_max THEN 'failed' ELSE 'pending' END, reserved_at = NULL
   WHERE state = 'reserved' AND reserved_at < now() - make_interval(mins => p_minutes);
  GET DIAGNOSTICS b = ROW_COUNT;
  RETURN QUERY SELECT a, b;
END $$;

-- ---------------------------------------------------------------------
-- Retention and LGPD (schedule in n8n, e.g. once a night). Periods are Carlos/legal's decision.
-- ---------------------------------------------------------------------
CREATE FUNCTION purge_old_data(p_payload_days integer DEFAULT 30, p_lookup_days integer DEFAULT 90, p_limit integer DEFAULT 10000)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE a integer; b integer;
BEGIN
  DELETE FROM message_payloads WHERE message_id IN
    (SELECT message_id FROM message_payloads WHERE created_at < now() - make_interval(days => p_payload_days) LIMIT p_limit);
  GET DIAGNOSTICS a = ROW_COUNT;
  UPDATE tickets SET sga_lookup = NULL WHERE id IN
    (SELECT id FROM tickets WHERE sga_lookup IS NOT NULL AND closed_at < now() - make_interval(days => p_lookup_days) LIMIT p_limit);
  GET DIAGNOSTICS b = ROW_COUNT;
  RETURN jsonb_build_object('payloads_deleted', a, 'lookups_cleared', b);
END $$;

CREATE FUNCTION anonymize_participant(p_participant bigint)
RETURNS void LANGUAGE sql AS $$
  UPDATE participants SET display_name = NULL, lid = CASE WHEN lid IS NULL THEN NULL ELSE 'anon' || id || '@lid' END,
         jid = CASE WHEN jid IS NULL THEN NULL ELSE 'anon' || id || '@anon' END, anonymized_at = now()
   WHERE id = p_participant;
$$;

-- ---------------------------------------------------------------------
-- View with the exact names of the agreed payload (for the panel/consumers that expect the contract)
-- ---------------------------------------------------------------------
CREATE VIEW v_message_payload AS
SELECT c.slug                       AS tenant_id,
       g.group_jid                  AS group_id,
       coalesce(p.lid, p.jid)       AS contact_id,
       p.display_name               AS sender_name,
       m.wa_message_id              AS message_id,
       m.text                       AS text,
       m.message_timestamp          AS "timestamp",
       m.author_type, m.type, m.id  AS db_message_id
  FROM messages m
  JOIN companies c ON c.id = m.company_id
  JOIN wa_groups g ON g.company_id = m.company_id AND g.id = m.group_id
  LEFT JOIN participants p ON p.company_id = m.company_id AND p.id = m.participant_id;

INSERT INTO schema_migrations (version, description) VALUES ('0002', 'ingestion, queue, retention functions and payload view');
COMMIT;
