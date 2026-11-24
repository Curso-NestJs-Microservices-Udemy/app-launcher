# Trabajar con git submodules

### Pasos para crear los Git Submodules

1. Crear un nuevo repositorio en GitHub
2. Clonar el repositorio en la máquina local
3. Añadir el submodule, donde `repository_url` es la url del repositorio y `directory_name` es el nombre de la carpeta donde quieres que se guarde el sub-módulo (no debe de existir en el proyecto)
```
git submodule add <repository_url> <directory_name>
```
4. Añadir los cambios al repositorio (git add, git commit, git push)
Ej:
```
git add .
git commit -m "Add submodule"
git push
```
5. Inicializar y actualizar Sub-módulos, cuando alguien clona el repositorio por primera vez, debe de ejecutar el siguiente comando para inicializar y actualizar los sub-módulos
```
git submodule update --init --recursive
```
6. Para actualizar las referencias de los sub-módulos
```
git submodule update --remote
```


## Importante
Si se trabaja en el repositorio que tiene los sub-módulos, **primero actualizar y hacer push** en el sub-módulo y **después** en el repositorio principal. 

Si se hace al revés, se perderán las referencias de los sub-módulos en el repositorio principal y tendremos que resolver conflictos.

# NestJS Microservicios — stack completo en Docker

Levantamiento de los tres servicios del proyecto (`client-gateway`, `orders-ms`,
`products-ms`) junto con su infraestructura (PostgreSQL y NATS) con un único
comando de Docker Compose.

Cada sub-proyecto tiene su propio README con el flujo de desarrollo en el host:

- [`client-gateway/README.md`](./client-gateway/README.md)
- [`orders-ms/README.md`](./orders-ms/README.md)
- [`products-ms/README.md`](./products-ms/README.md)

## Arquitectura

```
                          ┌──────────────────┐
   HTTP  :3000  ─────────▶ │  client-gateway  │  (NestJS HTTP → NATS)
   /api/products          └────────┬─────────┘
   /api/orders                      │
                                    │ NATS  nats://nats:4222
                    ┌───────────────┴───────────────┐
                    ▼                               ▼
         ┌────────────────────┐          ┌────────────────────┐
         │     orders-ms      │          │    products-ms     │
         │  (microservicio    │          │  (microservicio    │
         │   sin HTTP, NATS)  │          │   sin HTTP, NATS)  │
         └─────────┬──────────┘          └─────────┬──────────┘
                   │ Prisma (TCP 5432)             │ Prisma (SQLite)
                   ▼                                ▼
         ┌────────────────────┐          ┌────────────────────┐
         │     orders-db      │          │   products-data    │
         │  postgres:16.2     │          │  (named volume)    │
         └────────────────────┘          └────────────────────┘
```

| Servicio         | Imagen / build             | Puertos publicados                      | Volumen de datos                                     |
|------------------|----------------------------|-----------------------------------------|------------------------------------------------------|
| `nats`           | `nats:2.10-alpine`         | `4222` (NATS), `8222` (monitoring)      | `nats-data` (`/data`)                                |
| `orders-db`      | `postgres:16.2`            | `5432`                                  | `orders-db-data` (`/var/lib/postgresql/data`)        |
| `orders-ms`      | build `./orders-ms`        | — (no expone HTTP)                      | —                                                    |
| `products-ms`    | build `./products-ms`      | — (no expone HTTP)                      | `products-data` (`/data`)                            |
| `client-gateway` | build `./client-gateway`   | `3000`                                  | —                                                    |

El `docker-compose.yaml` de la raíz está comentado línea por línea: cada
servicio explica qué hace y por qué está configurado como está.

## Requisitos

- Docker Engine 24+ con Compose v2 (`docker compose version`).
- No hace falta Node ni pnpm en el host: las imágenes instalan sus dependencias.

