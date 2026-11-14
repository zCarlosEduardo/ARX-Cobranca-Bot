# Visual e UI dos cards

Fonte: `C:\Users\Carlos\Documents\GitHub\arxconnect\frontend` (lido só para consulta, nada alterado lá).

## O que o ERP usa hoje

| Item | Valor |
|---|---|
| Framework | React 19 + TypeScript 6 + **Vite 8** (SPA), não Next.js |
| CSS | Tailwind CSS **4** (`@tailwindcss/vite`, sem `tailwind.config`), tokens em `src/index.css` |
| Componentes | **shadcn** estilo `base-nova` (`components.json`), baseado em `@base-ui/react`, ícones `lucide-react`, cor base `neutral`, aliases `@/components`, `@/lib/utils` |
| Fonte | **Geist Variable** (`@fontsource-variable/geist`) |
| Dados | `@tanstack/react-query` + `axios` |
| Formulários | `react-hook-form` + `zod` |
| Outros | `sonner` (toasts), `next-themes` (tema claro/escuro), `recharts`, `framer-motion`, `cmdk`, `date-fns` |
| Layout | `src/layout/` (AppLayout, Header, Sidebar), `src/components/shared/` (DataTable, ConfirmDialog, MultiSelect, PaginacaoControls) |
| Padrão de card existente | `components/chats/ChatCard.tsx` (cores por estado: verde `#28a745`, amarelo `#ffdd57`, vermelho `#d62728`, tempo `HH:MM:SS`) |

## Tokens principais (`index.css`)

- Raio base `--radius: 0.625rem`.
- Claro: `background` branco, `foreground` `oklch(0.145 0 0)`, `primary` `oklch(0.205 0 0)`, `muted-foreground` `oklch(0.556 0 0)`, `border` `oklch(0.922 0 0)`, `destructive` `oklch(0.577 0.245 27.325)`.
- Escuro: `background` `oklch(0.145 0 0)`, `card` `oklch(0.205 0 0)`, `border` `oklch(1 0 0 / 10%)`.
- Marca (sidebar): verde `#16a34a` (claro) / `#22c55e` (escuro), item ativo `#dcfce7` com texto `#166534`; sidebar escura `#0b0e14`.

## Como os cards do bot seguem esse padrão

**Recomendação:** copiar do `arxconnect/frontend` para o app dos cards o `index.css` (tokens), `components.json`, `lib/utils`, a pasta `components/ui` e o que for útil de `components/shared` (DataTable, ConfirmDialog). Assim o iframe fica visualmente idêntico ao ERP.

**Mapa de prioridade e estado (proposta, a validar com Carlos):**

| Estado | Visual |
|---|---|
| `normal` | borda neutra, badge secundário |
| `alta` | amarelo do ChatCard (`#ffdd57`, texto escuro) |
| `urgente` | vermelho do ChatCard (`#d62728`, texto branco) |
| em dia / aprovado | verde `#28a745` |
| controle `humano` | badge com nome do atendente |

**Telas previstas:**
1. Fila de cards (DataTable com filtros por empresa, prioridade, controle; contador de prazo).
2. Detalhe do card: resumo, sugestão da IA, checklist, galeria de mídia (foto/vídeo), regras que bateram, histórico da conversa, rascunho do bot não enviado, botões Assumir, Devolver (com recado), Aprovar, Reprovar (motivo), Pedir mais.
3. Config da empresa (vencimentos, lotes, prazos, horário, grupo de supervisão).
4. Regras da empresa (ordem, condição, ação, versão) e base de conhecimento.
5. Grupos e atendentes (cadastro, modo sombra/ativo).
6. Código do dia (substitui o formulário do n8n).
7. Medição: concordância IA × humano por ação.

## Ponto de decisão: Next.js ou Vite?

O ERP é Vite SPA. A decisão D05 escolheu Next.js para o app (telas + API). Isso funciona, porque Tailwind 4, shadcn e Geist rodam igual nos dois. Mas há uma alternativa que reduz atrito visual:

| Opção | Prós | Contras |
|---|---|---|
| **Next.js (telas + API)** (decidido) | Um projeto e um deploy; API e telas juntas | Copiar os componentes para outro bundler; `base-ui` e Tailwind 4 precisam de teste no Next |
| Vite SPA igual ao ERP + API Next/Nest separada | Reaproveita componentes do ERP sem adaptar | Dois projetos |

Manter Next.js, com a regra de copiar os tokens e componentes tal como estão. Reavaliar se algo não renderizar igual.

## Integração por iframe
O Next serve as telas sob um caminho dedicado e o ERP embute por iframe, passando o token assinado (ver `05-dados-schema.md`). O tema claro/escuro deve acompanhar o ERP (passar `?theme=` ou mensagem `postMessage`; a definir).

## Observação sobre o que o ERP já tem
O Django do ERP já oferece chaves de API para bots (`integracoes`, cabeçalho `X-API-Key`, com recursos liberados) e um módulo de `monitoracao` de execuções. Pode servir para o bot registrar execuções e, no futuro, publicar dados no ERP sem depender de novas rotas grandes. Para isso o colega precisa só adicionar recursos novos à lista de `RECURSOS_DISPONIVEIS`.
