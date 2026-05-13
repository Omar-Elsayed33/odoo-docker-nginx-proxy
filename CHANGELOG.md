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
- `docker-compose.yml` wiring the base **Odoo + PostgreSQL** stack with named volumes, healthchecks, restart policies, an internal bridge network, and JSON-file log rotation. Database port is not published; Odoo HTTP/longpolling are bound to `127.0.0.1` only.
- `odoo/config/odoo.conf` — annotated server config: addons paths, data dir, workers, per-worker memory and time limits, longpolling on `gevent_port`, stdout logging, `proxy_mode = False` (flipped on when Nginx lands).
- `odoo/addons/` — host-mounted custom addons path with usage notes.
- `postgres/init/` — first-boot script directory with a `README.md` explaining ordering / lifecycle and an `10-extensions.sql.example` enabling `unaccent` and `pg_trgm`.

### Planned
- Nginx reverse proxy with TLS termination, websocket upgrade, and rate limiting on auth endpoints.
- PgBouncer in transaction-pool mode between Odoo and PostgreSQL.
- `scripts/backup.sh` and `scripts/restore.sh`.
- Self-signed cert bootstrap and Let's Encrypt sidecar example.
- CI pipeline (lint, compose config validation, hadolint).

---

## [0.0.1] — 2026-05-13

Initial repository.

[Unreleased]: https://github.com/<your-user>/odoo-docker-nginx-proxy/compare/v0.0.1...HEAD
[0.0.1]: https://github.com/<your-user>/odoo-docker-nginx-proxy/releases/tag/v0.0.1
