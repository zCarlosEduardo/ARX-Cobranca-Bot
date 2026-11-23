-- =====================================================================
-- 0008_direct_chats_and_context.sql   (PROPOSAL - not applied, waiting for Carlos Eduardo's ok)
--
-- 1) 1:1 chats. A "chat" keeps living in wa_groups (so every FK, close_batches and the indexes stay as they are),
--    now with kind = 'group' | 'direct'. A direct row is an AUTHORISED NUMBER (allow-list): a number that is not
--    registered is ignored, exactly like an unregistered group.
-- 2) Summarised context for the AI (cheaper in tokens): conversation_summaries + get_context() + helpers for flow 14.
-- 3) Retention: summaries expire after 30 days and are deleted when a participant is anonymised.
--
-- Nothing here changes existing rows. Undo: see the bottom of the file.
-- =====================================================================
BEGIN;

-- ---------------------------------------------------------------------
-- 1) Direct chats
-- ---------------------------------------------------------------------
ALTER TABLE wa_groups ADD COLUMN kind text NOT NULL DEFAULT 'group' CHECK (kind IN ('group', 'direct'));
-- direct chat: group_jid = canonical phone JID (5511...@s.whatsapp.net); alt_jid = the same person as @lid, when known.
ALTER TABLE wa_groups ADD COLUMN alt_jid text;
ALTER TABLE wa_groups DROP CONSTRAINT wa_groups_group_jid_check;
ALTER TABLE wa_groups ADD CONSTRAINT wa_groups_jid_kind_check CHECK (
     (kind = 'group'  AND group_jid LIKE '%@g.us' AND alt_jid IS NULL)
  OR (kind = 'direct' AND group_jid ~ '^[0-9]{10,15}@s\.whatsapp\.net$'
                      AND (alt_jid IS NULL OR alt_jid ~ '^[0-9]+@lid$')
                      AND roles = ARRAY['support']));
CREATE UNIQUE INDEX ux_wa_groups_alt_jid ON wa_groups (company_id, alt_jid) WHERE alt_jid IS NOT NULL;
COMMENT ON COLUMN wa_groups.kind IS 'group = WhatsApp group; direct = authorised 1:1 number (allow-list)';

-- ingest_message: same behaviour for groups; for 1:1 only authorised numbers are stored.
-- Payload contract for 1:1: group_id = remoteJid of the chat; contact_id = the OTHER person (also for from_me);
-- contact_alt = remoteJidAlt when Evolution sends one.
CREATE OR REPLACE FUNCTION public.ingest_message(p jsonb)
 RETURNS TABLE(status text, message_id bigint, company_id bigint, group_id bigint, participant_id bigint, author_type text, mode text, roles text[])
 LANGUAGE plpgsql
AS $function$
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
  v_cands   text[] := '{}';
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

  IF v_gjid LIKE '%@g.us' THEN
    SELECT g.id, g.roles, g.mode INTO v_grp, v_roles, v_mode
      FROM wa_groups g WHERE g.company_id = v_co AND g.kind = 'group' AND g.group_jid = v_gjid AND g.active;
  ELSE
    -- 1:1 chat: only authorised numbers (kind = 'direct'). The chat can arrive as phone JID or as @lid;
    -- remoteJid (group_id in the payload) and remoteJidAlt (contact_alt) are both tried.
    FOREACH v_id IN ARRAY ARRAY[v_gjid, nullif(btrim(p->>'contact_alt'), '')] LOOP
      CONTINUE WHEN v_id IS NULL;
      v_cands := v_cands || CASE WHEN v_id ~ '^[0-9]+$' THEN v_id || '@s.whatsapp.net' ELSE v_id END;
    END LOOP;
    SELECT g.id, g.roles, g.mode INTO v_grp, v_roles, v_mode
      FROM wa_groups g
     WHERE g.company_id = v_co AND g.kind = 'direct' AND g.active
       AND (g.group_jid = ANY (v_cands) OR g.alt_jid = ANY (v_cands))
     ORDER BY g.id LIMIT 1;
  END IF;
  IF v_grp IS NULL THEN   -- unregistered group or number: nothing is stored
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
END $function$;

