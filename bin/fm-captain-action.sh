#!/usr/bin/env bash
# Record a captain action taken outside firstmate chat (e.g. the web companion)
# and enqueue a low-priority wake so the next turn can reconcile it.
#
# Appends to data/captain-actions.log (gitignored under data/).
# Usage: bin/fm-captain-action.sh log <verb> <detail...>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
LOG="$DATA/captain-actions.log"

usage() {
  sed -n '2,6p' "$0"
  exit 1
}

[ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] && usage
[ "${1:-}" = "log" ] || usage
[ $# -ge 3 ] || usage

verb=$2
shift 2
detail=$*

case "$verb" in
  *[![:alnum:]_-]*|'') echo "error: invalid verb: $verb" >&2; exit 1 ;;
esac

mkdir -p "$DATA"
ts=$(date "+%Y-%m-%d %H:%M:%S %Z")
printf '%s\tweb\t%s\t%s\n' "$ts" "$verb" "$detail" >> "$LOG"
fm_wake_append check web-ui "${verb}: ${detail}" || true
printf 'logged captain action: %s\n' "$verb"