# Contributing

Thanks for considering a contribution. This project aims to stay
**small, opinionated, and production-ready** — the bar for new features
is "would I run this in production tomorrow?".

## Contents

- [Ways to contribute](#ways-to-contribute)
- [First-time contributors](#first-time-contributors)
- [Development workflow](#development-workflow)
- [Branch naming](#branch-naming)
- [Commit messages](#commit-messages)
- [Pull request checklist](#pull-request-checklist)
- [Code style](#code-style)
- [Reporting security issues](#reporting-security-issues)
- [License](#license)

---

## Ways to contribute

| Type | What's useful |
|---|---|
| **Bug report** | Minimal reproduction + outputs of `docker compose config`, `docker compose ps`, and relevant `./scripts/logs.sh --errors`. |
| **Documentation** | Fixes, clarifications, and runbooks for failure modes you've hit yourself. The [troubleshooting](docs/troubleshooting.md) catalogue grows one real failure at a time. |
| **Hardening** | Security improvements, sane defaults, and observability. High-value contributions. See [ROADMAP.md](ROADMAP.md) v0.4. |
| **Feature** | Open an issue first to discuss scope. See [ROADMAP.md](ROADMAP.md) → "Explicitly out of scope" before proposing anything that touches custom modules, multi-tenant orchestration, or non-Compose deployment targets. |

If you're not sure whether something fits, open an issue and ask
rather than building it and finding out at review time.

---

## First-time contributors

Never opened a PR against an open-source project before? The shape of
a contribution is mechanical; here's a tight walkthrough.

1. **Fork** the repository on GitHub (button in the top-right of the
   repo page).
2. **Clone** your fork locally:
   ```bash
   git clone https://github.com/<your-username>/odoo-docker-nginx-proxy.git
   cd odoo-docker-nginx-proxy
   git remote add upstream https://github.com/<original-owner>/odoo-docker-nginx-proxy.git
   ```
3. **Bring the stack up** so you have something to test against:
   ```bash
   ./scripts/install.sh
   ./scripts/start.sh
   ```
4. **Make your change** on a feature branch (see naming convention below).
5. **Test it** locally — `docker compose config --quiet` at minimum;
   for behavioural changes, restart the affected services and verify.
6. **Commit** with a Conventional Commits message (see below).
7. **Push** to your fork and **open a PR** against the upstream repo's
   `main` branch.

Reviewers will leave comments inline. Address them by pushing more
commits to the same branch — the PR updates automatically.

---

## Development workflow

```bash
# 1. Sync your fork with upstream
git checkout main
git fetch upstream && git merge upstream/main

# 2. Branch
git checkout -b feature/<short-description>

# 3. Bring the stack up (if not already running)
./scripts/install.sh    # idempotent — safe to re-run
./scripts/start.sh

# 4. Make your change. Validate the compose file:
docker compose config --quiet

# 5. Run any relevant scripts as a smoke test (for ops-script changes)
./scripts/backup.sh --keep 3
./scripts/logs.sh --errors --no-follow

# 6. Commit and push
git commit -m "feat(nginx): add rate limiting on /web/login"
git push origin feature/<short-description>

# 7. Open a PR against `main`
```

---

## Branch naming

- `feature/<slug>` — new functionality
- `fix/<slug>` — bug fixes
- `docs/<slug>` — documentation only
- `chore/<slug>` — tooling, deps, refactors with no behavior change
- `security/<slug>` — security fixes (see [SECURITY.md](SECURITY.md) first for non-public issues)

Slugs use lowercase and hyphens: `feature/rate-limit-login`, not
`feature/RateLimitLogin`.

---

## Commit messages

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <subject>

<body>

<footer>
```

| Type | When to use |
|---|---|
| `feat` | New functionality visible to operators |
| `fix` | Bug fix |
| `docs` | Documentation only |
| `chore` | Tooling, deps, refactors with no behavior change |
| `perf` | Performance improvement |
| `refactor` | Code restructure with no behavior change |
| `test` | Adding or fixing tests (when we have them) |
| `security` | Security-relevant fix or hardening |

Examples:

- `feat(pgbouncer): expose reserve_pool_timeout via .env`
- `fix(nginx): proxy_pass websocket Upgrade for longpolling`
- `docs(readme): clarify worker count formula`
- `chore(deps): bump odoo image to 18.0-20260401`

The **body** explains *why*, not *what* — the diff already shows what
changed. A useful body for the example above:

```
The default of 5 s is fine for a single Odoo instance with a small
pool, but operators running horizontally-scaled Odoo behind one
PgBouncer want to tune this without editing pgbouncer.ini directly.
Falls back to the existing 5 s if unset.
```

---

## Pull request checklist

Before requesting review, make sure:

- [ ] `docker compose config --quiet` exits 0 (with and without
      `docker-compose.prod.yml` if you touched compose).
- [ ] `docker compose up -d` brings the stack up clean from a fresh
      `.env.example` if you changed anything install-related.
- [ ] You can reach the Odoo login page over HTTPS in a browser.
- [ ] [CHANGELOG.md](CHANGELOG.md) has an entry under `[Unreleased]`
      describing the change (one or two lines, not a novel).
- [ ] No secrets, real domain names, or production data in the diff.
- [ ] Shell scripts pass `shellcheck`. (If you don't have shellcheck
      installed: `docker run --rm -v "$PWD:/mnt" koalaman/shellcheck
      mnt/scripts/*.sh`.)
- [ ] Dockerfiles (if any) pass `hadolint`.
- [ ] Documentation updated for any new env vars, scripts, or
      behaviour you've added.

For PRs that touch the request path (nginx vhost, Odoo workers,
PgBouncer pool config), include a one-paragraph note in the PR
description explaining what you tested manually — `compose config`
validation is necessary but not sufficient there.

---

## Code style

### Shell

- Shebang: `#!/usr/bin/env bash`.
- First line of every script: `set -euo pipefail`.
- All scripts source `scripts/lib/common.sh` for logging and helpers
  rather than defining their own colour codes.
- Pass `shellcheck` cleanly.
- Quote every variable expansion (`"$foo"`, not `$foo`) unless you
  specifically want word-splitting.
- Use `[[ … ]]` not `[ … ]` for tests.

### YAML

- Two-space indent, no tabs.
- Keys roughly sorted within a service where it doesn't hurt
  readability (image, container_name, restart, depends_on,
  environment, volumes, ports, networks, healthcheck, logging).
- Comments explain *why* (a non-obvious choice), not *what* (the diff
  already shows what).

### Nginx

- One directive per line.
- Includes from `templates/` are explicit, not glob-loaded.
- Comments explain *why* non-default values are chosen, not what each
  directive means (that's in the nginx docs).

### Markdown

- Hard-wrap is optional; semantic line breaks are encouraged for
  diff-friendly history.
- Headings start at H1 for the document title, H2 for top-level
  sections, etc. Don't skip levels.
- Tables for comparisons and decision matrices; prose for explanations.
- Code blocks are language-tagged (` ```bash`, ` ```yaml`, ` ```nginx`,
  ` ```sql`, ` ```ini`) for syntax highlighting on GitHub.

---

## Reporting security issues

**Do not open a public issue for security vulnerabilities.** Disclosing
publicly before a fix is available puts every user of this template at
risk.

See [SECURITY.md](SECURITY.md) for the private disclosure process and
expected response timeline.

---

## License

By contributing, you agree that your contributions will be licensed
under the [MIT License](LICENSE).
