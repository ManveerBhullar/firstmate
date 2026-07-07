# Web companion (experimental)

Localhost dashboard for watching a firstmate fleet without living in the terminal.
This is **experimental companion tooling** — not part of upstream firstmate today.
It reads fleet state from disk and calls existing `bin/` helpers for writes.

## Quick start

In a terminal **separate from your firstmate session** (the process does not start automatically when firstmate restarts):

```sh
bin/fm-web.sh
```

Open http://127.0.0.1:8787/ (default port; override with `--port`).

Requires `python3` on PATH and `gh` authenticated for the **Recent merges** section.

## What it shows

| Section | Source |
| --- | --- |
| Action required | In-flight tasks in `needs-decision`, `blocked`, `failed`, or PR-ready state (open PRs only — merged PRs drop out) |
| In flight | `state/*.meta` + live `fm-crew-state.sh` per task |
| Queued | `data/backlog.md` queued items |
| Recent merges | GitHub merged PRs (last few days), enriched with crew task id from `fm/<task>` branches |

Header counts include working, PR-ready, needs-you, queued, and recent merge totals.
Watcher liveness comes from `state/.last-watcher-beat`.

## Interactions

- **Click a task ID** — slide-over panel with agent pane output (`fm-peek.sh`) and a one-line send box (`fm-send.sh`).
- **Remove** on queued rows — runs `fm-backlog-rm.sh` (queued items only).
- **SSE** — `/api/events` pushes fleet refreshes; the page also polls every 30s as a fallback.

Web actions that firstmate should know about are appended to `data/captain-actions.log` via `fm-captain-action.sh`, and session start prints the last 15 lines of that log.

## HTTP API

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/api/health` | Fast liveness probe |
| GET | `/api/fleet` | Full fleet JSON snapshot |
| GET | `/api/events` | SSE stream (`fleet-changed` events) |
| GET | `/api/crew/<id>/peek?lines=50` | Agent pane capture |
| POST | `/api/crew/<id>/send` | `{"message":"one line"}` steer |
| POST | `/api/queue/remove` | `{"id":"<task-id>"}` remove queued item |
| POST | `/api/reconnect` | Refresh dashboard link; queue a firstmate ping via captain-actions |

All endpoints are localhost-only. Task ids must match `state/<id>.meta`.

## Environment

| Variable | Default | Meaning |
| --- | --- | --- |
| `FM_HOME` | repo root | Operational home (`state/`, `data/`) |
| `FM_WEB_MERGE_DAYS` | `3` | How far back to fetch GitHub merges |
| `FM_WEB_MERGE_LIMIT` | `80` | Max merge rows |
| `FM_WEB_MERGE_CACHE_SECS` | `120` | GitHub merge cache TTL |

GitHub repos queried: `roleready-modern`, `roleready-website-final`, `ManveerBhullar.com` (owner `ManveerBhullar`).
Edit `GITHUB_REPOS` in `bin/fm-web.sh` to match your fleet.

## Related scripts

| Script | Role |
| --- | --- |
| `fm-web.sh` | Web server |
| `fm-backlog-rm.sh` | Validated queue removal |
| `fm-captain-action.sh` | Log captain actions from outside chat |
| `fm-dashboard.sh` | Optional colored TUI (`--watch`) |
| `fm-fleet-dashboard.sh` | Compact text fleet overview |

## Fork workflow

This branch is maintained on a personal fork for experimentation.
Upstream is [kunchenguid/firstmate](https://github.com/kunchenguid/firstmate).

```sh
git fetch origin
git checkout fm-web-companion
bin/fm-web.sh
```

To contribute upstream later, follow [CONTRIBUTING.md](../CONTRIBUTING.md) and `no-mistakes init --fork-url` against your fork.

## Reconnect button

The header **Reconnect** button:

1. Refreshes fleet data and the SSE stream (fixes a stale or offline dashboard when `bin/fm-web.sh` is still running).
2. Logs a captain action and enqueues a low-priority wake so firstmate can reconcile — **only if** a live firstmate session and watcher are already running.

It **cannot** start a sleeping firstmate LLM session from the browser.
When the session lock is free or stale, open your firstmate chat to wake the agent; the dashboard will show **Firstmate: asleep**.

## PR status

Tasks that reported `done: PR <url>` normally show as **PR ready**.
The dashboard also checks GitHub: if the PR is already **merged**, the row moves to **Merged** (awaiting teardown) and leaves Action required.
The crew worktree stays until firstmate runs teardown — that is expected.

## Limits

- Send is **single-line only** (same contract as `fm-send.sh`).
- Recent merges prefer GitHub merge time; backlog `## Done` is a fallback when `gh` is unavailable.
- Dependabot and non-`fm/` branch PRs appear without a crew task id.
- The server is single-threaded Python with a short GitHub cache; do not expose beyond localhost.