# AGENTS.md

Repo launcher de un curso de microservicios NestJS: cuatro apps en submodules git y el stack de Docker Compose en la raíz. La raíz no tiene código de aplicación ni `package.json`; el trabajo acá es Compose, Dockerfiles y scripts.

## Estructura y propiedad del código

| Path | Qué es |
|---|---|
| `client-gateway/` | API HTTP pública (`:3000`, prefijo `/api`) que habla por NATS |
| `orders-ms/` | Microservicio NATS sin HTTP + Prisma/PostgreSQL; también llama a products-ms por NATS |
| `products-ms/` | Microservicio NATS sin HTTP + Prisma/SQLite |
| `payments-ms/` | API HTTP (`:3003`) + Stripe; no usa NATS ni base de datos |
| `docker-compose.yaml` / `docker-compose.prod.yaml` | Stacks de desarrollo y producción |
| `scripts/migrate.sh` | Migraciones Prisma y seed de productos |

- Cada app es un repo git propio. Cuando corresponda commitear, primero se commitea y pushea el submodule y después la raíz; al revés se pierden o pisan las referencias.
- El `README.md` raíz es el manual de operación detallado (Docker, Prisma, NATS y troubleshooting), pero documenta solo los tres servicios originales: no incluye payments-ms.
- `orders-ms/AGENTS.md` contiene las particularidades de ese servicio.

## Comandos

Todo el desarrollo corre en Docker; el host no tiene `node_modules` instalados.

- `docker compose up -d --build` — stack de desarrollo, target `development` y hot-reload.
- `docker compose up -d --build <servicio>` — rebuild y reinicio de un solo servicio.
- `docker compose -f docker-compose.prod.yaml up -d --build` — stack de producción, target `production`. Comparte `container_name` y puertos con el de desarrollo: no pueden correr juntos.
- `./scripts/migrate.sh` — migraciones de orders-ms y products-ms más el seed. Obligatorio con una base recién creada; idempotente, no hace falta en cada arranque.
- `docker compose logs -f <servicio>` y `docker compose exec <servicio> bash`.
- `COMPOSE_PARALLEL_LIMIT=1 docker compose build` — usar si los builds paralelos mueren con exit 137 por falta de RAM.
- `docker compose down` conserva los datos; `docker compose down -v` borra también los volúmenes.

## Gotchas que rompen el stack

- **`payments-ms/.env` tiene que existir en el host.** El Compose raíz lo carga con `env_file:` y falla por completo si el archivo no existe. Crearlo desde `payments-ms/.env.template` y completar Stripe. Está gitignored: no commitear las claves ni copiarlas al YAML.
- **Cada `package.json` necesita `"packageManager": "pnpm@11.23.0+sha512..."`.** Los Dockerfiles usan `corepack enable pnpm`; sin ese campo Corepack puede resolver otra versión y `pnpm install --frozen-lockfile` falla contra el lockfile de pnpm 11.
- **`pnpm-workspace.yaml` se copia antes de instalar.** Ahí vive `allowBuilds` (pnpm 10+); sin ese archivo pnpm bloquea postinstalls como `@parcel/watcher`, `prisma` y `better-sqlite3`.
- **`target:` en `build:` es obligatorio.** Sin él, Compose construye la última etapa del Dockerfile (`production`) y no hay hot-reload.
- **Las migraciones no se aplican al arrancar.** Sin `./scripts/migrate.sh`, las tablas no existen y aparece `relation "Order" does not exist`; la app no necesariamente se cae, falla el request.
- **Solo se monta `./<servicio>/src`.** `node_modules` no se monta porque los symlinks de pnpm quedarían rotos. Cambios en `package.json`, lockfile, `tsconfig.json` o `prisma/schema.prisma` requieren rebuild.
- **`procps` es necesario en la etapa `deps`.** Aporta `ps`, que usa tree-kill del Nest CLI; sin él queda el proceso viejo con el puerto tomado, aparece `EADDRINUSE` y el hot-reload no recarga.
- **`openssl` solo corresponde a `base-prisma`** de orders-ms y products-ms. client-gateway y payments-ms no usan Prisma.
- **El entrypoint compilado cambia según el servicio:** orders-ms y products-ms generan `dist/src/main.js` porque compilan también el `prisma7.config.ts` de la raíz; client-gateway y payments-ms generan `dist/main.js`. Por eso `pnpm start:prod` (`node dist/main`) está roto en orders-ms y products-ms.
- Dentro de los containers se usan nombres de servicio (`nats`, `orders-db`), no `localhost`. Las variables de `environment:` tienen prioridad sobre los `.env` locales; dotenv no pisa variables ya definidas.
- `docker-compose.prod.yaml` todavía no incluye payments-ms.

## Contratos entre servicios

- En NATS, products-ms usa objetos `{ cmd: '...' }` y orders-ms usa strings planos (`createOrder`, `findAllOrders`, `findOneOrder`, `changeOrderStatus`). No unificar los estilos: son contratos distintos.
- Existe el typo vigente `{ cmd: 'crete_product' }` tanto en el gateway como en products-ms. No corregirlo de un solo lado.
- orders-ms llama a products-ms con `{ cmd: 'validate_ids_products' }` al validar productos de una orden; products-ms debe estar disponible para ese flujo.
- El gateway usa `app.setGlobalPrefix('api')`: las rutas públicas son `/api/products` y `/api/orders`.
- payments-ms valida con Joi `PORT`, `STRIPE_SECRET`, `STRIPE_WEBHOOK_SECRET`, `STRIPE_SUCCESS_URL` y `STRIPE_CANCEL_URL`; sin alguna, tira `Config validation error` al bootear.

## Tests y lint

- No hay tests unitarios reales en los servicios: `pnpm test` termina con "no tests found".
- Los `test/app.e2e-spec.ts` son boilerplate de Nest, no una suite fiable; en orders-ms y products-ms además esperan una app HTTP que esos servicios no tienen.
- `pnpm lint` ejecuta ESLint con `--fix` y aplica Prettier (single quotes y trailing commas).
- Para ejecutar comandos Node/pnpm usar el container de desarrollo, por ejemplo `docker compose exec orders-ms pnpm lint`.

## Prisma

- Prisma 7 con driver adapter. La configuración está en `prisma7.config.ts`, no en el schema, y el cliente se genera en `generated/prisma` (gitignored).
- Después de cambiar `prisma/schema.prisma`, ejecutar `pnpm exec prisma generate`; sin el cliente generado el código no compila.
- `DATABASE_URL` la consumen `prisma7.config.ts` y el `ConfigService`; el bloque `datasource` del schema no lleva URL.
- Hay skills de Prisma 7 en `orders-ms/.agents/skills` (`prisma-client-api`, `prisma-upgrade-v7`, `prisma-driver-adapter-implementation`, etc.): cargarlas antes de tocar código Prisma.
- El seed de products-ms usa `data/products.sql` transformado a `INSERT OR IGNORE` por `scripts/migrate.sh`.
