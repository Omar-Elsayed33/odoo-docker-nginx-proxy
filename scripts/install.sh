#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# install.sh — one-time setup for a fresh clone
#
# Run this once after `git clone` (and re-run idempotently any time
# you want to re-bootstrap missing files). Does NOT start the stack —
# call `./scripts/start.sh` after this finishes.
#
# Steps:
#   1. Verify prerequisites (docker, compose, openssl, bash).
#   2. Copy .env.example → .env if missing; refuse to overwrite.
#   3. Auto-fill placeholder passwords in .env with `openssl rand`.
#   4. Generate self-signed TLS certs if nginx/certs/ is empty.
#   5. Generate pgbouncer/userlist.txt from .env.
#   6. Validate `docker compose config`.
#
# Existing files are left alone — re-running won't clobber a real cert,
# a real password, or a hand-edited userlist.
#
# Usage:
#   ./scripts/install.sh
#   ./scripts/install.sh --force        # answer yes to all prompts
# ─────────────────────────────────────────────────────────────────────
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

FORCE_FLAG=""
for arg in "$@"; do
    case "$arg" in --force|-f|--yes|-y) FORCE_FLAG="$arg" ;; esac
done

# ─── 1. Prerequisites ────────────────────────────────────────────────
log_step "Checking prerequisites"
require_command docker
require_command openssl
require_command bash
docker compose version >/dev/null 2>&1 || fatal "docker compose plugin not installed"
log_success "docker, compose, openssl, bash all present"

# ─── 2. .env ─────────────────────────────────────────────────────────
log_step "Configuring .env"
if [[ -f "$ENV_FILE" ]]; then
    log_info ".env already exists — leaving it alone"
else
    cp "$REPO_ROOT/.env.example" "$ENV_FILE"
    log_success "created .env from .env.example"
fi

# ─── 3. Replace placeholder passwords ────────────────────────────────
fill_placeholder() {
    local var="$1"
    local placeholder_pattern="$2"
    local current
    current="$(grep -E "^${var}=" "$ENV_FILE" | head -n1 | cut -d= -f2- || true)"
    if [[ "$current" =~ $placeholder_pattern ]]; then
        local generated
        generated="$(openssl rand -base64 32 | tr -d '\n/+=' | head -c 40)"
        # Use a sed-friendly delimiter (|) since passwords don't usually contain it.
        # macOS sed needs `-i ''`; GNU sed accepts `-i`. Use a tempfile for portability.
        local tmp="${ENV_FILE}.tmp"
        sed "s|^${var}=.*|${var}=${generated}|" "$ENV_FILE" > "$tmp" && mv "$tmp" "$ENV_FILE"
        log_success "generated random ${var}"
    else
        log_info "${var} already customised — leaving it alone"
    fi
}

log_step "Replacing placeholder secrets in .env"
fill_placeholder POSTGRES_PASSWORD '^change-me'
fill_placeholder ODOO_ADMIN_PASSWD '^change-me'

# ─── 4. TLS certs ────────────────────────────────────────────────────
log_step "Provisioning TLS certificates"
CERT="$REPO_ROOT/nginx/certs/fullchain.pem"
KEY="$REPO_ROOT/nginx/certs/privkey.pem"
if [[ -f "$CERT" && -f "$KEY" ]]; then
    log_info "certificates already present in nginx/certs/ — leaving them alone"
else
    log_info "generating self-signed cert for localhost (valid 365 days)"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$KEY" \
        -out    "$CERT" \
        -subj   "/CN=localhost" \
        -addext "subjectAltName=DNS:localhost,DNS:odoo.local,IP:127.0.0.1" \
        >/dev/null 2>&1
    chmod 600 "$KEY"
    log_success "self-signed cert written to nginx/certs/"
    log_warn   "browsers will warn about trust — that's expected for self-signed"
    log_warn   "replace with a real cert before exposing to the internet"
fi

# ─── 5. PgBouncer userlist ───────────────────────────────────────────
log_step "Generating pgbouncer/userlist.txt"
USERLIST="$REPO_ROOT/pgbouncer/userlist.txt"
# Treat empty as missing — a zero-byte userlist.txt is what's left
# behind when generate-userlist.sh aborts mid-write (placeholder
# password rejection, etc.) and breaks PgBouncer auth silently.
if [[ -s "$USERLIST" ]]; then
    log_info "userlist.txt already exists and is non-empty — leaving it alone"
    log_info "run ./pgbouncer/generate-userlist.sh manually if you rotate POSTGRES_PASSWORD"
else
    [[ -e "$USERLIST" ]] && log_warn "userlist.txt is empty — regenerating"
    bash "$REPO_ROOT/pgbouncer/generate-userlist.sh" "$ENV_FILE"
fi

# ─── 6. Validate compose ─────────────────────────────────────────────
log_step "Validating docker-compose.yml"
if compose config --quiet 2>/dev/null; then
    log_success "compose config is valid"
else
    log_warn "compose config reported issues — review:"
    compose config 1>/dev/null  # surface the errors
fi

# ─── Done ────────────────────────────────────────────────────────────
printf '\n'
log_success "install complete"
printf '\n'
printf '  %sNext steps:%s\n'        "$C_BOLD" "$C_RESET"
printf '    1. Review %s.env%s — the auto-generated passwords are 40 chars.\n' "$C_BOLD" "$C_RESET"
printf '    2. %s./scripts/start.sh%s\n' "$C_BOLD" "$C_RESET"
printf '    3. Open %shttps://localhost/%s in a browser (accept the self-signed warning).\n' "$C_BOLD" "$C_RESET"
printf '\n'