-- ---------------------------------------------------------------------
-- 2) Summarised context
-- ---------------------------------------------------------------------
-- Masks CPF, CNPJ and phone numbers. Plates are NOT masked (the AI needs them to find the vehicle).
-- Names cannot be masked in SQL: people are therefore referred to by a stable label ('P<participant_id>'),
-- never by name (see ctx_who). The summariser (flow 14) must keep using these labels and must not invent names.
CREATE FUNCTION mask_pii(t text) RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT regexp_replace(
           regexp_replace(
             regexp_replace(t, '(?<![0-9])[0-9]{2}\.?[0-9]{3}\.?[0-9]{3}/?[0-9]{4}-?[0-9]{2}(?![0-9])', '[CNPJ]', 'g'),
             '(?<![0-9])[0-9]{3}\.?[0-9]{3}\.?[0-9]{3}-?[0-9]{2}(?![0-9])', '[CPF]', 'g'),
           '(?<![0-9])(\+?55[ -]?)?\(?[0-9]{2}\)?[ -]?9?[0-9]{4}[ -]?[0-9]{4}(?![0-9])', '[TEL]', 'g')
$$;

-- "oi", "ok", "obrigado"... carry no meaning for the classifier and are dropped from the context window.
CREATE FUNCTION ctx_is_trivial(p_type text, p_text text) RETURNS boolean LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT p_type IN ('text', 'reaction', 'sticker')
     AND (p_type <> 'text'
          OR char_length(btrim(coalesce(p_text, ''))) <= 2
          OR lower(btrim(coalesce(p_text, ''), E' \n\t.!?,')) IN
             ('oi', 'ola', 'olá', 'ok', 'blz', 'beleza', 'bom dia', 'boa tarde', 'boa noite',
              'obrigado', 'obrigada', 'valeu', 'show', 'certo', 'entendi', 'tmj'))
$$;

-- Stable, anonymous label of who wrote a message: 'P12' for a person, 'bot' for the robot.
-- The group summary and the group context use it to say "P12 asked X, bot answered Y, P7 then asked for the slip".
CREATE FUNCTION ctx_who(p_participant bigint, p_author text) RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE WHEN p_author IN ('bot', 'bot_device') OR p_participant IS NULL THEN 'bot' ELSE 'P' || p_participant END
$$;

CREATE TABLE conversation_summaries (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id      bigint NOT NULL REFERENCES companies (id) ON DELETE CASCADE,
  scope           text   NOT NULL CHECK (scope IN ('participant', 'group')),
  group_id        bigint NOT NULL,
  participant_id  bigint,
  summary         text   NOT NULL CHECK (char_length(summary) BETWEEN 1 AND 2000),
  last_message_id bigint NOT NULL DEFAULT 0,           -- the summary covers messages up to this id
  messages_covered integer NOT NULL DEFAULT 0,
  version         integer NOT NULL DEFAULT 1,           -- optimistic lock: two runs of flow 14 never overwrite each other
  model           text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  expires_at      timestamptz NOT NULL DEFAULT now() + interval '30 days',   -- personal data: short life, renewed on update
  CHECK ((scope = 'participant') = (participant_id IS NOT NULL)),
  FOREIGN KEY (company_id, group_id)       REFERENCES wa_groups (company_id, id)    ON DELETE CASCADE,
  FOREIGN KEY (company_id, participant_id) REFERENCES participants (company_id, id) ON DELETE CASCADE
);
CREATE UNIQUE INDEX ux_summaries_participant ON conversation_summaries (company_id, group_id, participant_id) WHERE scope = 'participant';
CREATE UNIQUE INDEX ux_summaries_group       ON conversation_summaries (company_id, group_id)                 WHERE scope = 'group';
CREATE INDEX ix_summaries_expires ON conversation_summaries (expires_at);
CREATE TRIGGER trg_conversation_summaries_updated BEFORE UPDATE ON conversation_summaries
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
GRANT SELECT, INSERT, UPDATE, DELETE ON conversation_summaries TO bot_app;
GRANT SELECT ON conversation_summaries TO bot_readonly;

