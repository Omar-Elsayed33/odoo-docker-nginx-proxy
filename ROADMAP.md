# Roadmap

This document captures **what's planned**, **what's explicitly out of scope**, and **why**. It is the source of truth for "should I propose this feature?".

The project's north star: a Compose file you can read in five minutes and run in production by Friday.

**Target version:** Odoo **18.0** is the default and supported major. Odoo 17 and Odoo 19 are explicitly **not** the target — see [README.md → Switching Odoo versions](README.md#switching-odoo-versions). The scope is **standalone** deployment, not SaaS / multi-tenant.

---

## v0.1 — Minimum viable stack ✅ in progress

Goal: a working, opinionated Odoo deployment that boots cleanly from `.env.example`.

- [ ] `docker-compose.yml` with Nginx, Odoo, PgBouncer, PostgreSQL services
- [ ] `config/odoo.conf` parameterised via environment
- [ ] `config/nginx/` with TLS, gzip, websocket upgrade, sane proxy timeouts
- [ ] `pgbouncer/pgbouncer.ini` in transaction-pooling mode
- [ ] Named volumes for PG data and Odoo filestore
- [ ] Healthchecks on every service
- [ ] `scripts/backup.sh` (pg_dump + filestore tarball)
- [ ] `scripts/restore.sh`
- [ ] Self-signed cert bootstrap for local development

## v0.2 — Hardening

Goal: ship-it-to-a-VPS quality.

- [ ] Drop unnecessary capabilities (`cap_drop: [ALL]`) per service
- [ ] Read-only root filesystems where feasible
- [ ] Non-root users in every container
- [ ] Docker log rotation (`json-file` with size limits)
- [ ] Rate limiting on `/web/login` and `/web/database/*`
- [ ] Optional fail2ban sidecar / Nginx-level IP banning
- [ ] CIS-Docker benchmark gap analysis in `docs/security.md`

## v0.3 — Operations

Goal: you can actually run this without panic.

- [ ] Let's Encrypt sidecar (`acme.sh` or `certbot`) with auto-renewal
- [ ] Prometheus exporters (postgres_exporter, nginx-prometheus-exporter)
- [ ] Sample Grafana dashboards in `docs/observability/`
- [ ] Cron-driven off-host backup example (restic → S3-compatible target)
- [ ] Documented restore drill (the only backup that works is one you've restored)

## v0.4 — CI & quality

- [ ] GitHub Actions: `docker compose config` validation
- [ ] `hadolint` for any Dockerfiles we ship
- [ ] `shellcheck` for all `scripts/*.sh`
- [ ] `markdownlint` for docs
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
