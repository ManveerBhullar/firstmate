#!/usr/bin/env bash
# TEMP migration helper (firstmate-local): relaunch an existing crewmate window on
# opencode, reusing its existing treehouse worktree so the branch and all uncommitted
# WIP on disk are preserved. Only the agent's in-memory chat is replaced.
# Auto-builds a resume brief from the crew's original data/<id>/brief.md.
# Usage: fm-migrate-opencode.sh <task-id> [model]   (model default: zai-coding-plan/glm-5.2)
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE="$FM_ROOT/state"
DATA="$FM_ROOT/data"
ID=${1:?task-id}
MODEL=${2:-zai-coding-plan/glm-5.2}
META="$STATE/$ID.meta"
ORIG_BRIEF="$DATA/$ID/brief.md"
[ -f "$META" ] || { echo "error: no meta for $ID" >&2; exit 1; }
[ -f "$ORIG_BRIEF" ] || { echo "error: no original brief at $ORIG_BRIEF" >&2; exit 1; }
T=$(grep '^window=' "$META" | cut -d= -f2-)
WT=$(grep '^worktree=' "$META" | cut -d= -f2-)
[ -n "$T" ] && [ -n "$WT" ] || { echo "error: meta missing window/worktree" >&2; exit 1; }
[ -d "$WT" ] || { echo "error: worktree missing: $WT" >&2; exit 1; }
git -C "$WT" rev-parse --show-toplevel >/dev/null 2>&1 || { echo "error: $WT not a git worktree" >&2; exit 1; }

BR=$(git -C "$WT" rev-parse --abbrev-ref HEAD)
DIRTY=$(git -C "$WT" status --porcelain | wc -l | tr -d ' ')
echo "migrating $ID -> opencode/$MODEL (window=$T worktree=$WT branch=$BR dirty=$DIRTY)"

# Build the resume brief: continuation preamble + original brief.
RESUME="$DATA/$ID/resume-brief.md"
{
  echo "# RESUME (harness switched to opencode / $MODEL)"
  echo
  echo "You are RESUMING task \`$ID\` — a previous agent already worked in THIS worktree and its"
  echo "in-progress changes are on disk. Do NOT start over."
  echo "FIRST run: \`git status\`, \`git log --oneline -8\`, and \`git diff\` (and \`git diff --staged\`)"
  echo "to see exactly what was already done, then CONTINUE from there to completion."
  echo "Your branch is \`$BR\` — keep using it; do not create a new branch."
  echo "Finish the implementation, run the CI-order checks, push, open the PR with gh-axi, and"
  echo "append \`done: PR {url}\` to your status file, exactly as your original brief requires."
  echo
  echo "--- ORIGINAL BRIEF FOLLOWS ---"
  echo
  cat "$ORIG_BRIEF"
} > "$RESUME"

# Kill whatever agent runs in the pane and start a fresh shell in the worktree.
tmux respawn-pane -k -t "$T" -c "$WT"
sleep 1
# Belt-and-suspenders: reap any surviving stuck codex node children of the pane.
PANE_PID=$(tmux display-message -p -t "$T" '#{pane_pid}' 2>/dev/null || true)
if [ -n "${PANE_PID:-}" ]; then
  for c in $(pgrep -P "$PANE_PID" 2>/dev/null || true); do kill -9 "$c" 2>/dev/null || true; done
fi

# Install opencode turn-end plugin (touches state/<id>.turn-ended on session.idle).
TURNEND="$STATE/$ID.turn-ended"
mkdir -p "$WT/.opencode/plugins"
cat > "$WT/.opencode/plugins/fm-turn-end.js" <<EOF
export const FmTurnEnd = async ({ \$ }) => ({
  event: async ({ event }) => {
    if (event.type === "session.idle") await \$\`touch $TURNEND\`
  },
})
EOF
EXCL=$(git -C "$WT" rev-parse --git-path info/exclude 2>/dev/null || true)
if [ -n "$EXCL" ]; then mkdir -p "$(dirname "$EXCL")"; grep -qxF '.opencode/plugins/fm-turn-end.js' "$EXCL" 2>/dev/null || echo '.opencode/plugins/fm-turn-end.js' >> "$EXCL"; fi

# Update meta to opencode + record the model.
tmp=$(mktemp)
sed -e 's/^harness=.*/harness=opencode/' -e "s#^model=.*#model=$MODEL#" "$META" > "$tmp" && mv "$tmp" "$META"
grep -q '^model=' "$META" || echo "model=$MODEL" >> "$META"

# Launch opencode with the resume brief.
sq_brief=$(printf "'%s'" "$(printf '%s' "$RESUME" | sed "s/'/'\\\\''/g")")
LAUNCH="OPENCODE_CONFIG_CONTENT='{\"permission\":{\"*\":\"allow\"}}' opencode --model $MODEL --prompt \"\$(cat $sq_brief)\""
tmux send-keys -t "$T" -l "$LAUNCH"
sleep 0.3
tmux send-keys -t "$T" Enter
echo "  launched opencode/$MODEL in $T; peek in ~15s"
