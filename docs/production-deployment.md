# Production deployment

This is the operational reference for taking this stack live on a Linux
server. It assumes you've already worked with the stack locally and read
the top-level [README](../README.md), [architecture.md](architecture.md),
and [SECURITY.md](../SECURITY.md).

## Contents

- [Server requirements](#1-server-requirements)
- [Pre-deployment checklist](#2-pre-deployment-checklist)
- [Deployment](#3-deployment)
- [Environment separation](#4-environment-separation)
- [SSL strategy](#5-ssl-strategy)
- [Backup strategy](#6-backup-strategy)
- [Monitoring](#7-monitoring)
- [Scaling](#8-scaling)
- [Security recommendations](#9-security-recommendations)
- [Operational runbook](#10-operational-runbook)
- [Common production issues](#11-common-production-issues)
- [Before you cut over](#12-before-you-cut-over)

```
                              Internet
                                 │
                          ┌──────┴──────┐
                          │  Firewall   │  inbound: 80, 443, 22
                          │  (cloud-vm) │
                          └──────┬──────┘
                                 │
                          ┌──────┴──────┐
                          │   Server    │  Linux + Docker
                          │             │
                          │   nginx ───►│ TLS, gzip, security headers
                          │     │       │
                          │   odoo  ───►│ N workers, longpolling
                          │     │       │
                          │  pgbouncer ►│ transaction pool
                          │     │       │
                          │    db       │ persistent volume
                          │             │
                          │   backups/ ►│ off-host shipping
                          └─────────────┘
```

---

## 1. Server requirements

| Resource | Minimum | Recommended for ~50 active users |
|---|---|---|
| OS | Ubuntu 22.04 / Debian 12 / RHEL 9 | Same, kept patched |
| Architecture | x86_64 or arm64 | arm64 if cost matters; otherwise x86_64 |
| CPU | 2 cores | 4–8 cores |
| RAM | 4 GB | 8–16 GB |
| Disk | 20 GB SSD | 100 GB+ NVMe, snapshot-capable |
| Network | 100 Mbit symmetric | 1 Gbit |
| Docker Engine | 24.x or newer | 26.x |
| Docker Compose | v2.20+ | latest stable |

`deploy.resources.limits` in `docker-compose.prod.yml` requires
Compose v2.20+ for standalone (non-swarm) deployments.

### Why these numbers

- **RAM** dominates Odoo sizing. Each worker is ~250–700 MB at steady
  state. Postgres reserves ~256 MB for shared buffers plus per-connection
  cost. PgBouncer is negligible (~50 MB). 8 GB covers four workers,
  Postgres, nginx, and headroom.
- **CPU** dominates Odoo response latency. Workers are single-threaded
  CPython; more cores = more parallel requests.
- **Disk type** matters more than disk size for Postgres. A small NVMe
  beats a large spinning disk for any OLTP workload.

---

## 2. Pre-deployment checklist

Walk through this **on the production server**, not on your laptop.

### Server prep

- [ ] OS fully updated (`apt update && apt full-upgrade -y` or equivalent).
- [ ] Non-root user with sudo for ops; root login disabled in `/etc/ssh/sshd_config`.
- [ ] SSH key auth only (`PasswordAuthentication no`).
- [ ] Firewall configured: inbound 80, 443, 22 only. (UFW, nftables, or cloud-provider firewall.)
- [ ] Time sync running (`systemctl status systemd-timesyncd` or `chronyd`).
- [ ] Docker Engine 24+ installed; `docker compose version` reports 2.20+.
- [ ] User in `docker` group (`sudo usermod -aG docker $USER`, then re-login).
- [ ] Hostname matches the DNS A record pointing to this server.

### Repo + config

- [ ] Repo cloned to a non-home location (`/opt/odoo` or `/srv/odoo`).
- [ ] Owner is the deploying user, not root (`chown -R deploy:deploy /opt/odoo`).
- [ ] `.env.prod.example` copied to `.env`; every `REPLACE_WITH_OPENSSL_RAND` replaced with a real value.
- [ ] `DOMAIN`, `ACME_EMAIL` set to real values.
- [ ] `WORKERS` set to `(2 × CPU_cores) + 1`.
- [ ] `nginx/conf.d/odoo.conf` — `server_name` changed from `_` to `${DOMAIN}`.
- [ ] `odoo/config/odoo.conf` — `list_db = False` (block the database manager UI).

### TLS

- [ ] Real certificate at `nginx/certs/fullchain.pem` + `nginx/certs/privkey.pem` (not the self-signed dev one).
- [ ] Files `chmod 600`, owned by root.

### Verify before turning it on

```bash
# Compose parses cleanly with both files
docker compose config --quiet

# Show what nginx will serve (catches missing certs, bad DOMAIN)
docker compose run --rm --no-deps nginx nginx -t
```

---

## 3. Deployment

```bash
cd /opt/odoo

# One-time: generate cert (see "SSL strategy" below), then
./scripts/install.sh

# Bring it up
./scripts/start.sh

# Verify
./scripts/logs.sh --errors --no-follow
curl -fsSI https://${DOMAIN}/    # expect HTTP/2 200 (after first DB created)
```

With `COMPOSE_FILE` set in `.env`, every `scripts/` wrapper transparently
uses both the base and prod compose files — no separate `start-prod.sh`,
no remembering long `docker compose -f ... -f ... up -d` chains.

---

## 4. Environment separation

| Concern | Dev (local) | Production |
|---|---|---|
| Env file | `.env` (gitignored) | `.env` on the server (gitignored, never leaves the box) |
| Template | `.env.example` | `.env.prod.example` |
| Compose chain | `docker-compose.yml` (+ optional `docker-compose.override.yml`) | `docker-compose.yml` + `docker-compose.prod.yml` |
| TLS | self-signed (install.sh) | Let's Encrypt or commercial CA |
| Resource caps | unlimited | enforced via `docker-compose.prod.yml` |
| Restart policy | `unless-stopped` | `always` |
| `list_db` | `True` (so you can create test DBs) | `False` |
| Worker count | low (1–3) | `(2 × CPU) + 1` |
| Backups | manual | cron-driven, off-host |

**Never copy `.env` from dev to prod or vice versa.** Each environment
has its own credentials, its own volume names (`POSTGRES_VOLUME`), and
its own domain. Cross-contamination is the source of most "why is prod
talking to my laptop's database" incidents.

---

## 5. SSL strategy

### Option A — Let's Encrypt (free, automated, recommended)

Until the certbot sidecar lands in ROADMAP v0.5, run certbot in
"webroot" mode using nginx's already-wired `/.well-known/acme-challenge/`
path.

```bash
# Initial issuance (run when nginx is up and DOMAIN resolves to this host)
docker run --rm \
  -v "$(pwd)/nginx/certs:/etc/letsencrypt/live/${DOMAIN}" \
  -v odoo-certbot-webroot:/var/www/certbot \
  certbot/certbot certonly --webroot \
    -w /var/www/certbot \
    -d ${DOMAIN} \
    --email ${ACME_EMAIL} \
    --agree-tos --non-interactive

# Reload nginx without dropping connections
docker compose exec nginx nginx -s reload
```

Renewal: schedule weekly:

```cron
# /etc/cron.d/odoo-cert-renew
0 4 * * 1 deploy docker run --rm ... certbot renew && \
            docker compose exec nginx nginx -s reload
```

### Option B — Commercial / wildcard CA

Drop your `fullchain.pem` + `privkey.pem` into `nginx/certs/`, reload
nginx. See [`nginx/certs/README.md`](../nginx/certs/README.md) for the
verification commands and the safe rotation procedure.

### TLS hygiene

- [ ] `ssl-params.conf` ships with Mozilla intermediate profile. After
  you have a real cert, **uncomment the OCSP stapling block** in
  `nginx/templates/ssl-params.conf` — saves ~50 ms per first request.
- [ ] Test with [SSL Labs](https://www.ssllabs.com/ssltest/) — aim for A+.
  HSTS preload-eligibility lives in `nginx/templates/security-headers.conf`.
- [ ] Don't enable HSTS `preload` until you've run with `includeSubDomains`
  for at least 6 months without issues — removal from the preload list
  is slow.

---

## 6. Backup strategy

See [backup-and-restore.md](backup-and-restore.md) for the full
procedure, scheduling examples, and off-host shipping comparison. The
short version for production:

```bash
# Cron — nightly at 02:30, keep 14 days locally
30 2 * * * cd /opt/odoo && ./scripts/backup.sh --keep 14 \
            >> /var/log/odoo-backup.log 2>&1

# Cron — ship to off-host storage at 03:00
0 3 * * * deploy cd /opt/odoo && \
  RESTIC_REPOSITORY=b2:my-bucket:odoo \
  RESTIC_PASSWORD_FILE=/etc/odoo/restic.pass \
  restic backup ./backups/ --tag nightly && \
  restic forget --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --prune
```

The 3-2-1 rule, simplified:

- **3** copies of every backup (prod local + prod remote + audited archive)
- **2** different storage media (disk + object storage)
- **1** off-site (different region from prod)

### Restore drills

The only backup that works is one you've restored. Cadence: **monthly**
for the first quarter after going live, **quarterly** thereafter. See
[backup-and-restore.md → Restore drills](backup-and-restore.md#restore-drills)
for the procedure.

---

## 7. Monitoring

### Minimum viable

These run on the box itself, cost nothing extra:

```bash
# Container health at a glance
docker compose ps

# Live resource usage
docker stats --no-stream

# Errors in the last 5 minutes
./scripts/logs.sh --errors --since 5m --no-follow
```

Run them from cron and alert if anything regresses. A 10-line shell
script that checks `docker compose ps` for non-healthy services and
emails on change is a fully sufficient starter SLO.

### Sensible next step — Prometheus + Grafana

When the basics aren't enough, add side-car exporters and ship them to
a Grafana stack:

- `postgres_exporter` for Postgres internals (slow queries, cache hit
  ratio, dead tuples, replication lag if you add a replica).
- `nginx-prometheus-exporter` for request rate, latency, status codes.
- `pgbouncer_exporter` for pool saturation (`cl_waiting`) — the most
  actionable Odoo signal there is.
- `cadvisor` for per-container CPU / RAM / disk.

Wiring these into the stack is on ROADMAP v0.5 as `docs/observability/`.

### Log shipping

Production logs live in Docker's `json-file` driver (rotated 20 MB × 5
in `docker-compose.prod.yml` — ~100 MB per container before oldest is
discarded). For anything more than single-server debugging, ship them:

- **Loki + Promtail** if you already run Grafana.
- **Vector → S3** for cheap cold storage with structured search.
- **Self-hosted ELK / OpenSearch** for full-text Odoo log archaeology.

The `labels: "service=odoo,env=production"` field in the prod compose
file becomes a JSON tag on every line — your aggregator will pick it
up automatically.

---

## 8. Scaling

Take the cheap moves first.

### Vertical (easy)

1. More CPU cores → raise `WORKERS` in `.env` and `ODOO_CPUS` cap.
2. More RAM → raise `ODOO_MEMORY` and per-worker `limit_memory_*`
   in `odoo/config/odoo.conf`.
3. Faster disk → migrate Postgres volume to NVMe, set
   `synchronous_commit = off` (if you can tolerate the tiny window of
   committed-but-unflushed data on crash).

This works to a *surprising* level. A single VM with 8 cores and 16 GB
serves dozens of active Odoo users comfortably.

### Horizontal Odoo (when vertical isn't enough)

Multiple Odoo containers behind nginx, sharing one Postgres + PgBouncer:

```yaml
# docker-compose.scale.yml — additional override
services:
  odoo:
    deploy:
      replicas: 3
```

…and in `nginx/conf.d/odoo.conf`:

```nginx
upstream odoo_http {
    server odoo-1:8069;
    server odoo-2:8069;
    server odoo-3:8069;
    keepalive 32;
    hash $remote_addr consistent;   # session affinity
}
```

The filestore must be shared (NFS, EFS, GCS-FUSE) when there are
multiple Odoo replicas, or attachments uploaded on one replica won't
be visible on another.

### Horizontal Postgres

Don't unless you're sure you need it. Odoo's ORM doesn't natively
support read replicas; you can run streaming replication for DR /
warm-standby, but query routing to the replica is per-addon work.

Sequence to consider, in order:

1. Vertical Postgres scaling + PgBouncer tuning.
2. Move the Postgres volume to a managed PG service (RDS, Crunchy
   Bridge) — frees the host for the app and gets you backups, replicas,
   and version upgrades as managed concerns.
3. Streaming replication + manual failover. Last resort.

---

## 9. Security recommendations

The bar for "good enough" depends on what's in the database. Crank it
up for anything regulated.

### Container hardening (what `docker-compose.prod.yml` already does)

- `cap_drop: [ALL]` + minimal `cap_add` per service.
- `security_opt: [no-new-privileges]`.
- Resource limits prevent fork bombs / memory exhaustion from one
  bad worker.
- Restart policy `always`.

### What you should add (ROADMAP v0.4)

- **Read-only root filesystem** for nginx + odoo + db where the image
  permits, with `tmpfs` for genuinely-writable paths.
- **Image pinning by digest**, not by floating tag. `ODOO_IMAGE=odoo@sha256:<digest>`.
- **Vulnerability scanning** — `trivy image` or `grype` on a schedule.
- **AppArmor / SELinux** profile for each service.

### Network

- Inbound: 22, 80, 443 only at the cloud firewall.
- 22 from your bastion / management network only, not 0.0.0.0/0.
- Disable IPv6 inbound if you're not using it.
- Outbound from the server can be locked down too (egress to Docker
  Hub + Let's Encrypt + your backup target is all that's needed).

### Auth

- [ ] Strong `ODOO_ADMIN_PASSWD` (40+ chars random). Stored only on the
  server, never in chat / tickets / git.
- [ ] `list_db = False` in `odoo/config/odoo.conf`.
- [ ] Block `/web/database/*` at nginx after first DB creation —
  it's only needed once.
- [ ] Force 2FA for all Odoo admin users (Odoo enterprise feature, or
  the `auth_totp` community addon).

### Secrets management

`.env` on the host works for one server. As soon as you have two:

- **Docker secrets** (swarm mode, or compose 3.1 secrets which work
  standalone in v2.20+).
- **External vault** (Hashicorp Vault, AWS Secrets Manager) with
  `secrets:` mounted at runtime.
- **Sealed env** via SOPS or age, decrypted in CI on deploy.

### Updates

- Pin images, but update them deliberately.
- `./scripts/update.sh` takes a safety backup first; use it.
- **NEVER** run `update.sh` across a major Odoo version (e.g. 18 → 19).
  See README → "Switching Odoo versions".
- Test minor updates on a staging copy of prod before pulling on prod.

---

## 10. Operational runbook

| Task | Command |
|---|---|
| Tail errors across all services | `./scripts/logs.sh --errors` |
| Show running services | `docker compose ps` |
| Reload nginx after config edit | `docker compose exec nginx nginx -s reload` |
| Reload pgbouncer after `.ini` edit | `docker compose exec pgbouncer kill -HUP 1` |
| Show pool state | `docker compose exec pgbouncer psql -h 127.0.0.1 -p 6432 -U odoo pgbouncer -c "SHOW POOLS;"` |
| Take a manual backup | `./scripts/backup.sh --keep 14` |
| Restore from backup | `./scripts/restore.sh /path/to/archive.tar.gz` |
| Minor-version update | `./scripts/update.sh` |
| Drain for Postgres maintenance | `docker compose exec pgbouncer psql ... -c "PAUSE;"` |
| Resume | `docker compose exec pgbouncer psql ... -c "RESUME;"` |
| Open Odoo shell inside container | `docker compose exec odoo odoo shell -d <dbname>` |

---

## 11. Common production issues

See [troubleshooting.md](troubleshooting.md) for the full failure-mode
catalogue. The production-specific entries:

| Symptom | First check | Likely cause |
|---|---|---|
| Workers OOM-killed | `dmesg \| tail`, `docker stats` | `limit_memory_hard` in `odoo.conf` exceeds container memory — lower one or raise the other |
| Login spam from bots | nginx `access.log` | Turn on the rate-limit zones in `nginx/conf.d/odoo.conf` (already declared; just add `limit_req` directives in the `/web/login` location) |
| `cl_waiting` consistently > 0 in `SHOW POOLS` | PgBouncer stats | Pool too small — raise `default_pool_size` in `pgbouncer.ini` |
| Postgres slow after weeks of uptime | `\dt+`, `pg_stat_user_tables` | Bloat — schedule `VACUUM ANALYZE` weekly via cron |
| Bus / chat sluggish | longpolling worker logs | Either nginx isn't forwarding websocket Upgrade (verify in browser devtools), or PgBouncer is in transaction mode and you need the bypass for the longpolling worker — see [pgbouncer.md](pgbouncer.md) |
| Disk full | `df -h`, `docker system df` | Backups not pruning, log retention too generous, old images not GC'd — `docker system prune --volumes` carefully |

---

## 12. Before you cut over

A final checklist for the deploy itself:

- [ ] DNS A record for `${DOMAIN}` points at this server (verify with `dig +short`).
- [ ] Real TLS cert in place, browser-trusted (test from a clean profile).
- [ ] Backups have completed once and restored successfully on a staging box.
- [ ] Off-host backup destination authenticated and tested.
- [ ] Healthchecks all green in `docker compose ps`.
- [ ] Cron jobs (backup, log rotation, cert renewal) installed and `journalctl -u cron --since "10 minutes ago"` shows them running.
- [ ] Someone other than you can deploy this. Document the runbook
  *they* would need.
