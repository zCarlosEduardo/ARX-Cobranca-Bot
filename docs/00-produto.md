# Produto

## Problema

A ARX é uma administradora que cuida de 16 associações/cooperativas de proteção veicular. A maior (ANCORE) tem ~33 mil ativos e ~20 grupos de WhatsApp de equipes de consultores. Hoje os consultores pedem boleto e vistoria nesses grupos e a equipe da administradora responde na mão. Isso não escala e a mídia da vistoria fica só no grupo.

## Quem usa

| Papel | Quem é | O que faz |
|---|---|---|
| **Consultor** | Membro de um grupo de equipe cadastrado | Pede 2ª via de boleto e manda mídia da vistoria. **Não é o devedor.** |
| **Atendente** | Equipe da administradora, com número próprio | Responde no grupo, assume pedidos, decide cards no ERP |
| **Supervisor** | Chefia da equipe | Recebe alertas de prazo vencido |
| **Associado** | O devedor | Fase futura: fala no privado |

Autorização é **por grupo cadastrado**: quem está no grupo pode pedir, a princípio, boleto de qualquer associado da empresa (Carlos ainda não confirmou). Cadastro de consultor por número foi descartado por ser inviável.

## O que o bot faz (escopo)

1. **2ª via de boleto** de associado em dia (até o 5º dia após o vencimento).
2. **Vistoria** do inadimplente (6º ao 59º dia): pede mídia, confere data e código do dia, monta o checklist, cria card para um humano aprovar. Só depois envia o boleto.
3. **Dúvidas** (contatos, apps, site, dentista, rastreador) respondidas da base de conhecimento da empresa.
4. **Encaminhar a humano** o que é cancelamento, troca de placa/titularidade, fidelidade, retenção e qualquer caso fora das regras.
5. **SGA fora do ar**: avisa uma vez que o sistema está instável, põe o pedido em fila e responde quando voltar.

## O que fica de fora

- Desconto, régua de retenção e qualquer valor monetário decidido pela IA. Desconto só vale se vier estruturado do ERP.
- Cálculo de juros pelo bot (vem do SGA; só usa 2% + 0,033%/dia se o SGA não devolver o valor atualizado).
- Aprovar vistoria sozinho. A autonomia sobe por ação e por empresa, só com concordância medida acima de ~95% entre IA e humano.
- Atendimento no privado e régua proativa (fases futuras).

## Princípios

1. **A IA entende e escreve, o código decide.** Resposta nunca é texto engessado, mas "posso mandar o boleto?" e "de qual pedido é esta foto?" têm resposta determinística e testada.
2. **Controle humano é por pedido, nunca por grupo.** Se três consultores pedem e o atendente pega um, o bot segue nos outros dois.
3. **Empresa nova é configuração, não fluxo novo.** Uma ficha JSON + regras em tabela.
4. **Nenhum fluxo fica esperando horas.** Estado fica no Postgres; retomada é nova execução.
5. **Mídia de vistoria nunca é rejeitada** por falta de código do dia; o card avisa "conferir manualmente".

## Números de referência

- 16 empresas, 100 a 600 mensagens/dia cada, ~8 mil/dia no total hoje.
- Meta: 500 mil ativos somados (~9 mil mensagens/dia nos grupos; +20 a 50 mil se o privado entrar).
- Pico nos dias 6, 10 e 25: 5 a 10x a média.
- Custo estimado de IA: R$ 1,9 mil a R$ 4,3 mil/mês com vistoria em Sonnet (5% a 20% de vistorias). R$ 1,2 a 1,3 mil se Haiku também servir na vistoria (testar em ~20 vistorias reais). Falta medir a % real.
