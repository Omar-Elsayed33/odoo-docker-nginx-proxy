# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Project bootstrap and documentation scaffolding.
- `README.md` with architecture diagram, production checklist, and an Odoo version-switching section.
- `LICENSE` (MIT).
- `.gitignore` covering secrets, runtime data, Python, Node, and editor noise.
- `.env.example` documenting every configurable variable, with `ODOO_VERSION` and `ODOO_IMAGE` centralised.
- `CONTRIBUTING.md`, `ROADMAP.md`, `SECURITY.md`.

### Defaults
- **Odoo 18.0** is the default and only tested major version for this repository. Other majors are not the target.

### Added (base stack)
- `docker-compose.yml` wiring the base **Odoo + PostgreSQL** stack with named volumes, healthchecks, restart policies, an internal bridge network, and JSON-file log rotation.
- `odoo/config/odoo.conf` — annotated server config: addons paths, data dir, workers, per-worker memory and time limits, longpolling on `gevent_port`, stdout logging.
- `odoo/addons/` — host-mounted custom addons path with usage notes.
- `postgres/init/` — first-boot script directory with a `README.md` explaining ordering / lifecycle and an `10-extensions.sql.example` enabling `unaccent` and `pg_trgm`.

### Added (Nginx reverse proxy — v0.2)
- `nginx` service in `docker-compose.yml`: stock `nginx:${NGINX_VERSION}-alpine`, healthchecked on `/nginx-health`, the only service that publishes host ports.
- `nginx/conf.d/odoo.conf` — vhost with HTTP→HTTPS redirect, ACME challenge path, TLS termination, two upstreams (HTTP + longpolling), websocket upgrade on `/websocket` and `/longpolling/`, static-asset caching on `/web/{static,content,image}/`, and pre-declared rate-limit zones (enforced in v0.4).
- `nginx/templates/` — reusable snippets included from the vhost:
  - `proxy-params.conf` — `X-Forwarded-*` headers, HTTP/1.1, buffering, timeouts.
  - `ssl-params.conf` — TLS 1.2 + 1.3, Mozilla intermediate cipher set, session cache, OCSP stapling commented and ready.
  - `security-headers.conf` — HSTS, X-Frame-Options SAMEORIGIN (Odoo iframes itself), Referrer-Policy, Permissions-Policy, COOP / CORP.
  - `gzip.conf` — compression for `text/*`, JSON, JS, XML, SVG.
- `nginx/certs/` — TLS material directory with a `README.md` documenting self-signed bootstrap and production cert workflows. Real cert files are gitignored.
- `nginx/README.md` — architecture diagram, file structure rationale, ops runbook (config test, zero-downtime reload, troubleshooting), and customisation guide (domain, upload size, rate limits, additional vhosts, horizontal scaling).

### Changed (Nginx reverse proxy — v0.2)
- `odoo` service: removed published host ports; Odoo is reachable only on the private bridge network now. Local debugging via `docker compose exec` or a `docker-compose.override.yml`.
- `odoo/config/odoo.conf`: flipped `proxy_mode = True` to trust nginx's forwarded headers. Comment hardened to flag the spoofing risk if the nginx layer is ever removed without flipping this back.
- `.env.example`: added `NGINX_VERSION`, `NGINX_HTTP_PORT`, `NGINX_HTTPS_PORT` so port collisions on 80/443 are configurable without editing YAML.

### Added (PgBouncer connection pooling — v0.3)
- `pgbouncer` service in `docker-compose.yml`: `edoburu/pgbouncer:${PGBOUNCER_VERSION:-v1.25.1-p0}` (image uses a `v<version>-pN` tag convention, *not* raw upstream PgBouncer numbers), healthchecked via `pg_isready`, depends on a healthy `db`, not published to the host.
- `pgbouncer/pgbouncer.ini` — transaction-mode pool, SCRAM-SHA-256 auth, wildcard `[databases]` route so newly-created Odoo databases work without re-config. Pool sizing (`default_pool_size=25`, `reserve_pool_size=5`, `max_db_connections=100`, `max_client_conn=200`) and timeouts tuned for a single Odoo instance with 3–4 HTTP workers.
- `pgbouncer/userlist.txt.example` — annotated template documenting the three auth modes and the security trade-offs of plaintext-vs-SCRAM on disk.
- `pgbouncer/generate-userlist.sh` — idempotent helper that reads `POSTGRES_USER` / `POSTGRES_PASSWORD` from `.env`, writes a `chmod 600` userlist.txt, refuses to run against placeholder passwords.
- `docs/pgbouncer.md` — first entry in the docs/ tree: why pooling matters for Odoo (process-per-connection cost, worker fan-out, connection churn, `max_connections` ceiling), how the layer is wired, first-time setup, tuning table with rule-of-thumb sizing, pool-mode trade-offs, the LISTEN/NOTIFY caveat and how to bypass the pool for the longpolling worker, runbook (SHOW POOLS / SHOW STATS / SIGHUP reload / PAUSE-RESUME maintenance window), and a troubleshooting table.

