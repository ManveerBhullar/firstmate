#!/usr/bin/env bash
# fm-web.sh — experimental local web companion for firstmate fleet state.
#
# Serves a live dashboard from state/*.meta + fm-crew-state.sh on localhost.
# Queue removal, agent peek/send, and captain-action logging go through bin/ helpers.
# Recent merges are fetched from GitHub (see docs/web-companion.md).
#
# Usage:
#   bin/fm-web.sh              start on port 8787
#   bin/fm-web.sh --port 9000  custom port
#
# Open http://127.0.0.1:<port>/ in a browser; /api/fleet returns JSON.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOME_DIR="${FM_HOME:-$REPO_ROOT}"
STATE_DIR="${FM_STATE_OVERRIDE:-$HOME_DIR/state}"
PORT=8787

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT="${2:?}"; shift 2 ;;
    -h|--help)
      sed -n '2,11p' "$0"
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

export FM_WEB_HOME="$HOME_DIR"
export FM_WEB_STATE="$STATE_DIR"
export FM_WEB_BIN="$SCRIPT_DIR"
export FM_WEB_PORT="$PORT"

exec python3 - "$PORT" <<'PY'
import json
import os
import queue
import re
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

HOME = Path(os.environ["FM_WEB_HOME"])
STATE = Path(os.environ["FM_WEB_STATE"])
BIN = Path(os.environ["FM_WEB_BIN"])
PORT = int(sys.argv[1])
GRACE = int(os.environ.get("FM_GUARD_GRACE", "300"))

PR_RE = re.compile(r"https://github\.com/[^\s)]+/pull/\d+")
PR_PATH_RE = re.compile(r"github\.com/([^/]+)/([^/]+)/pull/(\d+)")
REPO_FROM_PR_RE = re.compile(r"github\.com/[^/]+/([^/]+)/pull/")
DONE_OUTCOME_RE = re.compile(r"\((merged|reported|open)(?:\s+([^)]+))?\)", re.I)
ID_RE = re.compile(r"\*\*([a-z0-9][-a-z0-9]*)\*\*|^([a-z0-9][-a-z0-9]*) -")
TASK_ID_RE = re.compile(r"^[a-z0-9][-a-z0-9]*$")
CREW_PEEK_RE = re.compile(r"^/api/crew/([a-z0-9][-a-z0-9]*)/peek$")
CREW_SEND_RE = re.compile(r"^/api/crew/([a-z0-9][-a-z0-9]*)/send$")


def meta_val(path: Path, key: str) -> str:
    try:
        for line in path.read_text().splitlines():
            if line.startswith(f"{key}="):
                return line.split("=", 1)[1]
    except OSError:
        pass
    return ""


def watcher_status() -> dict:
    beat = STATE / ".last-watcher-beat"
    if not beat.is_file():
        return {"alive": False, "age_secs": None, "grace": GRACE}
    age = max(0, int(time.time() - beat.stat().st_mtime))
    return {"alive": age <= GRACE, "age_secs": age, "grace": GRACE}


def firstmate_session_status() -> dict:
    try:
        out = subprocess.check_output(
            [str(BIN / "fm-lock.sh"), "status"],
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=5,
        ).strip()
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError):
        return {
            "state": "unknown",
            "alive": False,
            "detail": "session status unavailable",
            "raw": "",
        }
    alive = "held by live" in out
    if alive:
        state = "live"
    elif "free" in out:
        state = "asleep"
    else:
        state = "asleep"
    detail = out.replace("lock: ", "", 1).strip() if out else "unknown"
    return {"state": state, "alive": alive, "detail": detail, "raw": out}


def reconnect_message(firstmate: dict, watcher: dict) -> str:
    if firstmate.get("alive") and watcher.get("alive"):
        return "Dashboard refreshed. Firstmate session is live."
    if firstmate.get("alive"):
        return "Dashboard refreshed. Ping queued — re-arm watcher in firstmate if supervision is off."
    return (
        "Dashboard refreshed. Firstmate chat is asleep — open your agent session to wake it. "
        "A ping is queued for when it returns."
    )


def reconnect_firstmate() -> dict:
    log_captain_action("reconnect-ui", "dashboard reconnect")
    firstmate = firstmate_session_status()
    watcher = watcher_status()
    return {
        "ok": True,
        "firstmate": firstmate,
        "watcher": watcher,
        "message": reconnect_message(firstmate, watcher),
    }


def parse_live_state(raw: str) -> dict:
    state = "unknown"
    detail = raw
    pr = ""
    m = re.search(r"state:\s*([a-z-]+)", raw, re.I)
    if m:
        state = m.group(1).lower()
    pr_m = PR_RE.search(raw)
    if pr_m:
        pr = pr_m.group(0)
    if " · " in raw:
        parts = [p.strip() for p in raw.split("·")]
        detail = parts[-1] if len(parts) > 1 else raw
    bucket = state
    if state == "done" and pr:
        bucket = "pr-ready"
    elif state in ("needs-decision", "blocked", "failed"):
        bucket = state
    elif state in ("working", "unknown"):
        bucket = state
    return {"state": state, "bucket": bucket, "detail": detail, "pr_from_state": pr}


def crew_state(task_id: str) -> dict:
    try:
        out = subprocess.check_output(
            [str(BIN / "fm-crew-state.sh"), task_id],
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=8,
        ).strip()
        parsed = parse_live_state(out or "")
        parsed["raw"] = out or "(no state)"
        return parsed
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError):
        return {
            "state": "unknown",
            "bucket": "unknown",
            "detail": "state unavailable",
            "pr_from_state": "",
            "raw": "(state unavailable)",
        }


def parse_backlog() -> dict:
    backlog = HOME / "data" / "backlog.md"
    inflight: list[dict] = []
    queued: list[dict] = []
    titles: dict[str, str] = {}
    if not backlog.is_file():
        return {"inflight": inflight, "queued": queued, "titles": titles}

    section = None
    for line in backlog.read_text().splitlines():
        s = line.strip()
        if s == "## In flight":
            section = "inflight"
            continue
        if s == "## Queued":
            section = "queued"
            continue
        if s.startswith("## "):
            if section == "queued":
                break
            section = None
            continue
        if not section or not s.startswith("- "):
            continue
        body = s[2:].strip()
        body = re.sub(r"^\[[ x]\]\s*", "", body)
        tid = ""
        m = ID_RE.search(body)
        if m:
            tid = m.group(1) or m.group(2) or ""
        title = body
        if tid:
            title = re.sub(r"^\*\*" + re.escape(tid) + r"\*\*\s*-\s*", "", body)
            title = re.sub(r"^" + re.escape(tid) + r"\s*-\s*", "", title)
            titles[tid] = title
        repo_m = re.search(r"\(repo:\s*([^)]+)\)", body)
        repo = repo_m.group(1).strip() if repo_m else ""
        item = {"id": tid, "title": title, "repo": repo, "line": body}
        if section == "inflight":
            inflight.append(item)
        else:
            queued.append(item)
    return {"inflight": inflight, "queued": queued, "titles": titles}


