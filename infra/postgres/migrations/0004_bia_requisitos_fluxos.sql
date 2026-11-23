-- =====================================================================
-- 0004_bia_requisitos_fluxos.sql  (PROPOSTA da Bia para o Davi revisar/aplicar)
-- O que os fluxos n8n corrigidos precisam além do 0001-0003. Testado só em banco temporário.
--  1. pgcrypto: o fluxo 06 decifra company_sga com pgp_sym_decrypt, e o 03 calcula o HMAC do identificador.
--  2. outbox.media: o boleto em PDF sai pela mesma fila (antes o fluxo 11 enviava direto).
--  3. UNIQUE (company_id, batch_id, position) em tickets: idempotência do fluxo 03 (reprocessar um lote
--     não pode duplicar ticket). Sem isso o ON CONFLICT do 03 falha.
--  4. enqueue_outbox ganha p_media (substitui a função de 11 argumentos).
-- =====================================================================
BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

ALTER TABLE outbox ADD COLUMN IF NOT EXISTS media jsonb;
ALTER TABLE outbox DROP CONSTRAINT IF EXISTS outbox_media_check;
ALTER TABLE outbox ADD CONSTRAINT outbox_media_check
  CHECK (media IS NULL OR (jsonb_typeof(media) = 'object' AND media ? 'url'));   -- {url, mimetype, filename}

ALTER TABLE tickets DROP CONSTRAINT IF EXISTS tickets_batch_position_uq;
ALTER TABLE tickets ADD CONSTRAINT tickets_batch_position_uq UNIQUE (company_id, batch_id, position);

DROP FUNCTION IF EXISTS enqueue_outbox(bigint, text, text, text, text, text, bigint, bigint, bigint, text, timestamptz);
CREATE FUNCTION enqueue_outbox(p_company bigint, p_destination_jid text, p_type text, p_text text, p_key text,
                               p_mode text, p_group bigint DEFAULT NULL, p_ticket bigint DEFAULT NULL,
                               p_batch bigint DEFAULT NULL, p_quote text DEFAULT NULL,
                               p_send_at timestamptz DEFAULT now(), p_media jsonb DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE v_id bigint;
BEGIN
  INSERT INTO outbox (company_id, group_id, destination_jid, ticket_id, batch_id, type, text, quote_wa_id, mode, state, key, send_at, media)
  VALUES (p_company, p_group, p_destination_jid, p_ticket, p_batch, p_type, p_text, p_quote, p_mode,
          CASE WHEN p_mode = 'shadow' THEN 'simulated' ELSE 'pending' END, p_key, p_send_at, p_media)
  ON CONFLICT (company_id, key) DO NOTHING RETURNING id INTO v_id;
  IF v_id IS NULL THEN SELECT o.id INTO v_id FROM outbox o WHERE o.company_id = p_company AND o.key = p_key; END IF;
  RETURN v_id;
END $$;
GRANT EXECUTE ON FUNCTION enqueue_outbox(bigint, text, text, text, text, text, bigint, bigint, bigint, text, timestamptz, jsonb) TO bot_app;

INSERT INTO schema_migrations (version, description) VALUES ('0004', 'pgcrypto, outbox.media, tickets unique (batch, position), enqueue_outbox with media');
COMMIT;
