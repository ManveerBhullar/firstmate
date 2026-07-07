#!/usr/bin/env bash
# TEMP migration helper (firstmate-local): relaunch an existing crewmate window on
# claude, reusing its existing treehouse worktree so the branch and all uncommitted
# WIP on disk are preserved. Only the agent's in-memory chat is replaced.
# Usage: fm-migrate-claude.sh <task-id> <resume-brief-path>
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE="$FM_ROOT/state"
ID=${1:?task-id}
BRIEF=${2:?resume-brief-path}
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for $ID" >&2; exit 1; }
[ -f "$BRIEF" ] || { echo "error: no brief at $BRIEF" >&2; exit 1; }
T=$(grep '^window=' "$META" | cut -d= -f2-)
WT=$(grep '^worktree=' "$META" | cut -d= -f2-)
[ -n "$T" ] && [ -n "$WT" ] || { echo "error: meta missing window/worktree" >&2; exit 1; }
[ -d "$WT" ] || { echo "error: worktree missing: $WT" >&2; exit 1; }
git -C "$WT" rev-parse --show-toplevel >/dev/null 2>&1 || { echo "error: $WT not a git worktree" >&2; exit 1; }

echo "migrating $ID -> claude (window=$T worktree=$WT)"
echo "  pre-migration git: branch=$(git -C "$WT" rev-parse --abbrev-ref HEAD) dirty=$(git -C "$WT" status --porcelain | wc -l | tr -d ' ')"

# Kill whatever agent runs in the pane and start a fresh shell in the worktree.
tmux respawn-pane -k -t "$T" -c "$WT"
sleep 1

# Install claude turn-end hook (touches state/<id>.turn-ended on Stop).
TURNEND="$STATE/$ID.turn-ended"
mkdir -p "$WT/.claude"
cat > "$WT/.claude/settings.local.json" <<EOF
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"touch '$TURNEND'"}]}]}}
EOF
EXCL=$(git -C "$WT" rev-parse --git-path info/exclude 2>/dev/null || true)
if [ -n "$EXCL" ]; then mkdir -p "$(dirname "$EXCL")"; grep -qxF '.claude/settings.local.json' "$EXCL" 2>/dev/null || echo '.claude/settings.local.json' >> "$EXCL"; fi

# Update meta to claude.
tmp=$(mktemp)
sed 's/^harness=.*/harness=claude/' "$META" > "$tmp" && mv "$tmp" "$META"

# Launch claude with the resume brief.
sq_brief=$(printf "'%s'" "$(printf '%s' "$BRIEF" | sed "s/'/'\\\\''/g")")
LAUNCH="CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions \"\$(cat $sq_brief)\""
tmux send-keys -t "$T" -l "$LAUNCH"
sleep 0.3
tmux send-keys -t "$T" Enter
echo "  launched claude in $T; peek in ~15s for trust dialog"