def parse_done_line(body: str) -> dict:
    body = re.sub(r"^\[[ xX]\]\s*", "", body.strip())
    tid = ""
    remainder = body
    id_m = re.match(r"^\*\*([a-z0-9][-a-z0-9]*)\*\*\s*[-—]\s*(.+)$", body, re.I)
    if id_m:
        tid, remainder = id_m.group(1), id_m.group(2)
    else:
        id_m = re.match(r"^([a-z0-9][-a-z0-9]*)\s*[-—]\s*(.+)$", body, re.I)
        if id_m:
            tid, remainder = id_m.group(1), id_m.group(2)
    pr = PR_RE.search(body)
    pr_url = pr.group(0) if pr else ""
    repo = ""
    if pr_url:
        repo_m = REPO_FROM_PR_RE.search(pr_url)
        if repo_m:
            repo = repo_m.group(1)
    outcome = ""
    date = ""
    out_m = DONE_OUTCOME_RE.search(body)
    if out_m:
        outcome = out_m.group(1).lower()
        date = (out_m.group(2) or "").strip()
    summary = remainder if tid else body
    if pr_url:
        summary = summary.replace(pr_url, "")
    summary = DONE_OUTCOME_RE.sub("", summary)
    summary = re.sub(r"\s*[—–-]\s*$", "", summary).strip()
    return {
        "id": tid,
        "summary": summary,
        "pr": pr_url,
        "repo": repo,
        "outcome": outcome,
        "date": date,
    }


def parse_done() -> list[dict]:
    backlog = HOME / "data" / "backlog.md"
    done: list[dict] = []
    if not backlog.is_file():
        return done
    in_done = False
    for line in backlog.read_text().splitlines():
        s = line.strip()
        if s.startswith("## Done"):
            in_done = True
            continue
        if s.startswith("## "):
            in_done = s.startswith("## Done")
            if not in_done:
                continue
        if not in_done or not s.startswith("- "):
            continue
        body = s[2:].strip()
        if not re.match(r"^\[[xX]\]", body):
            continue
        item = parse_done_line(body)
        if item["id"] or item["pr"] or item["summary"]:
            done.append(item)
    return done


GITHUB_REPOS = [
    ("roleready-modern", "roleready"),
    ("roleready-website-final", "roleready-website"),
    ("ManveerBhullar.com", "personal-site"),
]
_MERGE_CACHE: dict = {"ts": 0.0, "rows": [], "error": ""}
MERGE_CACHE_TTL = int(os.environ.get("FM_WEB_MERGE_CACHE_SECS", "120"))
MERGE_DAYS = int(os.environ.get("FM_WEB_MERGE_DAYS", "3"))
MERGE_LIMIT = int(os.environ.get("FM_WEB_MERGE_LIMIT", "80"))


def task_id_from_branch(head: str) -> str:
    if head.startswith("fm/"):
        cand = head[3:]
        if TASK_ID_RE.fullmatch(cand):
            return cand
    return ""


def build_crew_index() -> dict:
    by_pr: dict[str, dict] = {}
    by_id: dict[str, str] = {}

    for item in parse_done():
        if item["pr"]:
            by_pr[item["pr"]] = {"id": item["id"], "summary": item["summary"]}
        if item["id"] and item["summary"]:
            by_id[item["id"]] = item["summary"]

    backlog = parse_backlog()
    for tid, title in backlog["titles"].items():
        clean = re.sub(r"\s*\(repo:[^)]*\).*$", "", title).strip()
        clean = re.sub(r"\s*blocked-by:.*$", "", clean).strip()
        if clean and tid not in by_id:
            by_id[tid] = clean

    for status_path in STATE.glob("*.status"):
        tid = status_path.stem
        try:
            lines = status_path.read_text().splitlines()
        except OSError:
            continue
        for line in lines:
            if not line.startswith("done: PR "):
                continue
            pr_url = line.split("done: PR ", 1)[1].strip()
            entry = by_pr.get(pr_url, {})
            if not entry.get("id"):
                entry["id"] = tid
            if not entry.get("summary") and tid in by_id:
                entry["summary"] = by_id[tid]
            by_pr[pr_url] = entry

    for meta_path in STATE.glob("*.meta"):
        tid = meta_path.stem
        if tid in by_id:
            continue
        title = backlog["titles"].get(tid, "")
        if title:
            by_id[tid] = re.sub(r"\s*\(repo:[^)]*\).*$", "", title).strip()

    return {"by_pr": by_pr, "by_id": by_id}


def _backlog_only_merges(limit: int) -> list[dict]:
    merges = [d for d in parse_done() if d["outcome"] == "merged" and d["pr"]]
    merges.sort(key=lambda x: x["date"], reverse=True)
    return merges[:limit]


def fetch_github_merges() -> tuple[list[dict], str]:
    since = time.strftime("%Y-%m-%d", time.localtime(time.time() - MERGE_DAYS * 86400))
    index = build_crew_index()
    by_pr = index["by_pr"]
    by_id = index["by_id"]
    rows: list[dict] = []
    errors: list[str] = []

    for gh_repo, fleet_repo in GITHUB_REPOS:
        try:
            out = subprocess.check_output(
                [
                    "gh",
                    "pr",
                    "list",
                    "--repo",
                    f"ManveerBhullar/{gh_repo}",
                    "--state",
                    "merged",
                    "--search",
                    f"merged:>={since}",
                    "--limit",
                    str(MERGE_LIMIT),
                    "--json",
                    "number,title,mergedAt,url,headRefName",
                ],
                stderr=subprocess.STDOUT,
                text=True,
                timeout=20,
            )
            prs = json.loads(out or "[]")
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError, json.JSONDecodeError) as exc:
            msg = str(exc)
            if hasattr(exc, "output") and exc.output:
                msg = exc.output.strip() or msg
            errors.append(f"{gh_repo}: {msg}")
            continue

        for pr in prs:
            url = pr.get("url", "")
            merged_at = pr.get("mergedAt", "")
            tid = task_id_from_branch(pr.get("headRefName", "") or "")
            info = by_pr.get(url, {})
            if not tid:
                tid = info.get("id", "")
            summary = info.get("summary") or by_id.get(tid, "") or pr.get("title", "")
            rows.append(
                {
                    "id": tid,
                    "summary": summary.strip(),
                    "pr": url,
                    "repo": gh_repo,
                    "fleet_repo": fleet_repo,
                    "outcome": "merged",
                    "date": merged_at[:10] if merged_at else "",
                    "merged_at": merged_at,
                    "number": pr.get("number"),
                }
            )

    rows.sort(key=lambda x: x.get("merged_at", ""), reverse=True)
    return rows[:MERGE_LIMIT], "; ".join(errors)