### Changed (PgBouncer connection pooling — v0.3)
- `odoo` service now `depends_on: pgbouncer (service_healthy)` and routes through it via `HOST=${ODOO_DB_HOST:-pgbouncer}` / `PORT=${ODOO_DB_PORT:-6432}`. `.env` can flip those back to `db` / `5432` to bypass the pool.
- `.env.example`: dropped the unused `PGBOUNCER_POOL_MODE` / `_MAX_CLIENT_CONN` / `_DEFAULT_POOL_SIZE` / `_RESERVE_POOL_*` knobs (PgBouncer does not envsubst its config). Added `PGBOUNCER_VERSION`, `ODOO_DB_HOST`, `ODOO_DB_PORT`. Comment explains tuning is via `pgbouncer.ini`.

### Added (operational scripts)
- `scripts/lib/common.sh` — shared color logging (respects `NO_COLOR` and non-TTY), `confirm` prompt with `--force` / `FORCE=1` bypass, `compose` wrapper that always runs from the repo root, `wait_healthy` with timeout, safe `load_env_var` (no `source` of `.env`).
- `scripts/install.sh` — idempotent first-time setup. Copies `.env.example` → `.env`, fills placeholder `POSTGRES_PASSWORD` / `ODOO_ADMIN_PASSWD` with `openssl rand`, generates self-signed TLS if `nginx/certs/` is empty, generates `pgbouncer/userlist.txt`, validates `docker compose config`. Never overwrites a hand-customised file.
- `scripts/start.sh` — preflight checks, `compose up -d`, waits for `db → pgbouncer → odoo → nginx` to all be healthy (180 s each), prints the access URL using `NGINX_HTTPS_PORT` from `.env`.
- `scripts/stop.sh` — `compose down` by default. `--pause` runs `compose stop` (keeps containers); `--volumes` wipes named volumes after a confirmation prompt.
- `scripts/backup.sh` — atomic, checksummed archive: `pg_dump -Fc` (direct to Postgres, bypassing PgBouncer because tx-mode pooling is incompatible with `pg_dump`'s snapshot semantics) + filestore tar + sha256-stamped manifest. Built in a temp dir and `mv`d into place so an interrupted backup leaves nothing partial. `--keep N` retention. `--database` for multi-DB clusters.
- `scripts/restore.sh` — verifies the archive's manifest sha256 before doing anything destructive, prompts (skippable via `--force`), kicks active sessions, drops + recreates the DB, `pg_restore -j 4`, replaces the filestore, waits for `/web/health`. `--target` to restore into a renamed DB.
- `scripts/update.sh` — takes a safety backup of every Odoo DB first (skippable via `--no-backup`), pulls images, recreates only changed services, waits healthy, prints a before/after image-diff. Comments explicitly forbid using it for major Odoo version jumps.
- `scripts/logs.sh` — `compose logs` wrapper. Sensible defaults (`--follow`, `--tail=200`), `--errors` mode that filters to ERROR/FATAL/WARN/Traceback lines.

### Changed (operational scripts)
- README: `Quick start` now points at `./scripts/install.sh` + `./scripts/start.sh` instead of raw `docker compose` commands. New "Operational scripts" section with the full table and one-liner cron examples.
- Repo layout in README updated to list the eight new files under `scripts/`.

### Added (production deployment surface)
- `docker-compose.prod.yml` — overrides applied on top of the base file: `restart: always`, `cap_drop: [ALL]` with minimal per-service `cap_add`, `security_opt: no-new-privileges`, env-driven `deploy.resources.limits` (CPU + memory) per service, tighter healthcheck cadence on odoo + nginx, log-rotation tightened to 20 MB × 5 with `service=…,env=production` labels for aggregator pickup.
- `.env.prod.example` — production env template with `COMPOSE_FILE=docker-compose.yml:docker-compose.prod.yml` so plain `docker compose` and every `scripts/` wrapper transparently apply the prod overrides. Production-oriented defaults: separate `POSTGRES_VOLUME` (`odoo-prod-pgdata`), real domain placeholder, `WORKERS=9`, resource caps per service.
- `docs/production-deployment.md` — server requirements table, pre-deployment checklist (server prep / repo / TLS / verify), step-by-step deploy, environment-separation table (dev ↔ prod), SSL strategy (Let's Encrypt webroot + commercial CA), backup strategy with 3-2-1 rule and restic example, monitoring tiers (MVP → Prometheus/Grafana → log shipping), scaling sequence (vertical → horizontal Odoo → horizontal Postgres last), security recommendations, operational runbook table, common production issues table, cut-over checklist.

### Changed (production deployment surface)
- README repo layout adds `docker-compose.prod.yml`, `.env.prod.example`, `docs/production-deployment.md`.
- README Documentation section now lists per-component docs (production, pgbouncer, nginx).

### Documentation pass (v1.0 readiness)
- README rewritten as a tight entry point: Contents TOC, "Why this stack" framing, Features table, Architecture diagram, 3-command Quick start, repo layout, Operational scripts table, Documentation link tree. Heavy content moved into per-concern docs.
- `docs/architecture.md` — new. Design rationale split into Components / Request flow / Data flow / Network topology / Configuration model / Lifecycle / Design decisions worth flagging / What's deliberately out of scope.
- `docs/installation.md` — new. Prerequisites table (Linux/macOS/Windows), 3-command install, what `install.sh` actually does, verifying the install, common installation issues, updating, uninstalling cleanly.
- `docs/backup-and-restore.md` — new. What's in a backup, taking a backup, restoring (in-place / renamed / non-interactive), scheduling (cron + systemd timer), off-host shipping (restic / rclone / borg comparison + restic example), restore drills with cadence, verification, encryption options, troubleshooting table.
- `docs/troubleshooting.md` — new. Symptom-organised catalogue of every failure mode this stack has actually hit: stack won't come up, auth failures, healthcheck failures, performance issues, backup/restore, TLS/proxy, env/config, cross-platform Windows, plus diagnostic recipes.
- `docs/production-deployment.md` — tightened: added Contents TOC, references `architecture.md` for the "why" and `backup-and-restore.md` instead of duplicating the backup section.
- `CONTRIBUTING.md` rewritten with: Contents TOC, first-time-contributor walkthrough, expanded development workflow, Conventional Commits type table with examples, code-style sub-sections per language (shell / YAML / nginx / markdown), expanded PR checklist.

### Added (CI & quality — v0.6)
- `.github/workflows/validate.yml` — two parallel jobs on every PR and on push to `main`: validates `docker compose config` for both the base chain and `base + prod`, and runs `shellcheck` (severity: error, `SC1091` excluded for `source`-resolution noise) across `scripts/` and `pgbouncer/generate-userlist.sh`.
- `.github/workflows/lint.yml` — markdownlint-cli2 across all `**/*.md`, configured via `.markdownlint.yaml`.
- `.markdownlint.yaml` — project-specific rule relaxations with one-line rationale per override: `MD013` (line length 200, off in tables / code blocks / headings), `MD024` (siblings-only so per-doc TOCs don't collide), `MD033`/`MD036`/`MD040` off (inline HTML reserved, bold-as-emphasis-in-prose, plaintext diagram blocks).
- `.github/pull_request_template.md` — Summary / Type / What changed / What's out of scope / Test plan checklist (CI verifies the first two boxes automatically) / Notes for reviewers.
- `.github/ISSUE_TEMPLATE/bug_report.yml` — form-based, requires git ref, platform, what-happened, expected, logs (rendered as shell), `docker compose ps`, with pre-submit checkboxes confirming secrets were redacted and troubleshooting.md was checked.
- `.github/ISSUE_TEMPLATE/feature_request.yml` — form-based, requires problem / proposal, with a ROADMAP "out of scope" scope-check checkbox to head off out-of-scope proposals at submission time.
- `.github/ISSUE_TEMPLATE/config.yml` — disables blank issues; routes security reports to `SECURITY.md` and conversations to GitHub Discussions.

### Planned
- Rate-limit enforcement on `/web/login` and `/web/database/*` (v0.4).
- Let's Encrypt certbot sidecar with auto-renewal (v0.5).
- Read-only root filesystems + image-pin-by-digest (v0.4).
- `hadolint` once we ship a Dockerfile of our own.
- Trivy / Grype image-vulnerability scan on a schedule (v0.6).

---

## [0.0.1] — 2026-05-13

Initial repository.

[Unreleased]: https://github.com/<your-user>/odoo-docker-nginx-proxy/compare/v0.0.1...HEAD
[0.0.1]: https://github.com/<your-user>/odoo-docker-nginx-proxy/releases/tag/v0.0.1
