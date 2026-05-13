#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# generate-userlist.sh — produce pgbouncer/userlist.txt from .env
#
# Reads POSTGRES_USER and POSTGRES_PASSWORD from .env and writes a
# minimal userlist.txt that PgBouncer will hash in memory at startup
# (we use auth_type = scram-sha-256 in pgbouncer.ini).
#
# Run this once before `docker compose up`, and again whenever you
# rotate POSTGRES_PASSWORD.
#
# Usage:
#     ./pgbouncer/generate-userlist.sh                     # uses ./.env
#     ./pgbouncer/generate-userlist.sh path/to/.env.prod   # custom env
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${1:-$REPO_ROOT/.env}"
OUT="$SCRIPT_DIR/userlist.txt"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "error: $ENV_FILE not found" >&2
    echo "       run \`cp .env.example .env\` and edit it first" >&2
    exit 1
fi

# Source only the two variables we care about. Strip CRLF first —
# Windows editors leave \r on every line, which `eval` would happily
# bake into the variable values and silently corrupt userlist.txt.
# shellcheck disable=SC1090
eval "$(grep -E '^(POSTGRES_USER|POSTGRES_PASSWORD)=' "$ENV_FILE" | tr -d '\r')"

: "${POSTGRES_USER:?POSTGRES_USER missing in $ENV_FILE}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD missing in $ENV_FILE}"

# Refuse to write if the password still looks like a placeholder.
case "$POSTGRES_PASSWORD" in
    change-me*|CHANGE_ME*|""|"your-"*)
        echo "error: POSTGRES_PASSWORD in $ENV_FILE looks like a placeholder" >&2
        echo "       generate a real value:  openssl rand -base64 32" >&2
        exit 1
        ;;
esac

# Write to a temp file first, then rename — atomic. Avoids leaving a
# zero-byte userlist.txt behind if the shell is interrupted (Ctrl-C,
# disk full, etc.) between `>` truncating the file and printf writing
# to it. PgBouncer treats an empty file as "no users", which silently
# breaks auth with SASL errors that are hard to diagnose.
umask 077
TMP="$OUT.partial.$$"
trap 'rm -f "$TMP"' EXIT
printf '"%s" "%s"\n' "$POSTGRES_USER" "$POSTGRES_PASSWORD" > "$TMP"
chmod 600 "$TMP"
mv "$TMP" "$OUT"
trap - EXIT

echo "wrote $OUT  (chmod 600)"
echo
echo "next: docker compose up -d"
echo
echo "to rotate the password later:"
echo "  1. update POSTGRES_PASSWORD in $ENV_FILE"
echo "  2. update the password in Postgres:"
echo "       docker compose exec db psql -U \"\$POSTGRES_USER\" -c \\"
echo "         \"ALTER ROLE \\\"\$POSTGRES_USER\\\" PASSWORD '\$POSTGRES_PASSWORD';\""
echo "  3. re-run this script and reload pgbouncer:"
echo "       docker compose exec pgbouncer kill -HUP 1"
