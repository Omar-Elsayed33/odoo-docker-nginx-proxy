#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# logs.sh — convenience wrapper around `docker compose logs`
#
# Defaults: follow=on, show last 200 lines, all services.
# Anything you pass through is forwarded to `docker compose logs`.
#
# Usage:
#   ./scripts/logs.sh                          # tail all services
#   ./scripts/logs.sh odoo                     # just odoo
#   ./scripts/logs.sh odoo nginx               # multiple
#   ./scripts/logs.sh -n 1000 odoo             # more lines
#   ./scripts/logs.sh --no-follow odoo         # don't follow (print and exit)
#   ./scripts/logs.sh --since 1h odoo          # last hour
#   ./scripts/logs.sh --errors                 # filter to ERROR / FATAL / WARN
# ─────────────────────────────────────────────────────────────────────
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

FOLLOW="--follow"
TAIL="200"
SINCE=""
ERRORS_ONLY=0
SERVICES=()

while (( $# > 0 )); do
    case "$1" in
        --no-follow)   FOLLOW="";       shift ;;
        -n|--tail)     TAIL="$2";       shift 2 ;;
        --since)       SINCE="--since $2"; shift 2 ;;
        --errors|-e)   ERRORS_ONLY=1;   shift ;;
        --help|-h)
            sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*) fatal "unknown flag: $1 (pass --help to see usage)" ;;
        *)  SERVICES+=("$1"); shift ;;
    esac
done

# Build the command. Empty $FOLLOW / $SINCE expand to nothing.
# shellcheck disable=SC2086
if (( ERRORS_ONLY == 1 )); then
    # Strip color from the inner stream before grepping so the
    # pattern matches reliably. The pager (less) can re-color via
    # --raw-control-chars if you want it.
    compose logs --tail="$TAIL" $FOLLOW $SINCE "${SERVICES[@]}" 2>&1 \
        | grep --line-buffered -iE 'error|fatal|warn|critical|traceback'
else
    compose logs --tail="$TAIL" $FOLLOW $SINCE "${SERVICES[@]}"
fi
