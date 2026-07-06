#!/usr/bin/env bash
# fm-dashboard.sh — pretty TUI dashboard of all worker tasks in this firstmate home.
#
# Reads state/*.meta + state/*.status + live tmux windows and renders a colored,
# boxed summary of every task: kind, project, status, PR, window liveness, and
# whether the pane is actively working or idle.
#
# Usage:
#   bin/fm-dashboard.sh           one-shot render
#   bin/fm-dashboard.sh --watch   live, refreshes every 5s (Ctrl-C to quit)
#   bin/fm-dashboard.sh --watch 10  custom refresh interval (seconds)
#
# Local convenience tool; read-only (never mutates project or state).
set -euo pipefail

# Resolve the firstmate home the same way the other bin/ scripts do.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOME_DIR="${FM_HOME:-$REPO_ROOT}"
STATE_DIR="${FM_STATE_OVERRIDE:-$HOME_DIR/state}"

# ---- colors (disabled if not a tty or NO_COLOR set) -------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  B=$'\033[1m'; D=$'\033[2m'; R=$'\033[0m'
  RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'
  BLU=$'\033[34m'; MAG=$'\033[35m'; CYN=$'\033[36m'; GRY=$'\033[90m'
else
  B=''; D=''; R=''; RED=''; GRN=''; YEL=''; BLU=''; MAG=''; CYN=''; GRY=''
fi

# ---- helpers ----------------------------------------------------------------
meta_val() { # meta_val <file> <key>
  grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2- || true
}

# Color for a status state keyword.
state_color() {
  case "$1" in
    done)          printf '%s' "$GRN" ;;
    failed|blocked) printf '%s' "$RED" ;;
    needs-decision) printf '%s' "$YEL" ;;
    working)       printf '%s' "$CYN" ;;
    *)             printf '%s' "$GRY" ;;
  esac
}

# Busy signature per harness (from harness-adapters).
busy_re() {
  case "$1" in
    claude|codex) printf '%s' 'esc to interrupt' ;;
    opencode)     printf '%s' 'esc interrupt' ;;
    pi)           printf '%s' 'Working\.\.\.' ;;
    *)            printf '%s' 'esc to interrupt' ;;
  esac
}

trunc() { # trunc <string> <width>
  local s="$1" w="$2"
  if (( ${#s} > w )); then printf '%s…' "${s:0:w-1}"; else printf '%s' "$s"; fi
}

render() {
  local now; now="$(date '+%Y-%m-%d %H:%M:%S')"
  local metas=( "$STATE_DIR"/*.meta )
  local total=0 alive=0 busy=0 idle=0 dead=0
  local rows=()

  # Live tmux windows (best-effort; tmux may be absent).
  local windows=""
  windows="$(tmux list-windows -a -F '#{session_name}:#{window_name}' 2>/dev/null || true)"

  if [[ -e "${metas[0]:-}" ]]; then
    for m in "${metas[@]}"; do
      local id; id="$(basename "$m" .meta)"
      local kind project mode window harness pr
      kind="$(meta_val "$m" kind)";       kind="${kind:-?}"
      project="$(meta_val "$m" project)"; project="$(basename "${project:-?}")"
      mode="$(meta_val "$m" mode)";       mode="${mode:-?}"
      window="$(meta_val "$m" window)"
      harness="$(meta_val "$m" harness)"; harness="${harness:-?}"
      pr="$(meta_val "$m" pr)"

      # last status line -> state keyword + note
      local statusfile="$STATE_DIR/$id.status"
      local lastline state note
      lastline="$(tail -1 "$statusfile" 2>/dev/null || true)"
      if [[ "$lastline" == *:* ]]; then
        state="${lastline%%:*}"; note="${lastline#*: }"
      else
        state="—"; note="$lastline"
      fi
      # only treat first token as a state keyword if it's a known one
      case "$state" in working|done|failed|blocked|needs-decision) ;; *) state="—"; note="$lastline" ;; esac

      # window liveness + busy
      local winstate winglyph
      if [[ -n "$window" ]] && grep -qxF "${window#*:}" <<<"$(printf '%s\n' "$windows" | sed 's/^[^:]*://')" 2>/dev/null; then
        # window exists; check busy signature in the pane
        local pane
        pane="$(tmux capture-pane -p -t "$window" 2>/dev/null | tail -25 || true)"
        if grep -qE "$(busy_re "$harness")" <<<"$pane"; then
          winstate="${CYN}● working${R}"; ((busy++)) || true
        else
          winstate="${BLU}○ idle${R}"; ((idle++)) || true
        fi
        ((alive++)) || true
      else
        winstate="${RED}✗ dead${R}"; ((dead++)) || true
      fi
      ((total++)) || true

      local sc; sc="$(state_color "$state")"
      local prcell="${GRY}—${R}"
      [[ -n "$pr" ]] && prcell="${MAG}${pr##*/}${R}"

      rows+=("$(printf '%b' "${B}$(trunc "$id" 22)${R}\t${kind}\t$(trunc "$project" 16)\t${winstate}\t${sc}$(trunc "$state" 14)${R}\t${prcell}\t${D}$(trunc "$note" 40)${R}")")
    done
  fi

  # ---- header ----
  printf '%b\n' "${B}${CYN}╔════════════════════════════════════════════════════════════════════════════════════╗${R}"
  printf '%b\n' "${B}${CYN}║${R}  ${B}⚓ FIRSTMATE FLEET DASHBOARD${R}   ${GRY}home: ${HOME_DIR/#$HOME/\~}${R}"
  printf '%b\n' "${B}${CYN}║${R}  ${GRY}${now}${R}    ${B}${total}${R} tasks   ${CYN}${busy} working${R}  ${BLU}${idle} idle${R}  ${RED}${dead} dead${R}"
  printf '%b\n' "${B}${CYN}╚════════════════════════════════════════════════════════════════════════════════════╝${R}"

  if (( total == 0 )); then
    printf '%b\n' "  ${GRY}No tasks in flight. Calm seas, captain.${R}"
    return
  fi

  # ---- table ----
  {
    printf '%b\n' "${B}${GRY}TASK\tKIND\tPROJECT\tWINDOW\tSTATE\tPR\tLATEST${R}"
    printf '%s\n' "${rows[@]}"
  } | column -t -s$'\t'

  printf '\n%b\n' "${GRY}legend: ${CYN}● working ${BLU}○ idle ${RED}✗ dead${GRY} | states ${GRN}done ${RED}failed/blocked ${YEL}needs-decision ${CYN}working${R}"
}

# ---- main -------------------------------------------------------------------
if [[ "${1:-}" == "--watch" ]]; then
  interval="${2:-5}"
  trap 'printf "\033[?25h"; exit 0' INT TERM
  printf '\033[?25l'  # hide cursor
  while true; do
    printf '\033[H\033[2J'  # home + clear
    render
    sleep "$interval"
  done
else
  render
fi
