# ARX Cobrança Bot: resumo de uma página

## O que é
Bot de WhatsApp pra cobrança das 16 associações de proteção veicular (maior: ANCORE, ~33 mil ativos). Meta: 500 mil ativos no total. Começa nos grupos de consultores e depois vai pro privado do associado.

Casos principais: 2ª via de boleto, e inadimplente que precisa de revistoria (foto/vídeo 360° com o código do dia) aprovada por um humano antes de receber o boleto.

## Como funciona
1. Consultor pede no grupo. A IA entende, acha a placa e escreve a resposta livre (sem texto engessado).
2. O sistema consulta o SGA da Hinova e aplica as regras R1 a R8, que decidem se manda boleto, pede revistoria ou chama humano. A IA não muda essa decisão.
3. Revistoria vira um card na tela do Connect: resumo + sugestão da IA. O humano confere veículo, código do dia, conservação e se não há dano ou edição, e aprova ou reprova.
4. Humano que responde no grupo pausa o bot só naquele pedido.
5. Se o SGA cair, o bot avisa que está instável, põe o pedido numa fila e responde quando voltar.

## Stack decidida
- Evolution API (um número por empresa, em todos os grupos dela). WhatsApp não oficial.
- RabbitMQ (filas), n8n com AI Agent (orquestração), Claude (IA).
- Next.js + Drizzle + Postgres: regras (`packages/core`, com testes), estado e cards.
- Cards em React, dentro do Connect via iframe, com o visual do `arxconnect`.
- Redis e RustFS (S3) pra mídias. Servidor Linux próprio, VPS depois.
- Sem Hermes Agent.
- Do Django (colega) só falta: um módulo novo `cobranca` no menu e uma rota que abre o iframe com token do usuário logado.

## Regras e prazos fechados
- ANCORE: até o 5º dia de atraso paga sem revistoria; a partir do 6º exige.
- R1 cancelamento, R2 novo contrato, R3 terceirizada ou atraso >= 60, R4 boletos 2019-2021, R5 INATIVO PENDENTE, R6 atraso <= 5, R7 atraso 6 a 59, R8 humano.
- Atendimento seg a sex, 8h às 18h. Só feriados nacionais.
- Devolução ao bot: 4 horas úteis sem o atendente falar no pedido.
- Prazo do card de revistoria: ver "Pendências".
- Prioridades: normal, alta, urgente. Urgente alerta o supervisor a cada 2 h úteis; o consultor é avisado uma vez.
- O código do dia é um só pras 16 empresas e é cadastrado todo dia.

## Pendências (precisam de resposta)
1. Prazo do card: foram dadas respostas de 2 e de 4 horas úteis. A última foi 4 h; os docs ainda dizem 2 h. Confirmar.
2. Token e documentação da API da Hinova (SGA).
3. Retenção das mídias (180 dias?) e parecer jurídico.
4. Limite de duração do vídeo (proposta: 60 s).
5. Qualquer associado da empresa pode ser consultado por qualquer grupo?
6. Quantas vistorias por dia (total e por empresa).
7. Quem escreve o backend (API, regras e testes).
8. Ficha de uma segunda empresa menor.

## Onde ver
- Visual: `docs/mockups/mockup-interativo.html` (abrir no navegador).
- Detalhes: `docs/00-produto.md` a `docs/08-roadmap.md`. Os mais úteis: `01-decisoes`, `03-fluxos`, `04-regras-negocio`.
- Stack local: `npm run up` sobe tudo (infra/compose.dev.yml).

## Ordem de construção
Subir a infra, depois modo sombra num grupo da ANCORE (só lê e registra o que responderia), 2ª via, revistoria com card, e uma empresa nova por vez.
