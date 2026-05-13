#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# restore.sh — restore an Odoo database + filestore from a backup.sh
#               archive
#
# WARNING — destructive. By default this drops the existing target
# database before restoring. The script always prompts for
# confirmation unless --force is passed.
#
# Steps:
#   1. Read the manifest from the archive; show what's being restored.
#   2. Stop the odoo container (it would otherwise hold connections to
#      the target DB and prevent DROP DATABASE).
#   3. Drop and recreate the target database (preserving owner).
#   4. pg_restore in parallel (-j 4).
#   5. Replace the filestore on disk.
#   6. Start odoo back up; wait for /web/health.
#
# Usage:
#   ./scripts/restore.sh <archive.tar.gz>
#   ./scripts/restore.sh <archive.tar.gz> --target <newdbname>
#   ./scripts/restore.sh <archive.tar.gz> --force
# ─────────────────────────────────────────────────────────────────────
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

ARCHIVE=""
TARGET_DB=""
PASS_FORCE=()

while (( $# > 0 )); do
    case "$1" in
        --target|-t)         TARGET_DB="$2"; shift 2 ;;
        --force|-f|--yes|-y) PASS_FORCE+=("$1"); shift ;;
        --help|-h)
            sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*) fatal "unknown flag: $1" ;;
        *)  [[ -z "$ARCHIVE" ]] && ARCHIVE="$1" || fatal "unexpected argument: $1"
            shift ;;
    esac
done

[[ -n "$ARCHIVE" ]] || fatal "usage: ./scripts/restore.sh <archive.tar.gz> [--target DB] [--force]"
[[ -f "$ARCHIVE" ]] || fatal "archive not found: $ARCHIVE"

require_env_file
is_running db || fatal "db container is not running — start the stack first"

POSTGRES_USER="$(load_env_var POSTGRES_USER)"

# ─── 1. Inspect the archive ─────────────────────────────────────────
log_step "Inspecting archive"
WORK_DIR="$(mktemp -d -t "odoo-restore-XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
tar -xzf "$ARCHIVE" -C "$WORK_DIR" \
    || fatal "archive is corrupt or not a valid tar.gz"

[[ -f "$WORK_DIR/manifest.txt" ]]   || fatal "archive missing manifest.txt — not a valid backup"
[[ -f "$WORK_DIR/database.dump" ]]  || fatal "archive missing database.dump"

ARCHIVE_DB="$(awk -F': +' '/^database name:/ {print $2}' "$WORK_DIR/manifest.txt")"
ARCHIVE_DATE="$(awk -F': +' '/^created at:/ {print $2}' "$WORK_DIR/manifest.txt")"
EXPECTED_SHA="$(awk -F': +' '/^database.dump sha256:/ {print $2}' "$WORK_DIR/manifest.txt")"
ACTUAL_SHA="$(sha256sum "$WORK_DIR/database.dump" | cut -d' ' -f1)"

[[ "$EXPECTED_SHA" == "$ACTUAL_SHA" ]] \
    || fatal "checksum mismatch — archive is corrupt (expected $EXPECTED_SHA, got $ACTUAL_SHA)"

[[ -z "$TARGET_DB" ]] && TARGET_DB="$ARCHIVE_DB"

cat >&2 <<EOF

  ${C_BOLD}Archive contents${C_RESET}
    file:           $ARCHIVE
    backed-up DB:   $ARCHIVE_DB
    created at:     $ARCHIVE_DATE
    sha256 (ok):    $ACTUAL_SHA

  ${C_BOLD}Restore target${C_RESET}
    database:       $TARGET_DB     ${C_DIM}(will be DROPPED and recreated)${C_RESET}

EOF

confirm "Drop and recreate database '$TARGET_DB' from this archive?" "${PASS_FORCE[@]}"

# ─── 2. Stop odoo so we can drop the DB ─────────────────────────────
log_step "Stopping odoo to release connections"
compose stop odoo nginx >/dev/null

# ─── 3. Drop + recreate ─────────────────────────────────────────────
log_step "Dropping and recreating database '$TARGET_DB'"
compose exec -T db psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 <<SQL
-- Force-disconnect any stragglers (cron, queue jobs, leftover sessions).
SELECT pg_terminate_backend(pid)
  FROM pg_stat_activity
 WHERE datname = '$TARGET_DB'
   AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS "$TARGET_DB";
CREATE DATABASE "$TARGET_DB" OWNER "$POSTGRES_USER";
SQL

# ─── 4. pg_restore ──────────────────────────────────────────────────
log_step "Restoring database (pg_restore -j 4)"
compose exec -T db pg_restore \
    -U "$POSTGRES_USER" \
    -d "$TARGET_DB" \
    --no-owner --no-acl \
    -j 4 \
    < "$WORK_DIR/database.dump"
log_success "database restored"

# ─── 5. Filestore ───────────────────────────────────────────────────
log_step "Replacing filestore for '$TARGET_DB'"
if [[ -d "$WORK_DIR/filestore/$ARCHIVE_DB" ]]; then
    # Wipe the existing filestore for the target DB, then stream the
    # archived one into the named volume via `tar`. We pipe through
    # the (currently stopped) odoo image to leverage its mount.
    compose run --rm --no-deps -T \
        --entrypoint sh odoo -c "
            rm -rf '/var/lib/odoo/filestore/$TARGET_DB' &&
            mkdir -p '/var/lib/odoo/filestore' &&
            tar -C '/var/lib/odoo/filestore' -xf -
        " < <(tar -C "$WORK_DIR/filestore" -cf - \
                "$ARCHIVE_DB" \
                --transform "s,^$ARCHIVE_DB,$TARGET_DB,")
    log_success "filestore restored"
else
    log_warn "archive contains no filestore for '$ARCHIVE_DB' — skipping"
fi

# ─── 6. Bring odoo back up ──────────────────────────────────────────
log_step "Starting odoo and nginx"
compose up -d odoo nginx >/dev/null
log_info "waiting for odoo to become healthy..."
wait_healthy odoo 180

printf '\n'
log_success "restore complete — database '$TARGET_DB' is back online"
printf '\n'
