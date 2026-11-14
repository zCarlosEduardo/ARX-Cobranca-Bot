# ARX Cobrança Bot

Bot de WhatsApp que atende as equipes de consultores das associações de proteção veicular que a ARX administra (16 empresas). Responde 2ª via de boleto, conduz a revistoria de inadimplentes e passa para um humano o que não pode ser decidido pela IA.

> Status: **fase de desenho**. Este repositório começa só com a documentação. O código entra depois do modo sombra (ver `docs/08-roadmap.md`).

## Índice da documentação

| Arquivo | Conteúdo |
|---|---|
| [docs/00-produto.md](docs/00-produto.md) | O que é o produto, quem usa, escopo e o que fica de fora |
| [docs/01-decisoes.md](docs/01-decisoes.md) | Registro de decisões (o que foi decidido, por quê, o que foi descartado) |
| [docs/02-stack-arquitetura.md](docs/02-stack-arquitetura.md) | Stack, quem faz o quê, escala, estrutura do monorepo |
| [docs/03-fluxos.md](docs/03-fluxos.md) | Mapa do processo, workflows do n8n, amarração de mensagens, humano no grupo, SGA fora do ar |
| [docs/04-regras-negocio.md](docs/04-regras-negocio.md) | Regras R1 a R8, config por empresa, prazos, ficha da ANCORE |
| [docs/05-dados-schema.md](docs/05-dados-schema.md) | Tabelas, estados, contratos do card e do webhook do ERP |
| [docs/06-visual-ui.md](docs/06-visual-ui.md) | Padrão visual extraído do ERP (arxconnect) para os cards |
| [docs/07-pendencias.md](docs/07-pendencias.md) | Perguntas em aberto e dependências externas |
| [docs/08-roadmap.md](docs/08-roadmap.md) | Fases, do modo sombra até a autonomia |
| [empresas/_modelo.json](empresas/_modelo.json) e [empresas/ancore.json](empresas/ancore.json) | Ficha padrão de empresa e a da ANCORE |

## Resumo em 10 linhas

- Canal: **Evolution API** (WhatsApp não oficial), um número por empresa, presente em todos os grupos de equipe dela.
- Orquestração e IA: **n8n** (modo fila) com nó **AI Agent** (Claude). Sem Hermes Agent.
- Fila: **RabbitMQ**. Guarda o que chega com o SGA fora do ar e segura os picos dos dias de vencimento.
- Regras de decisão, estado e cards: app **Next.js + Drizzle** em Postgres próprio, com `packages/core` em TypeScript puro e testado.
- Fonte de dados do associado: **SGA da Hinova**, por API, credencial por empresa. Banco: Sicoob.
- Humano no loop: cards no ERP (iframe), com Assumir, Aprovar, Reprovar, Pedir mais e Devolver.
- A IA entende e escreve livre. Dinheiro e vínculo mensagem↔pedido são decididos por código.
- Meta de escala: 500 mil ativos no total das associações (~9 mil mensagens/dia nos grupos).
- Começa em servidor Linux próprio; pode migrar para VPS.
- Primeira entrega: **modo sombra** num grupo da ANCORE (lê, classifica, grava o que responderia, não envia).