def recent_merges() -> tuple[list[dict], str]:
    now = time.time()
    if _MERGE_CACHE["rows"] and now - _MERGE_CACHE["ts"] < MERGE_CACHE_TTL:
        return _MERGE_CACHE["rows"], _MERGE_CACHE["error"]

    rows, err = fetch_github_merges()
    if not rows:
        rows = _backlog_only_merges(MERGE_LIMIT)
        if not err:
            err = "GitHub unavailable — showing backlog Done only"
    _MERGE_CACHE["ts"] = now
    _MERGE_CACHE["rows"] = rows
    _MERGE_CACHE["error"] = err
    return rows, err


def fleet_row(meta: Path, titles: dict[str, str]) -> dict:
    tid = meta.stem
    project = meta_val(meta, "project")
    repo = Path(project).name if project else "?"
    pr = meta_val(meta, "pr")
    live = crew_state(tid)
    if not pr and live["pr_from_state"]:
        pr = live["pr_from_state"]
    return {
        "id": tid,
        "title": titles.get(tid, ""),
        "kind": meta_val(meta, "kind") or "ship",
        "harness": meta_val(meta, "harness") or "?",
        "repo": repo,
        "mode": meta_val(meta, "mode") or "?",
        "yolo": meta_val(meta, "yolo") == "on",
        "window": meta_val(meta, "window"),
        "pr": pr,
        "state": live["state"],
        "bucket": live["bucket"],
        "detail": live["detail"],
        "raw": live["raw"],
    }


_PR_STATE_CACHE: dict[str, dict] = {}
PR_STATE_CACHE_TTL = int(os.environ.get("FM_WEB_PR_CACHE_SECS", "120"))


def github_pr_state(pr_url: str) -> dict | None:
    m = PR_PATH_RE.search(pr_url or "")
    if not m:
        return None
    owner, repo, number = m.group(1), m.group(2), m.group(3)
    now = time.time()
    cached = _PR_STATE_CACHE.get(pr_url)
    if cached and now - cached.get("ts", 0) < PR_STATE_CACHE_TTL:
        return cached
    try:
        out = subprocess.check_output(
            [
                "gh",
                "pr",
                "view",
                number,
                "--repo",
                f"{owner}/{repo}",
                "--json",
                "state,mergedAt",
            ],
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=12,
        )
        data = json.loads(out or "{}")
        result = {
            "state": (data.get("state") or "").upper(),
            "merged_at": data.get("mergedAt") or "",
            "ts": now,
        }
        _PR_STATE_CACHE[pr_url] = result
        return result
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError, json.JSONDecodeError):
        return None


def apply_github_pr_status(rows: list[dict]) -> None:
    targets = [r for r in rows if r.get("pr") and r.get("bucket") == "pr-ready"]
    if not targets:
        return

    def enrich(row: dict) -> None:
        gh = github_pr_state(row["pr"])
        if not gh:
            return
        gh_state = gh.get("state", "")
        if gh_state == "MERGED":
            row["bucket"] = "merged"
            row["state"] = "merged"
            row["pr_state"] = "MERGED"
            row["merged_at"] = gh.get("merged_at", "")
            row["detail"] = "Merged on GitHub — awaiting teardown"
        elif gh_state == "CLOSED":
            row["bucket"] = "closed"
            row["state"] = "closed"
            row["pr_state"] = "CLOSED"
            row["detail"] = "PR closed without merge"

    with ThreadPoolExecutor(max_workers=min(len(targets), 6)) as pool:
        list(pool.map(lambda r: enrich(r), targets))


def fleet_rows(titles: dict[str, str]) -> list[dict]:
    metas = sorted(STATE.glob("*.meta"))
    rows: list[dict] = []
    if not metas:
        return rows
    with ThreadPoolExecutor(max_workers=min(len(metas), 6)) as pool:
        futures = {pool.submit(fleet_row, meta, titles): meta for meta in metas}
        for fut in as_completed(futures):
            rows.append(fut.result())
    apply_github_pr_status(rows)
    order = {
        "needs-decision": 0,
        "blocked": 1,
        "failed": 2,
        "pr-ready": 3,
        "working": 4,
        "merged": 5,
        "closed": 6,
        "unknown": 7,
        "done": 8,
    }
    rows.sort(key=lambda r: (order.get(r["bucket"], 9), r["id"]))
    return rows


def log_captain_action(verb: str, detail: str) -> None:
    try:
        subprocess.run(
            [str(BIN / "fm-captain-action.sh"), "log", verb, detail],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=10,
        )
    except (subprocess.TimeoutExpired, OSError):
        pass


def task_meta_exists(task_id: str) -> bool:
    if not TASK_ID_RE.fullmatch(task_id or ""):
        return False
    return (STATE / f"{task_id}.meta").is_file()


def peek_crew(task_id: str, lines: int = 50) -> dict:
    if not task_meta_exists(task_id):
        return {"ok": False, "error": "unknown task"}
    lines = max(10, min(lines, 120))
    try:
        out = subprocess.check_output(
            [str(BIN / "fm-peek.sh"), f"fm-{task_id}", str(lines)],
            stderr=subprocess.STDOUT,
            text=True,
            timeout=12,
        )
        return {"ok": True, "output": out, "lines": lines}
    except subprocess.CalledProcessError as exc:
        msg = (exc.output or str(exc)).strip()
        return {"ok": False, "error": msg or "peek failed"}
    except (subprocess.TimeoutExpired, OSError) as exc:
        return {"ok": False, "error": str(exc)}


def send_to_crew(task_id: str, message: str) -> dict:
    if not task_meta_exists(task_id):
        return {"ok": False, "error": "unknown task"}
    message = (message or "").strip()
    if not message:
        return {"ok": False, "error": "empty message"}
    if "\n" in message or "\r" in message:
        return {"ok": False, "error": "message must be a single line"}
    if len(message) > 2000:
        return {"ok": False, "error": "message too long (max 2000 chars)"}
    try:
        subprocess.check_output(
            [str(BIN / "fm-send.sh"), f"fm-{task_id}", message],
            stderr=subprocess.STDOUT,
            text=True,
            timeout=30,
        )
        preview = message if len(message) <= 80 else message[:77] + "..."
        log_captain_action("steered-crew", f"{task_id}: {preview}")
        return {"ok": True, "message": "sent"}
    except subprocess.CalledProcessError as exc:
        msg = (exc.output or str(exc)).strip()
        return {"ok": False, "error": msg or "send failed"}
    except (subprocess.TimeoutExpired, OSError) as exc:
        return {"ok": False, "error": str(exc)}


