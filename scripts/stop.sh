#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# stop.sh — bring the stack down gracefully
#
# Default: `docker compose down` — stops & removes containers, keeps
# named volumes (your data survives).
#
# Use --volumes to ALSO wipe the named volumes (Postgres data, Odoo
# filestore, certbot webroot). This is destructive and prompts for
# confirmation unless --force is also passed.
#
# Usage:
#   ./scripts/stop.sh                       # stop, keep data
#   ./scripts/stop.sh --volumes             # stop, wipe data (prompts)
#   ./scripts/stop.sh --volumes --force     # stop, wipe data (no prompt)
#   ./scripts/stop.sh --pause               # `docker compose stop`
#                                           # (keeps containers, resume with start.sh)
# ─────────────────────────────────────────────────────────────────────
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

MODE="down"
WIPE_VOLUMES=0
PASS_FORCE=()

for arg in "$@"; do
    case "$arg" in
        --volumes|-v)         WIPE_VOLUMES=1 ;;
        --pause|--stop)       MODE="stop"    ;;
        --force|-f|--yes|-y)  PASS_FORCE+=("$arg") ;;
        --help|-h)
            sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) fatal "unknown argument: $arg" ;;
    esac
done

if [[ "$MODE" == "stop" ]]; then
    log_step "Stopping containers (keeping them around for fast restart)"
    compose stop
    log_success "stopped — resume with ./scripts/start.sh"
    exit 0
fi

if (( WIPE_VOLUMES == 1 )); then
    log_warn "this will DELETE all data: Postgres cluster, Odoo filestore, certbot webroot"
    log_warn "filesystem volumes survive only if you skip this flag"
    confirm "Really destroy the stack and wipe volumes?" "${PASS_FORCE[@]}"
    log_step "Bringing stack down + wiping volumes"
    compose down -v
    log_success "stack down, volumes wiped"
else
    log_step "Bringing stack down (keeping volumes)"
    compose down
    log_success "stack down — data preserved in named volumes"
fi