-- Flow 14: who needs a new summary?
--   participant: >= p_min_new new member messages since the last summary, OR a ticket closed after the last summary
--   group:       >= p_group_min_new new member messages since the last group summary
CREATE FUNCTION summaries_due(p_min_new int DEFAULT 10, p_group_min_new int DEFAULT 60, p_limit int DEFAULT 20)
RETURNS TABLE (scope text, company_id bigint, group_id bigint, participant_id bigint,
               last_message_id bigint, version int, new_messages bigint, reason text)
LANGUAGE sql STABLE AS $$
  SELECT * FROM (
    SELECT DISTINCT ON (d.scope, d.company_id, d.group_id, d.participant_id) d.*
      FROM (
        SELECT 'participant'::text AS scope, m.company_id, m.group_id, m.participant_id,
               coalesce(s.last_message_id, 0) AS last_message_id, coalesce(s.version, 0) AS version,
               count(*) AS new_messages, 'messages'::text AS reason
          FROM messages m
          JOIN wa_groups g ON g.company_id = m.company_id AND g.id = m.group_id AND 'support' = ANY (g.roles) AND g.active
          LEFT JOIN conversation_summaries s ON s.company_id = m.company_id AND s.scope = 'participant'
                                            AND s.group_id = m.group_id AND s.participant_id = m.participant_id
         WHERE m.author_type = 'member' AND m.participant_id IS NOT NULL
           AND m.message_timestamp > now() - interval '14 days'
           AND m.id > coalesce(s.last_message_id, 0)
         GROUP BY m.company_id, m.group_id, m.participant_id, s.last_message_id, s.version
        HAVING count(*) >= p_min_new
        UNION ALL
        SELECT 'participant', t.company_id, t.group_id, t.participant_id,
               coalesce(s.last_message_id, 0), coalesce(s.version, 0), 0, 'ticket_closed'
          FROM tickets t
          LEFT JOIN conversation_summaries s ON s.company_id = t.company_id AND s.scope = 'participant'
                                            AND s.group_id = t.group_id AND s.participant_id = t.participant_id
         WHERE t.closed_at > now() - interval '14 days' AND t.participant_id IS NOT NULL
           AND (s.updated_at IS NULL OR s.updated_at < t.closed_at)
        UNION ALL
        SELECT 'group', m.company_id, m.group_id, NULL::bigint,
               coalesce(s.last_message_id, 0), coalesce(s.version, 0), count(*), 'messages'
          FROM messages m
          JOIN wa_groups g ON g.company_id = m.company_id AND g.id = m.group_id AND 'support' = ANY (g.roles)
                          AND g.active AND g.kind = 'group'
          LEFT JOIN conversation_summaries s ON s.company_id = m.company_id AND s.scope = 'group' AND s.group_id = m.group_id
         WHERE m.author_type = 'member' AND m.message_timestamp > now() - interval '14 days'
           AND m.id > coalesce(s.last_message_id, 0)
         GROUP BY m.company_id, m.group_id, s.last_message_id, s.version
        HAVING count(*) >= p_group_min_new
      ) d
     ORDER BY d.scope, d.company_id, d.group_id, d.participant_id, d.new_messages DESC
  ) x
  ORDER BY x.new_messages DESC LIMIT p_limit
$$;

-- Flow 14: the input of the summariser, already masked and truncated (the model never sees raw PII or a huge text).
CREATE FUNCTION summary_input(p_company bigint, p_scope text, p_group bigint, p_participant bigint DEFAULT NULL,
                              p_limit int DEFAULT 40, p_max_chars int DEFAULT 300)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE s conversation_summaries%ROWTYPE;
