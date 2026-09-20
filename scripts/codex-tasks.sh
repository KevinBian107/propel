#!/usr/bin/env bash
# Propel — the Codex task block for a Claude Code status line.
#
# claude-hud's agents line shows Claude's subagents, including `codex-bridge`.
# But codex-bridge is a *Claude* agent; the Codex call happens inside it, so that
# line tells you the bridge is running, not that Codex is 12 seconds into a Gate 2
# design question. This block shows the consults themselves, beneath the agents.
#
#   ── codex ──
#   ◐ codex: Gate 2 (design)              12s
#   ✓ codex: Gate 3 (component 1)          4s
#
# Unlike the --extra-cmd label, this output is not sanitized by claude-hud, so it
# carries real ANSI colour and matches hud's palette (yellow running, green done).
#
# Prints nothing at all outside a Propel project, or when there is nothing to
# show. Never fails: a status line renders constantly, and one that errors is
# worse than one that is absent.

set -uo pipefail

MAX_RECENT=2   # mirrors claude-hud's own MAX_RECENT_COMPLETED

if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "$CLAUDE_PROJECT_DIR" ]; then
  cd "$CLAUDE_PROJECT_DIR" 2>/dev/null || true
fi

ROOT="$PWD"
while [ "$ROOT" != "/" ] && [ ! -d "$ROOT/.propel" ]; do
  ROOT=$(dirname "$ROOT")
done
[ -d "$ROOT/.propel" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

ROOT="$ROOT" MAX_RECENT="$MAX_RECENT" python3 - <<'PY' 2>/dev/null || exit 0
import json, os, pathlib, time

root = pathlib.Path(os.environ["ROOT"])
max_recent = int(os.environ.get("MAX_RECENT") or 2)

DIM = "\033[2m"; RESET = "\033[0m"
YELLOW = "\033[33m"; GREEN = "\033[32m"; RED = "\033[31m"; MAGENTA = "\033[35m"

def elapsed(seconds):
    if seconds is None:
        return "--"
    seconds = max(0, int(seconds))
    if seconds < 60:
        return f"{seconds}s"
    m, s = divmod(seconds, 60)
    return f"{m}m {s}s" if m < 60 else f"{m // 60}h {m % 60}m"

def truncate(text, limit=38):
    text = text or "?"
    return text if len(text) <= limit else text[: limit - 1] + "…"

def alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, ValueError, TypeError):
        return False

rows = []

# ── in flight ──
running = root / ".propel" / "codex-running.json"
if running.exists():
    try:
        m = json.loads(running.read_text())
        age = time.time() - float(m.get("started") or 0)
        # A SIGKILLed consult leaves the marker behind. Trust it only while the
        # process is actually alive and the age is inside the consult's timeout.
        if alive(m.get("pid")) and age < float(m.get("timeout") or 240) + 30:
            rows.append((f"{YELLOW}◐{RESET}", truncate(m.get("label")), elapsed(age)))
    except Exception:
        pass

# ── recently finished ──
log = root / ".propel" / "codex-log.jsonl"
if log.exists():
    try:
        with log.open("rb") as fh:
            try:
                fh.seek(-32 * 1024, os.SEEK_END)
                fh.readline()
            except OSError:
                fh.seek(0)
            lines = fh.read().decode("utf-8", "replace").splitlines()
        entries = []
        for line in lines:
            line = line.strip()
            if line:
                try:
                    entries.append(json.loads(line))
                except Exception:
                    pass
        for e in entries[-max_recent:]:
            outcome = e.get("outcome")
            icon = f"{GREEN}✓{RESET}" if outcome in ("reply", "no-findings") else f"{RED}✗{RESET}"
            rows.append((icon, truncate(e.get("label")), elapsed(e.get("duration_s"))))
    except Exception:
        pass

if not rows:
    raise SystemExit(0)

print(f"{DIM}── codex ──{RESET}")
width = max(len(label) for _, label, _ in rows)
for icon, label, took in rows:
    print(f"{icon} {MAGENTA}codex{RESET}{DIM}:{RESET} {label:<{width}}  {DIM}{took}{RESET}")
PY
