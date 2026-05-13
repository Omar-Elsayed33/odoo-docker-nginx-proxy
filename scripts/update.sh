#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# update.sh — pull new images and recreate containers safely
#
# Safety properties:
#   - Takes a backup of every Odoo database FIRST (unless --no-backup).
#     If anything goes wrong, restore.sh can put you back.
#   - Pulls before tearing down — a network failure during pull
#     leaves the old containers running.
#   - Uses `up -d` (not `down` + `up`) so only changed services are
#     recreated; the rest stay up.
#   - Waits for healthchecks before declaring success.
#
# IMPORTANT — Odoo MAJOR version changes (e.g. 17 → 18 → 19) are NOT
# safe to do with this script. They require running Odoo's
# migration tooling against a copy of prod. See README → "Switching
# Odoo versions". This script is for minor / patch updates only.
#
# Usage:
#   ./scripts/update.sh                  # pull, backup, recreate
#   ./scripts/update.sh --no-backup      # skip the safety backup
#   ./scripts/update.sh --force          # don't prompt for confirmation
# ─────────────────────────────────────────────────────────────────────
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

DO_BACKUP=1
PASS_FORCE=()
for arg in "$@"; do
    case "$arg" in
        --no-backup)         DO_BACKUP=0 ;;
        --force|-f|--yes|-y) PASS_FORCE+=("$arg") ;;
        --help|-h)
            sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) fatal "unknown argument: $arg" ;;
    esac
done

require_env_file

# ─── Record current image digests ───────────────────────────────────
log_step "Recording current image versions"
BEFORE="$(mktemp)"
compose images --format '{{.Service}}\t{{.Repository}}:{{.Tag}}' \
    | sort > "$BEFORE" 2>/dev/null || true
column -t -s $'\t' "$BEFORE" >&2 || cat "$BEFORE" >&2

# ─── Backup ─────────────────────────────────────────────────────────
if (( DO_BACKUP == 1 )); then
    if is_running db; then
        log_step "Taking safety backup of every database"
        POSTGRES_USER="$(load_env_var POSTGRES_USER)"
        mapfile -t DBS < <(
            compose exec -T db psql -U "$POSTGRES_USER" -d postgres -At -c \
                "SELECT datname FROM pg_database
                 WHERE datistemplate = false
                   AND datname NOT IN ('postgres');" 2>/dev/null || true
        )
        if (( ${#DBS[@]} == 0 )); then
            log_info "no application databases to back up"
        else
            for db in "${DBS[@]}"; do
                log_info "backing up: $db"
                "$SCRIPTS_DIR/backup.sh" --database "$db"
            done
        fi
    else
        log_warn "db container not running — skipping safety backup"
    fi
fi

# ─── Confirm before pulling ─────────────────────────────────────────
log_warn "this will pull new images and recreate any service whose image changed"
confirm "Proceed with update?" "${PASS_FORCE[@]}"

# ─── Pull ───────────────────────────────────────────────────────────
log_step "Pulling latest images"
compose pull

# ─── Recreate ───────────────────────────────────────────────────────
log_step "Recreating changed containers"
compose up -d

# ─── Wait for health ────────────────────────────────────────────────
log_step "Waiting for services to become healthy"
for svc in db pgbouncer odoo nginx; do
    if is_running "$svc"; then
        log_info "waiting for $svc..."
        wait_healthy "$svc" 180
        log_success "$svc healthy"
    fi
done

# ─── Diff ───────────────────────────────────────────────────────────
AFTER="$(mktemp)"
compose images --format '{{.Service}}\t{{.Repository}}:{{.Tag}}' \
    | sort > "$AFTER" 2>/dev/null || true

printf '\n'
log_success "update complete"
if ! diff -q "$BEFORE" "$AFTER" >/dev/null 2>&1; then
    printf '\n  %sImage changes:%s\n' "$C_BOLD" "$C_RESET"
    diff -U 0 "$BEFORE" "$AFTER" | grep -E '^[+-][^+-]' | sed 's/^/    /' >&2
else
    log_info "no image changes — everything was already at the pinned version"
fi
rm -f "$BEFORE" "$AFTER"
printf '\n'