BEGIN
  SELECT * INTO s FROM conversation_summaries x
   WHERE x.company_id = p_company AND x.scope = p_scope AND x.group_id = p_group
     AND x.participant_id IS NOT DISTINCT FROM (CASE WHEN p_scope = 'participant' THEN p_participant END);
  RETURN jsonb_build_object(
    'current_summary', s.summary,
    'version', coalesce(s.version, 0),
    'messages', (
      SELECT coalesce(jsonb_agg(q.j ORDER BY q.id), '[]'::jsonb) FROM (
        SELECT m.id, jsonb_strip_nulls(jsonb_build_object('id', m.id, 'ts', m.message_timestamp, 'type', m.type,
                 'who', ctx_who(m.participant_id, m.author_type),
                 'role', CASE WHEN m.author_type = 'attendant' THEN 'attendant' END,
                 'reply_to', (SELECT ctx_who(q2.participant_id, q2.author_type) || '#' || q2.id
                                FROM messages q2 WHERE q2.company_id = m.company_id AND q2.wa_message_id = m.quoted_wa_id LIMIT 1),
                 'text', left(mask_pii(CASE WHEN m.type = 'text' THEN m.text ELSE '[' || m.type || '] ' || coalesce(m.caption, '') END), p_max_chars))) AS j
          FROM messages m
         WHERE m.company_id = p_company AND m.group_id = p_group
           AND (p_scope = 'group' OR (m.author_type = 'member' AND m.participant_id = p_participant))
           AND m.id > coalesce(s.last_message_id, 0)
           AND NOT ctx_is_trivial(m.type, coalesce(m.text, m.caption))
         ORDER BY m.id LIMIT p_limit) q),
    'last_message_id', (SELECT max(m.id) FROM (
        SELECT m2.id FROM messages m2
         WHERE m2.company_id = p_company AND m2.group_id = p_group
           AND (p_scope = 'group' OR (m2.author_type = 'member' AND m2.participant_id = p_participant))
           AND m2.id > coalesce(s.last_message_id, 0)
           AND NOT ctx_is_trivial(m2.type, coalesce(m2.text, m2.caption))
         ORDER BY m2.id LIMIT p_limit) m),
    'tickets', (
      SELECT coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object('short_code', t.short_code, 'who', ctx_who(t.participant_id, 'member'),
               'intent', t.intent, 'state', t.state, 'result', t.result, 'human_reason', t.human_reason,
               'identifier_type', t.identifier_type, 'identifier_last', t.identifier_last,
               'origin_short_code', (SELECT o.short_code FROM tickets o WHERE o.company_id = t.company_id AND o.id = t.origin_ticket_id),
               'closed_at', t.closed_at)) ORDER BY t.id), '[]'::jsonb)
        FROM (SELECT * FROM tickets t0
               WHERE t0.company_id = p_company AND t0.group_id = p_group
                 AND (p_scope = 'group' OR t0.participant_id = p_participant)
                 AND (s.updated_at IS NULL OR t0.updated_at > s.updated_at)
               ORDER BY t0.id DESC LIMIT CASE WHEN p_scope = 'group' THEN 15 ELSE 10 END) t)
    );
END $$;

-- Flow 14: saves the summary. Returns the new version, or NULL when someone else saved first (just skip: no error).
CREATE FUNCTION save_summary(p_company bigint, p_scope text, p_group bigint, p_participant bigint,
                             p_summary text, p_last_message_id bigint, p_expected_version int DEFAULT 0,
                             p_model text DEFAULT NULL, p_covered int DEFAULT 0)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE s conversation_summaries%ROWTYPE;
BEGIN
  IF p_scope = 'group' THEN p_participant := NULL; END IF;
  SELECT * INTO s FROM conversation_summaries x
   WHERE x.company_id = p_company AND x.scope = p_scope AND x.group_id = p_group
     AND x.participant_id IS NOT DISTINCT FROM p_participant FOR UPDATE;
  IF NOT FOUND THEN
    IF coalesce(p_expected_version, 0) <> 0 THEN RETURN NULL; END IF;
    INSERT INTO conversation_summaries (company_id, scope, group_id, participant_id, summary, last_message_id, messages_covered, model)
    VALUES (p_company, p_scope, p_group, p_participant, p_summary, p_last_message_id, p_covered, p_model);
    RETURN 1;
  END IF;
  IF s.version <> coalesce(p_expected_version, s.version) OR p_last_message_id < s.last_message_id THEN RETURN NULL; END IF;
  UPDATE conversation_summaries
     SET summary = p_summary, last_message_id = p_last_message_id, messages_covered = messages_covered + p_covered,
         version = version + 1, model = coalesce(p_model, model), expires_at = now() + interval '30 days'
   WHERE id = s.id;
  RETURN s.version + 1;
