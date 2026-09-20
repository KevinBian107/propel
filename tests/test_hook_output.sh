#!/usr/bin/env bash
# Test that session-start.sh produces valid JSON output.
#
# Usage: bash tests/test_hook_output.sh
#
# This test verifies:
# 1. The hook script runs without error
# 2. Output is valid JSON
# 3. Required fields are present (plugin, version, context)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
HOOK_SCRIPT="$PLUGIN_DIR/hooks/session-start.sh"

# Store output in a temp file to avoid shell escaping issues with large JSON
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

echo "Testing: hooks/session-start.sh"
echo "================================"

# Test 1: Script exists and is executable
if [ ! -x "$HOOK_SCRIPT" ]; then
    echo "FAIL: $HOOK_SCRIPT is not executable"
    exit 1
fi
echo "PASS: Script is executable"

# Test 2: Script runs without error
bash "$HOOK_SCRIPT" > "$TMPFILE" 2>&1 || {
    echo "FAIL: Script exited with error"
    cat "$TMPFILE"
    exit 1
}
echo "PASS: Script runs without error"

# Test 3: Output is valid JSON
python3 -m json.tool < "$TMPFILE" > /dev/null 2>&1 || {
    echo "FAIL: Output is not valid JSON"
    cat "$TMPFILE"
    exit 1
}
echo "PASS: Output is valid JSON"

# Test 4: Required fields are present
python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
required_fields = ['plugin', 'version', 'context']
missing = [f for f in required_fields if f not in data]
if missing:
    print(f'FAIL: Missing required fields: {missing}')
    sys.exit(1)
if data['plugin'] != 'propel':
    print(f'FAIL: plugin should be \"propel\", got \"{data[\"plugin\"]}\"')
    sys.exit(1)
if data['version'] != '0.1.0':
    print(f'FAIL: version should be \"0.1.0\", got \"{data[\"version\"]}\"')
    sys.exit(1)
print('PASS: All required fields present and correct')
" "$TMPFILE" || exit 1

# Test 5: Context contains skill content
python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
context = data['context']
if 'using-propel' not in context.lower() and 'Using Propel' not in context:
    print('FAIL: Context does not contain using-propel skill content')
    sys.exit(1)
if 'Gate 0' not in context:
    print('FAIL: Context does not mention Gate 0')
    sys.exit(1)
print('PASS: Context contains expected skill content')
" "$TMPFILE" || exit 1

# Test 6: active_investigations is a list
python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
if not isinstance(data.get('active_investigations', None), list):
    print('FAIL: active_investigations should be a list')
    sys.exit(1)
print('PASS: active_investigations is a list')
" "$TMPFILE" || exit 1

# Test 7: registry_entries is a list
python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
if not isinstance(data.get('registry_entries', None), list):
    print('FAIL: registry_entries should be a list')
    sys.exit(1)
print('PASS: registry_entries is a list')
" "$TMPFILE" || exit 1

echo ""
echo "================================"
echo "All tests passed!"

# ── Codex + routing + auditor-dispatch hooks ─────────────────────────────

echo ""
echo "Testing: dual-model policy injection"
echo "================================"

python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
policy = data.get('codex_policy')
if not policy:
    print('FAIL: codex_policy is missing or empty')
    sys.exit(1)
if 'Codex is consulted automatically' not in policy:
    print('FAIL: codex_policy does not carry the automatic-consult rule')
    sys.exit(1)
state = data.get('codex_state')
if not isinstance(state, dict) or 'enabled' not in state:
    print('FAIL: codex_state should be an object with an enabled field')
    sys.exit(1)
print('PASS: codex_policy and codex_state present')
" "$TMPFILE" || exit 1

python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
policy = data.get('mode_selection_policy', '')
if 'AUTO' not in policy:
    print('FAIL: mode_selection_policy should instruct automatic selection')
    sys.exit(1)
print('PASS: mode selection is automatic')
" "$TMPFILE" || exit 1

echo ""
echo "Testing: hooks/route.sh"
echo "================================"

ROUTE_OUT=$(bash "$PLUGIN_DIR/hooks/route.sh") || {
    echo "FAIL: route.sh exited with error"
    exit 1
}
for needle in "[propel:routing]" "mode:" "codex:" "Gate 0"; do
    case "$ROUTE_OUT" in
        *"$needle"*) ;;
        *) echo "FAIL: route.sh output missing '$needle'"; exit 1 ;;
    esac
done
echo "PASS: route.sh emits the routing card"

echo ""
echo "Testing: hooks/auditor-dispatch.sh"
echo "================================"

