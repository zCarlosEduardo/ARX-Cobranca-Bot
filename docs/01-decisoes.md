# Registro de decisões

Formato: decisão, motivo, alternativas descartadas. Data: 14/11/2026 salvo indicação.

## D01. Só n8n com AI Agent, sem Hermes Agent
- **Motivo:** Hermes é assistente pessoal (um número/sessão por perfil, lista de usuários liberados). Não tem fila, regra por empresa nem card. n8n serve melhor para 16 empresas.
- **Descartado:** Hermes Agent.

## D02. Canal: WhatsApp não oficial (Evolution API), um número por empresa
- **Motivo:** a API oficial de grupos da Meta não serve (máx. 8 participantes, entrada só por link, conta verificada; fontes de terceiros, não conferido na doc da Meta). Os grupos de equipe só funcionam com Evolution.
- **Riscos e mitigação:** ban derruba todos os grupos da empresa. Manter número reserva já pareado, o bot nunca adiciona ninguém a grupo, IP separado por instância.
- **Privado em escala (futuro):** Cloud API oficial, atrás de um adapter de canal.

## D03. Hospedagem: servidor Linux próprio, migrar para VPS conforme custo
Mínimo 4 vCPU/8 GB/200 GB; recomendado 8 vCPU/16 GB com n8n em modo fila e 2 workers.

## D04. Fila: RabbitMQ
A Evolution publica direto no RabbitMQ. Se o n8n cair, nada se perde. Fila separada `aguardando_sga` para retomada controlada.
- **Cuidado:** gatilho RabbitMQ do n8n reentrega se a execução passar de 30 min (issue n8n #9499). Nenhum fluxo espera; toda execução tem chave de idempotência.

## D05. Backend de regras e estado: Next.js + Drizzle (fora do Django)
- **Motivo:** o Django do ERP é feito por um colega lento; Carlos quer depender dele o mínimo. Regra dentro de nó Code do n8n é difícil de testar e versionar. Drizzle escreve índice único parcial, `jsonb` e advisory lock direto; Prisma só tem índice parcial em preview.
- **Condição:** regras em `packages/core`, TypeScript puro, sem importar Next nem banco, testadas com Vitest. Se precisar, muda para NestJS sem reescrever.
- **Descartado:** tudo no n8n (difícil de testar), regras no React (não roda sem navegador aberto), Django (dependência do colega), NestJS agora (exagero).
- **Aberto:** quem escreve o backend. Carlos disse "vamos pensar agorinha"; a equipe programa TypeScript "um pouco".

## D06. Divisão IA × código
- **IA:** entender a mensagem, achar placa e CPF, responder dúvidas, conferir fotos da vistoria, escrever toda resposta.
- **Código:** pode mandar boleto?, o boleto já existe (lotes)?, de qual pedido é a mensagem?, quem controla o pedido?, estado, prazos.
- O AI Agent não tem ferramenta que grave dados; só chama o Next por endpoints de decisão.

## D07. Um workflow por processo, não por empresa
`empresa_id` vem da instância da Evolution, nunca do LLM. O que varia por empresa fica em `empresa_config` e `regras_empresa`. O nome do grupo serve só para sugerir a empresa no cadastro inicial; depois vale o `group_jid`.

## D08. Fonte de dados: SGA da Hinova, por API
- Credenciais por empresa (silo), nunca compartilhadas.
- O **n8n** chama o SGA (timeout ~8 s, 2 retentativas, disjuntor, fila). O Next só calcula em cima do que recebe.
- API v2 existe (`api.hinova.com.br/api/sga/v2/`), sem documentação pública confirmada. Ver pendências.

## D09. Autorização por grupo; atendentes por número próprio
Tabela `grupos` autoriza. `participantes` é só histórico. `atendentes` (jid e lid) por empresa. Mensagem de atendente nunca vai ao agente e não entra na espera de 15 s.

## D10. Humano assume por pedido
Ordem para achar o pedido pego: botão Assumir no ERP, placa no texto, citação, menção ao consultor (1 aberto: esse; vários: os em `aguardando_humano`), senão só registra. Aprovar card não é assumir. Volta ao bot por concluir, devolver (com recado) ou **4 horas úteis** sem o humano falar. Frase do humano no chat é informação, nunca autorização; desconto e exceção só estruturados via ERP.

## D11. Amarração de mensagem ao pedido em código, antes da IA
Ordem: citação, placa no texto/legenda, placa ativa do autor (cursor 10 min), único pedido aberto do autor, pergunta. Lote de 15 s por autor+conversa. Uma pergunta por lote, lembrete aos 30 min, depois vira card. Índice único parcial por empresa+placa.

## D12. Ordem das regras (ANCORE)
R1 cancelamento, R2 novo contrato, R3 terceirizada/atraso ≥ 60, R4 boletos 2019–2021, R5 INATIVO PENDENTE, R6 atraso ≤ 5 (envia), R7 atraso 6–59 (revistoria), R8 humano. O motor avalia todas, grava `regras_batidas`, a primeira decide e o card mostra todas.

## D13. Revistoria usa o código do dia da ARX
Um só para as 16 empresas, cadastrado à mão todo dia (formulário n8n com senha, depois tela no ERP). 4 fotos 360° ou 1 vídeo 360° (até 60 s) com data e código visíveis. Hash da mídia guardado para sempre (detecta foto reaproveitada).

## D14. Prazo do card e escalonamento
Prazo conta só em horário de atendimento (seg–sex 8h–18h, feriados nacionais). No prazo: prioridade alta, alerta ao supervisor, renova. No dobro: urgente e aviso único ao consultor. Depois disso, supervisor alertado a cada prazo até alguém decidir. Nunca aprova sozinho. Prioridades: `normal`, `alta`, `urgente`.
- **Feriados:** só nacionais (sem Carnaval, Corpus Christi, estaduais ou municipais).

## D15. SGA fora do ar
Avisa uma vez, cita a mensagem, pedido fica `aguardando_sga`. Na volta, reprocessa com 2 a 3 em paralelo e confere se humano assumiu. Se durar até o fim do expediente, vira card.

## D16. Monorepo, repositório privado
Nome do projeto: **ARX-Cobranca-Bot** (escolhido por Carlos; a sugestão do Beto era `cobranca-bot`). Estrutura em `docs/02-stack-arquitetura.md`.

## D17. Mídia: guardar
Hoje não é guardada. Recomendação: hash para sempre e mídia por no mínimo 180 dias (conferir com o jurídico). Storage MinIO local ou R2.

## D18. Cards em React/Next no padrão visual do ERP, via iframe
Carlos libera leitura do repositório `arxconnect` para copiar o design system. Ver `docs/06-visual-ui.md`.