def remove_queued_item(task_id: str) -> dict:
    if not TASK_ID_RE.fullmatch(task_id or ""):
        return {"ok": False, "error": "invalid task id"}
    try:
        out = subprocess.check_output(
            [str(BIN / "fm-backlog-rm.sh"), task_id],
            stderr=subprocess.STDOUT,
            text=True,
            timeout=15,
        ).strip()
        log_captain_action("removed-queued", task_id)
        return {"ok": True, "message": out}
    except subprocess.CalledProcessError as exc:
        msg = (exc.output or str(exc)).strip()
        return {"ok": False, "error": msg or "remove failed"}
    except (subprocess.TimeoutExpired, OSError) as exc:
        return {"ok": False, "error": str(exc)}


class FleetWatcher:
    """Poll fleet/backlog mtimes and notify SSE subscribers on change."""

    def __init__(self, home: Path, state: Path) -> None:
        self.home = home
        self.state = state
        self._clients: list[queue.Queue[str]] = []
        self._lock = threading.Lock()
        self._last = ""
        self._stop = threading.Event()

    def _fingerprint(self) -> str:
        parts: list[str] = []
        for pattern in ("*.meta", "*.status"):
            for path in sorted(self.state.glob(pattern)):
                try:
                    parts.append(f"{path.name}:{path.stat().st_mtime_ns}")
                except OSError:
                    continue
        for path in (self.home / "data" / "backlog.md", self.state / ".last-watcher-beat"):
            if path.is_file():
                try:
                    parts.append(f"{path}:{path.stat().st_mtime_ns}")
                except OSError:
                    continue
        return "|".join(parts)

    def run(self) -> None:
        while not self._stop.is_set():
            fp = self._fingerprint()
            if fp != self._last:
                if self._last:
                    self._broadcast('{"type":"fleet-changed"}')
                self._last = fp
            self._stop.wait(0.35)

    def subscribe(self) -> queue.Queue[str]:
        q: queue.Queue[str] = queue.Queue(maxsize=8)
        with self._lock:
            self._clients.append(q)
        return q

    def unsubscribe(self, q: queue.Queue[str]) -> None:
        with self._lock:
            try:
                self._clients.remove(q)
            except ValueError:
                pass

    def _broadcast(self, payload: str) -> None:
        with self._lock:
            live: list[queue.Queue[str]] = []
            for client in self._clients:
                try:
                    client.put_nowait(payload)
                    live.append(client)
                except queue.Full:
                    pass
            self._clients = live


FLEET_WATCHER: FleetWatcher | None = None


def snapshot() -> dict:
    backlog = parse_backlog()
    fleet = fleet_rows(backlog["titles"])
    summary = {
        "total": len(fleet),
        "working": sum(1 for r in fleet if r["bucket"] == "working"),
        "pr_ready": sum(1 for r in fleet if r["bucket"] == "pr-ready"),
        "merged_pending": sum(1 for r in fleet if r["bucket"] == "merged"),
        "needs_you": sum(1 for r in fleet if r["bucket"] in ("needs-decision", "blocked", "failed")),
        "queued": len(backlog["queued"]),
    }
    attention = [r for r in fleet if r["bucket"] in ("pr-ready", "needs-decision", "blocked", "failed")]
    merges, merge_err = recent_merges()
    summary["merged_recent"] = len(merges)
    summary["merge_days"] = MERGE_DAYS
    return {
        "home": str(HOME),
        "ts": time.strftime("%Y-%m-%d %H:%M:%S %Z"),
        "firstmate": firstmate_session_status(),
        "watcher": watcher_status(),
        "summary": summary,
        "attention": attention,
        "fleet": fleet,
        "backlog_inflight": backlog["inflight"],
        "backlog_queued": backlog["queued"][:30],
        "recent_merges": merges,
        "merge_note": merge_err,
    }