## Dev
1. Clonar el repositorio
2. Ejecutar el comando `git submodule update --init --recursive` para reconstruir los submodulos.
3. Ejecutar en bash
```
docker compose up -d --build
```

## Ver logs de de los containers de los ms
```
docker compose logs -f products-ms
docker compose logs -f orders-ms
docker compose logs -f client-gateway
```


Después:

```bash
curl http://localhost:3000/api/products
curl http://localhost:3000/api/orders
```

> **La primera vez hay que aplicar las migraciones** (la base arranca vacía):
>
> ```bash
> ./scripts/migrate.sh
> ```
>
> Ver [Migraciones](#migraciones) para saber cuándo hay que correrlo.

Corto todo (conservando datos):

```bash
docker compose down
```

Corto todo **borrando** los datos (PostgreSQL, SQLite y JetStream):

```bash
docker compose down -v
```

## Migraciones

Las migraciones de Prisma **no** se aplican solas al arrancar: las corrés a
mano con un script que usa la imagen de **desarrollo** (que tiene el CLI de
Prisma) sobre containers de un solo uso. Así las imágenes de producción no
necesitan llevar el CLI encima.

```bash
./scripts/migrate.sh
```

| Cuándo correrlo | Por qué |
|-----------------|---------|
| La primera vez que levantás el stack (base recién creada) | el historial de migraciones (4 en orders-ms, 3 en products-ms) tiene que aplicarse; sin esto no existen las tablas |
| Después de crear una migración nueva | si la creaste con `prisma migrate dev` en el host, esa ya está aplicada; el script sirve para las demás y para el seed |
| Cuando ves `relation "Order" does not exist` | faltan migraciones |
| ~~En cada arranque~~ | **no hace falta**: `prisma migrate deploy` es idempotente (si no hay migraciones pendientes, no hace nada) |

El script también aplica el **seed de productos** (`data/products.sql`, con
`INSERT OR IGNORE` para que sea idempotente).

Ojo: la app **no se cae** si faltan las tablas (Prisma solo hace el `$connect`);
el error aparece en el primer request a `/api/orders`.

## Imágenes multi-stage

Cada proyecto tiene **un solo Dockerfile** con etapas nombradas, de las que salen
las dos imágenes:

```
                     ┌─────────────────────────────────────────────┐
                     │ base          node:24-bookworm-slim         │
                     │               corepack enable pnpm          │
                     └───────┬──────────────────────┬──────────────┘
                             │                      │
                   ┌─────────▼──────────┐   ┌───────▼────────┐
                   │ deps               │   │ base-prisma    │
                   │  + apt (procps)    │   │  + apt(openssl)│
                   │  + pnpm install    │   │  (solo ms)     │
                   │    (con devDeps)   │   └───────┬────────┘
                   └──┬──────────────┬──┘           │
          ┌─────────▼──────┐  ┌────▼──────────┐    │
          │ builder        │  │ development   │    │  ← target del compose de dev
          │  generate      │  │  generate     │    │     (hot-reload)
          │  pnpm build    │  │  CMD start:dev│    │
          └───┬─────────┬──┘  └───────────────┘    │
              │         │                          │
              │  ┌──────▼──────────────────────────▼──────┐
              │  │ production                            │
              │  │  pnpm install --prod                  │
              │  │  COPY --from=builder dist             │
              │  │  CMD node dist/**/main.js              │ ← target del compose prod
              │  └────────────────────────────────────────┘
              └──┘
```

| Etapa | Qué tiene | Para qué |
|-------|-----------|----------|
| `base` | node + corepack (pnpm) | base común |
| `base-prisma` | base + `openssl` | solo los microservicios: Prisma necesita libssl |
| `deps` | `pnpm install` completo (con devDependencies) | se reusa en `builder` y `development` |
| `builder` | fuente + `prisma generate` + `pnpm build` | compila el `dist/` |
| `development` | deps + fuente + cliente Prisma | hot-reload (`nest start --watch`) |
| `production` | `pnpm install --prod` + `dist` | runtime sin tsc, sin watch y sin devDependencies |

Se construye por target:

```bash
# stack de desarrollo (hot-reload)
docker compose build                              # target: development

# stack de producción
docker compose -f docker-compose.prod.yaml build  # target: production
```

> El `target` en el compose es **obligatorio**: sin él, compose construye la
> última etapa del Dockerfile, que sería `production`.

### Tamaños y RAM (medidos en esta máquina)

| Imagen | Antes (una etapa) | Ahora (multi-stage) |
|---|---|---|
| `client-gateway` (dev) | 869 MB | **666 MB** |
| `orders-ms` (dev) | 1.52 GB | **1.12 GB** |
| `products-ms` (dev) | 1.57 GB | **1.17 GB** |
| `client-gateway` (prod) | — | **449 MB** |
| `orders-ms` (prod) | — | **944 MB** |
| `products-ms` (prod) | — | **938 MB** |

| Stack | RAM de los 3 servicios |
|---|---|
| desarrollo (con `tsc` en watch) | ~1.6 GB |
| producción (sin watch) | **~250 MB** |

De dónde sale el ahorro: el **metadata cache del registry** que pnpm guarda
(`~/.cache/pnpm`, 150-300 MB por imagen) ya no se hornea en la imagen porque va
en un *cache mount*, y la imagen de producción se queda solo con las
dependencias de runtime.

## Producción (opcional)

```bash
docker compose -f docker-compose.prod.yaml up -d --build
```

Qué cambia respecto al stack de desarrollo:

- Las imágenes se construyen con el target `production`: sin devDependencies,
  sin `tsc` en watch y con el código ya compilado.
- No se monta `./src`: no hay hot-reload (para eso está el stack de desarrollo).
- **Comparte los volúmenes de datos** con el stack de desarrollo, así que las
  bases ya migradas se reutilizan tal cual.
- Los dos stacks usan los mismos `container_name` y puertos → **no pueden
  correr al mismo tiempo**: pará el de desarrollo antes de levantar este.

## Comandos útiles

| Acción                          | Comando                                                            |
|---------------------------------|--------------------------------------------------------------------|
| Ver estado y health             | `docker compose ps`                                                |
| Ver logs de un servicio         | `docker compose logs -f orders-ms`                                 |
| Rebuild de un solo servicio     | `docker compose up -d --build client-gateway`                      |
| Rebuild sin caché               | `docker compose build --no-cache client-gateway`                   |
| Entrar a un container           | `docker compose exec orders-ms bash`                               |
| Ver logs de NATS                | `docker compose logs -f nats`                                      |
| Estado de NATS (JSON)           | `curl http://localhost:8222/healthz`                               |
| Conectar al Postgres            | `docker compose exec orders-db psql -U postgres -d ordersdb`       |
| Resetear solo la base de orders | `docker compose down -v orders-db && docker compose up -d orders-db` |
| **Aplicar migraciones + seed**  | `./scripts/migrate.sh`                                             |
| Build secuencial (menos RAM)    | `COMPOSE_PARALLEL_LIMIT=1 docker compose build`                    |

## Variables de entorno

Dentro de un container, `localhost` apunta al propio container, por eso los
servicios se comunican **por nombre de servicio** (DNS interno de Compose).
Las variables se inyectan desde el `docker-compose.yaml` (`environment:`) y
**tienen prioridad sobre los `.env`** (dotenv no pisa variables ya definidas
en el entorno).

| Servicio         | Variable       | Valor en Docker                                                            | `.env` local (no se usa)          |
|------------------|----------------|----------------------------------------------------------------------------|------------------------------------|
| `client-gateway` | `PORT`         | `3000`                                                                     | `3000`                             |
| `client-gateway` | `NATS_SERVERS` | `nats://nats:4222`                                                         | `nats://localhost:4222`            |
| `orders-ms`      | `PORT`         | `3002`                                                                     | `3002`                             |
| `orders-ms`      | `NATS_SERVERS` | `nats://nats:4222`                                                         | `nats://localhost:4222,nats://localhost:4223` |
| `orders-ms`      | `DATABASE_URL` | `postgresql://postgres:123456@orders-db:5432/ordersdb?schema=public`      | `postgresql://...@localhost:5432/...` |
| `products-ms`    | `PORT`         | `3001`                                                                     | `3001`                             |
| `products-ms`    | `NATS_SERVERS` | `nats://nats:4222`                                                         | `nats://localhost:4222,nats://localhost:4223` |
| `products-ms`    | `DATABASE_URL` | `file:/data/dev.db`                                                        | `file:./dev.db`                    |

Los `.env` locales quedan intactos para el flujo de desarrollo en el host.

## Hot reload

A cada microservicio se le monta **solo** `src/`:

```yaml
volumes:
  - ./orders-ms/src:/usr/src/app/src
```

Los tres servicios corren con `nest start --watch`, así que los cambios en
`src/` se recompilan y recargan solos.

Dos advertencias:

- `node_modules` **no** se monta: pnpm usa symlinks que quedarían rotos
  apuntando al `node_modules` del host. Por eso el directorio montado es
  únicamente `src/`.
- Cambios en `package.json`, `tsconfig.json`, `prisma/schema.prisma` o
  `pnpm-lock.yaml` **no** se reflejan en el container: hay que rebuildear
  (`docker compose up -d --build <servicio>`).

## pnpm dentro de Docker

La imagen oficial `node:24-bookworm-slim` **no incluye pnpm** (sí npm). En vez
de instalarlo con `npm i -g pnpm` (que suma ~59 MB), los tres `Dockerfile` usan
**corepack**, que ya viene incluido en la distribución de Node 24:

```dockerfile
RUN corepack enable pnpm
```

La versión del gestor se declara en el `package.json` de cada proyecto, así
que hay **una sola fuente de verdad**:

```json
"packageManager": "pnpm@11.23.0+sha512.f00082e5b283a199b74e079da28d155c008fe232f44c8a06ea7ddfa014ecf719fc362f790ecc67b28106ddac2afb24c49a9a079159da560b2ce7d1e98efd11af"
```

Corepack lee ese campo, descarga esa versión exacta de pnpm (durante el build,
queda cacheada en la imagen) y valida el hash. En el host, el mismo campo hace
que `pnpm` use siempre esa versión, en vez de la "última conocida" de corepack.

Se copia `pnpm-lock.yaml` y `pnpm-workspace.yaml` **antes** de instalar, y se
instala con `--frozen-lockfile`:

```dockerfile
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./

RUN --mount=type=cache,id=pnpm-store,target=/pnpm/store \
    --mount=type=cache,id=pnpm-cache,target=/root/.cache/pnpm \
    pnpm install --frozen-lockfile --store-dir=/pnpm/store --package-import-method=copy
```

Motivos:

- `--frozen-lockfile`: install determinista; falla si `package.json` y el
  lockfile no coinciden (en vez de reescribir el lockfile dentro del build).
- `pnpm-workspace.yaml`: desde pnpm 10 la configuración de scripts de build
  (`allowBuilds`) vive en ese archivo. Sin copiarlo, pnpm bloquea los
  postinstall de `prisma`, `@prisma/engines` y `better-sqlite3`.
- `--mount=type=cache` (store): el store de pnpm se persiste entre builds → las
  dependencias no se descargan de nuevo en cada cambio de código.
- `--mount=type=cache` (cache): el **metadata cache del registry** que pnpm
  guarda en `~/.cache/pnpm` (150-300 MB por imagen) tampoco se hornea en la
  imagen, y se reutiliza entre builds.
- `--package-import-method=copy`: necesario porque el store es un cache mount
  en otro filesystem (con hardlinks el `node_modules` de la imagen quedaría
  roto).

**Ojo:** `pnpm@11` exige **Node >= 22.13** (`engines` de pnpm), así que la
imagen base no puede bajar de `node:22.13`. Y **Node 25 eliminó corepack** de
la distribución: si se migra a Node 25, hay que volver a `npm i -g pnpm` o
copiar el binario oficial (`COPY --from=ghcr.io/pnpm/pnpm:11 /pnpm
/usr/local/bin/pnpm`).


## Paquetes de sistema en las imágenes

`node:24-bookworm-slim` es mínima, y el hot-reload y Prisma necesitan dos cosas
que no trae:

| Paquete  | Para qué                                                                                  | Dónde                      |
|----------|-------------------------------------------------------------------------------------------|----------------------------|
| `procps` | aporta `ps`, que el Nest CLI usa (`tree-kill`) para enumerar y matar el proceso de la app cuando recompila | etapas `deps` de los 3 Dockerfiles (en `production` no hace falta: no hay watch) |
| `openssl`| Prisma (CLI, engines y cliente) no detecta la versión de libssl sin él y avisa `failed to detect the libssl/openssl version to use` | etapa `base-prisma` de `orders-ms` y `products-ms` |

Sin `procps`, el proceso viejo de la app queda vivo con el puerto 3000 tomado
y el reinicio del watch falla con `EADDRINUSE`: el hot-reload **no** recarga el
código y el container queda sirviendo la versión vieja.

## Prisma

| Servicio       | Qué hace el container                                                                             |
|----------------|----------------------------------------------------------------------------------------------------|
| `orders-ms`    | `prisma generate` en el build; las migraciones se aplican a mano con `./scripts/migrate.sh`         |
| `products-ms`  | `prisma generate` en el build; migraciones + seed a mano con `./scripts/migrate.sh`                |

- `prisma generate` es obligatorio en el build: el cliente se genera en
  `generated/prisma` y el código lo importa; sin ese paso no compila. Como el
  cliente queda compilado dentro de `dist/generated/prisma`, la imagen de
  producción no lo necesita aparte.
- El CLI de Prisma es `devDependency`: **las imágenes de producción no lo
  llevan** (las migraciones se aplican con la imagen de desarrollo, vía
  `./scripts/migrate.sh`).
- Ojo: `@prisma/client` declara `prisma` y `typescript` como *peerDependencies*
  opcionales, y como el lockfile tiene `autoInstallPeers: true`, pnpm los
  instala también en el `install --prod` (~200 MB extra). Se puede evitar con
  `--config.auto-install-peers=false`, pero pnpm lo rechaza junto con
  `--frozen-lockfile` (el lockfile registra `autoInstallPeers: true`): habría
  que regenerar el lockfile.
- El seed de `products-ms` usa `data/products.sql` con `INSERT OR IGNORE`
  para poder ejecutarlo en cada arranque sin duplicar productos (`name` es
  `@unique`).
- `orders-ms` aplica sus 4 migraciones (`20261016023516_init` →
  `20261021000727_create`) sobre el PostgreSQL del compose.

## Volúmenes y datos

Se usan **named volumes** en lugar de bind mounts:

- `orders-db-data`: evita el problema de permisos del bind mount
  `./orders-ms/postgres` (directorio `root:dnsmasq` con permisos `700`, que el
  usuario `postgres` del container no puede escribir). Los datos que tengas
  hoy en `./orders-ms/postgres` no se reutilizan: el container arranca con una
  base nueva y las migraciones crean el schema.
- `products-data`: guarda el SQLite (`/data/dev.db`) entre reinicios.
- `nats-data`: guarda el estado de JetStream.

El `docker-compose.yml` que estaba en `orders-ms/` queda obsoleto (publicaba
el `5432` y usaba el bind mount problemático): no debe levantarse junto con
este compose.

## NATS

Un único server NATS con JetStream y monitoring:

```yaml
command: ["-js", "-sd", "/data", "-m", "8222"]
```

- `-js` habilita JetStream, `-sd /data` define el store (en el volumen).
- `-m 8222` habilita el endpoint de monitoring: `http://localhost:8222/healthz`
  se usa como healthcheck del container.
- Los `.env` locales de `orders-ms` y `products-ms` listan dos servers
  (`4222` y `4223`); con un solo server se inyecta `nats://nats:4222`.
  `orders-ms` hace `split(',')` y el gateway lo consume como string: ambos
  funcionan con un único valor.

## Troubleshooting

**El gateway responde 500 al pedir `/api/products` o `/api/orders`**
Revisá que `products-ms` y `orders-ms` estén levantados y sin errores:
`docker compose logs -f products-ms orders-ms`. El gateway se levanta apenas
NATS está *healthy*, no cuando los microservicios ya están escuchando.

**`pnpm: command not found` durante el build**
El `Dockerfile` debe tener `RUN corepack enable pnpm` (y el `package.json` el
campo `packageManager`). Si el build falla con `Cannot find matching keyid`,
corepack no pudo validar la firma del paquete: agregá
`ENV COREPACK_INTEGRITY_KEYS=0` (desactiva la verificación de firmas) o
actualizá corepack con `npm i -g corepack@latest`.

**El build falla con `ERR_PNPM_OUTDATED_LOCKFILE`**
`package.json` y `pnpm-lock.yaml` están desincronizados. Corregí con
`pnpm install` en el host y commiteá el lockfile.

**`Permission denied` en el volume de PostgreSQL**
Suele ser un directorio con owner `root` montado como bind mount. Con named
volumes no debería ocurrir; si pasa, `docker compose down -v` y volvé a levantar.

**Cambié `prisma/schema.prisma` y no se refleja**
Reconstruí el servicio: `docker compose up -d --build orders-ms`
(el `prisma generate` corre en el build).

**El puerto 3000/5432/4222 está ocupado**
`docker compose ps` y `ss -ltnp | grep -E '3000|5432|4222'`. El
`docker-compose.yml` viejo de `orders-ms/` también publica el `5432`.

**`Conflict. The container name "/nats-server" is already in use`**
Quedó un container NATS viejo del flujo manual (`docker run -d --name
nats-server ...`, está en los README de cada sub-proyecto). Borralo una vez:
`docker rm nats-server`.

**El hot-reload no recarga el código / `EADDRINUSE` en los logs**
Es el caso de la imagen sin `procps`: el proceso anterior queda con el puerto
tomado. Verificá que el `Dockerfile` instale `procps` y reconstruí la imagen
(`docker compose up -d --build <servicio>`). Con `ps` disponible, el Nest CLI
mata el proceso viejo y el nuevo toma el puerto sin problema.

**Prisma avisa `failed to detect the libssl/openssl version to use`**
Falta el paquete `openssl` en la imagen: instalalo en el `Dockerfile` de
`orders-ms` y `products-ms` y reconstruí.

**`docker compose up` levanta la imagen de producción en vez de la de desarrollo**
Falta el `target: development` en el `build:` del servicio. Sin `target`, compose
construye la **última** etapa del Dockerfile (que es `production`).

**El stack prod y el dev no levantan juntos**
Comparten `container_name` y puertos. Pará uno antes de levantar el otro:
`docker compose down` y después `docker compose -f docker-compose.prod.yaml up -d`.

**Un container muere con exit 137 (SIGKILL) durante los builds**
Es el OOM killer: sin swap, 3 `pnpm install` en paralelo + los 3 `tsc` en watch
consumen demasiado. Construí de a uno con `COMPOSE_PARALLEL_LIMIT=1 docker compose build`,
o usá el stack de producción (sin watch: ~250 MB de RAM en vez de ~1.6 GB).

