# `postgres/init/` — first-boot init scripts

This directory is bind-mounted into the `db` container at
`/docker-entrypoint-initdb.d/` (read-only). The PostgreSQL Docker
entrypoint runs anything here **once**, when the data directory is
empty — i.e. on the very first `docker compose up`.

## What runs, in what order

Files are executed in lexicographic order. Supported extensions:

| Pattern        | How it's executed                                                 |
|----------------|-------------------------------------------------------------------|
| `*.sql`        | `psql` against the `POSTGRES_DB` as `POSTGRES_USER`               |
| `*.sql.gz`     | Gunzipped, then piped to `psql`                                    |
| `*.sh`         | Executed by `bash` (set `+x` if you want a non-default shell)     |

The naming convention used here is **`NN-purpose.sql`** so order is obvious:
`10-extensions.sql`, `20-roles.sql`, `30-tuning.sql`, …

## What belongs here

- Enabling extensions on the cluster (`CREATE EXTENSION IF NOT EXISTS …`).
- One-off role / privilege grants that must exist before Odoo starts.
- Tuning that lives in SQL (e.g. `ALTER SYSTEM SET …; SELECT pg_reload_conf();`).

## What does NOT belong here

- Application schema or Odoo data — Odoo creates and manages its own
  databases through its own bootstrap process. Don't try to pre-seed
  them here.
- Anything that needs to run on every restart. This directory runs
  **once, ever**. To re-run, you must wipe the volume.
- Secrets. Anyone with read access to this repo can see these scripts.

## How to re-run init

Init only re-runs against an empty cluster. If you need to start over:

```bash
docker compose down
docker volume rm "$(grep ^POSTGRES_VOLUME .env | cut -d= -f2)"
docker compose up -d
```

This is destructive — back up first.

## Examples

See [`10-extensions.sql.example`](10-extensions.sql.example). Rename to
`.sql` (drop the `.example` suffix) to activate.
