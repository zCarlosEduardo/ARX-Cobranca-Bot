-- =====================================================================
-- 0001_tables.sql - `cobranca` database v2 (multi-company, horizontally scalable). ALL ENGLISH.
-- Author: Davi, 2026-11-19. Dev database rebuilt from scratch (authorized by Carlos Eduardo).
--
-- Conventions:
--  * English snake_case names; ids `bigint GENERATED ALWAYS AS IDENTITY`; timestamps `timestamptz` named *_at.
--  * EVERY business table has `company_id NOT NULL` (tenant). Links between tables use COMPOSITE FKs
--    (company_id, id): the database prevents a row of company A from pointing to company B.
--  * No native enums: `text` + CHECK (changing a CHECK is cheap; ALTER TYPE is not).
--  * No duplicated message text: batches and tickets point to `messages` by id only.
--  * Input contract (payload): see ingest_message() and the view v_message_payload.
--  * Glossary pt-BR -> English: see GLOSSARY.md
-- =====================================================================
BEGIN;

CREATE TABLE schema_migrations (
  version     text PRIMARY KEY,
  description text NOT NULL,
  applied_at  timestamptz NOT NULL DEFAULT now()
);

CREATE FUNCTION set_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at := now(); RETURN NEW; END $$;

-- ---------------------------------------------------------------------
-- Companies (tenant). `slug` = payload `tenant_id`. One Evolution instance per company.
-- ---------------------------------------------------------------------
CREATE TABLE companies (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  slug        text NOT NULL UNIQUE CHECK (slug ~ '^[a-z0-9][a-z0-9_-]*$'),
  name        text NOT NULL,
  instance    text NOT NULL UNIQUE,                 -- Evolution instance name
  active      boolean NOT NULL DEFAULT true,
  ticket_seq  bigint NOT NULL DEFAULT 0,            -- counter behind tickets.short_code
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_companies_updated BEFORE UPDATE ON companies FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Secret kept apart: the bot_readonly role has no access. The decryption key is NOT stored in the database.
CREATE TABLE company_sga (
  company_id      bigint PRIMARY KEY REFERENCES companies(id) ON DELETE CASCADE,
  token_encrypted bytea NOT NULL,
  key_version     smallint NOT NULL DEFAULT 1,
  updated_at      timestamptz NOT NULL DEFAULT now()
);

-- Per-company settings (replaces the old global config_bot). Value is always jsonb.
CREATE TABLE company_config (
  company_id  bigint NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  key         text NOT NULL,
  value       jsonb NOT NULL,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (company_id, key)
);

-- ---------------------------------------------------------------------
-- WhatsApp groups. This is the AUTHORIZATION: a message from an unregistered group is ignored at ingestion.
-- `roles` says what the group is for (one group may have several roles: e.g. registration + outsourced).
-- Registration, Outsourced and Alert groups are rows here too. A group shared by all companies = one row per company, same JID.
-- ---------------------------------------------------------------------
CREATE TABLE wa_groups (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id  bigint NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  group_jid   text NOT NULL CHECK (group_jid LIKE '%@g.us'),
  name        text,
  roles       text[] NOT NULL DEFAULT ARRAY['support'] CHECK (cardinality(roles) > 0 AND roles <@ ARRAY['support','registration','outsourced','alert']),
  mode        text NOT NULL DEFAULT 'shadow'  CHECK (mode IN ('shadow','active')),
  active      boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (company_id, group_jid),
  UNIQUE (company_id, id)
);
CREATE INDEX ix_wa_groups_roles ON wa_groups USING gin (roles) WHERE active;
CREATE TRIGGER trg_wa_groups_updated BEFORE UPDATE ON wa_groups FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------
-- Participants: who talks (payload contact_id / sender_name). History only, NEVER permission.
-- Keeps both forms of the identifier (@lid and phone JID). Name is personal data: anonymize_participant().
-- ---------------------------------------------------------------------
CREATE TABLE participants (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id    bigint NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  lid           text CHECK (lid LIKE '%@lid'),
  jid           text,
  display_name  text,
  first_seen_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at  timestamptz NOT NULL DEFAULT now(),
  anonymized_at timestamptz,
  CHECK (lid IS NOT NULL OR jid IS NOT NULL),
  UNIQUE (company_id, id)
);
CREATE UNIQUE INDEX uq_participants_lid ON participants (company_id, lid) WHERE lid IS NOT NULL;
CREATE UNIQUE INDEX uq_participants_jid ON participants (company_id, jid) WHERE jid IS NOT NULL;

-- Attendant = a participant who is staff. Points to participants (one place holds lid/jid).
CREATE TABLE attendants (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id     bigint NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  participant_id bigint NOT NULL,
  name           text,
  active         boolean NOT NULL DEFAULT true,
  created_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (company_id, participant_id),
  FOREIGN KEY (company_id, participant_id) REFERENCES participants (company_id, id)
);

-- ---------------------------------------------------------------------
-- Batches: messages from the same author merged by a window (15 s). It is the AI processing queue.
-- The AI decision (classification / what the bot would answer) lives here; there is no shadow_replies table.
-- ---------------------------------------------------------------------
CREATE TABLE batches (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id     bigint NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  group_id       bigint NOT NULL,
  participant_id bigint NOT NULL,
  state          text NOT NULL DEFAULT 'pending' CHECK (state IN ('pending','processing','done','error')),
  mode           text NOT NULL CHECK (mode IN ('shadow','active')),   -- group mode at the moment the batch closed
  attempts       integer NOT NULL DEFAULT 0,
  reserved_at    timestamptz,
  decision       jsonb,
  error          text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  completed_at   timestamptz,
  UNIQUE (company_id, id),
  FOREIGN KEY (company_id, group_id)       REFERENCES wa_groups (company_id, id),
  FOREIGN KEY (company_id, participant_id) REFERENCES participants (company_id, id)
);
CREATE INDEX ix_batches_queue ON batches (id) WHERE state IN ('pending','processing');
CREATE INDEX ix_batches_group ON batches (company_id, group_id, created_at DESC);
CREATE TRIGGER trg_batches_updated BEFORE UPDATE ON batches FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------
-- Messages (inbound, plus what the bot device sent). Text lives ONLY here.
-- ---------------------------------------------------------------------
CREATE TABLE messages (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id        bigint NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  group_id          bigint NOT NULL,
  participant_id    bigint,
  wa_message_id     text NOT NULL,                       -- payload message_id
  from_me           boolean NOT NULL DEFAULT false,
  author_type       text NOT NULL CHECK (author_type IN ('member','attendant','bot','bot_device')),
  type              text NOT NULL DEFAULT 'text' CHECK (type IN ('text','image','audio','video','document','sticker','reaction','location','contact','other')),
  text              text,                                -- payload text
  caption           text,
  quoted_wa_id      text,
  mentions          jsonb NOT NULL DEFAULT '[]'::jsonb,
  message_timestamp timestamptz NOT NULL,                -- payload timestamp
  batch_id          bigint,
  handled_at        timestamptz,                         -- attendant/device message already registered on the ticket
  created_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT messages_wa_uq UNIQUE (company_id, wa_message_id),   -- webhook idempotency
  UNIQUE (company_id, id),
  CHECK (author_type IN ('bot','bot_device') OR participant_id IS NOT NULL),
  FOREIGN KEY (company_id, group_id)       REFERENCES wa_groups (company_id, id),
  FOREIGN KEY (company_id, participant_id) REFERENCES participants (company_id, id),
  FOREIGN KEY (company_id, batch_id)       REFERENCES batches (company_id, id)
);
-- Batch-closing queue (members' messages that still have no batch):
CREATE INDEX ix_messages_queue   ON messages (company_id, group_id, participant_id) WHERE batch_id IS NULL AND author_type = 'member';
CREATE INDEX ix_messages_handle  ON messages (company_id, id) WHERE handled_at IS NULL AND author_type IN ('attendant','bot_device');
CREATE INDEX ix_messages_group   ON messages (company_id, group_id, message_timestamp DESC);
CREATE INDEX ix_messages_quoted  ON messages (company_id, quoted_wa_id) WHERE quoted_wa_id IS NOT NULL;
CREATE INDEX ix_messages_batch   ON messages (company_id, batch_id) WHERE batch_id IS NOT NULL;
CREATE INDEX ix_messages_person  ON messages (company_id, participant_id, message_timestamp DESC);

-- Raw Evolution payload kept apart: heavy and full of personal data, deleted by retention.
CREATE TABLE message_payloads (
  message_id bigint PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
  company_id bigint NOT NULL,
  payload    jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_message_payloads_created ON message_payloads (created_at);

-- ---------------------------------------------------------------------
-- Tickets
-- ---------------------------------------------------------------------
CREATE TABLE tickets (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id          bigint NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  short_code          bigint NOT NULL,                  -- "#482", sequence per company (trigger)
  group_id            bigint NOT NULL,
  batch_id            bigint NOT NULL,                  -- batch that opened it
  participant_id      bigint NOT NULL,                  -- who asked
  position            integer NOT NULL DEFAULT 1,       -- position inside the batch
  intent              text NOT NULL CHECK (intent IN ('payment_slip','status_inquiry','payment_not_posted','due_date_change','new_contract','refund','cancellation','registration_change','other')),
  confidence          numeric(3,2) CHECK (confidence BETWEEN 0 AND 1),
  identifier_type     text CHECK (identifier_type IN ('cpf','plate')),   -- NULL = no identifier
  identifier_last     text,                             -- only the last digits, for display
  identifier_hmac     text,                             -- HMAC-SHA256 computed in the core; the secret is NOT in the database
  state               text NOT NULL DEFAULT 'new' CHECK (state IN ('new','awaiting_data','querying','awaiting_sga','awaiting_inspection','awaiting_human','replied','finished','expired','cancelled','error')),
  destination         text NOT NULL DEFAULT 'collections' CHECK (destination IN ('collections','registration')),
  result              text,
  human_reason        text,
  missing             text,
  origin_ticket_id    bigint,
  sga_lookup          jsonb,                            -- SGA response (may hold a name: purge_old_data() clears it)
  reply_wa_id         text,
  attempts            integer NOT NULL DEFAULT 0,
  first_attempt_at    timestamptz,
  next_attempt_at     timestamptz,
  version             integer NOT NULL DEFAULT 1,       -- optimistic lock: UPDATE ... WHERE version = :read
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  closed_at           timestamptz,
  UNIQUE (company_id, id),
  UNIQUE (company_id, short_code),
  CHECK ((identifier_type IS NULL) = (identifier_hmac IS NULL)),
  FOREIGN KEY (company_id, group_id)         REFERENCES wa_groups (company_id, id),
  FOREIGN KEY (company_id, batch_id)         REFERENCES batches (company_id, id),
  FOREIGN KEY (company_id, participant_id)   REFERENCES participants (company_id, id),
  FOREIGN KEY (company_id, origin_ticket_id) REFERENCES tickets (company_id, id)
);
CREATE INDEX ix_tickets_open    ON tickets (company_id, state, updated_at) WHERE state NOT IN ('finished','expired','cancelled');
CREATE INDEX ix_tickets_person  ON tickets (company_id, participant_id, created_at DESC);
CREATE INDEX ix_tickets_batch   ON tickets (company_id, batch_id);
CREATE INDEX ix_tickets_group   ON tickets (company_id, group_id, created_at DESC);
CREATE INDEX ix_tickets_origin  ON tickets (company_id, origin_ticket_id) WHERE origin_ticket_id IS NOT NULL;
CREATE INDEX ix_tickets_ident   ON tickets (company_id, identifier_hmac) WHERE identifier_hmac IS NOT NULL;
CREATE INDEX ix_tickets_retry   ON tickets (next_attempt_at) WHERE next_attempt_at IS NOT NULL AND state IN ('awaiting_sga','querying');

-- Messages linked to each ticket (replaces the old jsonb array messages_ids; has integrity and an index)
CREATE TABLE ticket_messages (
  company_id bigint NOT NULL,
  ticket_id  bigint NOT NULL,
  message_id bigint NOT NULL,
  link_type  text NOT NULL CHECK (link_type IN ('opening','quote','identifier','single_open','ai','rule','human')),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (ticket_id, message_id),
  FOREIGN KEY (company_id, ticket_id)  REFERENCES tickets (company_id, id) ON DELETE CASCADE,
  FOREIGN KEY (company_id, message_id) REFERENCES messages (company_id, id)
);
CREATE INDEX ix_ticket_messages_msg ON ticket_messages (company_id, message_id);

-- Audit trail. State changes are written by TRIGGER (the flow does not have to remember).
-- A complement (old ticket_complementos) is an event with detail.
CREATE TABLE ticket_events (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id  bigint NOT NULL,
  ticket_id   bigint NOT NULL,
  type        text NOT NULL CHECK (type IN ('opening','complement','attendant_reply','bot_reply','state_change','forwarded','error','note')),
  author      text NOT NULL CHECK (author IN ('member','attendant','bot','system')),
  message_id  bigint,
  batch_id    bigint,
  link_type   text CHECK (link_type IN ('opening','quote','identifier','single_open','ai','rule','human')),
  state_from  text,
  state_to    text,
  detail      jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at  timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (company_id, ticket_id)  REFERENCES tickets (company_id, id) ON DELETE CASCADE,
  FOREIGN KEY (company_id, message_id) REFERENCES messages (company_id, id),
  FOREIGN KEY (company_id, batch_id)   REFERENCES batches (company_id, id)
);
CREATE INDEX ix_ticket_events_ticket ON ticket_events (ticket_id, created_at);
CREATE INDEX ix_ticket_events_msg    ON ticket_events (company_id, message_id) WHERE message_id IS NOT NULL;
CREATE INDEX ix_ticket_events_batch  ON ticket_events (company_id, batch_id)   WHERE batch_id IS NOT NULL;

-- AI suggestion x human decision (autonomy measurement)
CREATE TABLE ticket_suggestions (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id       bigint NOT NULL,
  ticket_id        bigint NOT NULL,
  model            text NOT NULL,
  suggested_intent text,
  suggested_reply  text,
  confidence       numeric(3,2) CHECK (confidence BETWEEN 0 AND 1),
  decision         text CHECK (decision IN ('approved','edited','ignored')),
  final_reply      text,
  decided_by       text,
  decided_at       timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (company_id, ticket_id) REFERENCES tickets (company_id, id) ON DELETE CASCADE
);
CREATE INDEX ix_ticket_suggestions_ticket ON ticket_suggestions (company_id, ticket_id);

CREATE TABLE evaluations (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id     bigint NOT NULL,
  ticket_id      bigint NOT NULL,
  verdict        text NOT NULL,
  correct_intent text,
  correct_result text,
  evaluator      text,
  note           text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (company_id, ticket_id) REFERENCES tickets (company_id, id) ON DELETE CASCADE
);
CREATE INDEX ix_evaluations_ticket ON evaluations (company_id, ticket_id);

-- ---------------------------------------------------------------------
-- Outbox. ONE queue for everything the bot sends. Replaces avisos_recepcao, cadastro_avisos,
-- avisos_terceirizada and mensagens_enviadas_bot. `key` makes sure the same send is never duplicated.
-- ---------------------------------------------------------------------
CREATE TABLE outbox (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id    bigint NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  group_id      bigint,
  destination_jid text NOT NULL,                      -- group or private chat
  ticket_id     bigint,
  batch_id      bigint,
  type          text NOT NULL CHECK (type IN ('reply','reception_notice','registration_group_notice','registration_consultant_notice','outsourced_notice','alert')),
  text          text NOT NULL,
  quote_wa_id   text,
  mode          text NOT NULL CHECK (mode IN ('shadow','active')),   -- shadow: born 'simulated', never sent
  state         text NOT NULL DEFAULT 'pending' CHECK (state IN ('pending','reserved','sent','failed','discarded','simulated')),
  key           text NOT NULL,                        -- idempotency, e.g. 'ticket:482:reply'
  attempts      integer NOT NULL DEFAULT 0,
  send_at       timestamptz NOT NULL DEFAULT now(),   -- scheduling and backoff
  reserved_at   timestamptz,
  sent_at       timestamptz,
  wa_message_id text,
  error         text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (company_id, key),
  FOREIGN KEY (company_id, group_id)  REFERENCES wa_groups (company_id, id),
  FOREIGN KEY (company_id, ticket_id) REFERENCES tickets (company_id, id),
  FOREIGN KEY (company_id, batch_id)  REFERENCES batches (company_id, id)
);
CREATE UNIQUE INDEX uq_outbox_wa ON outbox (company_id, wa_message_id) WHERE wa_message_id IS NOT NULL;
CREATE INDEX ix_outbox_queue  ON outbox (send_at, id) WHERE state = 'pending';
CREATE INDEX ix_outbox_stuck  ON outbox (reserved_at) WHERE state = 'reserved';
CREATE INDEX ix_outbox_ticket ON outbox (company_id, ticket_id) WHERE ticket_id IS NOT NULL;
CREATE INDEX ix_outbox_batch  ON outbox (company_id, batch_id)  WHERE batch_id IS NOT NULL;
CREATE TRIGGER trg_outbox_updated BEFORE UPDATE ON outbox FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------
-- Routing by intent (per company). Destination: a fixed group OR by group role.
-- ---------------------------------------------------------------------
CREATE TABLE routing_rules (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id      bigint NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  intent          text NOT NULL CHECK (intent IN ('payment_slip','status_inquiry','payment_not_posted','due_date_change','new_contract','refund','cancellation','registration_change','other')),
  department      text NOT NULL CHECK (department IN ('collections','registration','human')),
  action          text NOT NULL CHECK (action IN ('flow','forward','human')),
  flow            text,
  target_group_id bigint,
  target_role     text CHECK (target_role IN ('registration','outsourced','alert')),
  active          boolean NOT NULL DEFAULT true,
  UNIQUE (company_id, intent),
  CHECK (action <> 'flow' OR flow IS NOT NULL),
  FOREIGN KEY (company_id, target_group_id) REFERENCES wa_groups (company_id, id)
);

-- ---------------------------------------------------------------------
-- Ticket triggers
-- ---------------------------------------------------------------------
-- short_code per company (row lock on the company row: short, and serializes only the same company)
CREATE FUNCTION tickets_before_insert() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  UPDATE companies SET ticket_seq = ticket_seq + 1 WHERE id = NEW.company_id RETURNING ticket_seq INTO NEW.short_code;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_tickets_code BEFORE INSERT ON tickets FOR EACH ROW EXECUTE FUNCTION tickets_before_insert();

CREATE FUNCTION tickets_before_update() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  NEW.version := OLD.version + 1;
  IF NEW.state IN ('finished','expired','cancelled') AND OLD.state NOT IN ('finished','expired','cancelled') THEN
    NEW.closed_at := now();
  ELSIF NEW.state NOT IN ('finished','expired','cancelled') THEN
    NEW.closed_at := NULL;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_tickets_update BEFORE UPDATE ON tickets FOR EACH ROW EXECUTE FUNCTION tickets_before_update();

-- Automatic audit of state changes. To record the author: SET LOCAL app.author = 'attendant';
CREATE FUNCTION tickets_after_state() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_author text := coalesce(nullif(current_setting('app.author', true), ''), 'system');
BEGIN
  IF v_author NOT IN ('member','attendant','bot','system') THEN v_author := 'system'; END IF;
  INSERT INTO ticket_events (company_id, ticket_id, type, author, state_from, state_to)
  VALUES (NEW.company_id, NEW.id, 'state_change', v_author, CASE WHEN TG_OP = 'UPDATE' THEN OLD.state END, NEW.state);
  RETURN NULL;
END $$;
CREATE TRIGGER trg_tickets_state_ins AFTER INSERT ON tickets FOR EACH ROW EXECUTE FUNCTION tickets_after_state();
CREATE TRIGGER trg_tickets_state_upd AFTER UPDATE OF state ON tickets FOR EACH ROW WHEN (OLD.state IS DISTINCT FROM NEW.state) EXECUTE FUNCTION tickets_after_state();

INSERT INTO schema_migrations (version, description) VALUES ('0001', 'tables, constraints, indexes and triggers');
COMMIT;
