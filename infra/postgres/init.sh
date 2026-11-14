#!/bin/bash
# Roda uma vez, na primeira subida do Postgres: cria um banco por serviço.
set -e
for db in "$BOT_DB" "$N8N_DB" "$EVOLUTION_DB"; do
  psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres -c "CREATE DATABASE \"$db\""
done
