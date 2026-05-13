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

### Planned
- PgBouncer in transaction-pool mode between Odoo and PostgreSQL.
- Rate-limit enforcement on `/web/login` and `/web/database/*` (v0.4).
- `scripts/backup.sh` and `scripts/restore.sh`.
- Let's Encrypt certbot sidecar with auto-renewal (v0.5).
- CI pipeline (lint, compose config validation, hadolint).

---

## [0.0.1] — 2026-05-13

Initial repository.

[Unreleased]: https://github.com/<your-user>/odoo-docker-nginx-proxy/compare/v0.0.1...HEAD
[0.0.1]: https://github.com/<your-user>/odoo-docker-nginx-proxy/releases/tag/v0.0.1