EXCEPTION WHEN unique_violation THEN
  RETURN NULL;   -- two runs inserted at the same instant: the other one wins
END $$;

-- Flow 03: everything the classifier needs, in ONE call, small and masked.
--   current          the batch itself (NOT masked: the CPF/plate the person typed is what the flow must read)
--   recent           earlier messages of the same person in the same chat (masked)
--   *_summary        short summaries made by flow 14 (empty until it runs)
--   open_tickets     awaiting_data and awaiting_inspection of this person, with the last 2 linked messages (masked)
--   group_recent     what OTHER people and the bot said in the same group just before (masked, labelled 'P<id>' / 'bot'),
--                    so "the manager asked for his slip" is read as the continuation of an earlier request
--   group_tickets    recent tickets of OTHER people in the group (any state), with the identifier tail and has_sga_lookup:
--                    the flow can reuse the earlier lookup instead of asking for the CPF again
CREATE FUNCTION get_context(p_batch bigint, p_window int DEFAULT 8, p_recent_minutes int DEFAULT 120,
                            p_recent_limit int DEFAULT 6, p_max_chars int DEFAULT 300,
                            p_group_minutes int DEFAULT 60, p_group_limit int DEFAULT 10, p_ticket_hours int DEFAULT 72)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE b batches%ROWTYPE; v_first timestamptz; v_total int;
