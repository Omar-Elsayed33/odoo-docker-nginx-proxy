# Roadmap

This document captures **what's planned**, **what's explicitly out of scope**, and **why**. It is the source of truth for "should I propose this feature?".

The project's north star: a Compose file you can read in five minutes and run in production by Friday.

**Target version:** Odoo **18.0** is the default and supported major. Odoo 17 and Odoo 19 are explicitly **not** the target — see [README.md → Switching Odoo versions](README.md#switching-odoo-versions). The scope is **standalone** deployment, not SaaS / multi-tenant.

---

## v0.1 — Base standalone stack ✅ completed

Goal: a runnable Odoo + PostgreSQL Compose stack that boots cleanly from `.env.example`.

- [x] `docker-compose.yml` with Odoo + PostgreSQL services
- [x] `odoo/config/odoo.conf` parameterised via environment
- [x] Named, persistent volumes for the PG cluster and the Odoo filestore
- [x] Healthchecks on every service (`pg_isready`, `/web/health`)
- [x] Restart policies (`unless-stopped`) and log rotation (`json-file`)
- [x] Private bridge network; database not exposed to the host
- [x] `postgres/init/` for first-boot SQL/sh scripts (with an example)

## v0.2 — Nginx reverse proxy ✅ completed

Goal: a public, TLS-terminated entry point in front of Odoo.

- [x] `nginx/conf.d/odoo.conf` vhost with HTTP→HTTPS redirect + ACME path
- [x] TLS 1.2 / 1.3 with Mozilla intermediate cipher set + session cache
- [x] Websocket upgrade for `/websocket` and legacy `/longpolling/`
- [x] Reusable snippets in `nginx/templates/` (TLS, security headers, gzip, proxy)
- [x] `client_max_body_size`, gzip, and `X-Forwarded-*` headers
- [x] Static-asset caching on `/web/{static,content,image}/`
- [x] Flipped `proxy_mode = True` in `odoo.conf`
- [x] Self-signed cert bootstrap documented in `nginx/certs/README.md`
- [x] Rate-limit zones declared (enforcement deferred to v0.4)

## v0.3 — PgBouncer integration ✅ completed

Goal: insulate PostgreSQL from Odoo's worker fan-out.

- [x] `pgbouncer/pgbouncer.ini` in transaction-pooling mode
- [x] SCRAM-SHA-256 auth end-to-end; `userlist.txt` gitignored, generated from `.env`
- [x] `pgbouncer/generate-userlist.sh` idempotent helper
- [x] Odoo routed through PgBouncer; `ODOO_DB_HOST` / `ODOO_DB_PORT` bypass switch
- [x] `docs/pgbouncer.md` covering rationale, sizing, LISTEN/NOTIFY trade-offs, runbook

## v0.4 — Hardening

Goal: ship-it-to-a-VPS quality.

- [ ] Drop unnecessary capabilities (`cap_drop: [ALL]`) per service
- [ ] Read-only root filesystems where feasible
- [ ] Non-root users in every container
- [ ] Rate limiting on `/web/login` and `/web/database/*`
- [ ] Optional fail2ban sidecar / Nginx-level IP banning
- [ ] CIS-Docker benchmark gap analysis in `docs/security.md`

## v0.5 — Operations, backups & observability

Goal: you can actually run this without panic.

- [x] `scripts/install.sh`, `start.sh`, `stop.sh`, `update.sh`, `logs.sh`
- [x] `scripts/backup.sh` (pg_dump + filestore tarball, sha256-checksummed)
- [x] `scripts/restore.sh` with safety prompts and checksum verification
- [x] `docker-compose.prod.yml` + `.env.prod.example` + `docs/production-deployment.md`
- [x] Cron-driven off-host backup example (restic → S3-compatible target, in production docs)
- [x] Restore-drill cadence documented (monthly → quarterly)
- [ ] Let's Encrypt sidecar (`acme.sh` or `certbot`) with auto-renewal
- [ ] Prometheus exporters (postgres_exporter, nginx-prometheus-exporter)
- [ ] Sample Grafana dashboards in `docs/observability/`

## v0.6 — CI & quality

- [x] GitHub Actions: `docker compose config` validation (base + base+prod chains)
- [x] `shellcheck` for all `scripts/*.sh` + `pgbouncer/generate-userlist.sh`
- [x] `markdownlint` for docs (with project-specific config)
- [x] Pull request template + structured issue templates (bug + feature)
- [ ] `hadolint` — deferred until we ship a Dockerfile of our own
- [ ] Trivy / Grype image scan on a schedule

## v1.0 — Stable

Considered stable when:

- Two consecutive Odoo minor releases have been supported without breaking changes to `.env.example`.
- At least one full restore drill is documented and reproducible.
- A user can go from `git clone` to a working HTTPS Odoo on a fresh VPS in under 15 minutes.

---

## Explicitly out of scope

These belong in *other* projects. PRs that add them will be politely declined.

- **Custom Odoo modules.** This is infrastructure, not business logic. Mount your own `addons/` directory.
- **Kubernetes manifests / Helm charts.** A separate repo if there's demand. Compose is the contract here.
- **Multi-tenant / SaaS orchestration.** Use [docker-odoo-project](https://github.com/Tecnativa/docker-odoo-project) or build your own.
- **Odoo Enterprise.** Licensing makes this impossible to ship in an open-source template. Users with EE can swap the image themselves.
- **Database GUI tools** (pgAdmin, Adminer). Add them in a `docker-compose.override.yml` — they have no business in a prod stack.
- **Reverse proxies other than Nginx.** Caddy and Traefik are great; they're just not this project.

---

## Want to influence the roadmap?

Open a discussion or issue describing the use case. Concrete production pain points carry more weight than "it would be nice if".
