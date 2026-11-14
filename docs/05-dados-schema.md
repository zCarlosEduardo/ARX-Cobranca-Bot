# Dados e contratos

> Rascunho conceitual. O DDL definitivo nasce em `packages/db` (Drizzle). Os nomes abaixo são os combinados no desenho; ajustar na implementação.

## Tabelas

| Tabela | Para quê |
|---|---|
| `empresas` | Uma por associação; liga à instância da Evolution |
| `empresa_config` | `config jsonb` + colunas operacionais (prazo, horário, supervisão, inatividade) + `versao` |
| `empresa_sga` | Credenciais do SGA por empresa (cifradas ou no cofre do n8n) |
| `grupos` | `group_jid`, nome, ativo, `modo` (`sombra` ou `ativo`). **É a autorização** |
| `participantes` | jid, lid, nome do push. Só histórico, nunca permissão |
| `atendentes` | jid, lid, nome, ativo, por empresa |
| `solicitacoes` | Um pedido por placa (ver colunas) |
| `mensagens` | Entrada e saída; `autor_tipo`, `status_saida`, `wa_message_id` único por instância |
| `solicitacao_mensagens` | Liga uma mensagem a vários pedidos (citação) |
| `midias` | Arquivo no storage, sha256, tipo, origem |
| `cards` | Espelho do card no ERP |
| `eventos` | Auditoria de toda mudança de estado e ação humana |
| `regras_empresa` | `ordem`, nome, `condicao_json`, `acao`, `mensagem_modelo`, `ativo`, `versao` |
| `base_conhecimento` | `empresa_id`, tema, texto, versão |
| `codigo_dia` | `data`, `empresa_id` (NULL = todas), código, origem, `cadastrado_por`. Índice único `(data, coalesce(empresa_id,0))` |
| `respostas_sombra` | O que o bot teria respondido (modo sombra) |

Obs.: o ERP Django já tem `Empresa`, `Cooperativa` e `Consultor` (app `configs`). O bot mantém o próprio cadastro e sincroniza só o necessário; não escreve no banco do ERP.

## Colunas principais de `solicitacoes`

`id`, `codigo_curto` (sequência por empresa, ex. #482), `empresa_id`, `chat_jid`, `chat_tipo`, `placa` (7 caracteres maiúsculos), `associado_id`, `tipo` (`segunda_via` | `vistoria_boleto`), `estado`, `solicitante_jid`, `msg_origem_wa_id`, `midias_recebidas/exigidas`, `card_erp_id`, `solicitacao_anterior_id`, `versao`, `aberta_em`, `ultima_interacao_em`, `expira_em`, `concluida_em`, `motivo_fim`.

Controle humano: `controle` (`bot`|`humano`), `humano_jid`/`assumido_por`, `assumido_em`, `devolvido_em`, `nota_passagem`, `consultor_aguardando_desde`, `consultor_msgs_novas`, `consultor_alertado_em`.

Prazo: `prioridade` (`normal`|`alta`|`urgente`), `prazo_card_em`, `prazo_base_min`, `escalonamento_nivel`, `escalonamentos`, `alertas_supervisor`, `ultimo_alerta_em`.

Decisão: `regra_id`, `regra_versao`, `regras_batidas jsonb`, `acao_decidida`, `vencimento_efetivo`, `dias_atraso`, `alerta_codigo_dia`, `sombra`.

Índice único parcial: `(empresa_id, placa)` onde estado não está em concluida/cancelada/expirada/reprovada.

## `empresa_config` (campos)
`vencimentos`, `vencimento_dia_util`, `lotes_boleto`, `inadimplente_apos_dias`, `terceirizada`, `novo_contrato`, `juros`, `pagamento`, `revistoria`, `prazo_card_min`, `horario_atendimento` (dias, início, fim, offset, feriados), `grupo_supervisao_jid`, `humano_inatividade_min_uteis`, `consultor_espera_alerta_min`, segredo HMAC do ERP.

## Contrato: card (bot → ERP)

`POST /cards` (criar) e `PATCH /cards/{id}`:

```json
{
  "solicitacao_id": "…", "empresa_id": "…", "placa": "ABC1D23",
  "resumo": "…", "sugestao_ia": "…", "checklist_ia": [],
  "midias": [{"url": "…", "tipo": "foto|video", "sha256": "…"}],
  "regras_batidas": ["R2", "R4"],
  "prioridade": "normal|alta|urgente",
  "prazo_em": "…",
  "controle": "bot|humano",
  "assumido_por": "…", "assumido_em": "…",
  "nota_passagem": "…", "devolvido_em": "…",
  "consultor_msgs_novas": 2,
  "consultor_aguardando_desde": "…",
  "mensagens_descartadas": [{"texto": "…", "ts": "…"}],
  "alerta_codigo_dia": false
}
```

Botões: **Assumir** (quando `controle=bot`), **Devolver ao bot** (quando `humano`, campo `recado_bot`), **Aprovar**, **Reprovar**, **Pedir mais**. Selo "mensagem nova do consultor" com contador. Rascunho do bot não enviado aparece no card.

## Contrato: webhook de retorno (ERP → n8n)

`POST /webhook/erp-retorno`
- Cabeçalhos: `X-Timestamp` (unix s) e `X-Signature: sha256=<hex>` com `HMAC_SHA256(segredo_da_empresa, X-Timestamp + "." + corpo_bruto)`.
- Validação: recalcular e comparar em tempo constante; 401 se `|agora − ts| > 300 s`; 409 se `idempotency_key` repetida.

```json
{
  "empresa_id": "…", "solicitacao_id": "…",
  "acao": "aprovar|reprovar|pedir_mais|assumir|devolver",
  "usuario_id": "…", "usuario_nome": "…",
  "motivo": "…", "recado_bot": "…",
  "idempotency_key": "uuid"
}
```

| Ação | Pré-condição | Efeito |
|---|---|---|
| assumir | `controle=bot` | vira humano, zera contador, cancela saídas pendentes. 409 se já for de outro usuário |
| devolver | `controle=humano` | volta ao bot, grava `nota_passagem`. 409 se já for bot |
| aprovar / reprovar / pedir_mais | estado `aguardando_humano` | segue o fluxo. "Pedir mais" mantém o código e abre card novo |

Toda ação grava log com `usuario_id`. Aprovar não é assumir.

## Autenticação do iframe
O Django abre o iframe com token assinado do usuário logado; o Next valida e identifica quem aprovou. Até existir essa rota, os cards rodam com login próprio, só no modo sombra. (Nota: o ERP usa JWT com access token em memória e refresh em cookie httpOnly; ver pendências para o desenho do token do iframe.)

## Idempotência e consistência
`UNIQUE(instancia, wa_message_id)` + `ON CONFLICT DO NOTHING`; trava otimista por `versao`; transições com `WHERE estado = 'anterior'`; `pg_advisory_xact_lock(hashtext(chat_jid))` na amarração.

## Mídia
Baixada em chamada separada, guardada no MinIO/S3. `sha256` mantido para sempre; arquivo por no mínimo 180 dias (a confirmar com o jurídico). Premissa de ~15 MB por vistoria.
