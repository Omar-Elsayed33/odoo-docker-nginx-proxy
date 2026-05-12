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

### Planned
- `docker-compose.yml` wiring Nginx, Odoo, PgBouncer, and PostgreSQL.
- `config/odoo.conf`, `config/nginx/`, and `pgbouncer/` configuration files.
- `scripts/backup.sh` and `scripts/restore.sh`.
- Self-signed cert bootstrap and Let's Encrypt sidecar example.
- CI pipeline (lint, compose config validation, hadolint).

---

## [0.0.1] — 2026-05-13

Initial repository.

[Unreleased]: https://github.com/<your-user>/odoo-docker-nginx-proxy/compare/v0.0.1...HEAD
[0.0.1]: https://github.com/<your-user>/odoo-docker-nginx-proxy/releases/tag/v0.0.1
