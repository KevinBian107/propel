#!/usr/bin/env bash
# Propel — per-turn routing card (UserPromptSubmit)
#
# The session-start hook injects the full workflow once. Thirty turns later that
# injection is buried under investigation output, and the routing decisions it
# describes quietly stop happening. This hook re-states the short version every
# turn: what mode is active, whether the dual-model layer is on, how many tasks
# are open in the task ledger, and the handful of rules that must not decay.
#
# Deliberately small. A per-turn injection that grows becomes a per-turn tax.
#
# Never blocks a session: no `set -e`, exit 0 on every path; python3 is only
# used (behind a guard) to read JSON fields, with a grep fallback.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
# Resolve project-relative state from the project root, even when Claude Code
# was started in a subdirectory.
cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || true

HAVE_PYTHON=false
if command -v python3 >/dev/null 2>&1; then
  HAVE_PYTHON=true
fi

# The prompt payload arrives on stdin; only session_id is read from it.
# read_hook_input: at most 4,096 bytes into HOOK_INPUT, bounded in wall time so
# a pipe that stays open without EOF cannot hang the turn. (Same function as in
# session-start.sh — see the comment there.) A terminal or a closed stdin is not
# read; chunks end at each `"` with a 1 s timeout per read and a 2 s overall
# cap (SECONDS is whole seconds, so the real worst case is about 3-4 s)
# (bash 3.2 drops a timed-out read's partial data, so every complete JSON
# string that arrived is kept); past 4,096 bytes the rest is drained by a
# background cat killed after 1 s, so the writer never gets EPIPE. Accepted
# limit: a writer that resumes writing after that window can still get EPIPE.
read_hook_input() {
  HOOK_INPUT=""
  if [ -t 0 ] || ! { true 3<&0; } 2>/dev/null; then
    return 0
  fi
  RH_LC_SET="${LC_ALL+1}"; RH_LC="${LC_ALL-}"
  LC_ALL=C
  RH_START=$SECONDS; RH_FULL=0
  while :; do
    RH_LEFT=$(( 4096 - ${#HOOK_INPUT} ))
    if [ "$RH_LEFT" -le 0 ]; then RH_FULL=1; break; fi
    [ $(( SECONDS - RH_START )) -lt 2 ] || break
    RH_CHUNK=""
    if IFS= read -r -t 1 -d '"' -n "$RH_LEFT" RH_CHUNK; then
      if [ "${#RH_CHUNK}" -ge "$RH_LEFT" ]; then
        HOOK_INPUT="$HOOK_INPUT$RH_CHUNK"; RH_FULL=1; break
      fi
      HOOK_INPUT="$HOOK_INPUT$RH_CHUNK\""
    else
      HOOK_INPUT="$HOOK_INPUT$RH_CHUNK"; break   # EOF (partial chunk kept) or timeout
    fi
  done
  if [ -n "$RH_LC_SET" ]; then LC_ALL="$RH_LC"; else unset LC_ALL; fi
  if [ "$RH_FULL" = 1 ]; then
    exec 3<&0
    cat <&3 >/dev/null 2>&1 &
    RH_CAT=$!
    exec 3<&-
    ( sleep 1; kill "$RH_CAT" ) </dev/null >/dev/null 2>&1 &
    RH_WD=$!
    wait "$RH_CAT" 2>/dev/null
    kill "$RH_WD" 2>/dev/null; wait "$RH_WD" 2>/dev/null
  fi
  return 0
}
read_hook_input

MODE="unset"
SELECTED_BY=""
if [ -f ".propel/mode.json" ]; then
  M=""
  S=""
  if [ "$HAVE_PYTHON" = true ]; then
    M=$(python3 -c "
import json
try:
    d = json.load(open('.propel/mode.json'))
    print(d.get('mode','unset'))
except Exception:
    print('unset')
" 2>/dev/null || echo "")
    S=$(python3 -c "
import json
try:
    d = json.load(open('.propel/mode.json'))
    print(d.get('selected_by',''))
except Exception:
    print('')
" 2>/dev/null || echo "")
  fi
  # No python3, or it printed nothing: read the string values with grep. The
  # leading quote keeps "mode" from matching "previous_mode".
  if [ -z "$M" ]; then
    M=$(grep -o '"mode"[[:space:]]*:[[:space:]]*"[^"]*"' ".propel/mode.json" 2>/dev/null | head -1 \
      | sed 's/^"mode"[[:space:]]*:[[:space:]]*"//; s/"$//')
    S=$(grep -o '"selected_by"[[:space:]]*:[[:space:]]*"[^"]*"' ".propel/mode.json" 2>/dev/null | head -1 \
      | sed 's/^"selected_by"[[:space:]]*:[[:space:]]*"//; s/"$//')
  fi
  if [ -n "$M" ]; then
    MODE="$M"
  fi
  SELECTED_BY="$S"
fi

CODEX="on (automatic at every gate)"
if [ -f ".propel/codex.json" ]; then
  C=""
  if [ "$HAVE_PYTHON" = true ]; then
    C=$(python3 -c "
import json
try:
    d = json.load(open('.propel/codex.json'))
    if d.get('enabled', True) is False:
        print('OFF — user ran /disable-codex; do not consult Codex, do not nag')
    elif d.get('available') is False:
        print('enabled but CLI unavailable — notice already shown once; proceed single-model silently')
    else:
        print('on (automatic at every gate)')
except Exception:
    print('on (automatic at every gate)')
" 2>/dev/null || echo "")
  fi
  if [ -z "$C" ]; then
    # Same patterns as session-start.sh's state part, matched with all
    # whitespace removed so a value on its own line is still seen.
    CODEX_FLAT=$(tr -d '[:space:]' < ".propel/codex.json" 2>/dev/null)
    # Globs, not grep <<<: a here-string is a temp file on bash 3.2.
    case "$CODEX_FLAT" in
      *'"enabled":false'[!a-zA-Z0-9_]*|*'"enabled":false')
        C="OFF — user ran /disable-codex; do not consult Codex, do not nag" ;;
      *'"available":false'[!a-zA-Z0-9_]*|*'"available":false')
        C="enabled but CLI unavailable — notice already shown once; proceed single-model silently" ;;
      *)
        C="on (automatic at every gate)" ;;
    esac
  fi
  CODEX="$C"
fi

# Open tasks in the task ledger, counted by scripts/task-queue.sh. The session
# id is sanitized exactly as task-queue.sh sanitizes it.
TASKS_LINE=""
TQ="$PLUGIN_DIR/scripts/task-queue.sh"
if [ -d ".propel/tasks" ] && [ -f "$TQ" ]; then
  SESSION_ID=$(printf '%s' "$HOOK_INPUT" \
    | LC_ALL=C grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' 2>/dev/null | head -1 \
    | sed 's/^"session_id"[[:space:]]*:[[:space:]]*"//; s/"$//' \
    | LC_ALL=C tr -cd 'A-Za-z0-9._-')
  while [ "${SESSION_ID:0:1}" = "." ]; do SESSION_ID="${SESSION_ID#.}"; done
  SESSION_ID="${SESSION_ID:0:64}"
  # count may append a settle event (one lock try, never waits); its exit
  # status is ignored.
  COUNT=$("${BASH:-bash}" "$TQ" count --session "$SESSION_ID" < /dev/null 2>/dev/null)
  HERE="" EARLIER=""
  read -r HERE EARLIER _ <<EOF
$COUNT
EOF
  # Digits only, at most 9, read base 10: an arithmetic error (e.g. "08" read
  # as octal) would end this script with a non-zero status.
  case "$HERE" in ''|*[!0-9]*|??????????*) HERE="" ;; esac
  case "$EARLIER" in ''|*[!0-9]*|??????????*) EARLIER="" ;; esac
  if [ -n "$HERE" ] && [ -n "$EARLIER" ]; then
    HERE=$(( 10#$HERE )); EARLIER=$(( 10#$EARLIER ))
    if [ -n "$SESSION_ID" ]; then
      if [ "$HERE" -gt 0 ] || [ "$EARLIER" -gt 0 ]; then
        TASKS_LINE="tasks: $HERE open in this session, $EARLIER from earlier sessions — run check-progress"
      fi
    elif [ $(( HERE + EARLIER )) -gt 0 ]; then
      TASKS_LINE="tasks: $(( HERE + EARLIER )) open — run check-progress"
    fi
  fi
fi

if [ "$MODE" = "unset" ]; then
  MODE_LINE="none yet — infer it from this message (researcher / engineer / debugger / trainer), announce the choice in one line with the reason, write .propel/mode.json with \"selected_by\":\"auto\", and continue. Do not stop to ask."
else
  MODE_LINE="$MODE${SELECTED_BY:+ (selected_by: $SELECTED_BY)} — if this request belongs to a different mode, switch automatically, say so in one line, and continue."
fi

cat <<EOF
[propel:routing]
mode: ${MODE_LINE}
codex: ${CODEX}
EOF
if [ -n "$TASKS_LINE" ]; then
  printf '%s\n' "$TASKS_LINE"
fi
cat <<EOF
rules that must not decay:
  1. New task -> Gate 0 (scoping questions, one at a time) before any code. Then Q0.
  2. No implementation without an investigation documented in scratch/.
  3. Skills and agents are dispatched by you, automatically, from the trigger tables
     in the using-propel skill. The user should never have to name a skill.
  4. Every gate: Codex consult first (if on), then present, then the HUMAN decides.
     Gate questions are disjunctive ("A or B, because...") — never "shall I proceed?".
  5. Code changed -> the auditors named by the auto-dispatch hook are required.
  6. Never claim done/fixed/working without fresh evidence you just observed.
  7. Claim first, then its evidence; cut narration and restatement; never drop evidence (concise skill).
EOF
exit 0
