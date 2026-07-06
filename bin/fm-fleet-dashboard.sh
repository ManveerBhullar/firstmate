#!/bin/bash
# Fleet dashboard — high-level overview of all in-flight crews
# Usage: bin/fm-fleet-dashboard.sh [--log]
# --log: append to data/fleet-dashboard.log (gitignored)

FM_HOME="${FM_HOME:-$(dirname "$(dirname "$0")")}"
STATE_DIR="$FM_HOME/state"
DASHBOARD_LOG="$FM_HOME/data/fleet-dashboard.log"

print_dashboard() {
  local ts
  ts=$(date "+%Y-%m-%d %H:%M:%S %Z")

  echo "════════════════════════════════════════════════════════════════"
  echo "  FLEET DASHBOARD — $ts"
  echo "════════════════════════════════════════════════════════════════"
  echo ""

  local active=0 done=0 failed=0 working=0
  local meta_files=()
  while IFS= read -r f; do meta_files+=("$f"); done < <(ls "$STATE_DIR"/*.meta 2>/dev/null | sort)

  if [ ${#meta_files[@]} -eq 0 ]; then
    echo "  (no crews in flight)"
    echo ""
    echo "════════════════════════════════════════════════════════════════"
    return
  fi

  printf "  %-22s %-10s %-12s %-10s %s\n" "CREW" "HARNESS" "REPO" "STATE" "SUMMARY"
  echo "  ──────────────────────────────────────────────────────────────────────────────"

  for meta in "${meta_files[@]}"; do
    local id harness repo state summary window kind
    id=$(basename "$meta" .meta)
    harness=$(grep -m1 '^harness=' "$meta" 2>/dev/null | cut -d= -f2-)
    kind=$(grep -m1 '^kind=' "$meta" 2>/dev/null | cut -d= -f2-)
    [ -z "$harness" ] && harness="?"
    [ -z "$kind" ] && kind="ship"

    # Resolve repo from worktree path or project=
    local worktree project
    worktree=$(grep -m1 '^worktree=' "$meta" 2>/dev/null | cut -d= -f2-)
    project=$(grep -m1 '^project=' "$meta" 2>/dev/null | cut -d= -f2-)
    if [ -n "$project" ]; then
      repo=$(basename "$project")
    elif [ -n "$worktree" ]; then
      repo=$(basename "$worktree" | sed 's/-[0-9a-f]*$//')
    else
      repo="?"
    fi

    # Get last status line (wake event, not current state — but cheap high-level signal)
    local status_file="$STATE_DIR/${id}.status"
    if [ -f "$status_file" ]; then
      summary=$(tail -1 "$status_file" 2>/dev/null | head -c 60)
    else
      summary="(no status yet)"
    fi

    # Cheap state classification from the summary line
    case "$summary" in
      done:*) state="done"; done=$((done+1)) ;;
      failed:*) state="failed"; failed=$((failed+1)) ;;
      blocked:*) state="blocked"; working=$((working+1)) ;;
      needs-decision:*) state="decision"; working=$((working+1)) ;;
      working:*) state="working"; working=$((working+1)) ;;
      *) state="working"; working=$((working+1)) ;;
    esac
    active=$((active+1))

    # Truncate summary for display
    local display_summary="${summary:0:55}"
    [ ${#summary} -gt 55 ] && display_summary="${display_summary}…"

    printf "  %-22s %-10s %-12s %-10s %s\n" "$id" "$harness" "$repo" "$state" "$display_summary"
  done

  echo ""
  echo "  Total: $active crews (${working} working, ${done} done, ${failed} failed)"
  echo "════════════════════════════════════════════════════════════════"
}

if [ "$1" = "--log" ]; then
  print_dashboard >> "$DASHBOARD_LOG" 2>&1
  echo "logged to $DASHBOARD_LOG"
else
  print_dashboard
fi