BEGIN
  SELECT * INTO b FROM batches WHERE id = p_batch;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT min(message_timestamp), count(*) INTO v_first, v_total FROM messages WHERE company_id = b.company_id AND batch_id = b.id;
  RETURN jsonb_build_object(
    'batch', jsonb_build_object('id', b.id, 'company_id', b.company_id, 'group_id', b.group_id,
              'participant_id', b.participant_id, 'mode', b.mode,
              'chat_kind', (SELECT g.kind FROM wa_groups g WHERE g.company_id = b.company_id AND g.id = b.group_id),
              'messages_total', v_total),
    'participant_summary', (SELECT jsonb_build_object('text', s.summary, 'version', s.version, 'updated_at', s.updated_at)
                              FROM conversation_summaries s
                             WHERE s.company_id = b.company_id AND s.scope = 'participant' AND s.group_id = b.group_id
                               AND s.participant_id = b.participant_id AND s.expires_at > now()),
    'group_summary', (SELECT jsonb_build_object('text', s.summary, 'version', s.version, 'updated_at', s.updated_at)
                        FROM conversation_summaries s
                       WHERE s.company_id = b.company_id AND s.scope = 'group' AND s.group_id = b.group_id AND s.expires_at > now()),
    'current', (SELECT coalesce(jsonb_agg(q.j ORDER BY q.ts), '[]'::jsonb) FROM (
                  SELECT m.message_timestamp AS ts,
                         jsonb_build_object('id', m.id, 'wa_message_id', m.wa_message_id, 'ts', m.message_timestamp, 'type', m.type,
                           'quoted_wa_id', m.quoted_wa_id,
                           'text', left(CASE WHEN m.type = 'text' THEN m.text ELSE '[' || m.type || '] ' || coalesce(m.caption, '') END, p_max_chars)) AS j
                    FROM messages m
                   WHERE m.company_id = b.company_id AND m.batch_id = b.id
                     AND NOT ctx_is_trivial(m.type, coalesce(m.text, m.caption))
                   ORDER BY m.message_timestamp DESC, m.id DESC LIMIT p_window) q),
    'recent', (SELECT coalesce(jsonb_agg(q.j ORDER BY q.ts), '[]'::jsonb) FROM (
                  SELECT m.message_timestamp AS ts,
                         jsonb_build_object('id', m.id, 'ts', m.message_timestamp, 'type', m.type,
                           'text', left(mask_pii(CASE WHEN m.type = 'text' THEN m.text ELSE '[' || m.type || '] ' || coalesce(m.caption, '') END), p_max_chars)) AS j
                    FROM messages m
                   WHERE m.company_id = b.company_id AND m.participant_id = b.participant_id AND m.group_id = b.group_id
                     AND m.batch_id IS DISTINCT FROM b.id
                     AND m.message_timestamp < v_first AND m.message_timestamp >= v_first - make_interval(mins => p_recent_minutes)
                     AND NOT ctx_is_trivial(m.type, coalesce(m.text, m.caption))
                   ORDER BY m.message_timestamp DESC LIMIT p_recent_limit) q),
    'group_recent', (SELECT coalesce(jsonb_agg(q.j ORDER BY q.ts), '[]'::jsonb) FROM (
                  SELECT m.message_timestamp AS ts,
                         jsonb_strip_nulls(jsonb_build_object('id', m.id, 'ts', m.message_timestamp, 'type', m.type,
                           'who', ctx_who(m.participant_id, m.author_type),
                           'role', CASE WHEN m.author_type = 'attendant' THEN 'attendant' END,
                           'reply_to', (SELECT ctx_who(q2.participant_id, q2.author_type) || '#' || q2.id
                                          FROM messages q2 WHERE q2.company_id = m.company_id AND q2.wa_message_id = m.quoted_wa_id LIMIT 1),
                           'text', left(mask_pii(CASE WHEN m.type = 'text' THEN m.text ELSE '[' || m.type || '] ' || coalesce(m.caption, '') END), p_max_chars))) AS j
                    FROM messages m
                   WHERE m.company_id = b.company_id AND m.group_id = b.group_id
                     AND m.batch_id IS DISTINCT FROM b.id
                     AND m.participant_id IS DISTINCT FROM b.participant_id
                     AND m.message_timestamp < v_first AND m.message_timestamp >= v_first - make_interval(mins => p_group_minutes)
                     AND NOT ctx_is_trivial(m.type, coalesce(m.text, m.caption))
                   ORDER BY m.message_timestamp DESC LIMIT p_group_limit) q),
    'group_tickets', (SELECT coalesce(jsonb_agg(q.j ORDER BY q.id DESC), '[]'::jsonb) FROM (
                  SELECT t.id, jsonb_strip_nulls(jsonb_build_object('short_code', t.short_code, 'who', ctx_who(t.participant_id, 'member'),
                           'intent', t.intent, 'state', t.state, 'result', t.result,
                           'identifier_type', t.identifier_type, 'identifier_last', t.identifier_last,
                           'has_sga_lookup', t.sga_lookup IS NOT NULL, 'created_at', t.created_at)) AS j
                    FROM tickets t
                   WHERE t.company_id = b.company_id AND t.group_id = b.group_id
                     AND t.participant_id IS DISTINCT FROM b.participant_id
                     AND t.created_at >= v_first - make_interval(hours => p_ticket_hours)
                     AND t.batch_id <> b.id
                   ORDER BY t.id DESC LIMIT 8) q),
    'open_tickets', (SELECT coalesce(jsonb_agg(q.j ORDER BY q.id DESC), '[]'::jsonb) FROM (
                  SELECT t.id, jsonb_build_object('id', t.id, 'short_code', t.short_code, 'intent', t.intent, 'state', t.state,
                           'identifier_type', t.identifier_type, 'identifier_last', t.identifier_last, 'missing', t.missing,
                           'created_at', t.created_at,
                           'last_messages', (SELECT coalesce(jsonb_agg(left(mask_pii(coalesce(mm.text, mm.caption, '[' || mm.type || ']')), 200) ORDER BY mm.id), '[]'::jsonb)
                                               FROM (SELECT m2.* FROM ticket_messages tm JOIN messages m2 ON m2.company_id = tm.company_id AND m2.id = tm.message_id
                                                      WHERE tm.company_id = t.company_id AND tm.ticket_id = t.id
                                                      ORDER BY m2.id DESC LIMIT 2) mm)) AS j
                    FROM tickets t
                   WHERE t.company_id = b.company_id AND t.participant_id = b.participant_id AND t.group_id = b.group_id
                     AND t.state IN ('awaiting_data', 'awaiting_inspection') AND t.batch_id <> b.id
                   ORDER BY t.id DESC LIMIT 5) q));
END $$;

