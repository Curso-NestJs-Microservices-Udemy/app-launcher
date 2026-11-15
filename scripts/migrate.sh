#!/usr/bin/env bash
# ==============================================================================
# Aplica las migraciones de Prisma y el seed de productos.
#
#   ./scripts/migrate.sh
#
# Cuando hay que correrlo:
#
#   - La primera vez que se levanta el stack (base recien creada).
#   - Cada vez que se crea una migracion nueva (la que genera `prisma migrate
#     dev` en el host ya viene aplicada; esta es para las que se crean de otra
#     forma, o para el seed).
#   - Cuando la API responde "relation \"Order\" does not exist".
#
# NO hay que correrlo en cada arranque: `prisma migrate deploy` es idempotente
# (si no hay migraciones pendientes, no hace nada).
#
# Usa `docker compose run` con la imagen de DESARROLLO (que tiene el CLI de
# Prisma como devDependency) sobre containers de un solo uso: asi las imagenes
# de produccion no necesitan llevar el CLI encima.
# ==============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> Migraciones de orders-ms (PostgreSQL)"
docker compose run --rm --no-deps orders-ms pnpm exec prisma migrate deploy

echo "==> Migraciones de products-ms (SQLite)"
docker compose run --rm --no-deps products-ms pnpm exec prisma migrate deploy

echo "==> Seed de productos (idempotente: INSERT OR IGNORE)"
docker compose run --rm --no-deps products-ms sh -c \
  "sed 's/^INSERT INTO/INSERT OR IGNORE INTO/' data/products.sql > /tmp/seed.sql && pnpm exec prisma db execute --file /tmp/seed.sql"

echo "==> Listo"
