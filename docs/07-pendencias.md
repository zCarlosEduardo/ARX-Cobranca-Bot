# Pendências e perguntas em aberto

## Bloqueia a construção
| # | Item | Quem resolve |
|---|---|---|
| 1 | **Hinova**: documentação da API v2, token de teste da ANCORE com rotas habilitadas, usuário de integração só leitura. Falta confirmar se a API devolve situação textual, dias de atraso, valor atualizado, linha digitável e PDF | Carlos pede ao suporte da Hinova |
| 2 | Quem escreve o backend (API, `core`, testes): Beto escreve e a equipe revisa, ou a equipe? | Carlos |

## Valores a confirmar
| # | Item | Estado |
|---|---|---|
| 3 | **Prazo do card:** Carlos respondeu 2 horas úteis e, num formulário reenviado depois, 4 horas úteis. A documentação assume 2 h (e o nível 2 aos 4 h). Confirmar | conflito |
| 4 | % de pedidos que caem em vistoria (mede-se no modo sombra) | pendente |
| 5 | Retenção da mídia: hoje não se guarda. Recomendado hash para sempre e mídia por 180 dias; consultar jurídico | pendente |
| 6 | Grupo pode pedir boleto de qualquer associado da empresa? Carlos acredita que sim | confirmar |
| 7 | Ficha de uma 2ª empresa (de preferência menor) | Carlos manda depois |
| 8 | `[21, 1]` e `[6, 16]` são as datas de geração dos lotes? (a regra funciona de qualquer forma) | confirmar |
| 9 | Código do dia: quem cadastra e em que horário? | definir |
| 10 | Feriados: só nacionais (decidido). Conferir a Sexta-feira Santa de 2026 e 2027 em fonte externa | conferir |
| 11 | Atendentes: lista por empresa (jid e lid) | Carlos |
| 12 | Grupo interno de supervisão (`grupo_supervisao_jid`) ou só alerta no ERP | definir |

## Técnico a validar
- Payloads reais da Evolution v2: foto, foto encaminhada, vídeo, mensagem de número fora do grupo, `fromMe` do aparelho, reação ✋, membros `@lid` (bug #2739 na v2.4.0).
- Limites da Evolution v2 para mídia no webhook; download separado.
- Teste de carga do SGA (limite de chamadas, comportamento nos dias 6, 10 e 25).
- Rota do Django que abre o iframe com token assinado; compatibilidade com JWT do ERP (access em memória, refresh em cookie httpOnly). Alternativa: login próprio do bot até lá.
- `base-ui`/shadcn base-nova e Tailwind 4 dentro do Next.js.
- Conferir termos da Meta antes de usar a API oficial no privado (política contra assistente de IA genérico; bot de cobrança é permitido).
- Haiku vs Sonnet na vistoria: testar com ~20 vistorias reais.

## Riscos
1. Ban do número de uma empresa derruba todos os grupos dela. Número reserva obrigatório.
2. SGA instável ou com limite desconhecido.
3. Equipe humana vira gargalo se a % de vistoria for alta.
4. Dependência do colega do Django limitada à rota do iframe.
5. A mídia não guardada hoje pode ser prova em disputa de sinistro.
