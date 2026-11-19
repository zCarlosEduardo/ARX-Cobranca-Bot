-- Smoke tests for the English schema. Run on a THROWAWAY database only. Everything is rolled back at the end.
\set ON_ERROR_STOP on
BEGIN;
SELECT 'ok' AS t0_schema_loaded, count(*) AS tables FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE';

INSERT INTO companies (slug,name,instance) VALUES ('empresa_01','Company 1','inst1'),('empresa_02','Company 2','inst2');
INSERT INTO wa_groups (company_id,group_jid,name,roles,mode)
  SELECT id,'120363000000001@g.us','Support 1',ARRAY['support'],'active' FROM companies WHERE slug='empresa_01';
INSERT INTO wa_groups (company_id,group_jid,name,roles,mode)
  SELECT id,'120363000000009@g.us','Registration+Outsourced 1',ARRAY['registration','outsourced'],'active' FROM companies WHERE slug='empresa_01';
INSERT INTO wa_groups (company_id,group_jid,name,roles,mode)
  SELECT id,'120363000000002@g.us','Support 2',ARRAY['support'],'shadow' FROM companies WHERE slug='empresa_02';

-- same shared registration group registered for company 2 as well (one row per company, same JID)
INSERT INTO wa_groups (company_id,group_jid,name,roles,mode)
  SELECT id,'120363000000009@g.us','Registration+Outsourced 2',ARRAY['registration','outsourced'],'active' FROM companies WHERE slug='empresa_02';
SELECT 't0_shared_group_two_rows' AS t, count(*) FROM wa_groups WHERE group_jid='120363000000009@g.us';
SELECT 't0_multi_roles' AS t, roles FROM wa_groups WHERE group_jid='120363000000009@g.us' LIMIT 1;
-- 1) the payload from Carlos' example
SELECT 't1_example' AS t, * FROM ingest_message('{"tenant_id":"empresa_01","group_id":"120363000000001@g.us","contact_id":"contato_123","sender_name":"Joao","message_id":"MSG_001","text":"Terminei a integracao","timestamp":"2026-11-19T14:00:00-03:00"}'::jsonb);
-- 2) duplicate / unknown group / unknown company / invalid
SELECT 't2_dup' AS t, status FROM ingest_message('{"tenant_id":"empresa_01","group_id":"120363000000001@g.us","contact_id":"contato_123","message_id":"MSG_001","text":"x","timestamp":"2026-11-19T14:00:00-03:00"}'::jsonb);
SELECT 't2_group' AS t, status FROM ingest_message('{"tenant_id":"empresa_01","group_id":"999@g.us","contact_id":"a@lid","message_id":"M9","text":"x","timestamp":1795100000}'::jsonb);
SELECT 't2_company' AS t, status FROM ingest_message('{"tenant_id":"nope","group_id":"120363000000001@g.us","contact_id":"a@lid","message_id":"M9","text":"x","timestamp":1795100000}'::jsonb);
SELECT 't2_invalid' AS t, status FROM ingest_message('{"tenant_id":"empresa_01","group_id":"120363000000001@g.us","message_id":"M10","timestamp":"garbage"}'::jsonb);
SELECT 't2_no_contact' AS t, status FROM ingest_message('{"tenant_id":"empresa_01","group_id":"120363000000001@g.us","message_id":"M11","text":"x","timestamp":1795100000}'::jsonb);
-- 3) @lid + phone merge, attendant, bot, bot_device
SELECT 't3_lid' AS t, status, author_type FROM ingest_message('{"tenant_id":"empresa_01","group_id":"120363000000001@g.us","contact_id":"111@lid","contact_alt":"5511999990000","sender_name":"Maria","message_id":"M20","text":"boleto","timestamp":1795100001000}'::jsonb);
SELECT 't3_phone_same_person' AS t, count(*) AS participants_with_that_jid FROM participants WHERE jid='5511999990000@s.whatsapp.net';
INSERT INTO attendants (company_id, participant_id, name) SELECT company_id, id, 'Att' FROM participants WHERE lid='111@lid';
SELECT 't3_attendant' AS t, status, author_type FROM ingest_message('{"tenant_id":"empresa_01","group_id":"120363000000001@g.us","contact_id":"111@lid","message_id":"M21","text":"ok","timestamp":1795100002}'::jsonb);
SELECT 't3_device' AS t, status, author_type FROM ingest_message('{"tenant_id":"empresa_01","group_id":"120363000000001@g.us","from_me":true,"message_id":"M22","text":"from phone","timestamp":1795100003}'::jsonb);
-- 4) batches, tickets, short_code, state audit
INSERT INTO participants (company_id,lid) SELECT id,'222@lid' FROM companies WHERE slug='empresa_01';
SELECT 't4_member' AS t, status, author_type FROM ingest_message('{"tenant_id":"empresa_01","group_id":"120363000000001@g.us","contact_id":"222@lid","message_id":"M30","text":"preciso do boleto","timestamp":1795100010}'::jsonb);
SELECT 't4_member2' AS t, status FROM ingest_message('{"tenant_id":"empresa_01","group_id":"120363000000001@g.us","contact_id":"222@lid","message_id":"M31","text":"cpf 000","timestamp":1795100011}'::jsonb);
UPDATE messages SET created_at = now() - interval '1 minute';
SELECT 't4_closed_batches' AS t, count(*) FROM close_batches('15 seconds');
SELECT 't4_msgs_in_batch' AS t, count(*) FROM messages WHERE batch_id IS NOT NULL;
SELECT 't4_close_again_is_empty' AS t, count(*) FROM close_batches('15 seconds');
SELECT 't4_reserve' AS t, count(*) FROM reserve_batches(5);
INSERT INTO tickets (company_id,group_id,batch_id,participant_id,intent,identifier_type,identifier_hmac,identifier_last)
  SELECT b.company_id,b.group_id,b.id,b.participant_id,'payment_slip','cpf','hmac_fake','000' FROM batches b LIMIT 1;
