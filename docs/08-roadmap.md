# Roadmap

| Fase | Entra | Para quê | Saída esperada |
|---|---|---|---|
| **0. Infra e esqueleto** | Repo, `compose.dev.yml` (Postgres, RabbitMQ, n8n, Redis, MinIO, Evolution), `packages/db`, teste do `core` (vencimento no sábado) | Provar que a base sobe | Serviços saudáveis, teste verde |
| **1. Modo sombra** (1 a 2 semanas) | Bot em 1 ou 2 grupos da ANCORE: lê, amarra, classifica, roda o motor e grava `respostas_sombra`. Não envia nada | Medir volume e % de vistoria; ver como a equipe responde hoje; gerar payloads reais | Números reais e base de testes |
| **2. Segunda via em dia** | Responde sozinho (R6) nesses grupos, com tratamento de SGA fora já funcionando. Exige token da Hinova | Caso mais comum e de menor risco | MVP: 1 empresa, 1 regra, 3 testes |
| **3. Vistoria + cards** | Código do dia, mídia, hash, checklist da IA, cards no ERP, Assumir/Devolver | Human-in-the-loop | Fila de cards funcionando |
| **4. Escalar** | Os ~20 grupos da ANCORE, depois as outras empresas, uma por vez (uma linha de config + ficha) | Cobrir as 16 empresas | Empresa nova sem retrabalho |
| **5. Privado** | Associado fala direto, com checagem de identidade; Cloud API oficial se em escala | Segundo canal | Mesmo núcleo |
| **6. Autonomia** | Sobe o nível por ação e por empresa quando a concordância IA × humano passar de ~95% | Reduzir carga humana | Medição contínua |

## MVP mínimo
Uma empresa (ANCORE), um grupo, 2ª via de associado em dia, SGA simulado. Casos de teste: consultor sem grupo cadastrado, número desconhecido, tentativa de manipular o bot ("ignore as regras"), boleto de outra empresa, limite diário.

## Primeiros passos práticos
1. Carlos pede o acesso à API da Hinova.
2. Decidir quem escreve o backend.
3. Criar o esqueleto do monorepo e subir `compose.dev.yml`.
4. Parear um número de teste na Evolution, entrar num grupo de teste e capturar os 4 payloads (foto, encaminhada, vídeo, número estranho).
5. Ligar o modo sombra num grupo real da ANCORE.
