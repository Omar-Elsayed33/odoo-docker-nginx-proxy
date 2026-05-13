# Architecture

This document is the design rationale for the stack — what's in the box,
why each component is there, what flows where, and which decisions are
deliberately reversible vs. load-bearing. If a piece of config makes you
wonder "why is it like this," the answer is here.

## Contents

- [Components](#components)
- [Request flow](#request-flow)
- [Data flow](#data-flow)
- [Network topology](#network-topology)
- [Configuration model](#configuration-model)
- [Lifecycle](#lifecycle)
- [Design decisions worth flagging](#design-decisions-worth-flagging)
- [What's deliberately out of the architecture](#whats-deliberately-out-of-the-architecture)

---

## Components

Four services on one Compose file, plus a fifth (`certbot`) reserved for
v0.5.

| Service | Image | Job |
|---|---|---|
| `nginx` | `nginx:${NGINX_VERSION}-alpine` | TLS termination, gzip, security headers, websocket upgrade, reverse-proxy. The only service published to the host. |
| `odoo` | `odoo:${ODOO_VERSION}` | Application server. Runs N HTTP workers + one gevent-based longpolling worker for the bus. |
| `pgbouncer` | `edoburu/pgbouncer:${PGBOUNCER_VERSION}` | Transaction-mode connection pool. Fans Odoo's churn onto a small, warm set of Postgres backends. |
| `db` | `postgres:${POSTGRES_VERSION}-alpine` | Persistent storage. The only RDBMS Odoo supports. |

Every service is pinned by an env-var-driven tag, so version bumps are
config changes, not YAML edits.

---

## Request flow

The path of a single HTTP request from a user's browser to a `SELECT`
landing on Postgres:

```
1. Browser                     ──► nginx :443          (TLS handshake)
2. nginx (port 80)             redirects everything else to 443 (HSTS, 301)
3. nginx (port 443)
       ├─ TLS terminated by ssl-params.conf
       ├─ Security headers injected by security-headers.conf
       ├─ gzip applied (text, JSON, JS, XML, SVG)
       └─ Routes by path:
            /websocket           ──► odoo :8072  (Upgrade-aware proxy)
            /longpolling/        ──► odoo :8072  (legacy compat)
            /web/static/         ──► odoo :8069  (cached 60 min)
            *                    ──► odoo :8069
4. odoo (HTTP worker)
       ├─ Reads X-Forwarded-* headers (proxy_mode = True)
       ├─ Generates absolute URLs as https://
       └─ Opens a transaction:
                                 ──► pgbouncer :6432
5. pgbouncer (transaction pool)
       ├─ Resolves wildcard route * → host=db port=5432
       ├─ Authenticates the client against userlist.txt (SCRAM)
       ├─ Checks out a warm backend from the pool (creates if cold)
       └─ Forwards the transaction:
                                 ──► db :5432
6. db (PostgreSQL backend)
       ├─ Executes the SQL
       └─ Returns rows up the chain
7. Response unwinds back through pgbouncer → odoo → nginx → browser
```

Two non-obvious branches:

- **`/websocket` is routed to a different upstream (`odoo:8072`)** than
  the main app. Odoo runs the longpolling/bus worker as a separate
  gevent process on a separate port. Mix them and chat goes mute.
- **`/web/static/` is cached at the proxy** for 60 minutes. Saves a
  worker round-trip on every CSS / JS / image request — meaningful on
  cold page loads.

---

## Data flow

What persists, what's transient, where it lives.

```
┌──────────────────────────────────────────────────────────────────┐
│  Named Docker volumes (survive container rebuild, gone on -v)    │
├──────────────────────────────────────────────────────────────────┤
│  ${POSTGRES_VOLUME}            ←  /var/lib/postgresql/data       │
│      Postgres cluster: WAL, tables, indexes.                     │
│                                                                  │
│  ${COMPOSE_PROJECT_NAME}-filestore  ←  /var/lib/odoo             │
│      Odoo filestore: attachments, addon cache, session store.    │
│                                                                  │
│  ${COMPOSE_PROJECT_NAME}-certbot-webroot                         │
│      ACME challenge directory (idle until v0.5 lands certbot).   │
└──────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│  Bind mounts (host directory → container; live source)           │
├──────────────────────────────────────────────────────────────────┤
│  ./odoo/config/    →  /etc/odoo/             (ro)                │
│  ./odoo/addons/    →  /mnt/extra-addons      (rw — your code)    │
│  ./postgres/init/  →  /docker-entrypoint-initdb.d  (ro)          │
│  ./pgbouncer/      →  /etc/pgbouncer/        (rw — entrypoint)   │
│  ./nginx/conf.d/   →  /etc/nginx/conf.d/     (ro)                │
│  ./nginx/templates/→  /etc/nginx/templates/  (ro)                │
│  ./nginx/certs/    →  /etc/nginx/certs/      (ro)                │
└──────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│  Backups (created by ./scripts/backup.sh)                        │
├──────────────────────────────────────────────────────────────────┤
│  ./backups/<dbname>-YYYYMMDD-HHMMSS.tar.gz                       │
│      ├── manifest.txt    (versions, sha256 of database.dump)     │
│      ├── database.dump   (pg_dump -Fc, suitable for -j parallel) │
│      └── filestore/      (Odoo per-database attachments)         │
└──────────────────────────────────────────────────────────────────┘
```

The filestore is the easy-to-overlook second half of an Odoo backup.
Attachments live on disk (`/var/lib/odoo/filestore/<dbname>/`), not in
the database. A backup of just the database recovers data but leaves
every uploaded file broken.

---

## Network topology

One private bridge network. One public surface area.

```
   Host                                Containers
   ────                                ──────────
   :80   ──►  nginx :80
   :443  ──►  nginx :443

                                    ┌─────────────────────────┐
                                    │  bridge: odoo-net       │
                                    │                         │
                                    │  nginx     odoo         │
                                    │     │       │           │
                                    │     └───────┤           │
                                    │             │           │
                                    │          pgbouncer      │
                                    │             │           │
                                    │             db          │
                                    └─────────────────────────┘
```

- **`nginx` is the only service that publishes host ports.** `odoo`,
  `pgbouncer`, and `db` are reachable only inside the bridge network.
- **`db` has `expose: 5432`, not `ports:`.** It's reachable to other
  services on the bridge but not from the host. Same for `pgbouncer:6432`
  and `odoo:8069/8072`.
- **The bridge isolates inter-service traffic from anything else** on
  the Docker daemon. A container on a different Compose project can't
  reach into this network unless you `external: true` it.

---

## Configuration model

Three layers, each with a clear role.

### Layer 1 — `.env`

The only thing an operator should need to edit for a vanilla deploy.
Every tunable (versions, passwords, resource limits, domain, ports)
lives here. Docker Compose interpolates `${VAR}` references in
`docker-compose.yml` at parse time.

### Layer 2 — `docker-compose.yml` and `docker-compose.prod.yml`

Service shape: images, volumes, networks, healthchecks, depends-on.
The prod file is an *override* — applied on top of the base via
`COMPOSE_FILE=docker-compose.yml:docker-compose.prod.yml` in `.env`.
Run plain `docker compose` and both files apply automatically.

### Layer 3 — service-specific config files

`odoo/config/odoo.conf`, `pgbouncer/pgbouncer.ini`, `nginx/conf.d/*.conf`.
These are bind-mounted read-only into their containers (except
`pgbouncer/`, whose entrypoint needs to write `userlist.txt`).

### Why this split

- **`.env` is environment-specific** (dev laptop ≠ prod VPS).
- **Compose files are environment-shape** (which services exist, how
  they're connected — same on every host).
- **Config files are component-shape** (how a given component is
  tuned — same on every host where that component runs).

Cross-cutting tunables that *could* be env-driven but aren't include
PgBouncer pool sizing (no env-subst in `.ini`) and Nginx vhost details
(deliberately static for `git diff` clarity).

---

## Lifecycle

What runs when, from `git clone` to a steady-state running stack.

### First-time install (`./scripts/install.sh`)

```
1. Verify docker, openssl, bash on PATH
2. .env missing?      → copy from .env.example
3. Placeholder passwords? → fill with `openssl rand -base64 32`
4. nginx/certs/ empty?    → generate self-signed cert (365 days, localhost)
5. pgbouncer/userlist.txt missing/empty? → generate from .env
6. Validate `docker compose config`
```

Idempotent. Re-running never overwrites a hand-customised file.

### Cold start (`./scripts/start.sh` or `docker compose up -d`)

```
1. db          starts
                  ├─ on first init, runs postgres/init/*.sql
                  ├─ creates ${POSTGRES_USER} role with password
                  └─ becomes healthy when pg_isready returns 0
2. pgbouncer   starts (depends_on db, condition: service_healthy)
                  ├─ reads pgbouncer.ini + userlist.txt
                  └─ becomes healthy when port 6432 accepts connections
3. odoo        starts (depends_on pgbouncer, condition: service_healthy)
                  ├─ entrypoint injects HOST/PORT/USER/PASSWORD as --db_*
                  ├─ starts N workers + 1 longpolling worker
                  └─ becomes healthy when /web/health returns 200
4. nginx       starts (depends_on odoo, condition: service_healthy)
                  ├─ reads nginx/conf.d/*.conf + included snippets
                  ├─ binds 80/443 on the host
                  └─ becomes healthy when /nginx-health returns 200
```

### Runtime

- Each Odoo HTTP worker opens a short-lived Postgres connection per
  request → PgBouncer pool checkout.
- The longpolling worker holds a connection open per active websocket
  → bypassed by PgBouncer pool quirks for LISTEN/NOTIFY (falls back to
  polling — see [pgbouncer.md](pgbouncer.md)).
- Logs stream to Docker's `json-file` driver, rotated 10 MB × 5 in dev,
  20 MB × 5 in prod.
- Healthchecks run on each service every 10–30 s.

### Shutdown (`./scripts/stop.sh` or `docker compose down`)

Containers stopped in reverse-dependency order. Volumes survive unless
`--volumes` is passed explicitly (which prompts for confirmation in
the script).

---

## Design decisions worth flagging

### Transaction-mode pooling for everything

PgBouncer in session mode is barely better than no pool. Statement mode
breaks transactions. Transaction mode is the sweet spot for Odoo's
short-lived connection pattern. The cost: `LISTEN/NOTIFY` and server-side
prepared statements don't survive across transactions, so Odoo's bus
falls back to polling instead of push notifications. The trade-off is
documented in [pgbouncer.md](pgbouncer.md) and worth it for nearly every
deployment.

### `nginx/templates/` for snippets, not envsubst

The official nginx Docker image processes `*.template` files in
`/etc/nginx/templates/` with `envsubst`. We use the same directory for
**reusable nginx config fragments** (TLS, security headers, gzip, proxy
params) that are explicitly `include`d from vhosts. Files don't end in
`.template`, so envsubst skips them. This keeps the vhost short and
makes a second site (status page, staging mirror, second Odoo instance)
a copy-paste-and-edit, not a copy-paste-and-pray.

### env-var routing for the DB host

`odoo` reads `HOST=${ODOO_DB_HOST:-pgbouncer}` from `.env`, with `db`
as a one-line bypass switch. Useful for: debugging ("is PgBouncer the
problem?"), migrations (DDL-heavy work doesn't pool well), and the
longpolling worker if you decide push notifications matter more than
pool efficiency. Bypass is intentionally easy because the cases that
need it are legitimate.

### Self-signed cert by default

`install.sh` generates a localhost cert valid for one year. Browsers
warn; that's fine. The alternative — refusing to start without a real
cert — would block every laptop-first developer for no security gain on
`localhost`. Production replaces the cert (per [production-deployment.md](production-deployment.md))
or wires up Let's Encrypt (v0.5).

### `proxy_mode = True` in `odoo.conf`

Odoo trusts `X-Forwarded-*` only when `proxy_mode = True`. Setting it
without a trusted proxy in front lets clients spoof HTTPS detection and
client IP. The setting is flipped on as soon as the nginx layer lands,
and the comment block in `odoo.conf` flags the risk for anyone who
later thinks "what if I removed nginx?"

### Mount `pgbouncer/` directory writable

The edoburu image's entrypoint `touch`es `userlist.txt` at startup to
enforce permissions. Against a read-only mount, the entrypoint loops
forever. Mounting the directory writable is a smaller risk than the
operational fragility of an unreachable PgBouncer. The container is
already trusted with database credentials; write access to its own
config dir is fine.

### `odoo.conf` deliberately omits `db_host` / `db_port` / `db_user`

The Odoo Docker entrypoint runs:

```
if param exists in odoo.conf:  use conf value
else:                          use HOST/PORT/USER env var
```

Putting `db_host = db` in `odoo.conf` therefore *defeats* the
`ODOO_DB_HOST` env-var override. Those lines are kept out so the env
vars in `docker-compose.yml` win.

---

## What's deliberately out of the architecture

- **Custom Odoo modules.** Mount your own `addons/`. This repo is
  infrastructure.
- **Kubernetes / Swarm orchestration.** Compose is the contract. The
  same compose file scales to a second Odoo replica behind nginx; past
  that, fork.
- **Read replicas / managed Postgres.** Recommended in `production-deployment.md`
  as the scaling exit ramp; not built in because the routing is
  per-addon work.
- **Encryption at rest of backups.** Backups inherit the filesystem's
  encryption. If you need application-level encryption, layer `restic`
  or `borg` on top.
- **Application-level audit logging.** Out of scope — handled by Odoo
  addons if your compliance requires it.
- **Multi-tenant database routing.** PgBouncer's wildcard route lets
  multiple Odoo databases coexist on one cluster, but per-tenant
  isolation (separate clusters, separate compose stacks per tenant) is
  someone else's project — see [docker-odoo-project](https://github.com/Tecnativa/docker-odoo-project).
