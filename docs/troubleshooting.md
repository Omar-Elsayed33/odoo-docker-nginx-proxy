# Troubleshooting

A catalogue of failure modes this stack has actually hit, organised by
**symptom** rather than by component — when something breaks, you
usually know what you saw, not which service is at fault.

Every entry has the form **symptom → likely cause → fix**, plus a
diagnostic command you can run before touching anything.

## Contents

- [Stack won't come up](#stack-wont-come-up)
- [Authentication failures](#authentication-failures)
- [Healthcheck failures](#healthcheck-failures)
- [Performance issues](#performance-issues)
- [Backup and restore](#backup-and-restore)
- [TLS and proxy](#tls-and-proxy)
- [Environment and configuration](#environment-and-configuration)
- [Cross-platform (Windows)](#cross-platform-windows)
- [Diagnostic recipes](#diagnostic-recipes)

---

## Stack won't come up

### `Image edoburu/pgbouncer:X.Y.Z: not found`

The PgBouncer image uses a `v<version>-pN` tag convention with a `v`
prefix and a packager-patch suffix. Raw upstream version numbers don't
exist as tags.

Diagnosis:

```bash
grep PGBOUNCER_VERSION .env
```

Fix: set `PGBOUNCER_VERSION=v1.25.1-p0` (or any tag from
<https://hub.docker.com/r/edoburu/pgbouncer/tags>). The compose-file
default already uses this form.

### `dependency failed to start: container X is unhealthy`

Compose's `depends_on … condition: service_healthy` aborted because a
prerequisite never became healthy. Identify which:

```bash
docker compose ps
```

Look for the service in `(unhealthy)` or `Restarting`. Its logs tell
you the actual reason:

```bash
./scripts/logs.sh --no-follow <service-name>
```

The most common offenders and their entries in this document:

- pgbouncer: see [PgBouncer ERROR: unknown parameter](#pgbouncer-error-unknown-parameter-pgbouncerdaemon)
- pgbouncer: see [PgBouncer SASL authentication failed](#pgbouncer-sasl-authentication-failed)
- db: see [Postgres rejects auth as POSTGRES_USER](#postgres-rejects-auth-as-postgres_user) (Odoo failures with the same root cause point here too)

### Containers loop on `touch: /etc/pgbouncer/userlist.txt: Read-only file system`

The edoburu/pgbouncer entrypoint runs `touch` + `chmod` on
`userlist.txt` at startup to enforce permissions. Against a read-only
bind mount, the entrypoint loops forever.

Fix: the bind mount in `docker-compose.yml` must NOT be `:ro`. Verify:

```bash
grep -A1 "pgbouncer:/etc/pgbouncer" docker-compose.yml
# Expected:  - ./pgbouncer:/etc/pgbouncer
# Wrong:     - ./pgbouncer:/etc/pgbouncer:ro
```

### `port is already allocated` on 80 / 443

Another service on the host owns the port. Diagnose:

```bash
sudo ss -ltnp | grep -E ':(80|443)\b'         # Linux
sudo lsof -nP -i :443 -sTCP:LISTEN            # macOS
Get-NetTCPConnection -LocalPort 443 -State Listen  # Windows PowerShell
```

Fix: either stop the conflicting service, or change the host-side port
in `.env` (`NGINX_HTTP_PORT=8080`, `NGINX_HTTPS_PORT=8443`) and restart
the stack. Then open `https://localhost:8443/`.

---

## Authentication failures

### Postgres rejects auth as `POSTGRES_USER`

Logs show repeatedly:

```
FATAL: password authentication failed for user "odoo"
```

Diagnosis — three places must agree on the password:

```bash
# 1. What's in .env
grep ^POSTGRES_PASSWORD .env

# 2. What's in the running Postgres volume
docker compose exec db psql -U odoo -c "SELECT 1;"   # uses libpq's expectation

# 3. What's in pgbouncer's userlist
cat pgbouncer/userlist.txt
```

Common cause: `.env` was edited after Postgres initialised. Postgres
stores the password from `POSTGRES_PASSWORD` on first init; later edits
to `.env` don't propagate.

Fix paths, choose one:

- **Nuke and pave** (if you have no real data):

  ```bash
  docker compose down -v
  ./scripts/install.sh    # fills any remaining placeholder secrets
  ./scripts/start.sh
  ```

- **Rotate in place** (preserves data):

  ```bash
  # Set a new password in .env, then:
  docker compose exec db psql -U "$POSTGRES_USER" -c \
    "ALTER ROLE \"$POSTGRES_USER\" PASSWORD '<new>';"
  ./pgbouncer/generate-userlist.sh
  docker compose up -d --force-recreate pgbouncer odoo nginx
  ```

### PgBouncer "SASL authentication failed"

Logs show:

```
ERROR ...: password authentication failed
WARNING ...: pooler error: SASL authentication failed
```

This means Odoo (or another client) sent a password that doesn't match
what's in `userlist.txt`. Diagnose:

```bash
grep ^POSTGRES_PASSWORD .env
cat pgbouncer/userlist.txt    # must contain the same password
```

Fix: regenerate userlist and recreate pgbouncer:

```bash
rm -f pgbouncer/userlist.txt
./pgbouncer/generate-userlist.sh
docker compose up -d --force-recreate pgbouncer
```

### PgBouncer "no such user: odoo"

`userlist.txt` is missing the user PgBouncer is being asked to
authenticate. Often a **zero-byte file** left behind by an interrupted
or aborted run of `generate-userlist.sh`.

```bash
wc -c pgbouncer/userlist.txt    # if 0, that's your bug
```

Fix: regenerate. (`install.sh` is now hardened to treat empty as
missing; if your `install.sh` predates the fix, `rm` then regenerate
explicitly.)

### PgBouncer "ERROR unknown parameter: pgbouncer/daemon"

PgBouncer 1.25 removed the `daemon` config setting. If your
`pgbouncer.ini` still has `daemon = 0`, delete the line. The container
runs in the foreground by default.

---

## Healthcheck failures

### `odoo` is `(unhealthy)` but reachable in the browser

`/web/health` returns non-200 during heavy database operations
(migrations, large imports). The default `start_period` is 60 s; if
your hardware is slow on cold start, raise it in
`docker-compose.yml`:

```yaml
healthcheck:
  start_period: 180s
```

If `/web/health` returns 200 manually but the container is still
marked unhealthy, check whether `wget` is actually in your Odoo image
(it's in the official one — but if you've customised, the healthcheck
binary may have changed).

### `pg_isready` succeeds but PgBouncer rejects connections

`pg_isready` checks that the server is *accepting* connections, not
that it can authenticate. PgBouncer can be "healthy" by the
healthcheck's definition while every actual login fails. See
[PgBouncer SASL authentication failed](#pgbouncer-sasl-authentication-failed)
or [PgBouncer "no such user"](#pgbouncer-no-such-user-odoo).

### Nginx is healthy but `https://localhost/` hangs

Nginx serves `/nginx-health` over HTTP on port 80 (no TLS needed),
which is what the healthcheck hits. The hang is on HTTPS — usually
because the TLS cert is missing or unreadable. Check:

```bash
docker compose exec nginx nginx -t
docker compose exec nginx ls -la /etc/nginx/certs/
```

If `fullchain.pem` or `privkey.pem` is missing, regenerate via
`install.sh` or follow [`nginx/certs/README.md`](../nginx/certs/README.md).

---

## Performance issues

### Slow Odoo response times

The first thing to check is **pool saturation**:

```bash
docker compose exec pgbouncer \
  psql -h 127.0.0.1 -p 6432 -U odoo pgbouncer -c "SHOW POOLS;"
```

Look at `cl_waiting` — clients waiting for a backend slot. If
consistently > 0, raise `default_pool_size` in `pgbouncer.ini` and
reload (`docker compose exec pgbouncer kill -HUP 1`).

Then check **worker CPU saturation**:

```bash
docker stats --no-stream
```

If `odoo` is pegged at its `cpus:` limit, either raise the limit or
add workers (`WORKERS` in `.env`, then restart).

### Bus / chat feels sluggish

Expected if PgBouncer is in transaction mode (the default). Odoo's bus
falls back to polling instead of `LISTEN/NOTIFY` push because
transaction-mode pooling loses the LISTEN registration when a
connection returns to the pool. See [pgbouncer.md → LISTEN/NOTIFY](pgbouncer.md#listennotify-and-the-odoo-bus)
for the bypass instructions.

### Database queries getting slower over time

Postgres bloat. Schedule a weekly `VACUUM ANALYZE`:

```bash
docker compose exec db psql -U "$POSTGRES_USER" -d <dbname> -c "VACUUM ANALYZE;"
```

For aggressive bloat (high-churn tables), `VACUUM FULL` reclaims more
space but requires an exclusive lock. Do it during a maintenance
window.

### Disk filling up

```bash
df -h
docker system df
```

Likely culprits, in descending order of frequency:

1. **Backups not pruning.** Check `--keep` is set on your backup cron.
2. **Old images not GC'd.** `docker system prune` (careful — also
   removes stopped containers).
3. **Log retention too generous.** Lower `max-size` / `max-file` in
   `docker-compose.yml` logging blocks.
4. **Postgres bloat.** See above.

---

## Backup and restore

### `backup.sh`: "no application databases found"

The script automatically finds the one Odoo application database in the
cluster. If there are zero, you haven't created one yet (do it from
`/web/database/manager`). If there are multiple, pass `--database
<name>`.

### `backup.sh`: errors like `role "odoo" does not exist`

The script looks up `POSTGRES_USER` from `.env` and uses it. If the
running Postgres has a different role name, you'll see this error.
Diagnose:

```bash
docker compose exec db printenv POSTGRES_USER
grep ^POSTGRES_USER .env
```

Both should be the same. If not, decide which is canonical and align
the other.

### `restore.sh`: "checksum mismatch — archive is corrupt"

The archive's `database.dump` doesn't match the sha256 recorded in its
manifest. Either:

- Disk failure mid-write.
- Truncated `scp` / network transfer.
- Someone manually repacked the archive (don't).

Get a fresh copy from off-host.

### `restore.sh`: "archive missing manifest.txt"

Archive wasn't produced by this stack's `backup.sh`. If it's a raw
`pg_dump` file from elsewhere, use Odoo's own `/web/database/restore`
or `pg_restore` manually.

---

## TLS and proxy

### Browser shows "Your connection is not private"

Expected when using the self-signed cert `install.sh` generates. Either
accept the warning for local development, or provision a real cert per
[`nginx/certs/README.md`](../nginx/certs/README.md).

### Odoo generates `http://` URLs even though I'm on HTTPS

`proxy_mode = False` in `odoo.conf`, or nginx isn't forwarding the
`X-Forwarded-Proto` header. Check:

```bash
grep proxy_mode odoo/config/odoo.conf       # expect: proxy_mode = True
grep "X-Forwarded-Proto" nginx/templates/proxy-params.conf
```

Both should be set. Reload nginx + restart odoo if you change either.

### Login form rejects valid credentials with no error

Browser is sending the cookie over plain HTTP because the redirect
isn't firing, OR Odoo isn't recognising HTTPS because `proxy_mode` is
off. Same fix as above.

### Websocket / chat shows "Disconnected" banner

Nginx isn't forwarding the `Upgrade` header. Check:

```bash
grep -A4 "location.*=.*/websocket" nginx/conf.d/odoo.conf
# Should include:
#   proxy_set_header Upgrade $http_upgrade;
#   proxy_set_header Connection $connection_upgrade;
```

The base config ships this correctly; only worry about it if you've
customised the vhost.

---

## Environment and configuration

### `.env` changes not taking effect

Compose interpolates `.env` at `docker compose up` time, not at every
docker command. Restart the affected service:

```bash
docker compose up -d --force-recreate <service>
```

For variables that Postgres reads only on first init
(`POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`), see the
[Postgres rejects auth](#postgres-rejects-auth-as-postgres_user) section.

### `load_env_var` returns a value with weird trailing characters

`.env` has Windows CRLF line endings, and the script's CRLF-strip
didn't catch them. Normalise the file once:

```bash
sed -i 's/\r$//' .env
file .env    # expect: ASCII text, no CRLF mention
```

---

## Cross-platform (Windows)

### "bash: ./scripts/install.sh: cannot execute"

PowerShell can't run bash directly. Two options:

```powershell
# Option 1: run through Git Bash
bash ./scripts/install.sh

# Option 2: open a Git Bash terminal, then run as normal
./scripts/install.sh
```

### Scripts run but `.env` lookups return wrong values

Notepad / Notepad++ save `.env` with CRLF by default. Some scripts'
older versions of `load_env_var` strip only `\n`, leaving `\r` baked
into the value — which then propagates into psql / passwords / paths.
Fix:

```bash
# In Git Bash
sed -i 's/\r$//' .env pgbouncer/userlist.txt 2>/dev/null
```

Configure your editor to save with LF line endings going forward. In
VS Code, click `CRLF` in the bottom right and switch to `LF`.

### File-permission warnings about `userlist.txt`

`chmod 600` doesn't fully translate to Windows ACLs. The file is still
readable only by the owner under Git Bash, but Windows Explorer's
"properties" dialog might show the permissions differently. Functionally
fine.

---

## Diagnostic recipes

When you don't know which way is up, run these and bring the output to
the question:

### Snapshot of the whole stack

```bash
echo "── compose ──"
docker compose ps

echo "── env (sanitised) ──"
grep -v -E "PASSWORD|PASSWD|SECRET" .env

echo "── recent errors ──"
./scripts/logs.sh --errors --no-follow --since 10m

echo "── disk ──"
df -h .
docker system df

echo "── pool state (if pgbouncer is up) ──"
docker compose exec pgbouncer \
  psql -h 127.0.0.1 -p 6432 -U odoo pgbouncer -c "SHOW POOLS;" 2>/dev/null || true
```

### Single-service deep dive

```bash
SVC=odoo    # or db / pgbouncer / nginx
docker compose ps "$SVC"
docker compose logs --tail=100 "$SVC"
docker inspect $(docker compose ps -q "$SVC") \
  | jq '.[0] | {State, RestartCount: .RestartCount, Health: .State.Health}'
```

### Reproduce a config issue without affecting prod

```bash
# Render the merged compose config that compose would actually use
docker compose config

# Validate without running anything
docker compose config --quiet && echo "OK"
```

### Open a one-off shell inside a service

```bash
docker compose exec odoo bash
docker compose exec db psql -U "$POSTGRES_USER" -d postgres
docker compose exec pgbouncer sh
docker compose exec nginx sh
```

---

If your issue isn't here, the right next step is usually
`./scripts/logs.sh --errors`. Most failures in this stack leave a clear
breadcrumb in the logs the first time they happen.
