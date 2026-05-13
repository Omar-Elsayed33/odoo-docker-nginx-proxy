#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# start.sh — bring the stack up and wait until everything is healthy
#
# Idempotent: starting an already-running stack just re-applies any
# config changes and waits for health.
#
# Usage:
#   ./scripts/start.sh              # all services
#   ./scripts/start.sh odoo         # just one service (and its deps)
#   ./scripts/start.sh --no-wait    # don't block on healthchecks
# ─────────────────────────────────────────────────────────────────────
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

WAIT=1
SERVICES=()
for arg in "$@"; do
    case "$arg" in
        --no-wait) WAIT=0 ;;
        --help|-h)
            sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) SERVICES+=("$arg") ;;
    esac
done

# ─── Preflight ───────────────────────────────────────────────────────
log_step "Preflight checks"
require_env_file
require_command docker

# Confirm the things install.sh would have created.
[[ -f "$REPO_ROOT/nginx/certs/fullchain.pem" ]] \
    || fatal "TLS certs missing — run ./scripts/install.sh"
[[ -f "$REPO_ROOT/pgbouncer/userlist.txt" ]] \
    || fatal "pgbouncer/userlist.txt missing — run ./scripts/install.sh"

# ─── Up ──────────────────────────────────────────────────────────────
log_step "Starting stack"
if (( ${#SERVICES[@]} > 0 )); then
    compose up -d "${SERVICES[@]}"
else
    compose up -d
fi

# ─── Wait for health ─────────────────────────────────────────────────
if (( WAIT == 1 )); then
    log_step "Waiting for services to become healthy"
    # Order matters: db → pgbouncer → odoo → nginx.
    for svc in db pgbouncer odoo nginx; do
        if is_running "$svc"; then
            log_info "waiting for $svc..."
            wait_healthy "$svc" 180
            log_success "$svc healthy"
        fi
    done
fi

# ─── Summary ─────────────────────────────────────────────────────────
printf '\n'
log_success "stack is up"
printf '\n'
compose ps
printf '\n'

# Best-effort: pull the published HTTPS port from .env so the URL is
# correct even if the operator changed NGINX_HTTPS_PORT.
HTTPS_PORT="$(load_env_var NGINX_HTTPS_PORT 2>/dev/null || echo 443)"
if [[ "$HTTPS_PORT" == "443" ]]; then
    URL="https://localhost/"
else
    URL="https://localhost:${HTTPS_PORT}/"
fi
printf '  Open %s%s%s in a browser to reach Odoo.\n' "$C_BOLD" "$URL" "$C_RESET"
printf '  Tail logs with: %s./scripts/logs.sh%s\n' "$C_BOLD" "$C_RESET"
printf '\n'