-- ---------------------------------------------------------------------
-- 3) Retention
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION purge_old_data(p_payload_days integer DEFAULT 30, p_lookup_days integer DEFAULT 90, p_limit integer DEFAULT 10000)
 RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE a integer; b integer; c integer;
BEGIN
  DELETE FROM message_payloads WHERE message_id IN
    (SELECT message_id FROM message_payloads WHERE created_at < now() - make_interval(days => p_payload_days) LIMIT p_limit);
  GET DIAGNOSTICS a = ROW_COUNT;
  UPDATE tickets SET sga_lookup = NULL WHERE id IN
    (SELECT id FROM tickets WHERE sga_lookup IS NOT NULL AND closed_at < now() - make_interval(days => p_lookup_days) LIMIT p_limit);
  GET DIAGNOSTICS b = ROW_COUNT;
  DELETE FROM conversation_summaries WHERE id IN
    (SELECT id FROM conversation_summaries WHERE expires_at < now() LIMIT p_limit);
  GET DIAGNOSTICS c = ROW_COUNT;
  RETURN jsonb_build_object('payloads_deleted', a, 'lookups_cleared', b, 'summaries_deleted', c);
END $$;

CREATE OR REPLACE FUNCTION anonymize_participant(p_participant bigint) RETURNS void LANGUAGE sql AS $$
  DELETE FROM conversation_summaries WHERE participant_id = p_participant;
  UPDATE participants SET display_name = NULL, lid = CASE WHEN lid IS NULL THEN NULL ELSE 'anon' || id || '@lid' END,
         jid = CASE WHEN jid IS NULL THEN NULL ELSE 'anon' || id || '@anon' END, anonymized_at = now()
   WHERE id = p_participant;
$$;

-- new functions: not public, only the bot role (same as the existing ones, minus PUBLIC)
REVOKE ALL ON FUNCTION mask_pii(text), ctx_is_trivial(text, text), ctx_who(bigint, text), summaries_due(int, int, int),
  summary_input(bigint, text, bigint, bigint, int, int),
  save_summary(bigint, text, bigint, bigint, text, bigint, int, text, int),
  get_context(bigint, int, int, int, int, int, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION mask_pii(text), ctx_is_trivial(text, text), ctx_who(bigint, text), summaries_due(int, int, int),
  summary_input(bigint, text, bigint, bigint, int, int),
  save_summary(bigint, text, bigint, bigint, text, bigint, int, text, int),
  get_context(bigint, int, int, int, int, int, int, int) TO bot_app;

INSERT INTO schema_migrations (version, description)
VALUES ('0008', 'wa_groups.kind (1:1 allow-list), conversation_summaries, get_context, summaries_due, save_summary, mask_pii');
COMMIT;

-- =====================================================================
-- UNDO (manual, in this order). Before it: DELETE FROM wa_groups WHERE kind = 'direct'.
--   DROP FUNCTION get_context(bigint,int,int,int,int,int,int,int), save_summary(bigint,text,bigint,bigint,text,bigint,int,text,int),
--     summary_input(bigint,text,bigint,bigint,int,int), summaries_due(int,int,int), ctx_is_trivial(text,text), ctx_who(bigint,text), mask_pii(text);
--   DROP TABLE conversation_summaries;
--   -- restore purge_old_data / anonymize_participant / ingest_message from 0002 and 0004+ (previous definitions)
--   ALTER TABLE wa_groups DROP CONSTRAINT wa_groups_jid_kind_check;
--   ALTER TABLE wa_groups ADD CONSTRAINT wa_groups_group_jid_check CHECK (group_jid LIKE '%@g.us');
--   DROP INDEX ux_wa_groups_alt_jid; ALTER TABLE wa_groups DROP COLUMN alt_jid; ALTER TABLE wa_groups DROP COLUMN kind;
--   DELETE FROM schema_migrations WHERE version = '0008';
-- =====================================================================
--
-- Example, AFTER approval (needs the real numbers; not part of the migration):
--   INSERT INTO wa_groups (company_id, group_jid, alt_jid, name, roles, kind, mode)
--   VALUES (1, '5511999990000@s.whatsapp.net', NULL, 'Consultor X (1:1)', ARRAY['support'], 'direct', 'shadow');
