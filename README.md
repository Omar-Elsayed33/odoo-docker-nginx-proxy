# odoo-docker-nginx-proxy

> Production-grade, **standalone** Odoo deployment on Docker Compose — backed by PostgreSQL, accelerated by PgBouncer, and fronted by an Nginx reverse proxy with TLS termination.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Docker Compose](https://img.shields.io/badge/Docker%20Compose-v2-2496ED?logo=docker&logoColor=white)](https://docs.docker.com/compose/)
[![Odoo](https://img.shields.io/badge/Odoo-18.0%20(default)-714B67?logo=odoo&logoColor=white)](https://www.odoo.com/)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-16-336791?logo=postgresql&logoColor=white)](https://www.postgresql.org/)
[![Nginx](https://img.shields.io/badge/Nginx-stable-009639?logo=nginx&logoColor=white)](https://nginx.org/)

---

## Contents

- [Why this stack](#why-this-stack)
- [Features](#features)
- [Architecture](#architecture)
- [Quick start](#quick-start)
- [Repository layout](#repository-layout)
- [Operational scripts](#operational-scripts)
- [Documentation](#documentation)
- [License](#license)

---

## Why this stack

Standing up Odoo for production is **not** the same as `docker run odoo`. You need a reverse proxy that knows how to forward Odoo's websocket bus. You need a connection pooler in front of Postgres or every cold request pays a backend-startup tax. You need backups that survive an interrupted run. You need TLS termination, security headers, and a way to update without losing data.

This repository ships all of that as a small, opinionated, **standalone** Compose stack — readable in five minutes, deployable in fifteen. It is not a SaaS template, not a Kubernetes platform, and not a place for your custom modules. It is the boring, correct base on which the interesting work happens.

---

## Features

| Area | What you get |
|---|---|
| **Reverse proxy** | Nginx vhost with TLS 1.2/1.3 (Mozilla intermediate), HTTP→HTTPS redirect, websocket upgrade for Odoo's bus, gzip, security headers (HSTS, X-Frame, Referrer-Policy, COOP/CORP), static-asset caching, rate-limit zones |
| **Connection pooling** | PgBouncer in transaction mode; SCRAM-SHA-256 end-to-end; wildcard DB route; documented sizing rule-of-thumb; bypass switch for session-mode workloads |
| **Persistence** | Named volumes for Postgres cluster and Odoo filestore; first-boot init script directory; configurable per-environment volume names |
| **Backups** | `pg_dump -Fc` + filestore tar + sha256-stamped manifest in a single atomic archive; retention policy; checksum verification on restore |
| **Operational scripts** | `install / start / stop / backup / restore / update / logs`, all sharing one logging library and respecting `NO_COLOR` |
| **Production overrides** | Separate `docker-compose.prod.yml` with `cap_drop`, `no-new-privileges`, resource limits, tighter healthchecks — auto-loaded via `COMPOSE_FILE` in `.env` |
| **Documentation** | One doc per concern (architecture, install, backup, pgbouncer, production, troubleshooting) — each readable in under 15 minutes |

---

## Architecture

```
                ┌────────────────────────────────────────────────────┐
                │                    Internet                         │
                └────────────────────────┬───────────────────────────┘
                                         │ 80 / 443
                                         ▼
                              ┌───────────────────┐
                              │      Nginx        │  TLS termination,
                              │  (reverse proxy)  │  gzip, websockets,
                              │                   │  security headers
                              └─────────┬─────────┘
                                        │ 8069 / 8072 (longpolling)
                                        ▼
                              ┌───────────────────┐
                              │       Odoo        │  Application server
                              │   (workers + lp)  │  custom addons mount
                              └─────────┬─────────┘
                                        │ 6432
                                        ▼
                              ┌───────────────────┐
                              │     PgBouncer     │  Transaction pooling,
                              │ (connection pool) │  protects PG from
                              │                   │  worker fan-out
                              └─────────┬─────────┘
                                        │ 5432
                                        ▼
                              ┌───────────────────┐
                              │    PostgreSQL     │  Persistent storage
                              │   (data volume)   │  + filestore alongside
                              └───────────────────┘
```

Read the design rationale in **[docs/architecture.md](docs/architecture.md)** — why each layer exists, what flows where, and which decisions are deliberately reversible vs. load-bearing.

---

## Quick start

> Prerequisites: Docker Engine 24+, Docker Compose v2.20+, `bash`, `openssl`. On Windows, use Git Bash or WSL for any `./scripts/*.sh` invocation.

```bash
git clone https://github.com/<your-user>/odoo-docker-nginx-proxy.git
cd odoo-docker-nginx-proxy

./scripts/install.sh    # .env, random passwords, self-signed cert, userlist
./scripts/start.sh      # bring up; waits for every service to be healthy
```

Open **<https://localhost/>** in a browser, accept the self-signed cert warning, and create your first database via Odoo's database manager.

For production targets (Linux VPS, real domain, real CA), follow **[docs/installation.md](docs/installation.md)** end-to-end.

---

## Repository layout

```
.
├── docker-compose.yml          # Base service definitions
├── docker-compose.prod.yml     # Production overrides (caps, limits, restart)
├── .env.example                # Local-dev env template
├── .env.prod.example           # Production env template
│
├── odoo/
│   ├── config/odoo.conf        # Server config (workers, limits, longpolling)
│   └── addons/                 # Mounted at /mnt/extra-addons in the container
│
├── postgres/init/              # First-boot SQL/sh scripts (idempotent)
│
├── pgbouncer/
│   ├── pgbouncer.ini           # Transaction-mode pool config
│   ├── userlist.txt.example    # Real file gitignored
│   └── generate-userlist.sh    # Derives userlist.txt from .env
│
├── nginx/
│   ├── conf.d/odoo.conf        # Vhost: upstreams, TLS, websocket, static cache
│   ├── templates/              # Reusable snippets (TLS, security, gzip, proxy)
│   ├── certs/                  # TLS material (gitignored except README.md)
│   └── README.md               # Reverse-proxy architecture + runbook
│
├── docs/
│   ├── architecture.md         # Design decisions, request flow, data flow
│   ├── installation.md         # Step-by-step install (dev + VPS)
│   ├── backup-and-restore.md   # backup.sh + restore.sh + drill cadence
│   ├── pgbouncer.md            # Why PgBouncer + tuning + LISTEN/NOTIFY
│   ├── production-deployment.md# Server prep, SSL, monitoring, scaling, runbook
│   └── troubleshooting.md      # Every failure mode this stack has hit
│
└── scripts/
    ├── install.sh   start.sh   stop.sh
    ├── backup.sh    restore.sh update.sh   logs.sh
    └── lib/common.sh           # Color logging + helpers (sourced by all)
```

---

## Operational scripts

Every routine action has a wrapper under `scripts/`. They share one logging library, respect `NO_COLOR`, prompt before destructive operations, and accept `--force` for automation.

| Script | Purpose |
|---|---|
| `install.sh` | First-time setup: `.env`, random passwords, self-signed cert, `pgbouncer/userlist.txt`, `docker compose config` validate. **Idempotent.** |
| `start.sh` | `compose up -d`, then waits for `db → pgbouncer → odoo → nginx` to all report healthy. Prints the access URL. |
| `stop.sh` | `compose down` (keeps data). `--pause` keeps containers; `--volumes` wipes data with a confirmation prompt. |
| `backup.sh` | Atomic, checksummed archive: `pg_dump -Fc` (direct to Postgres) + filestore tar + manifest. `--keep N` retention. |
| `restore.sh` | Verifies the archive sha256, prompts, drops + recreates the DB, `pg_restore -j 4`, replaces the filestore, waits for `/web/health`. |
| `update.sh` | Safety-backups every DB, pulls images, recreates changed services, waits healthy, prints the version diff. |
| `logs.sh` | `compose logs` wrapper with sensible defaults; `--errors` filters to ERROR/FATAL/WARN/Traceback. |

Production usage is identical — once `COMPOSE_FILE=docker-compose.yml:docker-compose.prod.yml` is set in `.env` on the server, every script transparently applies the production overrides.

---

## Documentation

### Getting started

- **[docs/installation.md](docs/installation.md)** — step-by-step install for laptop and VPS
- **[docs/architecture.md](docs/architecture.md)** — design rationale and request flow
- **[docs/troubleshooting.md](docs/troubleshooting.md)** — failure modes and fixes

### Operations

- **[docs/backup-and-restore.md](docs/backup-and-restore.md)** — backup procedure, drill cadence, off-host shipping
- **[docs/production-deployment.md](docs/production-deployment.md)** — server prep, SSL, monitoring, scaling, security
- **[docs/pgbouncer.md](docs/pgbouncer.md)** — why connection pooling matters; sizing; LISTEN/NOTIFY trade-offs
- **[nginx/README.md](nginx/README.md)** — reverse-proxy architecture and customisation

### Project

- **[CHANGELOG.md](CHANGELOG.md)** — release history
- **[CONTRIBUTING.md](CONTRIBUTING.md)** — workflow, code style, PR process
- **[ROADMAP.md](ROADMAP.md)** — what's planned and what's out of scope
- **[SECURITY.md](SECURITY.md)** — vulnerability disclosure policy

---

## License

[MIT](LICENSE) — use it, fork it, ship it.
