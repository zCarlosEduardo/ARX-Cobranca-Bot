# Glossary pt-BR (old) -> English (new schema)

## Tables
| Old (pt-BR) | New | Note |
|---|---|---|
| schema_migracoes | schema_migrations | |
| empresas | companies | `slug` = payload `tenant_id` |
| empresa_sga | company_sga | secret, hidden from `bot_readonly` |
| empresa_config / config_bot | company_config | per company now |
| grupos | wa_groups | (`groups` avoided: SQL keyword) |
| participantes | participants | new: holds `lid` + `jid` + `display_name` |
| atendentes | attendants | now points to `participants` |
| lotes | batches | also holds the AI decision (`decision`) |
| mensagens | messages | |
| mensagens_payload | message_payloads | retention |
| tickets | tickets | |
| ticket_mensagens | ticket_messages | replaces jsonb `mensagens_ids` |
| ticket_eventos / ticket_complementos | ticket_events | complement = event type `complement` |
| ticket_sugestoes | ticket_suggestions | |
| avaliacoes | evaluations | |
| saidas (replaces avisos_recepcao, cadastro_avisos, avisos_terceirizada, mensagens_enviadas_bot) | outbox | one send queue |
| roteamentos | routing_rules | |
| respostas_sombra | (removed) | decision lives in `batches.decision` |
| encaminhamentos | (not recreated) | idempotency = `outbox UNIQUE (company_id, key)` |

## Common columns
`empresa_id` -> `company_id` · `criado_em` -> `created_at` · `atualizado_em` -> `updated_at` · `ativo` -> `active` · `nome` -> `name` · `modo` -> `mode` · `estado` -> `state` · `tentativas` -> `attempts` · `erro` -> `error` · `texto` -> `text` · `tipo` -> `type` · `grupo_id` -> `group_id` · `lote_id` -> `batch_id` · `participante_id` -> `participant_id`

## Specific columns
| Old | New |
|---|---|
| empresas.instancia | companies.instance |
| mensagens.autor_tipo | messages.author_type |
| mensagens.legenda / mencoes | messages.caption / mentions |
| mensagens.tratada_em | messages.handled_at |
| lotes.reservado_em / concluido_em | batches.reserved_at / completed_at |
| tickets.codigo_curto | tickets.short_code |
| tickets.ordem | tickets.position |
| tickets.intencao | tickets.intent |
| tickets.confianca | tickets.confidence |
| tickets.identificador_tipo / _final / _hash | tickets.identifier_type / identifier_last / identifier_hmac |
| tickets.consulta | tickets.sga_lookup |
| tickets.motivo_humano / faltando | tickets.human_reason / missing |
| tickets.encerrado_em | tickets.closed_at |
| tickets.versao | tickets.version |
| saidas.destino_jid / citar_wa_id / chave / disparar_em | outbox.destination_jid / quote_wa_id / key / send_at |
| roteamentos.acao / departamento / grupo_destino_id / papel_destino | routing_rules.action / department / target_group_id / target_role |

## Values (CHECK constraints)
| Column | Old -> New |
|---|---|
| wa_groups.roles (text[]) | atendimento -> `support` · cadastro -> `registration` · terceirizada -> `outsourced` · alerta -> `alert` |
| *.mode | sombra -> `shadow` · ativo -> `active` |
| batches.state | pendente -> `pending` · processando -> `processing` · concluido -> `done` · erro -> `error` |
| messages.author_type | membro -> `member` · atendente -> `attendant` · bot -> `bot` · bot_aparelho -> `bot_device` |
| messages.type | texto -> `text` · imagem -> `image` · audio -> `audio` · video -> `video` · documento -> `document` · sticker -> `sticker` · reacao -> `reaction` · localizacao -> `location` · contato -> `contact` · outro -> `other` |
| tickets.intent | boleto -> `payment_slip` · situacao -> `status_inquiry` · pagamento_sem_baixa -> `payment_not_posted` · troca_vencimento -> `due_date_change` · novo_contrato -> `new_contract` · estorno -> `refund` · cancelamento -> `cancellation` · alteracao_cadastro -> `registration_change` · outro -> `other` |
| tickets.identifier_type | cpf -> `cpf` · placa -> `plate` (NULL = none) |
| tickets.state | novo -> `new` · aguardando_dados -> `awaiting_data` · consultando -> `querying` · aguardando_sga -> `awaiting_sga` · aguardando_vistoria -> `awaiting_inspection` · aguardando_humano -> `awaiting_human` · respondido -> `replied` · finalizado -> `finished` · expirado -> `expired` · cancelado -> `cancelled` · erro -> `error` |
| tickets.destination | cobranca -> `collections` · cadastro -> `registration` |
| ticket_messages.link_type | abertura -> `opening` · citacao -> `quote` · identificador -> `identifier` · unico_aberto -> `single_open` · ia -> `ai` · regra -> `rule` · humano -> `human` |
| ticket_events.type | abertura -> `opening` · complemento -> `complement` · resposta_atendente -> `attendant_reply` · resposta_bot -> `bot_reply` · mudanca_estado -> `state_change` · encaminhado -> `forwarded` · erro -> `error` · nota -> `note` |
| ticket_events.author | associado -> `member` · atendente -> `attendant` · bot -> `bot` · sistema -> `system` |
| ticket_suggestions.decision | aprovada -> `approved` · editada -> `edited` · ignorada -> `ignored` |
| outbox.type | resposta -> `reply` · aviso_recepcao -> `reception_notice` · aviso_cadastro_grupo -> `registration_group_notice` · aviso_cadastro_consultor -> `registration_consultant_notice` · aviso_terceirizada -> `outsourced_notice` · alerta -> `alert` |
| outbox.state | pendente -> `pending` · reservada -> `reserved` · enviada -> `sent` · falhou -> `failed` · descartada -> `discarded` · simulada -> `simulated` |
| routing_rules.department | cobranca -> `collections` · cadastro -> `registration` · humano -> `human` |
| routing_rules.action | fluxo -> `flow` · encaminhar -> `forward` · humano -> `human` |

## Functions (n8n calls these)
| Old | New |
|---|---|
| ingerir_mensagem(jsonb) | ingest_message(jsonb) -> status `new` / `duplicate` / `ignored_company` / `ignored_group` / `invalid` |
| fechar_lotes | close_batches |
| reservar_lotes / concluir_lote / falhar_lote | reserve_batches / complete_batch / fail_batch |
| enfileirar_saida | enqueue_outbox |
| reservar_saidas / marcar_saida_enviada / falhar_saida | reserve_outbox / mark_outbox_sent / fail_outbox |
| recuperar_travados | recover_stuck |
| limpar_dados_antigos | purge_old_data |
| anonimizar_participante | anonymize_participant |
| view v_payload_mensagens | v_message_payload |
| session var `app.autor` | `app.author` |

## Payload contract (unchanged, already English)
`tenant_id, group_id, contact_id, sender_name, message_id, text, timestamp` + optional `contact_alt, from_me, type, caption, quoted_message_id, mentions, raw`.
