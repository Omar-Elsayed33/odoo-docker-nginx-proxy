# Installation guide

How to go from `git clone` to a running Odoo. This document covers the
**local-development** path. For a production VPS deployment, follow
[production-deployment.md](production-deployment.md) — it picks up
where this guide ends.

## Contents

- [Prerequisites](#prerequisites)
- [Install in 3 commands](#install-in-3-commands)
- [What `install.sh` actually does](#what-installsh-actually-does)
- [Verifying the install](#verifying-the-install)
- [Common installation issues](#common-installation-issues)
- [Updating after an install](#updating-after-an-install)
- [Uninstalling cleanly](#uninstalling-cleanly)

---

## Prerequisites

| Tool | Minimum | Check with |
|---|---|---|
| Docker Engine | 24.0 | `docker --version` |
| Docker Compose plugin | 2.20 | `docker compose version` |
| `bash` | 4.x | `bash --version` |
| `openssl` | any recent | `openssl version` |

### Platform notes

- **Linux**: install Docker Engine + Compose plugin from your distro's
  package manager or Docker's official repo. Add your user to the
  `docker` group (`sudo usermod -aG docker $USER`, then log out / in).
- **macOS**: Docker Desktop ships Compose v2.20+ by default.
- **Windows**: Docker Desktop with WSL 2 backend. All `./scripts/*.sh`
  commands must be run from **Git Bash** or a WSL terminal, not from
  PowerShell or CMD. PowerShell can run `docker compose` directly.

### Disk and RAM

Local development is comfortable on a machine with at least 4 GB free
RAM and 5 GB free disk. The first `docker compose up` pulls roughly
2 GB of images; subsequent starts are seconds.

---

## Install in 3 commands

```bash
git clone https://github.com/<your-user>/odoo-docker-nginx-proxy.git
cd odoo-docker-nginx-proxy
./scripts/install.sh && ./scripts/start.sh
```

That's the whole flow. The first run pulls images (one-time, ~2 GB)
and creates fresh volumes; subsequent starts take seconds.

Open **<https://localhost/>**. Your browser will warn about the
self-signed certificate — accept it (or generate a trusted one; see
[`nginx/certs/README.md`](../nginx/certs/README.md)). Create your first
database via Odoo's database manager using the `ODOO_ADMIN_PASSWD`
value from `.env`.

---

## What `install.sh` actually does

The script is **idempotent** — re-running it doesn't clobber any
file you've already customised. Step by step:

| Step | What it does | What it skips |
|---|---|---|
| 1. Preflight | Verifies `docker`, `openssl`, `bash`, and `docker compose` are on PATH | Fails fast with a clear message if any is missing |
| 2. `.env` | Copies `.env.example` → `.env` | Leaves an existing `.env` alone |
| 3. Secrets | Replaces `POSTGRES_PASSWORD` / `ODOO_ADMIN_PASSWD` placeholders with 40-char random strings (`openssl rand -base64 32`) | Leaves any value that doesn't look like the literal placeholder |
| 4. TLS | Generates a self-signed certificate for `localhost` valid for 365 days into `nginx/certs/` | Leaves real certs in place if `fullchain.pem` + `privkey.pem` already exist |
| 5. PgBouncer userlist | Generates `pgbouncer/userlist.txt` from `.env` credentials | Leaves an existing non-empty file alone (treats empty as missing — see [troubleshooting.md](troubleshooting.md)) |
| 6. Compose validate | Runs `docker compose config --quiet` | Reports issues without aborting |

The script writes to stderr with colored log lines and leaves `.env`
ready to edit if you want to customise further before starting.

---

## Verifying the install

After `./scripts/start.sh` reports "stack is up", run:

```bash
# All four services healthy?
docker compose ps

# Anything in the error stream?
./scripts/logs.sh --errors --no-follow

# Direct probe through nginx
curl -fsSk https://localhost/web/health     # expect: {"status": "pass"}
curl -fsSI http://localhost/                # expect: HTTP/1.1 301 to https
```

Expected `docker compose ps` output:

```
NAME              STATUS
odoo-db           Up X minutes (healthy)
odoo-pgbouncer    Up X minutes (healthy)
odoo-app          Up X minutes (healthy)
odoo-nginx        Up X minutes (healthy)
```

If any service is `(unhealthy)` or `Restarting`, see
[troubleshooting.md](troubleshooting.md).

---

## Common installation issues

These are the failure modes contributors have actually hit. Full
catalogue in [troubleshooting.md](troubleshooting.md).

### "docker: command not found"

Docker isn't installed or isn't on PATH. On Linux, `sudo apt install docker.io docker-compose-v2` (Debian/Ubuntu) or your distro's equivalent. On macOS / Windows, install Docker Desktop.

### "permission denied while trying to connect to the Docker daemon"

Your user isn't in the `docker` group. `sudo usermod -aG docker $USER`, then **log out and back in** (group membership doesn't refresh in your current shell).

### "bash: ./scripts/install.sh: Permission denied" on Linux/Mac

Scripts lost their executable bit. `chmod +x scripts/*.sh scripts/lib/*.sh pgbouncer/generate-userlist.sh`.

### "bash: ./scripts/install.sh: cannot execute" on Windows PowerShell

PowerShell can't run bash scripts directly. Run them through Git Bash:
`bash ./scripts/install.sh`. Or open a Git Bash terminal and run them
the normal way: `./scripts/install.sh`.

### `error: POSTGRES_PASSWORD … looks like a placeholder`

Your `.env` still has the literal default password. Edit `.env` and
replace `POSTGRES_PASSWORD=change-me-…` with something real, or just
re-run `./scripts/install.sh` (it'll fill the placeholder with `openssl
rand` output).

### Self-signed certificate warning in browser

Expected. The cert generated by `install.sh` is not issued by a public
CA. Accept the warning for local development, or generate a real cert
per [`nginx/certs/README.md`](../nginx/certs/README.md).

### `port is already allocated` on 80 or 443

Another service on your machine is using these ports (often a host
nginx, Apache, or another Docker stack). Either stop the other service
or change the published port in `.env`:

```bash
NGINX_HTTP_PORT=8080
NGINX_HTTPS_PORT=8443
```

Then `./scripts/stop.sh && ./scripts/start.sh`. Access via
<https://localhost:8443/>.

---

## Updating after an install

Three update paths, depending on what changed.

### Pulling repo changes without touching data

```bash
git pull
./scripts/update.sh        # auto-backs-up, pulls images, recreates changed services
```

`update.sh` is the safe path — it takes a backup of every Odoo database
before pulling anything, so a regression in a new image is one
`./scripts/restore.sh` away from being undone.

### Rotating credentials

```bash
# 1. Edit POSTGRES_PASSWORD / ODOO_ADMIN_PASSWD in .env
# 2. Update Postgres to match:
docker compose exec db psql -U "$POSTGRES_USER" -c \
  "ALTER ROLE \"$POSTGRES_USER\" PASSWORD '<new-password>';"
# 3. Regenerate pgbouncer userlist:
./pgbouncer/generate-userlist.sh
# 4. Reload pgbouncer:
docker compose exec pgbouncer kill -HUP 1
```

### Switching Odoo major versions

**Don't.** Or at least, not via `update.sh`. Cross-major version
changes are database migrations, not deploys. See the
[Switching Odoo versions](../README.md#why-this-stack) section of the
README for the prerequisites (backup, staging copy, OpenUpgrade,
rollback plan).

---

## Uninstalling cleanly

```bash
./scripts/stop.sh --volumes    # wipes named volumes after a confirmation
```

This removes the containers, the network, and the named volumes
(Postgres data + Odoo filestore). The repository itself stays. To
delete everything including the source:

```bash
cd ..
rm -rf odoo-docker-nginx-proxy
```

If you want to keep your data for a future re-install, omit the
`--volumes` flag. The named volumes survive `down` and are reattached
on the next `up`.