PAGE = r"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Firstmate</title>
  <style>
    :root {
      --bg: #0d0d0d;
      --line: #2a2a2a;
      --text: #ececec;
      --muted: #8a8a8a;
      --link: #6eb5ff;
      --ok: #4ade80;
      --warn: #facc15;
      --bad: #f87171;
      --work: #93c5fd;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font: 16px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
      background: var(--bg);
      color: var(--text);
      min-height: 100vh;
    }
    .wrap { max-width: 1200px; margin: 0 auto; padding: 28px 24px 48px; }

    .top {
      padding-bottom: 20px;
      border-bottom: 1px solid var(--line);
      margin-bottom: 24px;
    }
    .top h1 { font-size: 22px; font-weight: 600; }
    .top .meta { color: var(--muted); font-size: 15px; margin-top: 4px; }
    .counts {
      display: flex;
      flex-wrap: wrap;
      gap: 16px 20px;
      margin-top: 14px;
      font-size: 15px;
      color: var(--muted);
    }
    .counts b { color: var(--text); font-weight: 600; }
    .counts .hi b { color: var(--warn); }
    .counts .pr b { color: var(--link); }
    .supervision {
      display: flex; align-items: center; gap: 8px;
      margin-top: 12px;
      font-size: 15px; color: var(--muted);
    }
    .supervision .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--ok); }
    .supervision.off .dot { background: var(--bad); }
    .supervision.off { color: var(--bad); }
    .supervision.warn .dot { background: var(--warn); }
    .supervision.warn { color: var(--warn); }
    .supervision-row {
      display: flex;
      flex-wrap: wrap;
      align-items: center;
      gap: 12px 16px;
      margin-top: 12px;
    }
    .reconnect-note {
      color: var(--muted);
      font-size: 14px;
      margin-top: 8px;
      min-height: 1.2em;
      line-height: 1.45;
    }

    .alert {
      display: none;
      padding: 14px 16px;
      border: 1px solid #7f1d1d;
      background: #1a0a0a;
      color: #fca5a5;
      font-size: 15px;
      line-height: 1.45;
      margin-bottom: 24px;
      border-radius: 6px;
    }
    .alert.show { display: block; }

    .stack { display: flex; flex-direction: column; gap: 32px; }

    .section-title {
      font-size: 14px;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.06em;
      color: var(--muted);
      margin-bottom: 10px;
    }

    .table-box {
      border: 1px solid var(--line);
      border-radius: 8px;
      overflow: auto;
    }
    table.data {
      width: 100%;
      border-collapse: collapse;
      font-size: 16px;
    }
    table.data thead th {
      position: sticky;
      top: 0;
      z-index: 1;
      background: #141414;
      border-bottom: 1px solid var(--line);
      padding: 12px 14px;
      text-align: left;
      font-size: 13px;
      font-weight: 600;
      color: var(--muted);
      text-transform: uppercase;
      letter-spacing: 0.04em;
      white-space: nowrap;
    }
    table.data tbody td {
      padding: 14px;
      border-bottom: 1px solid #1f1f1f;
      vertical-align: top;
      line-height: 1.45;
    }
    table.data tbody tr:last-child td { border-bottom: none; }
    table.data tbody tr:hover { background: #141414; }
    table.data tbody tr.flag { background: #141008; }
    table.data tbody tr.flag-pr { background: #0a1018; }
    table.data tbody tr.merge { background: #081208; }
    .merges-box { max-height: 520px; }
    .merge-note { color: var(--muted); font-size: 14px; margin-top: 8px; min-height: 1.2em; }

    .mono {
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      font-size: 14px;
      color: var(--muted);
    }
    .task-name { font-weight: 600; }
    .task-name.empty { color: var(--muted); font-weight: 400; }
    .muted { color: var(--muted); }

    .status {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      font-weight: 600;
      white-space: nowrap;
    }
    .status .dot { width: 8px; height: 8px; border-radius: 50%; flex-shrink: 0; }
    .status.s-working .dot { background: var(--work); }
    .status.s-pr-ready .dot { background: var(--ok); }
    .status.s-merged .dot { background: var(--ok); }
    table.data tbody tr.flag-merged { background: #0a140a; }
    .status.s-needs-decision .dot, .status.s-blocked .dot, .status.s-failed .dot { background: var(--warn); }
    .status.s-done .dot { background: var(--ok); }
    .status.s-unknown .dot { background: var(--muted); }

    .note { color: #b0b0b0; max-width: 280px; word-wrap: break-word; }
    .empty-cell {
      text-align: center;
      color: var(--muted);
      padding: 36px 16px !important;
    }

    a { color: var(--link); text-decoration: none; }
    a:hover { text-decoration: underline; }

    .btn {
      font: inherit;
      font-size: 14px;
      padding: 6px 12px;
      border-radius: 4px;
      border: 1px solid var(--line);
      background: #1a1a1a;
      color: var(--text);
      cursor: pointer;
    }
    .btn:hover { background: #242424; }
    .btn.danger { border-color: #5c2328; color: #fca5a5; }
    .btn.danger:hover { background: #2a1518; }
    .btn:disabled { opacity: 0.5; cursor: not-allowed; }

    footer { margin-top: 32px; font-size: 14px; color: var(--muted); }

    .id-link {
      color: var(--link);
      cursor: pointer;
      text-decoration: none;
      border-bottom: 1px dotted transparent;
    }
    .id-link:hover { border-bottom-color: var(--link); }

    .crew-panel {
      display: none;
      position: fixed;
      inset: 0;
      z-index: 100;
      background: rgba(0, 0, 0, 0.55);
    }
    .crew-panel.open { display: flex; align-items: stretch; justify-content: flex-end; }
    .crew-sheet {
      width: min(720px, 100%);
      background: #111;
      border-left: 1px solid var(--line);
      display: flex;
      flex-direction: column;
      max-height: 100vh;
    }
    .crew-head {
      display: flex;
      align-items: flex-start;
      justify-content: space-between;
      gap: 12px;
      padding: 16px 18px;
      border-bottom: 1px solid var(--line);
      flex-shrink: 0;
    }
    .crew-head h2 { font-size: 17px; font-weight: 600; }
    .crew-head .sub { color: var(--muted); font-size: 14px; margin-top: 4px; }
    .crew-out {
      flex: 1;
      overflow: auto;
      margin: 0;
      padding: 14px 18px;
      font: 13px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace;
      color: #d4d4d4;
      white-space: pre-wrap;
      word-break: break-word;
      background: #0a0a0a;
    }
    .crew-foot {
      padding: 14px 18px 18px;
      border-top: 1px solid var(--line);
      flex-shrink: 0;
    }
    .crew-foot form { display: flex; gap: 10px; }
    .crew-foot input {
      flex: 1;
      font: inherit;
      font-size: 15px;
      padding: 10px 12px;
      border-radius: 6px;
      border: 1px solid var(--line);
      background: #1a1a1a;
      color: var(--text);
    }
    .crew-foot input:focus { outline: none; border-color: #444; }
    .crew-foot .hint { color: var(--muted); font-size: 13px; margin-top: 8px; }
    .crew-err { color: var(--bad); font-size: 14px; margin-top: 8px; min-height: 1.2em; }
    .crew-actions { display: flex; gap: 8px; flex-shrink: 0; }
  </style>
</head>
<body>
  <div class="wrap">
    <div class="top">
      <h1>Firstmate</h1>
      <div class="meta" id="meta">Loading…</div>
      <div class="counts" id="counts"></div>
      <div class="supervision-row">
        <div class="supervision" id="firstmate-session">
          <span class="dot"></span><span id="firstmate-text">Firstmate: checking</span>
        </div>
        <div class="supervision" id="supervision">
          <span class="dot"></span><span id="supervision-text">Watcher: checking</span>
        </div>
        <button class="btn" type="button" id="reconnect-btn">Reconnect</button>
      </div>
      <div class="reconnect-note" id="reconnect-note"></div>
    </div>

    <div class="alert" id="watcher-alert"></div>

    <div class="stack">
      <section id="attention-section" style="display:none">
        <div class="section-title">Action required (<span id="attention-count">0</span>)</div>
        <div class="table-box">
          <table class="data">
            <thead>
              <tr>
                <th>ID</th><th>Task</th><th>Type</th><th>Agent</th><th>Repo</th><th>Status</th><th>PR</th><th>Latest</th>
              </tr>
            </thead>
            <tbody id="attention"></tbody>
          </table>
        </div>
      </section>

      <section>
        <div class="section-title">In flight (<span id="fleet-count">0</span>)</div>
        <div class="table-box">
          <table class="data">
            <thead>
              <tr>
                <th>ID</th><th>Task</th><th>Type</th><th>Agent</th><th>Repo</th><th>Status</th><th>PR</th><th>Latest</th>
              </tr>
            </thead>
            <tbody id="fleet"></tbody>
          </table>
        </div>
      </section>

      <section>
        <div class="section-title">Queued (<span id="queued-count">0</span>)</div>
        <div class="table-box">
          <table class="data">
            <thead>
              <tr><th>ID</th><th>Task</th><th>Repo</th><th></th></tr>
            </thead>
            <tbody id="queued"></tbody>
          </table>
        </div>
      </section>

      <section>
        <div class="section-title">Recent merges — last <span id="merges-days">3</span> days (<span id="merges-count">0</span>)</div>
        <div class="table-box merges-box">
          <table class="data">
            <thead>
              <tr><th>ID</th><th>Summary</th><th>Repo</th><th>PR</th><th>Merged</th></tr>
            </thead>
            <tbody id="merges"></tbody>
          </table>
        </div>
        <div class="merge-note" id="merge-note"></div>
      </section>
    </div>

    <footer>Live SSE updates · click an ID to peek/send · actions log to data/captain-actions.log</footer>
  </div>

  <div class="crew-panel" id="crew-panel" aria-hidden="true">
    <div class="crew-sheet">
      <div class="crew-head">
        <div>
          <h2 id="crew-title">Agent</h2>
          <div class="sub" id="crew-sub"></div>
        </div>
        <div class="crew-actions">
          <button class="btn" type="button" id="crew-refresh">Refresh</button>
          <button class="btn" type="button" id="crew-close">Close</button>
        </div>
      </div>
      <pre class="crew-out" id="crew-out">Loading…</pre>
      <div class="crew-foot">
        <form id="crew-send-form">
          <input type="text" id="crew-input" placeholder="Send a one-line message to this agent…" autocomplete="off">
          <button class="btn" type="submit" id="crew-send-btn">Send</button>
        </form>
        <div class="hint">Single line only — same as steering in the terminal. Sends are logged for firstmate.</div>
        <div class="crew-err" id="crew-err"></div>
      </div>
    </div>
  </div>

  <script>
    function esc(s) {
      return String(s ?? '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
    }
    function prNum(pr) {
      const m = (pr || '').match(/\/pull\/(\d+)/);
      return m ? m[1] : '';
    }
    function prLink(pr) {
      if (!pr) return '<span class="muted">—</span>';
      const n = prNum(pr);
      return `<a href="${esc(pr)}" target="_blank" rel="noopener">#${esc(n || 'PR')}</a>`;
    }
    let crewOpenId = null;
    let fleetCache = null;
    let tickBusy = false;
    let peekTimer = null;
    let sse = null;

    function fetchTimeout(ms) {
      if (typeof AbortSignal !== 'undefined' && AbortSignal.timeout) {
        return AbortSignal.timeout(ms);
      }
      const ctrl = new AbortController();
      setTimeout(() => ctrl.abort(), ms);
      return ctrl.signal;
    }

    function scheduleCrewPeek() {
      if (!crewOpenId) return;
      clearTimeout(peekTimer);
      peekTimer = setTimeout(refreshCrewPeek, 1200);
    }

    function idCell(id) {
      if (!id) return '<span class="muted">—</span>';
      return `<a class="mono id-link" href="#" data-crew-id="${esc(id)}" onclick="openCrew(this.dataset.crewId); return false;">${esc(id)}</a>`;
    }
    function taskRow(r) {
      const flag = r.bucket === 'pr-ready' ? 'flag-pr'
        : r.bucket === 'merged' ? 'flag-merged'
        : (r.bucket === 'needs-decision' || r.bucket === 'blocked' || r.bucket === 'failed') ? 'flag' : '';
      const title = r.title || '';
      const note = trimNote(r.detail) || '—';
      return `<tr class="${flag}">
        <td>${idCell(r.id)}</td>
        <td><div class="task-name${title ? '' : ' empty'}">${esc(title || '—')}</div></td>
        <td class="muted">${esc(r.kind)}</td>
        <td>${esc(agentName(r.harness))}</td>
        <td class="muted">${esc(r.repo)}</td>
        <td>${statusHtml(r.bucket, r.state)}</td>
        <td>${prLink(r.pr)}</td>
        <td class="note">${esc(note)}</td>
      </tr>`;
    }
    function agentName(h) {
      const map = { opencode: 'OpenCode', codex: 'Codex', claude: 'Claude', grok: 'Grok', pi: 'Pi' };
      return map[h] || h;
    }
    function statusLabel(bucket, state) {
      if (bucket === 'pr-ready') return 'PR ready';
      if (bucket === 'merged') return 'Merged';
      if (bucket === 'closed') return 'PR closed';
      if (bucket === 'needs-decision') return 'Decision';
      if (bucket === 'blocked') return 'Blocked';
      if (bucket === 'failed') return 'Failed';
      if (state === 'working') return 'Working';
      if (state === 'done') return 'Done';
      return state || 'Unknown';
    }
    function statusHtml(bucket, state) {
      const cls = 'status s-' + (bucket || state || 'unknown');
      return `<span class="${cls}"><span class="dot"></span>${esc(statusLabel(bucket, state))}</span>`;
    }
    function shortHome(h) {
      const parts = h.split('/');
      return parts[parts.length - 1] || h;
    }
    function trimNote(s) {
      return (s || '').replace(/^PR https?:\/\/\S+\s*/, '').trim();
    }
    function formatMergedAt(mergedAt, dateFallback) {
      if (!mergedAt) return dateFallback || '—';
      try {
        const d = new Date(mergedAt);
        if (isNaN(d.getTime())) return dateFallback || '—';
        const today = new Date();
        const sameDay = d.toDateString() === today.toDateString();
        if (sameDay) {
          return d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
        }
        return d.toLocaleDateString([], { month: 'short', day: 'numeric' });
      } catch (e) {
        return dateFallback || '—';
      }
    }

    function render(data) {
      try { renderInner(data); }
      catch (e) {
        console.error(e);
        document.getElementById('meta').textContent = 'Render error: ' + e.message;
      }
    }
    function findCrewRow(id) {
      if (!fleetCache || !id) return null;
      return (fleetCache.fleet || []).find(r => r.id === id)
        || (fleetCache.attention || []).find(r => r.id === id);
    }

    function closeCrew() {
      crewOpenId = null;
      const panel = document.getElementById('crew-panel');
      panel.classList.remove('open');
      panel.setAttribute('aria-hidden', 'true');
    }

    async function refreshCrewPeek() {
      if (!crewOpenId) return;
      const out = document.getElementById('crew-out');
      const err = document.getElementById('crew-err');
      try {
        const res = await fetch('/api/crew/' + encodeURIComponent(crewOpenId) + '/peek?lines=50', {
          cache: 'no-store',
          signal: fetchTimeout(15000),
        });
        const data = await res.json();
        if (!res.ok || !data.ok) throw new Error(data.error || ('HTTP ' + res.status));
        out.textContent = data.output || '(empty)';
        err.textContent = '';
      } catch (e) {
        out.textContent = '(peek failed)';
        err.textContent = e.message || 'Peek failed';
      }
    }

    function openCrew(id) {
      if (!id) return;
      crewOpenId = id;
      const row = findCrewRow(id);
      const panel = document.getElementById('crew-panel');
      document.getElementById('crew-title').textContent = id;
      const sub = row
        ? (agentName(row.harness) + ' · ' + (row.repo || '?') + ' · ' + statusLabel(row.bucket, row.state))
        : 'In-flight agent';
      document.getElementById('crew-sub').textContent = sub;
      document.getElementById('crew-out').textContent = 'Loading…';
      document.getElementById('crew-err').textContent = '';
      document.getElementById('crew-input').value = '';
      panel.classList.add('open');
      panel.setAttribute('aria-hidden', 'false');
      refreshCrewPeek();
      setTimeout(() => document.getElementById('crew-input').focus(), 50);
    }

    async function sendCrewMessage(ev) {
      ev.preventDefault();
      if (!crewOpenId) return;
      const input = document.getElementById('crew-input');
      const btn = document.getElementById('crew-send-btn');
      const err = document.getElementById('crew-err');
      const msg = (input.value || '').trim();
      if (!msg) return;
      btn.disabled = true;
      err.textContent = '';
      try {
        const res = await fetch('/api/crew/' + encodeURIComponent(crewOpenId) + '/send', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ message: msg }),
        });
        const data = await res.json();
        if (!res.ok || !data.ok) throw new Error(data.error || ('HTTP ' + res.status));
        input.value = '';
        await refreshCrewPeek();
      } catch (e) {
        err.textContent = e.message || 'Send failed';
      } finally {
        btn.disabled = false;
      }
    }

    document.getElementById('crew-close').addEventListener('click', closeCrew);
    document.getElementById('crew-refresh').addEventListener('click', refreshCrewPeek);
    document.getElementById('crew-send-form').addEventListener('submit', sendCrewMessage);
    document.getElementById('crew-panel').addEventListener('click', (ev) => {
      if (ev.target.id === 'crew-panel') closeCrew();
    });
    document.addEventListener('keydown', (ev) => {
      if (ev.key === 'Escape' && crewOpenId) closeCrew();
    });

    function renderInner(data) {
      fleetCache = data;
      document.getElementById('meta').textContent =
        data.ts + ' · ' + shortHome(data.home);

      const fm = data.firstmate || {};
      const fmEl = document.getElementById('firstmate-session');
      const fmText = document.getElementById('firstmate-text');
      if (fm.alive) {
        fmEl.classList.remove('off', 'warn');
        fmText.textContent = 'Firstmate: live';
      } else if (fm.state === 'asleep') {
        fmEl.classList.remove('off');
        fmEl.classList.add('warn');
        fmText.textContent = 'Firstmate: asleep';
      } else {
        fmEl.classList.add('off');
        fmEl.classList.remove('warn');
        fmText.textContent = 'Firstmate: unknown';
      }

      const w = data.watcher;
      const sup = document.getElementById('supervision');
      const supText = document.getElementById('supervision-text');
      const alert = document.getElementById('watcher-alert');
      if (w.alive) {
        sup.classList.remove('off');
        supText.textContent = 'Watcher: on (' + w.age_secs + 's)';
        alert.classList.remove('show');
      } else {
        sup.classList.add('off');
        const age = w.age_secs == null ? 'no beacon' : w.age_secs + 's stale';
        supText.textContent = 'Watcher: off';
        alert.textContent = 'Supervision is not running (' + age + '). Re-arm in your firstmate session.';
        alert.classList.add('show');
      }

      const s = data.summary;
      let countsHtml = '<span><b>' + s.working + '</b> working</span>';
      if (s.pr_ready) countsHtml += '<span class="pr"><b>' + s.pr_ready + '</b> PR ready</span>';
      if (s.merged_pending) countsHtml += '<span><b>' + s.merged_pending + '</b> merged (teardown)</span>';
      if (s.needs_you) countsHtml += '<span class="hi"><b>' + s.needs_you + '</b> need you</span>';
      countsHtml += '<span><b>' + s.total + '</b> in flight</span>';
      countsHtml += '<span><b>' + s.queued + '</b> queued</span>';
      if (s.merged_recent) countsHtml += '<span class="pr"><b>' + s.merged_recent + '</b> recent merges</span>';
      document.getElementById('counts').innerHTML = countsHtml;

      const att = data.attention || [];
      const attSection = document.getElementById('attention-section');
      document.getElementById('attention-count').textContent = att.length;
      if (att.length) {
        attSection.style.display = 'block';
        document.getElementById('attention').innerHTML = att.map(r => taskRow(r)).join('');
      } else {
        attSection.style.display = 'none';
      }

      document.getElementById('fleet-count').textContent = data.fleet.length;
      const fleetEl = document.getElementById('fleet');
      fleetEl.innerHTML = data.fleet.length
        ? data.fleet.map(r => taskRow(r)).join('')
        : '<tr><td colspan="8" class="empty-cell">No tasks in flight</td></tr>';

      const q = data.backlog_queued || [];
      document.getElementById('queued-count').textContent =
        q.length + (data.summary.queued > q.length ? '+' : '');
      const ql = document.getElementById('queued');
      ql.innerHTML = q.length
        ? q.map(i => {
            const t = (i.title || '').replace(/\(repo:[^)]*\)/, '').trim();
            const repo = i.repo ? i.repo.split(',')[0].trim() : '—';
            const id = i.id || '';
            const btn = id
              ? `<button class="btn danger" type="button" data-qid="${esc(id)}" onclick="removeQueued(this.dataset.qid)">Remove</button>`
              : '';
            return `<tr>
              <td class="mono">${esc(id || '—')}</td>
              <td>${esc(t)}</td>
              <td class="muted">${esc(repo)}</td>
              <td>${btn}</td>
            </tr>`;
          }).join('')
        : '<tr><td colspan="4" class="empty-cell">Nothing queued</td></tr>';

      const merges = data.recent_merges || [];
      const mergeDays = (data.summary && data.summary.merge_days) || 3;
      document.getElementById('merges-days').textContent = mergeDays;
      document.getElementById('merges-count').textContent = merges.length;
      document.getElementById('merge-note').textContent = data.merge_note
        ? data.merge_note
        : 'From GitHub merge time · crew id from fm/<task> branch when present';
      document.getElementById('merges').innerHTML = merges.length
        ? merges.map(m => {
            const summary = (m.summary || '').trim() || '—';
            const repo = m.fleet_repo || m.repo || '—';
            const when = formatMergedAt(m.merged_at, m.date);
            return `<tr class="merge">
              <td class="mono">${esc(m.id || '—')}</td>
              <td>${esc(summary)}</td>
              <td class="muted">${esc(repo)}</td>
              <td>${prLink(m.pr)}</td>
              <td class="muted">${esc(when)}</td>
            </tr>`;
          }).join('')
        : '<tr><td colspan="5" class="empty-cell">No merges in the last ' + mergeDays + ' days</td></tr>';

      if (crewOpenId) {
        const row = findCrewRow(crewOpenId);
        if (row) {
          document.getElementById('crew-sub').textContent =
            agentName(row.harness) + ' · ' + (row.repo || '?') + ' · ' + statusLabel(row.bucket, row.state);
        }
        scheduleCrewPeek();
      }
    }

    async function removeQueued(id) {
      if (!id || !confirm('Remove ' + id + ' from the queue?')) return;
      try {
        const res = await fetch('/api/queue/remove', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ id }),
        });
        const data = await res.json();
        if (!res.ok || !data.ok) throw new Error(data.error || ('HTTP ' + res.status));
        await tick();
      } catch (e) {
        alert(e.message || 'Remove failed');
      }
    }

    async function tick(retries) {
      retries = retries || 0;
      if (tickBusy && retries === 0) return;
      tickBusy = true;
      try {
        const res = await fetch('/api/fleet', {
          cache: 'no-store',
          signal: fetchTimeout(25000),
        });
        if (!res.ok) throw new Error('HTTP ' + res.status);
        render(await res.json());
      } catch (e) {
        if (retries < 2) {
          document.getElementById('meta').textContent = 'Connecting… (retry ' + (retries + 1) + ')';
          setTimeout(() => { tickBusy = false; tick(retries + 1); }, 2000);
          return;
        }
        const msg = (e && e.name === 'AbortError')
          ? 'Timed out — server may be overloaded; try refreshing'
          : 'Server not running — in a terminal run: bin/fm-web.sh';
        document.getElementById('meta').textContent = msg;
        document.getElementById('supervision').classList.add('off');
        document.getElementById('supervision-text').textContent = 'Offline';
      } finally {
        tickBusy = false;
      }
    }
    function connectSSE() {
      if (sse) sse.close();
      sse = new EventSource('/api/events');
      sse.onmessage = () => tick();
      sse.onerror = () => {
        sse.close();
        setTimeout(connectSSE, 3000);
      };
    }

    async function reconnect() {
      const btn = document.getElementById('reconnect-btn');
      const note = document.getElementById('reconnect-note');
      btn.disabled = true;
      note.textContent = 'Reconnecting…';
      try {
        const res = await fetch('/api/reconnect', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: '{}',
          signal: fetchTimeout(12000),
        });
        const data = await res.json();
        if (!res.ok || !data.ok) throw new Error(data.error || ('HTTP ' + res.status));
        connectSSE();
        tickBusy = false;
        await tick(0);
        note.textContent = data.message || 'Reconnected.';
      } catch (e) {
        note.textContent = (e.message || 'Reconnect failed')
          + ' — if the dashboard server is down, run bin/fm-web.sh';
        document.getElementById('meta').textContent = 'Reconnect failed';
        document.getElementById('supervision').classList.add('off');
        document.getElementById('supervision-text').textContent = 'Offline';
      } finally {
        btn.disabled = false;
      }
    }

    document.getElementById('reconnect-btn').addEventListener('click', reconnect);

    async function boot() {
      document.getElementById('meta').textContent = 'Connecting…';
      try {
        const res = await fetch('/api/health', { cache: 'no-store', signal: fetchTimeout(4000) });
        if (!res.ok) throw new Error('health failed');
      } catch (e) {
        document.getElementById('meta').textContent = 'Server not running — in a terminal run: bin/fm-web.sh';
        document.getElementById('supervision').classList.add('off');
        document.getElementById('supervision-text').textContent = 'Offline';
        setTimeout(boot, 5000);
        return;
      }
      await tick();
      connectSSE();
      setInterval(() => tick(), 30000);
    }
    boot();
  </script>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def _json_response(self, code: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        path = urlparse(self.path).path
        length = int(self.headers.get("Content-Length", "0") or 0)
        raw = self.rfile.read(length).decode("utf-8", errors="replace") if length else "{}"
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            self._json_response(400, {"ok": False, "error": "invalid JSON"})
            return

        send_m = CREW_SEND_RE.match(path)
        if send_m:
            message = str(data.get("message", ""))
            result = send_to_crew(send_m.group(1), message)
            self._json_response(200 if result["ok"] else 400, result)
            return

        if path == "/api/reconnect":
            result = reconnect_firstmate()
            self._json_response(200, result)
            return

        if path != "/api/queue/remove":
            self.send_response(404)
            self.end_headers()
            return
        task_id = str(data.get("id", "")).strip()
        result = remove_queued_item(task_id)
        self._json_response(200 if result["ok"] else 400, result)

    def _sse_events(self) -> None:
        global FLEET_WATCHER
        if FLEET_WATCHER is None:
            self.send_response(503)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.end_headers()
        client = FLEET_WATCHER.subscribe()
        try:
            self.wfile.write(b": connected\n\n")
            self.wfile.flush()
            while True:
                try:
                    payload = client.get(timeout=20.0)
                    msg = f"data: {payload}\n\n".encode()
                    self.wfile.write(msg)
                    self.wfile.flush()
                except queue.Empty:
                    self.wfile.write(b": ping\n\n")
                    self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            FLEET_WATCHER.unsubscribe(client)

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if path == "/api/events":
            self._sse_events()
            return
        peek_m = CREW_PEEK_RE.match(path)
        if peek_m:
            qs = parse_qs(parsed.query)
            lines_raw = (qs.get("lines") or ["50"])[0]
            try:
                lines = int(lines_raw)
            except ValueError:
                lines = 50
            result = peek_crew(peek_m.group(1), lines)
            self._json_response(200 if result["ok"] else 400, result)
            return
        if path == "/api/health":
            self._json_response(
                200,
                {
                    "ok": True,
                    "ts": time.strftime("%Y-%m-%d %H:%M:%S %Z"),
                    "firstmate": firstmate_session_status(),
                    "watcher": watcher_status(),
                },
            )
            return
        if path == "/api/fleet":
            body = json.dumps(snapshot()).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
            return
        if path in ("/", "/index.html"):
            body = PAGE.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.end_headers()


if __name__ == "__main__":
    host = "127.0.0.1"
    FLEET_WATCHER = FleetWatcher(HOME, STATE)
    threading.Thread(target=FLEET_WATCHER.run, daemon=True, name="fm-web-watch").start()
    server = ThreadingHTTPServer((host, PORT), Handler)
    print(f"firstmate web companion: http://{host}:{PORT}/", flush=True)
    print("live SSE on /api/events · localhost only · Ctrl-C to stop", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped", flush=True)
PY