SELECT 't4_ticket' AS t, short_code, state, version FROM tickets;
UPDATE tickets SET state='awaiting_human';
UPDATE tickets SET state='finished';
SELECT 't4_audit' AS t, type, state_from, state_to, author FROM ticket_events ORDER BY id;
SELECT 't4_closed_at_set' AS t, closed_at IS NOT NULL AS ok, version FROM tickets;
SELECT complete_batch(id, '{"intent":"payment_slip"}') FROM batches LIMIT 1;
SELECT 't4_batch_done' AS t, state, decision FROM batches;
-- 5) outbox: shadow vs active, idempotency, reserve, fail, recover
SELECT 't5_enqueue_active' AS t, enqueue_outbox(c.id,'120363000000001@g.us','reply','hi','ticket:1:reply','active') FROM companies c WHERE slug='empresa_01';
SELECT 't5_same_key_same_id' AS t, enqueue_outbox(c.id,'120363000000001@g.us','reply','hi','ticket:1:reply','active') FROM companies c WHERE slug='empresa_01';
SELECT 't5_shadow' AS t, enqueue_outbox(c.id,'120363000000002@g.us','reply','hi','ticket:1:reply','shadow') FROM companies c WHERE slug='empresa_02';
SELECT 't5_states' AS t, c.slug, o.state FROM outbox o JOIN companies c ON c.id=o.company_id ORDER BY o.id;
SELECT 't5_reserved' AS t, count(*) FROM reserve_outbox(10);
SELECT fail_outbox(id,'timeout') FROM outbox WHERE state='reserved';
SELECT 't5_after_fail' AS t, state, attempts, send_at > now() AS backoff FROM outbox WHERE state<>'simulated';
UPDATE outbox SET send_at = now(), state='reserved', reserved_at = now() - interval '20 minutes' WHERE state='pending';
SELECT 't5_recover' AS t, * FROM recover_stuck(10);
UPDATE outbox SET send_at = now() WHERE state='pending';
SELECT mark_outbox_sent(o.id,'WAID1') FROM outbox o WHERE state='pending';
SELECT 't5_sent' AS t, state, wa_message_id FROM outbox WHERE wa_message_id IS NOT NULL;
-- bot webhook arrives AFTER the send was marked -> author 'bot'
SELECT 't5_bot_echo' AS t, status, author_type FROM ingest_message('{"tenant_id":"empresa_01","group_id":"120363000000001@g.us","from_me":true,"message_id":"WAID1","text":"hi","timestamp":1795100050}'::jsonb);
-- 6) retention + anonymization
INSERT INTO message_payloads (message_id, company_id, payload, created_at) SELECT id, company_id, '{"k":1}', now() - interval '40 days' FROM messages LIMIT 1;
SELECT 't6_purge' AS t, purge_old_data(30, 90);
SELECT 't6_anonymize' AS t, anonymize_participant(id) FROM participants WHERE lid='222@lid';
SELECT 't6_anon_row' AS t, lid, display_name, anonymized_at IS NOT NULL FROM participants WHERE anonymized_at IS NOT NULL;
-- 7) view = payload contract
SELECT 't7_view_columns' AS t, string_agg(column_name, ',' ORDER BY ordinal_position) FROM information_schema.columns WHERE table_name='v_message_payload';
SELECT 't7_view_row' AS t, tenant_id, group_id, contact_id, message_id, text FROM v_message_payload WHERE message_id='MSG_001';
SAVEPOINT s;
-- 8) tenant isolation: ticket of company 2 pointing to batch of company 1 must FAIL
DO $$ BEGIN
  BEGIN
    INSERT INTO tickets (company_id,group_id,batch_id,participant_id,intent)
      SELECT (SELECT id FROM companies WHERE slug='empresa_02'), g.id, b.id, b.participant_id, 'other'
        FROM batches b, wa_groups g WHERE g.group_jid='120363000000002@g.us' LIMIT 1;
    RAISE NOTICE 't8_isolation: FAILED TO BLOCK';
  EXCEPTION WHEN foreign_key_violation THEN RAISE NOTICE 't8_isolation: blocked by composite FK (ok)';
  END;
  BEGIN
    INSERT INTO tickets (company_id,group_id,batch_id,participant_id,intent) SELECT b.company_id,b.group_id,b.id,b.participant_id,'invalid_intent' FROM batches b LIMIT 1;
    RAISE NOTICE 't8_check: FAILED TO BLOCK';
  EXCEPTION WHEN check_violation THEN RAISE NOTICE 't8_check: bad intent blocked (ok)';
  END;
  BEGIN
    INSERT INTO tickets (company_id,group_id,batch_id,participant_id,intent,identifier_type) SELECT b.company_id,b.group_id,b.id,b.participant_id,'other','cpf' FROM batches b LIMIT 1;
    RAISE NOTICE 't8_hmac_pair: FAILED TO BLOCK';
  EXCEPTION WHEN check_violation THEN RAISE NOTICE 't8_hmac_pair: identifier_type without hmac blocked (ok)';
  END;
END $$;
DO $$ BEGIN
  BEGIN INSERT INTO wa_groups (company_id,group_jid,roles) SELECT id,'1@g.us',ARRAY['bogus'] FROM companies LIMIT 1;
    RAISE NOTICE 't8_roles: FAILED TO BLOCK';
  EXCEPTION WHEN check_violation THEN RAISE NOTICE 't8_roles: invalid role blocked (ok)'; END;
END $$;
-- 9) concurrency-ish: short_code per company is independent
INSERT INTO tickets (company_id,group_id,batch_id,participant_id,intent) SELECT b.company_id,b.group_id,b.id,b.participant_id,'other' FROM batches b LIMIT 1;
SELECT 't9_short_codes' AS t, c.slug, array_agg(t.short_code ORDER BY t.short_code) FROM tickets t JOIN companies c ON c.id=t.company_id GROUP BY c.slug;
ROLLBACK;
