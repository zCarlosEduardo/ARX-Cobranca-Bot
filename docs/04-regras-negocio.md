# Regras de negócio

Fonte: ficha da ANCORE enviada por Carlos. As outras 15 empresas ainda não mandaram a ficha; o que diferir vira campo de config, o que for igual vai para o núcleo.

## Motor de regras (ANCORE)

Avalia todas, grava `regras_batidas`, a primeira que bate decide, o card mostra todas.

| Ordem | Regra | Condição | Ação |
|---|---|---|---|
| 1 | R1 | Situação EM CANCELAMENTO | humano (retenção) |
| 2 | R2 | Inadimplente > 6 meses ou inativo > 30 dias | não emite ("novo contrato") + humano |
| 3 | R3 | SUSPENSO TERCEIRIZADA ou atraso ≥ 60 dias | não emite (Innovare) + humano |
| 4 | R4 | Boleto aberto com vencimento 2019–2021 | humano (protesto, carta de anuência) |
| 5 | R5 | INATIVO PENDENTE | humano (débito de cancelamento) |
| 6 | R6 | Atraso ≤ 5 dias | envia boleto (ATIVO PENDENTE avisa a pendência) |
| 7 | R7 | Atraso de 6 a 59 dias | revistoria |
| 8 | R8 | Nada bateu | humano |

- **Atraso** conta a partir do vencimento **efetivo** (transferido para dia útil). Teste: venc. sáb 14/11/2026 → efetivo seg 16/11; dia 21/11 = 5 dias (R6), dia 22/11 = 6 (R7).
- **Inadimplente** só a partir do 6º dia. Até o 5º paga sem revistoria.
- **Lotes de boleto:** vencimento 10 → lotes dia 21 (do mês anterior) e dia 1; vencimento 25 → dias 6 e 16. Boleto do próximo vencimento ainda inexistente e lote futuro → "ainda não foi gerado, sai no dia X". Datas dos lotes já passaram e não há boleto → humano ("boleto não encontrado após geração do lote").
- **Juros:** o bot não calcula; valor atualizado vem do SGA. Fallback: multa 2% + mora 0,033%/dia.
- **Mensagens de recusa:** nunca texto fixo; a regra devolve `{acao, motivo}` e a IA redige.

## Ficha da empresa (`empresas/ancore.json`)
Ver o arquivo. Campos: vencimentos [10, 25], vencimento em dia útil, lotes, `inadimplente_apos_dias`, terceirizada (Innovare, 60 dias), novo contrato, juros, formas de pagamento, revistoria, prazos e horário.

## Situações do SGA
ATIVO, ATIVO PENDENTE, INADIMPLENTE (passou de 5 dias), EM CANCELAMENTO, INATIVO PENDENTE, INATIVO, SUSPENSO TERCEIRIZADA.

## Revistoria
4 fotos do veículo 360° ou vídeo 360° (até 60 s) com **data** e **código do dia** (https://codigododia.arxadm.com.br/). Código único para as 16 empresas, cadastrado manualmente. Humano confere estado, código, conservação e ausência de dano/edição por IA.

## Prazos e atendimento
- Horário: seg a sex, 08:00–18:00, só feriados nacionais.
- Prazo do card, alerta e escalonamento: ver D14. Valor do prazo **a confirmar** (2 h úteis ou 4 h úteis, ver pendências).
- Humano sem falar no pedido: volta ao bot em **4 horas úteis** (`humano_inatividade_min_uteis = 240`).
- Teste: última fala do atendente sex 27/11/2026 16:00 → volta seg 30/11 10:00.
- Escalonamento: nível 1 alta + alerta supervisor + renova; nível 2 urgente + aviso único ao consultor; depois alerta ao supervisor a cada prazo, contando em `alertas_supervisor`.
- Testes do prazo (120 min, seg–sex 8–18): seg 17:30 → ter 09:30; sex 17:30 → seg 09:30; sáb 10:00 → seg 10:00; seg 07:00 → seg 10:00; seg 16:00 → seg 18:00; qui 19/11/2026 17:30 → seg 23/11 09:30 (20/11 é feriado).
- Um subworkflow/função `prazo_util(inicio, minutos, horario_atendimento)` serve ao prazo do card e à devolução.

## Fora da IA (procedimento humano)
Cancelamento, troca de placa, troca de titularidade, fidelidade, régua de retenção (descontos e produtos). A IA reconhece o assunto (`assunto_humano`) e encaminha. **Desconto nunca sai da IA**: o prompt proíbe e há checagem em código antes de enviar.

## Base de conhecimento (a IA consulta só para dúvidas)
Contatos e assistência 24h, apps (ANCORE, ClubGás), site, Clube Certo, benefício dentista, rastreadores e regra de instalação obrigatória, formas de pagamento, chats (Mundiale permite disparo; EZChat não).

## Regras operacionais gerais
- Número que não é de grupo cadastrado: bot calado, só registra.
- Limite diário e proteção contra manipulação ("ignore as regras") são casos de teste obrigatórios.
- Boleto de outra empresa nunca é emitido (empresa vem da instância).
- Permitido utilizar números ARX para contato.