# A model/loss source file must require silent-bug-detector and regression-guard
echo '{"tool_name":"Edit","tool_input":{"file_path":"src/models/vq_loss.py"}}' \
  | bash "$PLUGIN_DIR/hooks/auditor-dispatch.sh" > "$TMPFILE"
python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
ctx = data['hookSpecificOutput']['additionalContext']
for needle in ['silent-bug-detector', 'regression-guard', 'vq_loss.py']:
    if needle not in ctx:
        print(f'FAIL: dispatch context missing {needle}')
        sys.exit(1)
if data['hookSpecificOutput']['hookEventName'] != 'PostToolUse':
    print('FAIL: wrong hookEventName')
    sys.exit(1)
print('PASS: source edit names the required auditors')
" "$TMPFILE" || exit 1

# scratch/ and markdown must produce no output at all
for path in "scratch/2026-01-01-foo/README.md" "docs/guide.md" ".claude/settings.local.json"; do
    OUT=$(echo "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$path\"}}" \
      | bash "$PLUGIN_DIR/hooks/auditor-dispatch.sh")
    if [ -n "$OUT" ]; then
        echo "FAIL: auditor-dispatch should ignore $path"
        exit 1
    fi
done
echo "PASS: working surfaces and non-source files are ignored"

echo ""
echo "Testing: scripts/codex-consult.sh"
echo "================================"

# Run in a throwaway directory with the layer disabled. Two reasons: the test
# must not append to the real project's audit ledger, and it must not spend a
# real Codex call (and ~7s of wall clock) on every run just to prove the
# wrapper's contract. Disabled is a real code path and exercises the same
# guarantees: recognized output, exit 0, ledger entry.
CODEX_DIR=$(mktemp -d)
(
    cd "$CODEX_DIR"
    mkdir -p .propel
    echo '{"enabled": false}' > .propel/codex.json

    CODEX_OUT=$(printf 'test brief' | bash "$PLUGIN_DIR/scripts/codex-consult.sh" --label "test" --timeout 5)
    case "$CODEX_OUT" in
        *"=== CODEX UNAVAILABLE ==="*|*"=== CODEX REPLY ==="*) ;;
        *) echo "FAIL: codex-consult.sh produced unrecognized output"; exit 1 ;;
    esac

    # It must never fail the caller, whatever happened.
    printf 'test brief' | bash "$PLUGIN_DIR/scripts/codex-consult.sh" --label "test" --timeout 5 >/dev/null || {
        echo "FAIL: codex-consult.sh must always exit 0"
        exit 1
    }

    # And the same with the CLI unreachable, which is the path users actually hit.
    printf 'test brief' | env PATH=/usr/bin:/bin bash "$PLUGIN_DIR/scripts/codex-consult.sh" \
        --label "test" --timeout 5 | grep -q "CODEX UNAVAILABLE" || {
        echo "FAIL: missing CLI should report UNAVAILABLE"
        exit 1
    }
    echo "PASS: codex-consult.sh degrades gracefully and never blocks"
) || { rm -rf "$CODEX_DIR"; exit 1; }

# The real project's ledger must be untouched by the test suite.
if [ -f "$PLUGIN_DIR/.propel/codex-log.jsonl" ]; then
    if grep -q '"label": "test"' "$PLUGIN_DIR/.propel/codex-log.jsonl" 2>/dev/null; then
        echo "FAIL: tests wrote into the project's real audit ledger"
        rm -rf "$CODEX_DIR"
        exit 1
    fi
fi
rm -rf "$CODEX_DIR"
echo "PASS: tests leave the project ledger alone"

echo ""
echo "Testing: the Codex audit ledger"
echo "================================"

# The ledger is the only Codex signal a model cannot forge, so it must be written
# on EVERY path — including the ones where the consult never happens.
LEDGER_DIR=$(mktemp -d)
(
  cd "$LEDGER_DIR"
  mkdir -p .propel

  # 1. disabled — exits before the brief is even read
  echo '{"enabled": false}' > .propel/codex.json
  printf 'QUESTION\n  disabled path\n' \
    | bash "$PLUGIN_DIR/scripts/codex-consult.sh" --label "Gate 1 (findings)" >/dev/null

  # 2. CLI missing — PATH stripped so `codex` cannot resolve
  echo '{"enabled": true}' > .propel/codex.json
  printf 'QUESTION\n  missing cli path\n' \
    | env PATH=/usr/bin:/bin bash "$PLUGIN_DIR/scripts/codex-consult.sh" \
        --label "Gate 4 (diagnosis)" >/dev/null

  python3 -c "
import json, sys, pathlib
p = pathlib.Path('.propel/codex-log.jsonl')
if not p.exists():
    print('FAIL: no ledger written')
    sys.exit(1)
rows = [json.loads(l) for l in p.read_text().splitlines() if l.strip()]
if len(rows) != 2:
    print(f'FAIL: expected 2 ledger entries, got {len(rows)}')
    sys.exit(1)
outcomes = [r['outcome'] for r in rows]
if outcomes != ['disabled', 'unavailable']:
    print(f'FAIL: wrong outcomes {outcomes}')
    sys.exit(1)
for r in rows:
    for field in ('ts', 'label', 'outcome', 'duration_s', 'cwd'):
        if field not in r:
            print(f'FAIL: ledger entry missing {field}')
            sys.exit(1)
if rows[0]['label'] != 'Gate 1 (findings)' or rows[1]['label'] != 'Gate 4 (diagnosis)':
    print('FAIL: decision-point labels not recorded')
    sys.exit(1)
if not rows[1]['detail']:
    print('FAIL: unavailable entry carries no reason')
    sys.exit(1)
print('PASS: every consult path writes a ledger entry')
"
) || { rm -rf "$LEDGER_DIR"; exit 1; }

