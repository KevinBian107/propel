#!/usr/bin/env bash
# Propel — Codex status segment for a Claude Code status line.
#
# Prints a single JSON object, {"label": "..."}, which is the contract
# claude-hud's `--extra-cmd` expects. Any status line that can run a command and
# read `label` out of its JSON can use it.
#
# The ledger (.propel/codex-log.jsonl) answers "did it run?" after the fact.
# This answers "is it on, and did it just fire?" at a glance, which is the
# question you actually have while working.
#
# States:
#   codex 🟢 4 · 3s    enabled, 4 consults today, the last one 3 seconds ago
#   codex 🟢 ready     enabled and reachable, nothing consulted today
#   codex 🔴 off       /disable-codex is in effect for this project
#   codex 🟡 no cli    enabled, but the CLI isn't installed or on PATH
#
# The dots are emoji rather than ANSI-coloured glyphs on purpose: claude-hud
# sanitizes escape sequences out of an --extra-cmd label, so a colour code would
# simply be stripped. Emoji carry their own colour and pass through untouched.
#
# Outside a Propel project it prints `{}` — no label, so the segment is omitted
# rather than showing a misleading "off".
#
# Never fails, never blocks, never takes longer than a few milliseconds: a status
# line runs on every render, and one that can hang is one that will.

set -uo pipefail

# Status lines are invoked from the project directory, but don't rely on it.
if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "$CLAUDE_PROJECT_DIR" ]; then
  cd "$CLAUDE_PROJECT_DIR" 2>/dev/null || true
fi

nothing() { printf '{}\n'; exit 0; }

# Walk up for .propel/, so the segment still works from a subdirectory.
ROOT="$PWD"
while [ "$ROOT" != "/" ] && [ ! -d "$ROOT/.propel" ]; do
  ROOT=$(dirname "$ROOT")
done
[ -d "$ROOT/.propel" ] || nothing

command -v python3 >/dev/null 2>&1 || nothing

CODEX_ON_PATH=0
{ command -v codex >/dev/null 2>&1 || { [ -n "${HOME:-}" ] && [ -x "${HOME:-}/.local/bin/codex" ]; }; } && CODEX_ON_PATH=1

ROOT="$ROOT" CODEX_ON_PATH="$CODEX_ON_PATH" python3 - <<'PY' 2>/dev/null || nothing
import json, os, pathlib, re, time

root = pathlib.Path(os.environ["ROOT"])
on_path = os.environ.get("CODEX_ON_PATH") == "1"

def emit(label):
    print(json.dumps({"label": label} if label else {}))
    raise SystemExit(0)

# ── enabled? ──
# The Codex "enabled" rule, identical in every Propel script that reads
# .propel/codex.json (see scripts/codex-consult.sh): OFF when "enabled" is JSON
# false, null or 0, or a string that, trimmed and lowercased, is "false", "0",
# "off", "no" or empty. A missing file or key leaves it ON.
def off(v):
    if v is None or v is False:
        return True
    if isinstance(v, bool):
        return False
    if isinstance(v, (int, float)):
        return v == 0
    if isinstance(v, str):
        return v.strip().lower() in ("false", "0", "off", "no", "")
    return False

def flat_off(text):
    # Same as the shell scripts' fallback for a file that is not a JSON
    # object: all whitespace removed, off if any "enabled" value is off.
    flat = re.sub(r"\s", "", text)
    for m in re.finditer(r'"enabled":("([^"]*)"?|[^,}\]]*)', flat):
        if m.group(2) is not None:
            if m.group(2).lower() in ("", "0", "false", "off", "no"):
                return True
        elif m.group(1).lower() in ("false", "null") or re.fullmatch(r"-?0(\.0*)?([eE].*)?", m.group(1)):
            return True
    return False

enabled = True
cfg = root / ".propel" / "codex.json"
if cfg.exists():
    try:
        text = cfg.read_text()
        try:
            d = json.loads(text)
        except Exception:
            d = None
        if isinstance(d, dict):
            enabled = not off(d.get("enabled", True))
        else:
            enabled = not flat_off(text)
    except Exception:
        pass

if not enabled:
    emit("codex 🔴 off")
if not on_path:
    emit("codex 🟡 no cli")

# ── usage today, and how long since the last one ──
today = time.strftime("%Y-%m-%d")
count = 0
last = None
log = root / ".propel" / "codex-log.jsonl"
if log.exists():
    try:
        # Only the tail matters; don't read a long ledger on every render.
        with log.open("rb") as fh:
            try:
                fh.seek(-64 * 1024, os.SEEK_END)
                fh.readline()  # discard a partial first line
            except OSError:
                fh.seek(0)
            lines = fh.read().decode("utf-8", "replace").splitlines()
        for line in lines:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except Exception:
                continue
            ts = entry.get("ts") or ""
            if ts[:10] == today:
                count += 1
            last = ts or last
    except Exception:
        pass

if not count:
    emit("codex 🟢 ready")

ago = ""
if last:
    try:
        then = time.strptime(last[:19], "%Y-%m-%dT%H:%M:%S")
        # ts carries a local-time offset, so compare against local time.
        delta = int(time.mktime(time.localtime()) - time.mktime(then))
        if delta < 0:
            delta = 0
        if delta < 60:
            ago = f" · {delta}s"
        elif delta < 3600:
            ago = f" · {delta // 60}m"
        elif delta < 86400:
            ago = f" · {delta // 3600}h"
    except Exception:
        ago = ""

emit(f"codex 🟢 {count}{ago}")
PY
