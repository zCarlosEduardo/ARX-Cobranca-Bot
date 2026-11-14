# Fluxos

## Mapa do processo

```
CONSULTOR no grupo "Equipe X"
   ▼
EVOLUTION (1 número por empresa)  ─ webhook/RabbitMQ
   ▼
[1] ENTRADA: dedupe · empresa = instância · grupo cadastrado? (senão ignora)
    quem falou?  bot → ignora · ATENDENTE → [H] · membro → segue
    junta mensagens do mesmo autor por 15 s
   ▼
[2] AMARRAÇÃO (código): citação → placa → placa ativa → único aberto → pergunta
    pedido em controle humano? → só registra
   ▼
[3] AGENTE (IA): {intencao, placa, cpf, observacao}
    dúvida → base de conhecimento · assunto_humano → card "encaminhado"
   ▼
[4] MOTOR DE REGRAS (SGA + R1..R8)
   ├ R6 em dia ─────────► [5a] 2ª via → [7]
   ├ R7 vistoria ───────► [5b] código do dia → mídia → hash → checklist IA → CARD
   └ demais ────────────► humano / não emite / resposta com motivo
[6] ERP: card → retorno assinado: aprovar → [5a] · reprovar → [7] · pedir_mais → aguardando_mídia
[7] SAÍDA: recheca controle → cita msg original + placa → fila → Evolution
[8] AGENDADOR: código vencido · lembretes · card fora do prazo · devolução por inatividade
[9] MEDIÇÃO: sugestão da IA × decisão humana → sobe autonomia por ação
[H] atendente: marca o pedido pego como HUMANO (nunca passa pela IA)
```

## Máquina de estados do pedido

`recebida → identificando → consultando → aguardando_midia → aguardando_humano → enviando → concluida | expirada | reprovada`
Mais `aguardando_sga` quando o SGA está fora. Cada transição só acontece se o estado anterior for o esperado (`UPDATE ... WHERE estado = 'X'`), o que protege contra webhook repetido e prazo vencendo durante resposta do ERP. Trava otimista por `versao`.

## Amarração de mensagens (detalhe)

- **Escopo:** conversa + autor. A foto do consultor A não cai no pedido do B.
- **Lote:** espera 15 s sem mensagem nova do mesmo autor; ordena por `messageTimestamp`.
- **Regras em ordem:**
  1. Citação de mensagem ligada a pedido. Pedido concluído → abre novo ligado ao anterior (`solicitacao_anterior_id`). Citação e texto com placas diferentes → pergunta.
  2. Placa no texto ou legenda (1 só). Várias placas → um pedido para cada, cursor vazio.
  3. Placa ativa do autor (cursor, 10 min).
  4. Único pedido aberto do autor esperando mídia.
  5. Senão, pergunta numerada. Uma por lote. Lembrete aos 30 min; depois vira card.
- **Perguntar:** mais de uma candidata sem sinal; citação e texto divergem; quem manda não é quem abriu; placa inexistente no cadastro. **Não perguntar** com uma candidata só.
- **Regra de saída:** toda mensagem do bot sobre um pedido cita a mensagem original, traz placa e nome do associado, e salva o `wa_message_id` com o `solicitacao_id`. É isso que faz a citação funcionar.
- **Quebras e prevenções:**

| Quebra | Prevenção |
|---|---|
| Rajada abre 2 pedidos | `pg_advisory_xact_lock(hashtext(chat_jid))` + índice único parcial |
| Webhook duplicado | `UNIQUE(instancia, wa_message_id)` + `ON CONFLICT DO NOTHING` |
| Fora de ordem | Ordenar por timestamp |
| Legenda só na 1ª foto | Placa de qualquer mídia do lote vale para o lote (se for uma só) |
| `@s.whatsapp.net` e `@lid` do mesmo consultor | Guardar as duas formas |
| Mídia depois de ir ao humano | Anexa ao mesmo pedido, card marca "mídia nova após envio" |
| n8n reinicia | Estado só no Postgres; lote `processada=false` é retomado |
| Memória do agente mistura placas | Memória curta; contexto do pedido vem do banco |

- **Privado (futuro):** mesma regra; placa sai do cadastro ligado ao telefone; só fala de placas daquele número.

## Humano no grupo

- Candidatos: só pedidos abertos da conversa. Ordem: botão Assumir (ERP) → placa no texto → citação (todos os pedidos abertos pela mensagem citada) → menção ao consultor → nenhum (só registra).
- Interface: `pedido_pego(empresa_id, chat_jid, atendente_jid, msg{wa_id, quoted_wa_id, mentions[], texto, ts}) -> {solicitacao_ids, motivo}`.
- **Disputa no tempo:** espera de 15 s aberta: lote fecha normalmente, agente não é chamado para pedidos em humano. Agente rodando: termina, a saída barra. Resposta na fila: saída descarta (`descartada_humano`) e o texto aparece no card como rascunho. Já enviada: só registra evento.
- **Saída transacional:** `SELECT controle ... FOR UPDATE`; se humano, descarta; senão marca `enviando`.
- Uma mensagem de decisão por pedido.
- **Volta ao bot:** concluir, "Devolver ao bot" (recado opcional) ou 4 h úteis sem o humano falar, em silêncio. O bot só fala se a última mensagem for do consultor e estiver sem resposta, e roda o motor de novo. Atendente desativado devolve na hora.
- **Mensagem do consultor com pedido em humano:** salva e amarra, bot não fala no grupo, trabalho de bastidor continua (checklist, SGA), selo e contador no card. 30 min sem resposta → prioridade alta + alerta.
- **Contexto na volta:** mensagens do atendente entram no histórico marcadas; nota de passagem (recado ou resumo curto de IA).
- **Alguém usando o aparelho do bot:** `fromMe=true` com id que o bot não enviou = humano (`bot_aparelho`). Precisa de payload real para confirmar.
- Atalho com reação ✋: a validar com a Evolution; se o evento não vier, não faz falta (o botão do ERP é o sinal principal).

## SGA fora do ar

1. Toda chamada com timeout (~8 s) e até 2 retentativas.
2. **Disjuntor:** após falhas seguidas, marca SGA fora e ninguém mais chama; um fluxo testa a cada minuto.
3. Bot responde **uma vez**: "O sistema da associação está instável agora. Seu pedido #482 (ABC1D23) ficou na fila e eu respondo aqui assim que ele voltar."
4. Na volta, 2 a 3 em paralelo, conferindo se humano já assumiu.
5. Se durar até o fim do expediente, vira card.

## Código do dia

```
Equipe (manhã) ─► Formulário n8n (senha) ─► tabela codigo_dia
08:00 dia útil: não tem código de hoje? ─► alerta único ao supervisor
Revistoria chega sem código ─► recebe mesmo assim; card: "conferir manualmente"
```

## Validação da mídia (checklist da IA)
Data legível e igual a hoje, código igual ao do dia, 4 fotos 360° ou vídeo 360° (até 60 s), placa, danos, mídia encaminhada, hash repetido. O humano confere estado do veículo, código, conservação e se há dano ou edição por IA.

## Pontos a testar com payload real da Evolution
Foto, foto encaminhada, vídeo e mensagem de número não cadastrado. A mídia é baixada em chamada separada (relato de bug com base64 no webhook).