# The wrapper's headline promise is that it never hangs. A trailing flag with no
# value used to spin `shift 2` forever; assert every flag consumes an argument.
(
  cd "$LEDGER_DIR"
  for FLAG in --label --timeout --model --question; do
    ( printf 'x' | env PATH=/usr/bin:/bin bash "$PLUGIN_DIR/scripts/codex-consult.sh" $FLAG ) \
      >/dev/null 2>&1 &
    ARG_PID=$!
    ( sleep 6; kill -9 $ARG_PID 2>/dev/null ) >/dev/null 2>&1 &
    ARG_WATCH=$!
    ARG_START=$(date +%s)
    wait $ARG_PID 2>/dev/null
    kill $ARG_WATCH 2>/dev/null
    if [ $(( $(date +%s) - ARG_START )) -ge 6 ]; then
      echo "FAIL: trailing $FLAG hangs the argument loop"
      exit 1
    fi
  done
  echo "PASS: a trailing flag with no value never hangs"
) || { rm -rf "$LEDGER_DIR"; exit 1; }

# Codex's stderr can echo the brief back, so it must never reach the ledger.
(
  cd "$LEDGER_DIR"
  mkdir -p fakebin
  printf '#!/bin/sh\necho "prompt echo: API_KEY=sk-LEAK-CANARY-9999" >&2\nexit 1\n' > fakebin/codex
  chmod +x fakebin/codex
  printf 'x' | env PATH="$PWD/fakebin:/usr/bin:/bin" \
    bash "$PLUGIN_DIR/scripts/codex-consult.sh" --label t --question "safe" >/dev/null 2>&1
  if grep -q "sk-LEAK-CANARY-9999" .propel/codex-log.jsonl; then
    echo "FAIL: Codex stderr leaked into the audit ledger"
    exit 1
  fi
  echo "PASS: Codex stderr never reaches the ledger"
) || { rm -rf "$LEDGER_DIR"; exit 1; }

# The ledger carries only what was passed as --question. Two shapes are tested:
# material above the question, and material that itself contains a QUESTION line
# — the second is what defeated the old parse-it-out-of-the-brief approach.
(
  cd "$LEDGER_DIR"
  printf 'CONTEXT\n  secret_token = "SHOULD_NEVER_BE_LOGGED"\n\nQUESTION\n  is this safe\n' \
    | env PATH=/usr/bin:/bin bash "$PLUGIN_DIR/scripts/codex-consult.sh" \
        --label "Gate 2" --question "is this safe" >/dev/null
  printf 'CONTEXT\nQUESTION\n  PRIVATE_TOKEN = ghp_NEVER_LOG_THIS\n\nQUESTION\n  the real one\n' \
    | env PATH=/usr/bin:/bin bash "$PLUGIN_DIR/scripts/codex-consult.sh" \
        --label "Gate 2" --question "the real one" >/dev/null
  if grep -qE "SHOULD_NEVER_BE_LOGGED|ghp_NEVER_LOG_THIS" .propel/codex-log.jsonl; then
    echo "FAIL: ledger leaked brief material"
    exit 1
  fi
  python3 -c "
import json, sys
rows = [json.loads(l) for l in open('.propel/codex-log.jsonl') if l.strip()]
qs = [r['question'] for r in rows if r['question']]
if 'the real one' not in qs:
    print(f'FAIL: the passed question was not recorded: {qs}')
    sys.exit(1)
" || exit 1
  echo "PASS: ledger records the passed question, never the material"
) || { rm -rf "$LEDGER_DIR"; exit 1; }

rm -rf "$LEDGER_DIR"

echo ""
echo "Testing: the Codex status-line segment"
echo "================================"

