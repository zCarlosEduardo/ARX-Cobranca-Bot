# Stack e arquitetura

## Quem faz o quê

| Peça | Papel |
|---|---|
| **Evolution API** | Um número por empresa, em todos os grupos dela. Publica eventos no RabbitMQ |
| **RabbitMQ** | Fila `entrada` e fila `aguardando_sga` |
| **n8n** (modo fila + workers) | Entrada, lote de 15 s, AI Agent, chamada ao SGA com disjuntor, saída, agendador, formulário do código do dia, alertas |
| **Claude** (nó AI Agent) | Entende, extrai placa/CPF, escreve respostas, responde dúvidas, checklist da vistoria. Haiku nas tarefas simples, Sonnet na vistoria (testar Haiku) |
| **Next.js + Drizzle** | API de decisão (`/vincular`, `/decidir`, `/pode-enviar`, `/cards`, `/jobs/prazos`) e telas (cards, config, regras) |
| **Postgres** (do bot, separado do ERP) | Config, regras, pedidos, estado, cards, eventos |
| **Redis** | Travas e dedupe |
| **MinIO / S3** | Fotos e vídeos de vistoria |
| **ERP Django (arxconnect)** | Abre o iframe com token assinado do usuário logado. Nada além disso é exigido do Django |

## Diagrama

```
GRUPOS ─► Evolution ─► RabbitMQ ─► n8n ENTRADA (dedupe · empresa · atendente? · lote 15 s)
                                        ▼
                                  n8n AI AGENT (entende e escreve, livre)
                                   ├ tool vincular ──► Next /vincular
                                   ├ tool decidir:  n8n chama o SGA (timeout, disjuntor, fila)
                                   │                  └ dados ──► Next /decidir → {acao, motivo, regras_batidas}
                                   ├ tool dúvidas ───► base de conhecimento
                                   └ tool humano ────► Next /cards
                                        ▼
                                  n8n SAÍDA ─► Next /pode-enviar ─► Evolution (com limite de ritmo)
n8n CRON (1 min) ─► Next /jobs/prazos (escala card, devolve ao bot)

NEXT.JS (iframe no ERP)  telas: cards · Assumir/Aprovar/Devolver · config e regras
                         core/: regras R1..R8 em TS puro + Vitest
POSTGRES do bot · Drizzle
```

## O que o n8n NÃO faz
Regra de negócio. Se um dia o n8n sair, troca-se só o orquestrador.

## Escala (500 mil ativos no total)

O volume não é o problema (~9 mil mensagens/dia nos grupos). Escala-se com mais workers n8n e processos Next; o RabbitMQ segura picos. Os gargalos reais são:
1. **Ban do número** (mitigação em D02).
2. **Limite e instabilidade do SGA** (disjuntor, concorrência 2 a 3 na retomada, teste de carga quando houver token).
3. **Regras erradas ao mudar** (teste automático antes de ativar; regras versionadas).
4. **Equipe humana** de revistoria (centenas de cards/dia se 10% forem vistoria).
5. **Custo de IA**: nunca mandar histórico inteiro nem foto na memória da conversa. O contexto vem do banco a cada chamada; memória do agente é curta por conversa+autor.

## Estrutura do monorepo (alvo)

```
ARX-Cobranca-Bot/
├─ apps/web/            # Next.js: telas + API
├─ packages/core/       # regras, prazo útil, amarração (TS puro + Vitest)
├─ packages/db/         # schema Drizzle + migrations
├─ n8n/workflows/       # JSON exportado (sem credenciais) + README
├─ infra/               # compose.dev.yml, compose.prod.yml, caddy, backup
├─ empresas/            # _modelo.json, ancore.json (seed)
├─ docs/
├─ .env.example
├─ pnpm-workspace.yaml
└─ package.json
```

Regras do repo:
1. `packages/core` não importa Next nem banco.
2. Segredos nunca no repo (só `.env.example`); token do SGA por empresa em variável de ambiente ou credenciais do n8n.
3. Workflows exportados com `n8n export:workflow`, sem credenciais, revisados como código.
4. `main` protegida, testes do `core` no CI.
5. Empresa nova = arquivo em `empresas/` + seed.

## Primeiro commit de código
`compose.dev.yml` com Postgres, RabbitMQ e n8n; `packages/db` com `empresas`, `grupos`, `solicitacoes`; um teste do `core` (vencimento no sábado). Se subir e o teste passar, a base está certa.

## Os 7 workflows do n8n

1. **Entrada**: dedupe por `wa_message_id`, empresa pela instância, grupo cadastrado?, quem é (bot, atendente, membro), lote 15 s.
2. **Agente**: AI Agent com as tools acima.
3. **Revistoria**: mídia baixada em chamada separada → MinIO + sha256 → IA checklist → card.
4. **Retorno ERP**: webhook assinado (HMAC) com aprovar, reprovar, pedir_mais, assumir, devolver.
5. **Retomada SGA**: reprocessa a fila `aguardando_sga` devagar.
6. **Agendador**: prazos úteis, lembretes, código do dia às 08:00, devolução por inatividade.
7. **Saída**: confere controle, cita a mensagem original com placa, envia com limite de ritmo.

Empresa nova não ganha fluxo.
