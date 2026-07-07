---
name: blitz
description: Use when the captain drops a list of tasks (in chat or a file) and wants them all worked through overnight by multiple crews until everything is merged, built, and deployed.
user-invocable: true
metadata:
  internal: true
---

# Blitz — overnight batch task orchestration

Use when the captain drops a list of tasks (in chat or a file) and wants them all worked through overnight by multiple crews until everything is merged, built, and deployed.

## Activation
Captain says "blitz", "run all night", "work through this list", or drops a batch of tasks with instructions to get them all merged.

## Crew staffing model

Two tiers of intelligence, managed by a usage-aware promotion/demotion:

### Tier 1 — Fable (claude-fable-5, the frontier model)
- **Role:** Hard planning, UI/UX design decisions, breaking complex tasks into implementation-ready chunks, confirming difficult technical decisions.
- **Used as:** Scout tasks that produce implementation-ready plans/reports, OR ship tasks for end-to-end difficult iterative work.
- **Usage watch:** Fable is on the MAX plan and burns tokens fast. Monitor usage throughout the night.

### Tier 2 — OpenCode (GLM via Z.AI)
- **Role:** Everything else — implementation of well-scoped chunks, iterative fixes, cleanup, standard ship tasks.
- **Used as:** Ship tasks with clear briefs (either from the task list directly or from Fable-produced plans).
- **Effectively unlimited** — self-heals on rate limits via retries.

### Tier 2.5 — Claude Opus/Sonnet (the "smart" fallback)
- **Role:** Steps in as the "smart" tier when Fable usage approaches limits.
- **Trigger:** At ~50% Fable usage, wind down active Fable sessions to free context. Switch to Opus/Sonnet for planning/scoping. Reserve remaining Fable budget for only the hardest UI/UX or architectural decisions.

## Orchestration rules

1. **Batch size:** 4-5 concurrent crews max (OOM lesson — 16 concurrent kills the machine).
2. **Categorize tasks:** Sort into Fable-tier (hard/design/planning) and OpenCode-tier (implementation/cleanup).
3. **Dependencies first:** Tasks that unblock others go in Wave 1.
4. **Parallel where possible:** Fable scouts plan while OpenCode crews implement independent tasks simultaneously.
5. **Plans become tasks:** When a Fable scout finishes, its report becomes 1-3 OpenCode implementation tasks.
6. **Merge continuously:** Review diff, merge, teardown, dispatch next — never let the pipeline go empty.
7. **Keep the watcher alive:** Run in detached tmux pane, check beacon on every turn.
8. **Deploy at the end:** After all tasks are merged, run the captain's deploy command: `bun run docker:build && bun run docker:push && bun run docker:deploy`.

## Deploy
The captain specifies the deploy command. Default: `bun run docker:build && bun run docker:push && bun run docker:deploy`. Run AFTER all merges are confirmed on main. Background it or run in a dedicated tmux pane so it doesn't block the watcher.
