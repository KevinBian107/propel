#!/usr/bin/env bash
# Propel — per-turn routing card (UserPromptSubmit)
#
# The session-start hook injects the full workflow once. Thirty turns later that
# injection is buried under investigation output, and the routing decisions it
# describes quietly stop happening. This hook re-states the short version every
# turn: what mode is active, whether the dual-model layer is on, and the handful
# of rules that must not decay.
#
# Deliberately small. A per-turn injection that grows becomes a per-turn tax.

set -uo pipefail

MODE="unset"
SELECTED_BY=""
if [ -f ".propel/mode.json" ]; then
  MODE=$(python3 -c "
import json
try:
    d = json.load(open('.propel/mode.json'))
    print(d.get('mode','unset'))
except Exception:
    print('unset')
" 2>/dev/null || echo unset)
  SELECTED_BY=$(python3 -c "
import json
try:
    d = json.load(open('.propel/mode.json'))
    print(d.get('selected_by',''))
except Exception:
    print('')
" 2>/dev/null || echo "")
fi

CODEX="on (automatic at every gate)"
if [ -f ".propel/codex.json" ]; then
  CODEX=$(python3 -c "
import json
try:
    d = json.load(open('.propel/codex.json'))
    if not d.get('enabled', True):
        print('OFF — user ran /disable-codex; do not consult Codex, do not nag')
    elif d.get('available') is False:
        print('enabled but CLI unavailable — notice already shown once; proceed single-model silently')
    else:
        print('on (automatic at every gate)')
except Exception:
    print('on (automatic at every gate)')
" 2>/dev/null || echo "on (automatic at every gate)")
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
rules that must not decay:
  1. New task -> Gate 0 (scoping questions, one at a time) before any code. Then Q0.
  2. No implementation without an investigation documented in scratch/.
  3. Skills and agents are dispatched by you, automatically, from the trigger tables
     in the using-propel skill. The user should never have to name a skill.
  4. Every gate: Codex consult first (if on), then present, then the HUMAN decides.
     Gate questions are disjunctive ("A or B, because...") — never "shall I proceed?".
  5. Code changed -> the auditors named by the auto-dispatch hook are required.
  6. Never claim done/fixed/working without fresh evidence you just observed.
EOF
exit 0
