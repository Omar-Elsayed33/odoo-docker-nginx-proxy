# PgBouncer

PgBouncer is a lightweight connection pooler that sits between Odoo
and PostgreSQL. This document explains *why* it's worth running for
Odoo specifically, how it's wired into this stack, and how to tune
and operate it.

```
                       ┌──────────────────┐
   workers ──tx──►     │   PgBouncer      │   ──tx──► PostgreSQL
   (many short          │  transaction      │           (few warm
    connections)        │  pool, port 6432) │            backends)
                       └──────────────────┘
```

---

## Why PgBouncer matters for Odoo

PostgreSQL is a process-per-connection database: every client connection
forks a backend with its own ~10 MB of resident memory and a fair share
of cluster-wide CPU bookkeeping. That model is fine for a handful of
long-lived application connections but very expensive for an
application that **opens and closes connections rapidly**, which is
exactly Odoo's pattern.

Four specifics make Odoo particularly sensitive to this:

1. **Multi-worker architecture.** Odoo runs `N` HTTP workers (typically
   `(2 × CPU) + 1`) plus a longpolling worker plus the cron worker.
   Each worker is an independent Python process holding its own
   connection pool. With four workers and three concurrent transactions
   each, you're already at 12 backends just for one Odoo instance —
   and that's before queue jobs, reports, or imports.

2. **Connection churn.** Odoo's ORM opens a fresh transaction per HTTP
   request and closes the underlying connection eagerly. Without a
   pool, every request pays the cost of a Postgres backend startup
   (fork, auth handshake, catalog warm-up). On a busy instance this
   round-trip dominates latency for small queries.

3. **Database creation.** Odoo treats databases as multi-tenant units
   via `/web/database/manager`. Each new database requires its own
   pool, which PgBouncer handles transparently thanks to the wildcard
   route in `[databases]`. Without a pooler you'd be re-tuning
   Postgres `max_connections` every time you add a tenant.

4. **`max_connections` is a hard ceiling.** Setting Postgres'
   `max_connections` very high to "make room" wastes memory and slows
   the cluster (the planner walks the connection list). With PgBouncer
   you keep Postgres' `max_connections` modest (e.g. 100) and let the
   pool fan many client connections onto a small number of warm
   backends.

The practical win on a real Odoo deployment is roughly:
- **Latency**: 5–30 ms shaved off small queries (no backend fork).
- **Memory**: 5–10× fewer Postgres backends for the same workload.
- **Resilience**: a connection spike (e.g. an import job, a poorly
  written addon) is absorbed by the pool instead of cratering
  Postgres.

You feel none of this on a developer laptop with one user. You feel
all of it under real production load.

---

## How it's wired

```
docker-compose.yml
    └── pgbouncer service
        ├── image: edoburu/pgbouncer
        ├── mounts:  ./pgbouncer/      → /etc/pgbouncer/  (ro)
        │            ./pgbouncer/      → contains pgbouncer.ini + userlist.txt
        └── expose:  6432              (internal only, no host port)

odoo service
    └── environment:
        HOST = ${ODOO_DB_HOST:-pgbouncer}   # → pgbouncer by default
        PORT = ${ODOO_DB_PORT:-6432}
```

Authentication is **SCRAM-SHA-256 end-to-end**: Odoo authenticates to
PgBouncer with SCRAM, and PgBouncer authenticates to Postgres with
SCRAM. PgBouncer 1.18+ accepts plaintext entries in `userlist.txt`
and hashes them in memory at startup, so you don't need to pre-compute
SCRAM secrets by hand.

---

## First-time setup

```bash
# 1. Generate pgbouncer/userlist.txt from .env credentials
./pgbouncer/generate-userlist.sh

# 2. Bring the stack up
docker compose up -d
```

The script writes a `chmod 600` file containing one line:

```
"<POSTGRES_USER>" "<POSTGRES_PASSWORD>"
```

If you rotate `POSTGRES_PASSWORD`, re-run the script and reload
PgBouncer (`docker compose exec pgbouncer kill -HUP 1`).

If you'd rather not have plaintext on disk, query Postgres for the
SCRAM secret and paste it into `userlist.txt` instead — see the
example file for the exact form.

---

## Tuning

The four numbers that matter live in [`pgbouncer/pgbouncer.ini`](../pgbouncer/pgbouncer.ini).
Tuning is *edit the file, reload the container* — there's no env-var
plumbing because the gain isn't worth the indirection.

| Setting | Default | Tune up when… | Tune down when… |
|---|---|---|---|
| `max_client_conn` | 200 | Many concurrent users; longpolling clients keep connections open | Memory pressure on the pgbouncer container |
| `default_pool_size` | 25 | Slow queries are queuing (visible in `SHOW POOLS`) | Postgres backends idle most of the time |
| `reserve_pool_size` | 5 | Brief spikes (cron firing, report bursts) cause queueing | Pool is rarely saturated |
| `max_db_connections` | 100 | You raised Postgres' `max_connections` above ~150 | You lowered Postgres' `max_connections` |

Sizing rule of thumb:

```
peak_backends ≈ odoo_workers × concurrent_tx_per_worker
```

