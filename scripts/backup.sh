#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# backup.sh — production-safe backup of an Odoo database + filestore
#
# Produces a single timestamped archive at
#   backups/<dbname>-YYYYMMDD-HHMMSS.tar.gz
# containing:
#   - database.dump   (pg_dump custom format, suitable for pg_restore -j)
#   - filestore/      (Odoo's per-database attachment store)
#   - manifest.txt    (versions, db name, sha256 of database.dump)
#
# Safety properties:
#   - pg_dump bypasses PgBouncer and connects to Postgres directly,
#     since transaction-mode pooling is incompatible with the prepared
#     transactions and replication snapshot pg_dump uses internally.
#   - The archive is built in a temp directory and `mv`d into place
#     atomically — interrupted backups leave nothing partial behind.
#   - SHA-256 checksum is embedded in the manifest and printed.
#   - Old backups are NOT automatically deleted; retention is the
#     operator's call (see --keep below for an opt-in policy).
#
# Usage:
#   ./scripts/backup.sh                       # back up the only DB
#   ./scripts/backup.sh -d <dbname>           # specific database
#   ./scripts/backup.sh --keep 7              # delete archives older
#                                             # than the 7 most recent
#                                             # (for THIS database)
#   ./scripts/backup.sh --output /path        # custom output dir
#
# Restore with:  ./scripts/restore.sh <archive>
# ─────────────────────────────────────────────────────────────────────
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

DBNAME=""
KEEP=0
OUTPUT_DIR="$BACKUPS_DIR"

while (( $# > 0 )); do
    case "$1" in
        -d|--database) DBNAME="$2"; shift 2 ;;
        --keep)        KEEP="$2"; shift 2 ;;
        --output|-o)   OUTPUT_DIR="$2"; shift 2 ;;
        --help|-h)
            sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) fatal "unknown argument: $1" ;;
    esac
done

require_env_file
is_running db || fatal "db container is not running — start the stack first"

POSTGRES_USER="$(load_env_var POSTGRES_USER)"

# ─── Discover the database to back up ───────────────────────────────
if [[ -z "$DBNAME" ]]; then
    log_step "Discovering Odoo databases"
    mapfile -t DBS < <(
        compose exec -T db psql -U "$POSTGRES_USER" -d postgres -At -c \
            "SELECT datname FROM pg_database
             WHERE datistemplate = false
               AND datname NOT IN ('postgres');"
    )
    case "${#DBS[@]}" in
        0) fatal "no application databases found — create one in /web/database/manager first" ;;
        1) DBNAME="${DBS[0]}"
           log_info "backing up the only database: $DBNAME" ;;
        *) log_error "multiple databases found — choose one with -d <dbname>:"
           printf '    %s\n' "${DBS[@]}" >&2
           exit 1 ;;
    esac
fi

# ─── Prepare paths ──────────────────────────────────────────────────
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE_NAME="${DBNAME}-${TIMESTAMP}.tar.gz"
FINAL_PATH="${OUTPUT_DIR}/${ARCHIVE_NAME}"
mkdir -p "$OUTPUT_DIR"

# Build in a sibling temp dir so a crash mid-tar doesn't pollute backups/.
WORK_DIR="$(mktemp -d "${OUTPUT_DIR}/.tmp-${DBNAME}-XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

# ─── Dump the database ──────────────────────────────────────────────
log_step "Dumping database '$DBNAME' (pg_dump -Fc, direct to Postgres)"
compose exec -T db pg_dump \
    -U "$POSTGRES_USER" \
    -d "$DBNAME" \
    -Fc -Z 6 \
    --no-owner --no-acl \
    > "$WORK_DIR/database.dump"
DB_SIZE="$(du -h "$WORK_DIR/database.dump" | cut -f1)"
log_success "database dump complete ($DB_SIZE)"

# ─── Copy the filestore ─────────────────────────────────────────────
log_step "Copying filestore for '$DBNAME'"
mkdir -p "$WORK_DIR/filestore"
# Use the named-volume mount inside the odoo container.
# Tolerate a missing filestore (fresh DB with no attachments yet).
if compose exec -T odoo test -d "/var/lib/odoo/filestore/$DBNAME" 2>/dev/null; then
    compose exec -T odoo tar -C "/var/lib/odoo/filestore" -cf - "$DBNAME" \
        | tar -C "$WORK_DIR/filestore" -xf -
    FS_SIZE="$(du -sh "$WORK_DIR/filestore" | cut -f1)"
    log_success "filestore copied ($FS_SIZE)"
else
    log_warn "no filestore directory for '$DBNAME' — backing up an empty placeholder"
fi

# ─── Manifest ───────────────────────────────────────────────────────
log_step "Writing manifest"
ODOO_IMAGE="$(compose images odoo --format '{{.Repository}}:{{.Tag}}' 2>/dev/null || echo unknown)"
PG_IMAGE="$(compose images db --format '{{.Repository}}:{{.Tag}}' 2>/dev/null || echo unknown)"
DB_SHA="$(sha256sum "$WORK_DIR/database.dump" | cut -d' ' -f1)"
cat > "$WORK_DIR/manifest.txt" <<EOF
backup version:     1
database name:      $DBNAME
created at:         $(date -u +"%Y-%m-%dT%H:%M:%SZ")
created by:         ${USER:-unknown}@$(hostname)
odoo image:         $ODOO_IMAGE
postgres image:     $PG_IMAGE
database.dump size: $DB_SIZE
database.dump sha256: $DB_SHA
EOF

# ─── Tar it all up, atomically ──────────────────────────────────────
log_step "Building archive"
TMP_ARCHIVE="$WORK_DIR/${ARCHIVE_NAME}.partial"
tar -C "$WORK_DIR" -czf "$TMP_ARCHIVE" \
    --exclude="$(basename "$TMP_ARCHIVE")" \
    manifest.txt database.dump filestore
mv "$TMP_ARCHIVE" "$FINAL_PATH"
chmod 600 "$FINAL_PATH"
FINAL_SIZE="$(du -h "$FINAL_PATH" | cut -f1)"
log_success "archive: $FINAL_PATH ($FINAL_SIZE)"

# ─── Retention ──────────────────────────────────────────────────────
if (( KEEP > 0 )); then
    log_step "Applying retention policy: keep newest $KEEP"
    mapfile -t OLD < <(
        ls -1t "$OUTPUT_DIR"/"$DBNAME"-*.tar.gz 2>/dev/null | tail -n "+$((KEEP + 1))"
    )
    if (( ${#OLD[@]} > 0 )); then
        for f in "${OLD[@]}"; do
            log_info "removing $f"
            rm -f -- "$f"
        done
        log_success "${#OLD[@]} old archive(s) deleted"
    else
        log_info "nothing to delete"
    fi
fi

printf '\n'
log_success "backup complete"
printf '  Restore with: %s./scripts/restore.sh %s%s\n\n' "$C_BOLD" "$FINAL_PATH" "$C_RESET"
