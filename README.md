# odoo-docker-nginx-proxy

> Production-grade, **standalone** Odoo deployment on Docker Compose — backed by PostgreSQL, accelerated by PgBouncer, and fronted by an Nginx reverse proxy with TLS termination.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Docker Compose](https://img.shields.io/badge/Docker%20Compose-v2-2496ED?logo=docker&logoColor=white)](https://docs.docker.com/compose/)
[![Odoo](https://img.shields.io/badge/Odoo-18.0%20(default)-714B67?logo=odoo&logoColor=white)](https://www.odoo.com/)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-16-336791?logo=postgresql&logoColor=white)](https://www.postgresql.org/)
[![Nginx](https://img.shields.io/badge/Nginx-stable-009639?logo=nginx&logoColor=white)](https://nginx.org/)

---

## Overview

This project provides a **batteries-included, reproducible Odoo deployment** that you can spin up locally, on a VPS, or behind any orchestrator that speaks Docker Compose. It is opinionated where it matters (security defaults, connection pooling, reverse-proxy hardening) and unopinionated where it shouldn't be (custom modules, themes, business logic).

The deployment model is **standalone** — one Odoo instance, one database cluster, fronted by one reverse proxy. This is not a SaaS / multi-tenant template.

> **Default Odoo version: 18.0.** This is the version the stack is built, tested, and supported against. Other major versions are not the target for this repository — see [Switching Odoo versions](#switching-odoo-versions) below.

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
                              │                   │  rate limiting
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
                              │   (data volume)   │  WAL + tuned config
                              └───────────────────┘
```

### Why each layer exists

| Layer | Role | Why it matters |
|-------|------|----------------|
| **Nginx** | Reverse proxy, TLS termination, static asset caching, websocket upgrade for Odoo longpolling. | Keeps Odoo off the public network, enables HTTPS, and offloads connection handling. |
| **Odoo** | The application. Runs HTTP workers + a dedicated longpolling worker. | Multi-worker setup is required for any non-toy deployment. |
| **PgBouncer** | Transaction-mode connection pool between Odoo workers and PostgreSQL. | Odoo opens many short-lived connections; PgBouncer prevents PG from being overwhelmed and reduces latency. |
| **PostgreSQL** | The database. | Odoo's only supported RDBMS. Tuned for OLTP-style workloads. |

## Quick start

```bash
# 1. Clone
git clone https://github.com/<your-user>/odoo-docker-nginx-proxy.git
cd odoo-docker-nginx-proxy

# 2. One-time setup (.env, self-signed certs, secrets, userlist)
./scripts/install.sh

# 3. Bring it up
./scripts/start.sh

# 4. Initialise the database (first run only)
#    Visit https://localhost/ and create the master database, or use
#    the Odoo CLI inside the container.
```

That's it. Logs:

```bash
docker compose logs -f odoo
```

## Repository layout

```
.
├── docker-compose.yml          # Service definitions (Odoo + Postgres today)
├── .env.example                # Documented environment template
├── odoo/
│   ├── config/
│   │   └── odoo.conf           # Odoo server config (workers, addons path, limits)
│   └── addons/                 # Mounted into Odoo at /mnt/extra-addons
├── postgres/
│   └── init/                   # First-boot SQL/sh scripts for the cluster
│       ├── README.md
│       └── 10-extensions.sql.example
├── nginx/
│   ├── README.md               # Reverse-proxy architecture, ops, customisation
│   ├── conf.d/
│   │   └── odoo.conf           # Vhost: upstreams, TLS, websocket, static cache
│   ├── templates/              # Reusable snippets (TLS, security, gzip, proxy)
│   └── certs/                  # TLS material (gitignored except README.md)
├── pgbouncer/
│   ├── pgbouncer.ini           # Pool config (transaction mode, sizing, timeouts)
│   ├── userlist.txt.example    # userlist.txt format reference (real file gitignored)
│   └── generate-userlist.sh    # Generates userlist.txt from .env credentials
├── docs/
│   └── pgbouncer.md            # Why PgBouncer + tuning + LISTEN/NOTIFY tradeoff
└── scripts/
    ├── install.sh              # First-time setup: .env, certs, secrets, userlist
    ├── start.sh                # Bring stack up; wait until healthy
    ├── stop.sh                 # Bring down (--volumes to wipe data, --pause to keep)
    ├── backup.sh               # pg_dump + filestore tar; atomic, checksummed
    ├── restore.sh              # Reverse of backup.sh; safety prompts
    ├── update.sh               # Pull → backup → recreate → wait-healthy
    ├── logs.sh                 # Tail any service; --errors filter
    └── lib/
        └── common.sh           # Shared color logging + helpers
```

## Configuration

All configuration lives in `.env` and the files under `config/`. The `.env` file is the **only** thing you should need to edit for a vanilla deployment.

See [`.env.example`](.env.example) for the full list of variables, each with inline documentation.

### Version strategy

The Odoo image and tag are controlled by a single variable in `.env`:

```bash
ODOO_VERSION=18.0          # default — tested, supported
ODOO_IMAGE=odoo:${ODOO_VERSION}
```

Pinning is centralised. Don't hard-code an image tag inside `docker-compose.yml` — change `ODOO_VERSION` (or override `ODOO_IMAGE` outright) and let Compose interpolate.

### Switching Odoo versions

> **Read this before changing `ODOO_VERSION`.** A version bump is a database migration, not a config tweak.

- **Odoo 18.0 is the default and only tested version** for this repository. The Nginx vhost, `odoo.conf` defaults, PgBouncer pool sizing, and backup scripts are calibrated against 18.0.
- Other major versions (e.g. 17.0, 19.0) are **not** the default target. They may work, but expect at minimum:
  - Different custom-addon API compatibility (Odoo's ORM and view syntax change across majors).
  - Different default config keys in `odoo.conf` (e.g. worker / longpolling flags have been renamed historically).
  - Database schema incompatibility — an Odoo 18 filestore + database **cannot** be opened by Odoo 17, and moving to Odoo 19 requires running Odoo's migration tooling against a copy.
- **Never switch versions on a live production database without:**
  1. A verified, restorable backup (run [`scripts/restore.sh`](scripts/restore.sh) against a clean stack and confirm the data loads).
  2. A staging environment running the target version with a copy of prod data.
  3. A migration plan — either OpenUpgrade for community modules or a paid Odoo migration service for enterprise.
  4. A rollback plan (image tag + backup) you have actually rehearsed.
- To experiment with a different version locally:
  ```bash
  # In a throwaway .env, never on prod
  ODOO_VERSION=19.0
  POSTGRES_VOLUME=odoo-pgdata-19   # isolate the data dir per major
  ```
  Always pair a version bump with a renamed `POSTGRES_VOLUME` so you cannot accidentally point a new Odoo at an old database.

### Production checklist

Before exposing to the internet:

- [ ] Confirm `ODOO_VERSION=18.0` (or your deliberate, tested override).
- [ ] Set strong `POSTGRES_PASSWORD` and `ODOO_ADMIN_PASSWD` (≥ 32 chars).
- [ ] Replace the self-signed TLS cert with a real one (Let's Encrypt or commercial CA).
- [ ] Set `list_db = False` in `odoo/config/odoo.conf` to disable the database manager.
- [ ] Restrict `/web/database/*` endpoints in Nginx.
- [ ] Configure off-host backups (see [`scripts/backup.sh`](scripts/backup.sh)).
- [ ] Pin image tags to immutable digests, not floating tags.
- [ ] Enable Docker log rotation (`json-file` with `max-size` + `max-file`).

## Operational scripts

Everything routine has a wrapper in `scripts/`. They share a tiny logging library, respect `NO_COLOR`, prompt before destructive actions, and accept `--force` for automation.

| Script | What it does |
|---|---|
| `install.sh` | First-time setup: copies `.env.example` → `.env`, generates 40-char random passwords for the placeholders, makes a self-signed cert if `nginx/certs/` is empty, generates `pgbouncer/userlist.txt`, validates the Compose file. Idempotent. |
| `start.sh` | Brings the stack up and waits until every service reports healthy. Prints the URL to open. |
| `stop.sh` | Default: `docker compose down`, keeps your data. `--pause` keeps the containers around. `--volumes` wipes the named volumes (prompts for confirmation). |
| `backup.sh` | Atomic, checksummed archive of one database: `pg_dump -Fc` (bypassing PgBouncer) + filestore tar + manifest, all sha256'd. `--keep N` enforces retention. |
| `restore.sh` | Verifies an archive's checksum, prompts for confirmation, drops + recreates the target DB, `pg_restore -j 4`, replaces the filestore, restarts Odoo. |
| `update.sh` | Takes a safety backup of every DB, pulls new images, recreates only changed services, waits healthy, prints the version diff. |
| `logs.sh` | `docker compose logs` wrapper with sensible defaults (`--follow`, last 200) and an `--errors` mode that greps for ERROR/FATAL/WARN/Traceback. |

```bash
# Daily life
./scripts/backup.sh --keep 7         # nightly cron-friendly
./scripts/logs.sh odoo --errors      # what broke?
./scripts/restore.sh backups/<file>  # roll forward (or back)
./scripts/update.sh                  # patch-update Odoo / Postgres / nginx
```

Backups land in `./backups/` and are gitignored. Ship them off-host (S3, B2, restic — your choice) on a schedule; the archives are self-contained and verifiable via their manifest.

## Operating notes

- **Worker count**: Tune `WORKERS` in `.env` to `(2 × CPU) + 1` as a starting point. The longpolling worker is separate and always-on.
- **Memory limits**: Each worker is capped via `limit_memory_hard` / `limit_memory_soft` in `odoo.conf`. Adjust to your host.
- **Updating Odoo within a major**: Bump the Odoo image digest (not the major version) in your registry pin, pull, and `docker compose up -d`. Test on a staging copy of prod first — even point releases can carry data migrations.
- **Updating Odoo across majors**: See [Switching Odoo versions](#switching-odoo-versions). This is a migration project, not a deploy.

## Documentation

- [CHANGELOG.md](CHANGELOG.md) — release history
- [CONTRIBUTING.md](CONTRIBUTING.md) — development workflow, code style, PR process
- [ROADMAP.md](ROADMAP.md) — what's planned and what's out of scope
- [SECURITY.md](SECURITY.md) — vulnerability disclosure policy

## License

[MIT](LICENSE) — use it, fork it, ship it.
