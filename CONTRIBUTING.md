# Contributing

Thanks for considering a contribution. This project aims to stay **small, opinionated, and production-ready** — the bar for new features is "would I run this in production tomorrow?".

## Ways to contribute

- **Bug reports** — open an issue with a minimal reproduction and the output of `docker compose config`, `docker compose ps`, and relevant logs.
- **Documentation** — fixes, clarifications, and runbooks for failure modes you've hit are always welcome.
- **Features** — please open an issue first to discuss scope. See [ROADMAP.md](ROADMAP.md) for what's in/out.
- **Hardening** — security improvements, sane defaults, and observability are high-value contributions.

## Development workflow

```bash
# 1. Fork and clone
git clone https://github.com/<you>/odoo-docker-nginx-proxy.git
cd odoo-docker-nginx-proxy

# 2. Branch
git checkout -b feature/<short-description>
# or  fix/<short-description>
# or  docs/<short-description>

# 3. Configure a local stack
cp .env.example .env
# edit .env — use throwaway passwords locally

# 4. Bring it up
docker compose up -d
docker compose logs -f

# 5. Make your change. Re-validate the compose file:
docker compose config > /dev/null

# 6. Commit and push
git commit -m "feat(nginx): add rate limiting on /web/login"
git push origin feature/<short-description>

# 7. Open a PR against `main`
```

## Branch naming

- `feature/<slug>` — new functionality
- `fix/<slug>` — bug fixes
- `docs/<slug>` — documentation only
- `chore/<slug>` — tooling, deps, refactors with no behavior change
- `security/<slug>` — security fixes (see [SECURITY.md](SECURITY.md) first for non-public issues)

## Commit messages

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <subject>

<body>

<footer>
```

Examples:

- `feat(pgbouncer): expose reserve_pool_timeout via .env`
- `fix(nginx): proxy_pass websocket upgrade for longpolling`
- `docs(readme): clarify worker count formula`
- `chore(deps): bump odoo image to 18.0-20260401`

## Pull request checklist

Before requesting review, make sure:

- [ ] `docker compose config` parses without warnings.
- [ ] `docker compose up -d` brings the stack up clean from a fresh `.env.example`.
- [ ] You can reach the Odoo login page over HTTPS in a browser.
- [ ] `CHANGELOG.md` has an entry under `[Unreleased]`.
- [ ] No secrets, real domain names, or production data in the diff.
- [ ] Shell scripts pass `shellcheck`.
- [ ] Dockerfiles (if any) pass `hadolint`.

## Code style

- **Shell**: `#!/usr/bin/env bash`, `set -euo pipefail`, `shellcheck`-clean.
- **YAML**: 2-space indent, no tabs, keys sorted within a service where it doesn't hurt readability.
- **Nginx**: one directive per line, comments explain *why* not *what*.
- **Markdown**: hard-wrap is optional; semantic line breaks are encouraged.

## Reporting security issues

**Do not open a public issue for security vulnerabilities.** See [SECURITY.md](SECURITY.md) for the disclosure process.

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
