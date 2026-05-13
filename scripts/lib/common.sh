#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# scripts/lib/common.sh — shared helpers sourced by every script
#
# Not executable on its own. Source it from the start of each script:
#     source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# ─────────────────────────────────────────────────────────────────────

# ─── Strict mode ─────────────────────────────────────────────────────
# Inherited by sourcing scripts. Individual scripts can re-set if they
# need different flags, but the safe default is on.
set -euo pipefail

# ─── Repo paths ──────────────────────────────────────────────────────
# Resolved relative to *this* file so the scripts work regardless of
# the caller's CWD.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(dirname "$LIB_DIR")"
REPO_ROOT="$(dirname "$SCRIPTS_DIR")"
ENV_FILE="$REPO_ROOT/.env"
BACKUPS_DIR="$REPO_ROOT/backups"

# ─── Colors (respect NO_COLOR + non-TTY) ─────────────────────────────
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RED=$'\033[0;31m'
    C_GREEN=$'\033[0;32m'
    C_YELLOW=$'\033[1;33m'
    C_BLUE=$'\033[0;34m'
    C_DIM=$'\033[2m'
    C_BOLD=$'\033[1m'
    C_RESET=$'\033[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''
    C_DIM=''; C_BOLD=''; C_RESET=''
fi

# ─── Logging primitives ──────────────────────────────────────────────
# Pattern: log_*  writes to stderr (so stdout stays for data),
# leading symbol indicates severity at a glance.
log_step()    { printf '%s▸ %s%s\n' "$C_BLUE"   "$*" "$C_RESET" >&2; }
log_info()    { printf '%s  %s%s\n' "$C_DIM"    "$*" "$C_RESET" >&2; }
log_success() { printf '%s✔ %s%s\n' "$C_GREEN"  "$*" "$C_RESET" >&2; }
log_warn()    { printf '%s! %s%s\n' "$C_YELLOW" "$*" "$C_RESET" >&2; }
log_error()   { printf '%s✘ %s%s\n' "$C_RED"    "$*" "$C_RESET" >&2; }
fatal()       { log_error "$@"; exit 1; }

# ─── Prompts ─────────────────────────────────────────────────────────
# confirm "Drop the database?"        → exits 1 if user says no
# confirm "Drop the database?" --force → bypasses prompt
confirm() {
    local prompt="$1"; shift || true
    # Honor --force / -f anywhere in the remaining args.
    for arg in "$@"; do
        case "$arg" in --force|-f|--yes|-y) return 0 ;; esac
    done
    # Honor FORCE=1 env var (useful in CI).
    [[ "${FORCE:-0}" == "1" ]] && return 0

    local reply
    printf '%s? %s (y/N) %s' "$C_YELLOW" "$prompt" "$C_RESET" >&2
    read -r reply
    [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]] || fatal "aborted by user"
}

# ─── Prerequisites ───────────────────────────────────────────────────
require_command() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || fatal "required command not found: $cmd"
}

require_env_file() {
    [[ -f "$ENV_FILE" ]] || fatal "$ENV_FILE not found — run scripts/install.sh first"
}

# Load a *specific* variable from .env into the current environment.
# Doesn't `source` the file (would leak unrelated vars and execute
# anything that looks like a command).
load_env_var() {
    local var="$1"
    require_env_file
    local val
    val="$(grep -E "^${var}=" "$ENV_FILE" | head -n1 | cut -d= -f2- || true)"
    # Strip trailing carriage return — Windows editors (Notepad, some
    # VS Code defaults) write CRLF, and `cut` leaves the CR attached.
    # A CR-suffixed value silently breaks psql -U, libpq passwords,
    # and anything else that doesn't trim whitespace internally.
    val="${val%$'\r'}"
    [[ -n "$val" ]] || fatal "$var not set in $ENV_FILE"
    # Strip optional surrounding quotes.
    val="${val%\"}"; val="${val#\"}"
    val="${val%\'}"; val="${val#\'}"
    printf '%s' "$val"
}

# ─── Compose wrapper ─────────────────────────────────────────────────
# Always run docker compose from the repo root so relative paths in
# docker-compose.yml resolve correctly regardless of caller CWD.
compose() {
    ( cd "$REPO_ROOT" && docker compose "$@" )
}

# is_running odoo  →  exit 0 if container is up, 1 otherwise
is_running() {
    local service="$1"
    local state
    state="$(compose ps --status running --services 2>/dev/null | grep -Fx "$service" || true)"
    [[ -n "$state" ]]
}

# wait_healthy <service> [timeout-seconds]
wait_healthy() {
    local service="$1"
    local timeout="${2:-120}"
    local elapsed=0 status
    while (( elapsed < timeout )); do
        status="$(compose ps --format '{{.Service}} {{.Health}}' 2>/dev/null \
                  | awk -v s="$service" '$1==s {print $2}')"
        case "$status" in
            healthy) return 0 ;;
            unhealthy) fatal "$service became unhealthy" ;;
        esac
        sleep 2
        elapsed=$(( elapsed + 2 ))
    done
    fatal "$service did not become healthy within ${timeout}s"
}
