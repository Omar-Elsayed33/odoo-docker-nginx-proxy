# Backup and restore

This stack has two things worth backing up: the Postgres database and
the Odoo filestore. They live in different places, change at different
rates, and are easy to back up one and not the other — leaving a backup
that "works" until someone clicks an attachment and gets a 404.

`./scripts/backup.sh` and `./scripts/restore.sh` handle both as one
atomic unit. This document explains what they do, when to schedule
them, and what to do off-host so a single disk failure doesn't take
your business down.

## Contents

- [What's in a backup](#whats-in-a-backup)
- [Taking a backup](#taking-a-backup)
- [Restoring from a backup](#restoring-from-a-backup)
- [Scheduling](#scheduling)
- [Off-host shipping](#off-host-shipping)
- [Restore drills](#restore-drills)
- [Verifying a backup](#verifying-a-backup)
- [Encryption](#encryption)
- [Troubleshooting](#troubleshooting)

---

## What's in a backup

Every archive `backup.sh` produces is a single gzipped tarball named
`<dbname>-YYYYMMDD-HHMMSS.tar.gz` with three things inside:

```
my_db-20260513-023045.tar.gz
├── manifest.txt        # versions, db name, timestamp, sha256 of database.dump
├── database.dump       # pg_dump -Fc (custom format, suitable for pg_restore -j)
└── filestore/
    └── my_db/          # Odoo's per-database attachments directory
        └── ...
```

**Database** is dumped with `pg_dump -Fc -Z 6`:

- Custom format → restorable with `pg_restore -j N` (parallel).
- Compression level 6 → ~60–70% of plain SQL size, fast to produce.
- `--no-owner --no-acl` → restores cleanly into a database with a
  different owner role (useful when you migrate between environments).

**Filestore** is what's in `/var/lib/odoo/filestore/<dbname>/` inside
the container — every attachment a user has uploaded, the addons asset
cache, and a few session files. Without this, a restored database
loads but every attachment URL 404s.

**Manifest** records what produced the archive and a sha256 of the
database dump:

```
backup version:     1
database name:      my_db
created at:         2026-05-13T02:30:45Z
created by:         deploy@odoo-prod
odoo image:         odoo:18.0
postgres image:     postgres:16-alpine
database.dump size: 142M
database.dump sha256: 3a7c…d91f
```

The sha256 is verified by `restore.sh` before doing anything
destructive — a corrupted archive fails fast instead of getting halfway
through a destructive restore.

> **Why `pg_dump` bypasses PgBouncer**: pooling is incompatible with
> the snapshot semantics `pg_dump` uses internally. Going through
> PgBouncer would silently produce a torn, inconsistent dump. The
> script connects to `db:5432` directly via `docker compose exec`.

---

## Taking a backup

### Single database (the common case)

```bash
./scripts/backup.sh
# → backups/my_db-20260513-023045.tar.gz
```

If exactly one Odoo application database exists in the cluster, the
script picks it automatically.

### Specific database

```bash
./scripts/backup.sh --database my_db
```

Required when multiple Odoo databases coexist (the script lists them
and exits if you didn't pick one).

### With retention

```bash
./scripts/backup.sh --keep 14
```

After writing the new archive, deletes older archives for the same
database, keeping only the 14 most recent. Retention is per-database —
backups for `staging_db` are not affected by `--keep` on `prod_db`.

### Custom output location

```bash
./scripts/backup.sh --output /mnt/backups
```

Use when `./backups/` is on the same disk as Postgres and you want the
output on a separate mount. The directory is created if missing.

### Where it runs

The script connects to the running `db` container via `docker compose
exec`. It needs the stack to be **up** — `backup.sh` is not an offline
tool. If you need an offline dump (e.g. before a migration), stop
`odoo` first to quiesce writers, leave `db` running, then run the
script.

---

## Restoring from a backup

> **Restore is destructive.** It drops the target database and
> recreates it from the archive. The script prompts for confirmation
> unless `--force` is passed.

### Restore in place

```bash
./scripts/restore.sh backups/my_db-20260513-023045.tar.gz
```

What happens, in order:

1. Archive's manifest sha256 is verified against the actual dump bytes.
   Mismatch aborts here, before anything destructive.
2. You're shown the archive contents and prompted for confirmation.
3. `odoo` and `nginx` are stopped so they release connections.
4. Active sessions on the target DB are terminated via
   `pg_terminate_backend`.
5. The target DB is `DROP`ped and `CREATE`d fresh.
6. `pg_restore -j 4` parallel-restores the dump.
7. Filestore is wiped and re-extracted from the archive.
8. `odoo` and `nginx` are started; the script waits for
   `/web/health` to return 200.

### Restore into a different database name

Useful for restore drills, side-by-side comparisons, or migrating data
into a renamed environment:

```bash
./scripts/restore.sh backups/my_db-20260513.tar.gz --target staging_copy
```

The archive's filestore is renamed during extraction
(`filestore/my_db/` → `filestore/staging_copy/`).

### Non-interactive restore (automation)

```bash
./scripts/restore.sh backups/<archive> --force
# or, equivalently:
FORCE=1 ./scripts/restore.sh backups/<archive>
```

Skips the confirmation prompt. Use sparingly — the prompt has prevented
more than one accidental "I restored into prod by mistake."

---

## Scheduling

### Local cron (single-host deployments)

Nightly at 02:30, keep two weeks:

```cron
30 2 * * * cd /opt/odoo && ./scripts/backup.sh --keep 14 \
            >> /var/log/odoo-backup.log 2>&1
```

The `--keep 14` rotates archives in place, so disk usage plateaus
after two weeks. If you have heavy upload churn, monitor `df -h` on
the backup partition for the first month to confirm the plateau.

### Systemd timer (alternative to cron)

```ini
# /etc/systemd/system/odoo-backup.service
[Unit]
Description=Odoo backup
After=docker.service

[Service]
Type=oneshot
User=deploy
WorkingDirectory=/opt/odoo
ExecStart=/opt/odoo/scripts/backup.sh --keep 14
StandardOutput=append:/var/log/odoo-backup.log
StandardError=append:/var/log/odoo-backup.log
```

```ini
# /etc/systemd/system/odoo-backup.timer
[Unit]
Description=Nightly Odoo backup

[Timer]
OnCalendar=*-*-* 02:30:00
Persistent=true

[Install]
WantedBy=timers.target
```

`systemctl enable --now odoo-backup.timer`. Systemd timers survive
restarts better than cron, log via journalctl, and don't email you on
every successful run.

---

## Off-host shipping

> A backup on the same host as the database is not a backup — it's a
> hedge against `rm -rf`, nothing more.

Pick one tool from this table; integrate with the local cron above.

| Tool | Best for | Encryption | Dedup |
|---|---|---|---|
| `restic` | Personal / small ops, S3-compatible target | AES-256 built-in | Yes |
| `rclone` | Already using cloud storage | Optional | No |
| `borg` | Self-hosted backup server over SSH | AES-256 built-in | Yes |
| `aws s3 sync` | AWS-only shop | SSE | No |
| `rsync` | LAN-to-LAN, e.g. NAS | At rest only | No |

### Restic example — ship to Backblaze B2 nightly at 03:00

```bash
# /etc/cron.d/odoo-ship-backups
0 3 * * * deploy cd /opt/odoo && \
  RESTIC_REPOSITORY=b2:my-bucket:odoo \
  RESTIC_PASSWORD_FILE=/etc/odoo/restic.pass \
  restic backup ./backups/ --tag nightly && \
  restic forget --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --prune
```

- `--keep-daily 14 --keep-weekly 8 --keep-monthly 12` gives you 14 days,
  then weekly for two months, then monthly for a year — generous
  recovery window without unbounded growth.
- `--prune` runs after the forget pass and reclaims storage actually.
- `restic` is content-addressable and encrypted — losing your B2
  credentials leaks ciphertext, not data.

### The 3-2-1 rule, simplified

- **3** copies of every backup (prod local + prod remote + audited archive)
- **2** different storage media (disk + object storage)
- **1** off-site (different region from prod)

If you have all three, a single failure mode (disk, region, ransomware,
malicious admin) doesn't take you down.

---

## Restore drills

The only backup that works is one you've restored.

| When | Cadence |
|---|---|
| First quarter after going live | Monthly |
| Steady state | Quarterly |
| After any change to `backup.sh` / `restore.sh` | Immediately |
| After a Postgres or Odoo major upgrade | Immediately |

### How to drill

On a **non-production** machine that mirrors prod's compose stack:

```bash
# Copy a recent prod backup over
scp prod:/opt/odoo/backups/<archive> ./backups/

# Restore into a sandbox database
./scripts/restore.sh backups/<archive> --target drill_$(date +%Y%m%d)

# Smoke test: log in, click through critical screens, query a recent record
docker compose exec odoo odoo shell -d drill_$(date +%Y%m%d) <<< \
  "print(self.env['res.users'].search_count([]))"

# Tear down the sandbox DB
docker compose exec db psql -U odoo -d postgres -c \
  "DROP DATABASE drill_$(date +%Y%m%d);"
```

If the smoke test passes, the drill passed. Log it somewhere durable —
your future self will want to know when the last successful drill ran.

---

## Verifying a backup

You can verify an archive without restoring it:

```bash
# Sha256 in the manifest matches the actual dump?
tmp=$(mktemp -d)
tar -xzf backups/<archive> -C "$tmp"
expected=$(awk -F': +' '/^database.dump sha256:/ {print $2}' "$tmp/manifest.txt")
actual=$(sha256sum "$tmp/database.dump" | cut -d' ' -f1)
test "$expected" = "$actual" && echo "OK" || echo "CORRUPT"
rm -rf "$tmp"
```

`restore.sh` does this check before touching the database. You can
also run it from a cron job on the day-of backups as a smoke test that
the archive is not silently truncated by a disk-full or
interrupted-tar event.

---

## Encryption

The shipped archives are **not** encrypted at rest. Three options to
add encryption, in increasing order of complexity:

1. **Disk encryption on the backup host** (LUKS, FileVault, BitLocker).
   Zero application changes; threat model assumes the host stays under
   your control.
2. **Encrypted off-host shipping tool** (`restic`, `borg`). Archives
   are written locally unencrypted but ciphertext-only off-host. Recommended
   for most cases.
3. **GPG-encrypt at write time**. Pipe `pg_dump` output through `gpg
   --symmetric` (requires modifying `backup.sh`). Strongest guarantee;
   most operationally fragile (lose the GPG key, lose the backup).

For a typical small-business Odoo deployment, **option 2** is the
right answer: cheap, automated, and you don't have to think about it
after the initial setup.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `backup.sh` says "no application databases found" | The `db` container isn't running, or you've created the Postgres user but haven't created an Odoo app DB yet. Run `docker compose ps` and the Odoo database manager. |
| `pg_dump: error: connection to server on socket … failed: FATAL: role "X" does not exist` | `POSTGRES_USER` in `.env` doesn't match the role inside the existing Postgres volume. Usually the result of changing `.env` after Postgres was already initialised. Solution: `docker compose down -v` + fresh up, OR `ALTER ROLE` to add the new user. |
| `restore.sh` aborts with "checksum mismatch — archive is corrupt" | The dump bytes don't match the sha256 in the manifest. Disk failure mid-write, scp truncation, or someone repacked the archive. Get a fresh copy from off-host. |
| `restore.sh` says "archive missing manifest.txt — not a valid backup" | Archive wasn't produced by this stack's `backup.sh` (could be a raw `pg_dump` file, or an older format). Use the appropriate Odoo restore method for that source. |
| Restore succeeds but attachments 404 | The filestore for the target DB name wasn't extracted. Check the archive's `filestore/` directory contains a subdir matching the target DB. The `--target` flag handles renaming automatically. |
| Backups grow unboundedly | `--keep N` not set on the cron line. Add it. |
| Backups fail with "no space left on device" | `./backups/` is full. Move to a larger partition with `--output`, increase the partition, or lower retention. |

For unrelated stack-wide issues, see [troubleshooting.md](troubleshooting.md).