For a single Odoo with 4 HTTP workers and ~3 concurrent transactions
per worker under load, peak ≈ 12 backends. `default_pool_size = 25`
gives you 2× headroom — usually right.

Watch for queueing:

```bash
docker compose exec pgbouncer psql -h 127.0.0.1 -p 6432 -U odoo pgbouncer -c "SHOW POOLS;"
```

If `cl_waiting` is consistently > 0, raise `default_pool_size`.

---

## Pool mode trade-offs

PgBouncer is configured in **transaction mode**: a backend is returned
to the pool at the end of every transaction. This maximises pool
efficiency but breaks a handful of session-level Postgres features:

| Feature | Status under transaction mode |
|---|---|
| `LISTEN` / `NOTIFY` | `NOTIFY` works (fires inside a tx). `LISTEN` is unreliable — the connection is returned to the pool, losing the listener. |
| `WITH HOLD CURSOR` | Broken. The cursor lives in a session that gets recycled. |
| `PREPARE` / `EXECUTE` across requests | Broken. Each `EXECUTE` may land on a different backend. |
| `SET` session variables | Limited. Lasts only for the current transaction. |
| Temporary tables across statements in different transactions | Broken. |
| Transactions | Work as expected (each tx is one pool checkout). |

### LISTEN/NOTIFY and the Odoo bus

Odoo's chat / bus / notification system uses Postgres `NOTIFY` to push
events between workers, and historically used `LISTEN` for low-latency
pickup in the longpolling worker. Under transaction-mode pooling,
`LISTEN` is unreliable, so Odoo falls back to polling the `bus_bus`
table at a short interval. The user-visible effect is a tiny extra
latency (sub-second) for chat messages.

If sub-second bus latency matters to you, **bypass PgBouncer for the
longpolling worker** by overriding the DB host in a `docker-compose.override.yml`:

```yaml
services:
  odoo:
    environment:
      # Longpolling worker reads HOST/PORT at process start; the rest
      # of Odoo reads from odoo.conf. To split routing cleanly, run two
      # Odoo services pointed at the same filestore — one through
      # pgbouncer (workers), one direct to db (longpolling).
      HOST: db
      PORT: 5432
```

For most deployments, transaction-mode through PgBouncer is the right
default.

---

## Operations

### Show pool state

```bash
docker compose exec pgbouncer \
  psql -h 127.0.0.1 -p 6432 -U odoo pgbouncer -c "SHOW POOLS;"
```

Look at:
- `cl_active` — clients currently using a backend
- `cl_waiting` — clients waiting for a slot (should be 0)
- `sv_active` — backends in use
- `sv_idle` — backends warm and idle in the pool

### Show stats

```bash
docker compose exec pgbouncer \
  psql -h 127.0.0.1 -p 6432 -U odoo pgbouncer -c "SHOW STATS;"
```

`total_query_time / total_query_count` gives mean query latency at the
pool. Track over time to spot regressions.

### Reload config without restarting

```bash
docker compose exec pgbouncer kill -HUP 1
```

PgBouncer reloads `pgbouncer.ini` on `SIGHUP`. Pool-size and timeout
changes take effect for new connections; existing pooled backends drain
naturally.

### Drain before maintenance

```bash
# 1. Stop accepting new clients, finish in-flight transactions.
docker compose exec pgbouncer psql -h 127.0.0.1 -p 6432 -U odoo pgbouncer -c "PAUSE;"

# 2. Do whatever needed maintenance (Postgres restart, failover, etc.)

# 3. Resume.
docker compose exec pgbouncer psql -h 127.0.0.1 -p 6432 -U odoo pgbouncer -c "RESUME;"
```

This is the right way to take Postgres down for a quick maintenance
window without breaking active Odoo sessions.

---

## Bypassing PgBouncer

There are three legitimate reasons to bypass the pool:

1. **Debugging.** You want to rule out PgBouncer as the cause of an
   issue you're seeing.
2. **Migrations / DDL-heavy workloads.** Long-running DDL holding
   transactions open defeats the pool's purpose.
3. **The longpolling worker** (see above).

Override the DB host in `.env`:

```bash
ODOO_DB_HOST=db
ODOO_DB_PORT=5432
```

…and `docker compose up -d odoo` to restart Odoo against Postgres
directly. PgBouncer keeps running but goes idle.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `password authentication failed for user "odoo"` | `userlist.txt` missing, empty, or out of sync with `POSTGRES_PASSWORD`. Re-run `generate-userlist.sh` and reload. |
| `unsupported startup parameter` | A startup param libpq sends isn't in `ignore_startup_parameters`. Add it to the list in `pgbouncer.ini`. |
| `prepared statement "..." does not exist` | Code is using session-level prepared statements under transaction mode. Either switch the affected code to plain SQL or route it around the pool. |
| `cl_waiting` consistently > 0 | Pool too small. Raise `default_pool_size`. |
| Postgres' `max_connections` exhausted despite PgBouncer | `max_db_connections` set too high relative to Postgres' `max_connections`. Lower it, leaving headroom for direct admin connections. |
| Odoo chat works but feels sluggish | Bus is polling instead of LISTEN/NOTIFY (expected in transaction mode). See "LISTEN/NOTIFY and the Odoo bus" above. |
