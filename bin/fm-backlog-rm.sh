#!/usr/bin/env bash
# Remove one backlog item from ## Queued only.
#
# Refuses items in ## In flight, ## Done, or absent from the backlog.
# Uses tasks-axi when the default compatible backend is active; otherwise
# edits data/backlog.md in place with the same line-matching rules as handoff.
#
# Usage: bin/fm-backlog-rm.sh <id>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
BACKLOG="$DATA/backlog.md"

# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

usage() {
  sed -n '2,8p' "$0"
  exit 1
}

[ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] && usage
[ $# -eq 1 ] || usage

ID=$1
case "$ID" in
  *[!a-z0-9-]*|''|-*) echo "error: invalid task id: $ID" >&2; exit 1 ;;
esac

[ -f "$BACKLOG" ] || { echo "error: backlog missing: $BACKLOG" >&2; exit 1; }
if [ -L "$BACKLOG" ]; then
  echo "error: backlog must not be a symlink: $BACKLOG" >&2
  exit 1
fi

backlog_key_section() {
  local file=$1 key=$2
  awk -v key="$key" '
    function item_id(rest,    id) {
      if (match(rest, /^\*\*[^*]+\*\*/)) {
        id = substr(rest, RSTART + 2, RLENGTH - 4)
        return id
      }
      id = rest
      sub(/ - .*/, "", id)
      sub(/[ \t].*/, "", id)
      return id
    }
    BEGIN { section = ""; found = 0 }
    /^## / { section = $0; next }
    /^- \[[ x]\] / {
      rest = $0
      sub(/^- \[[ x]\] +/, "", rest)
      if (item_id(rest) == key) {
        print section
        found = 1
        exit
      }
    }
    END { exit found ? 0 : 1 }
  ' "$file"
}

section=$(backlog_key_section "$BACKLOG" "$ID") || {
  echo "error: no backlog item matched id $ID in $BACKLOG" >&2
  exit 1
}

if [ "$section" = "## In flight" ]; then
  echo "error: refusing to remove in-flight item $ID (teardown the crew instead)" >&2
  exit 1
fi
if [ "$section" = "## Done" ]; then
  echo "error: refusing to remove done item $ID" >&2
  exit 1
fi
if [ "$section" != "## Queued" ]; then
  echo "error: refusing to remove $ID from section: $section" >&2
  exit 1
fi

if fm_tasks_axi_backend_available "$CONFIG"; then
  if tasks-axi rm "$ID" 2>/dev/null; then
    echo "removed queued item $ID (tasks-axi)"
    exit 0
  fi
  if tasks-axi cancel "$ID" 2>/dev/null; then
    echo "removed queued item $ID (tasks-axi cancel)"
    exit 0
  fi
fi

TMP=$(mktemp "$DATA/.fm-backlog-rm.XXXXXX")
BAK=$(mktemp "$DATA/.fm-backlog-rm-bak.XXXXXX")
cp "$BACKLOG" "$BAK"
if ! awk -v key="$ID" '
  function item_id(rest,    id) {
    if (match(rest, /^\*\*[^*]+\*\*/)) {
      id = substr(rest, RSTART + 2, RLENGTH - 4)
      return id
    }
    id = rest
    sub(/ - .*/, "", id)
    sub(/[ \t].*/, "", id)
    return id
  }
  BEGIN { in_queued = 0; removed = 0 }
  /^## Queued$/ { in_queued = 1; print; next }
  /^## / { in_queued = 0 }
  in_queued && /^- \[[ x]\] / {
    rest = $0
    sub(/^- \[[ x]\] +/, "", rest)
    if (item_id(rest) == key) { removed = 1; next }
  }
  { print }
  END { exit removed ? 0 : 1 }
' "$BACKLOG" > "$TMP"; then
  rm -f "$TMP" "$BAK"
  echo "error: queued item $ID not found during edit" >&2
  exit 1
fi
mv "$TMP" "$BACKLOG"
rm -f "$BAK"
echo "removed queued item $ID"