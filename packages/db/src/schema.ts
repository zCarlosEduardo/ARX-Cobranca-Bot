// Schema completo em docs/05-dados-schema.md. Aqui só o ponto de partida.
import { pgTable, bigserial, text, boolean } from "drizzle-orm/pg-core";

export const empresas = pgTable("empresas", {
  id: bigserial("id", { mode: "number" }).primaryKey(),
  slug: text("slug").notNull().unique(),
  nome: text("nome").notNull(),
  instanciaEvolution: text("instancia_evolution").notNull().unique(),
  ativo: boolean("ativo").notNull().default(true),
});