SEG="$PLUGIN_DIR/scripts/codex-statusline.sh"
SEG_DIR=$(mktemp -d)
(
  cd "$SEG_DIR"

  # Outside a Propel project it must emit no label, so the segment is omitted
  # rather than rendering a misleading state.
  OUT=$(bash "$SEG")
  python3 -c "
import json, sys
d = json.loads('''$OUT''')
if 'label' in d:
    print(f'FAIL: emitted a label outside a Propel project: {d}')
    sys.exit(1)
" || exit 1

  mkdir -p .propel

  echo '{"enabled": false}' > .propel/codex.json
  bash "$SEG" | grep -q 'off' || { echo "FAIL: disabled state not shown"; exit 1; }

  echo '{"enabled": true}' > .propel/codex.json
  env PATH=/usr/bin:/bin bash "$SEG" | grep -q 'no cli' \
    || { echo "FAIL: missing-CLI state not shown"; exit 1; }

  # Every state must be valid JSON with a label inside the 50-char limit that
  # claude-hud truncates at.
  python3 -c "
import json, subprocess, sys
out = subprocess.run(['bash', '$SEG'], capture_output=True, text=True).stdout
d = json.loads(out)
label = d.get('label', '')
if not label:
    print('FAIL: no label inside a Propel project')
    sys.exit(1)
if len(label) > 50:
    print(f'FAIL: label is {len(label)} chars, over the 50-char limit')
    sys.exit(1)
if not label.startswith('codex'):
    print(f'FAIL: unexpected label {label!r}')
    sys.exit(1)
print('PASS: segment reports every state as a valid, short label')
" || exit 1

  # A status line renders on every keystroke-ish interval; a slow or hanging
  # segment is worse than no segment.
  python3 -c "
import subprocess, sys, time
start = time.time()
for _ in range(5):
    subprocess.run(['bash', '$SEG'], capture_output=True)
per = (time.time() - start) / 5
if per > 0.5:
    print(f'FAIL: {per*1000:.0f}ms per render is too slow for a status line')
    sys.exit(1)
print(f'PASS: {per*1000:.0f}ms per render')
" || exit 1
) || { rm -rf "$SEG_DIR"; exit 1; }
rm -rf "$SEG_DIR"

echo ""
echo "Testing: the Codex task block and status-line wrapper"
echo "================================"

TASK_DIR=$(mktemp -d)
(
  cd "$TASK_DIR"
  # Outside a Propel project: silence, so unrelated work is never cluttered.
  if [ -n "$(bash "$PLUGIN_DIR/scripts/codex-tasks.sh")" ]; then
    echo "FAIL: task block printed outside a Propel project"
    exit 1
  fi

  mkdir -p .propel
  python3 -c "
import json, pathlib, time
t = time.localtime(time.time() - 30)
pathlib.Path('.propel/codex-log.jsonl').write_text(json.dumps({
    'ts': time.strftime('%Y-%m-%dT%H:%M:%S%z', t), 'label': 'Gate 2 (design)',
    'outcome': 'reply', 'detail': '', 'question': 'q', 'model': '',
    'duration_s': 12.0, 'cwd': '.'}) + '\n')
"
  bash "$PLUGIN_DIR/scripts/codex-tasks.sh" | grep -q "Gate 2 (design)" \
    || { echo "FAIL: finished consult not shown"; exit 1; }

  # A stale running marker -- process long gone -- must not render as in-flight.
  python3 -c "
import json, pathlib, time
pathlib.Path('.propel/codex-running.json').write_text(json.dumps({
    'label': 'GHOST', 'question': 'q', 'started': time.time() - 9999,
    'timeout': 240, 'pid': 999999}) + '\n')
"
  if bash "$PLUGIN_DIR/scripts/codex-tasks.sh" | grep -q "GHOST"; then
    echo "FAIL: a stale running marker rendered as in-flight"
    exit 1
  fi
  echo "PASS: task block shows real consults and ignores stale markers"

  # The wrapper must survive claude-hud being missing entirely.
  OUT=$(printf '{}' | CLAUDE_CONFIG_DIR=/nonexistent bash "$PLUGIN_DIR/scripts/propel-statusline.sh" 2>&1)
  RC=$?
  if [ $RC -ne 0 ]; then
    echo "FAIL: wrapper exited $RC when claude-hud was unavailable"
    exit 1
  fi
  case "$OUT" in
    *Error*|*Traceback*|*"No such file"*)
      echo "FAIL: wrapper leaked an error when claude-hud was unavailable"
      exit 1 ;;
  esac
  echo "PASS: status-line wrapper degrades cleanly without claude-hud"
) || { rm -rf "$TASK_DIR"; exit 1; }
rm -rf "$TASK_DIR"

echo ""
echo "================================"
echo "All extended tests passed!"
