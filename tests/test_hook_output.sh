#!/usr/bin/env bash
# Tests for Propel's hooks and Codex scripts.
#
# Usage: bash tests/test_hook_output.sh
#
# session-start.sh and working-memory.sh emit PLAIN TEXT: Claude Code adds
# plain-text SessionStart stdout to context, while stdout that starts with `{`
# is parsed as hook JSON (and a custom object is dropped). These tests verify:
# 1. every session-start part (state, core, codex, routing1-4) runs, exits 0,
#    is NOT a JSON object, and is under the ~10,000-character per-hook cap
# 2. CORE.md and CODEX.md arrive untruncated; the routing parts reproduce
#    using-propel/SKILL.md losslessly in no more chunks than are registered
# 3. the version line comes from .propel/manifest.json, "unknown" without one
# 4. working-memory prints nothing when empty, its sections when not, and caps
#    long logs
# 5. every hook exits 0 with no python3 on PATH
# 6. plugin.json and the package agree on the version

set -euo pipefail

# Hooks prefer CLAUDE_PROJECT_DIR over the cwd. Running this test from inside a
# Claude Code session exports it, which would point every hook run below at
# the real project instead of the throwaway dirs. Tests that need it set it.
unset CLAUDE_PROJECT_DIR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
HOOK_SCRIPT="$PLUGIN_DIR/hooks/session-start.sh"
WM_SCRIPT="$PLUGIN_DIR/hooks/working-memory.sh"

TMPFILE=$(mktemp)
# "No Codex installed" needs an empty HOME as well as a trimmed PATH: the
# scripts also look in ~/.local/bin, where the native installer puts codex.
NOCLI_HOME=$(mktemp -d)
# Throwaway project dir for hook runs that depend on project state.
PROJ_DIR=$(mktemp -d)
trap 'rm -f "$TMPFILE"; rm -rf "$NOCLI_HOME" "$PROJ_DIR"' EXIT

assert_contains() {  # <haystack-file> <needle> <label>
    if ! grep -qF -- "$2" "$1"; then
        echo "FAIL: $3 (missing '$2')"
        exit 1
    fi
}

echo "Testing: hooks/session-start.sh"
echo "================================"

# Test 1: Script exists and is executable
if [ ! -x "$HOOK_SCRIPT" ]; then
    echo "FAIL: $HOOK_SCRIPT is not executable"
    exit 1
fi
echo "PASS: Script is executable"

PARTS="state core codex routing1 routing2 routing3 routing4"
ROUTING_REGISTERED=4
PART_DIR=$(mktemp -d)
trap 'rm -f "$TMPFILE"; rm -rf "$NOCLI_HOME" "$PROJ_DIR" "$PART_DIR"' EXIT

# Test 1b: the session-start parts registered in hooks/hooks.json are exactly
# PARTS, in order — so dropping (or adding) a registration fails here.
REGISTERED_PARTS=$(grep -o '"command": *"bash hooks/session-start.sh [^"]*"' "$PLUGIN_DIR/hooks/hooks.json" \
    | sed 's/.*session-start\.sh \([^"]*\)"$/\1/' | tr '\n' ' ' | sed 's/ $//')
if [ "$REGISTERED_PARTS" != "$PARTS" ]; then
    echo "FAIL: hooks/hooks.json registers session-start.sh parts '$REGISTERED_PARTS' but this test expects '$PARTS'"
    exit 1
fi
REGISTERED_ROUTING=$(echo "$REGISTERED_PARTS" | tr ' ' '\n' | grep -c '^routing[0-9][0-9]*$' || true)
if [ "$REGISTERED_ROUTING" != "$ROUTING_REGISTERED" ]; then
    echo "FAIL: hooks/hooks.json registers $REGISTERED_ROUTING routing parts, ROUTING_REGISTERED is $ROUTING_REGISTERED"
    exit 1
fi
echo "PASS: hooks/hooks.json registers exactly the session-start parts: $PARTS"

# Test 2: every part, run from the repo root, exits 0, is plain text, and stays
# under Claude Code's per-hook cap (~10,000 characters; above it the output is
# replaced by a short preview). wc -c counts bytes, which is >= characters.
for part in $PARTS; do
    ( cd "$PLUGIN_DIR" && bash "$HOOK_SCRIPT" "$part" > "$PART_DIR/$part" 2>/dev/null ) || {
        echo "FAIL: part '$part' exited non-zero"
        exit 1
    }
    if [ "$part" = "routing1" ]; then
        # Checked before the size cap so an outgrown SKILL.md names the fix.
        M1=$(sed -n 's/^## using-propel skill (part 1 of \([0-9][0-9]*\))$/\1/p' "$PART_DIR/routing1")
        if [ -n "$M1" ] && [ "$M1" -gt "$ROUTING_REGISTERED" ]; then
            echo "FAIL: using-propel/SKILL.md now needs $M1 chunks but only $ROUTING_REGISTERED are registered — add 'bash hooks/session-start.sh routing$((ROUTING_REGISTERED + 1))' (and up) to hooks/hooks.json and to PARTS / ROUTING_REGISTERED in this test"
            exit 1
        fi
    fi
    if [ "$(head -c 1 "$PART_DIR/$part")" = "{" ]; then
        echo "FAIL: part '$part' starts with '{' — Claude Code would parse it as hook JSON and drop it"
        exit 1
    fi
    SIZE=$(wc -c < "$PART_DIR/$part" | tr -d '[:space:]')
    if [ "$SIZE" -ge 10000 ]; then
        echo "FAIL: part '$part' is $SIZE bytes — over the ~10,000-character per-hook cap"
        exit 1
    fi
    if [ "$SIZE" -gt 0 ]; then
        assert_contains "$PART_DIR/$part" "[propel:session-start $part] Propel " "part '$part' header line"
    fi
done
echo "PASS: every part exits 0, is plain text, and is under 10,000 characters"

# Test 3: no argument is the state part (a stale no-arg registration stays small)
( cd "$PLUGIN_DIR" && bash "$HOOK_SCRIPT" > "$TMPFILE" 2>/dev/null ) || { echo "FAIL: no-arg run exited non-zero"; exit 1; }
if ! diff -q "$TMPFILE" "$PART_DIR/state" >/dev/null; then
    echo "FAIL: running with no argument should equal the 'state' part"
    exit 1
fi
echo "PASS: no argument == state part"

# Test 4: required content per part
assert_contains "$PART_DIR/state" "## Codex state" "Codex state section"
assert_contains "$PART_DIR/state" "## Mode" "mode section"
assert_contains "$PART_DIR/state" "AUTO" "automatic mode-selection policy"
assert_contains "$PART_DIR/state" "mode_selection_needed: " "mode_selection_needed line"
assert_contains "$PART_DIR/state" "## Active investigations" "investigations section"
assert_contains "$PART_DIR/state" "## Empty repo" "empty-repo section"
assert_contains "$PART_DIR/state" "## Registry entries" "registry section"
assert_contains "$PART_DIR/core" "## Core principles" "core section"
assert_contains "$PART_DIR/codex" "## Dual-model (Codex) policy" "Codex policy section"
assert_contains "$PART_DIR/codex" "Codex is consulted automatically" "Codex policy content"
# CORE.md and CODEX.md must arrive whole: the part minus its 4 header lines is
# the file, byte for byte. A truncated policy fails here on purpose.
for pair in "core:core/CORE.md" "codex:core/CODEX.md"; do
    part="${pair%%:*}"; file="${pair#*:}"
    if ! tail -n +5 "$PART_DIR/$part" | diff -q - "$PLUGIN_DIR/$file" >/dev/null; then
        echo "FAIL: part '$part' does not reproduce $file intact (truncated? — shorten $file below 9,500 characters)"
        exit 1
    fi
done
echo "PASS: state, core and codex parts carry their content; CORE.md and CODEX.md are not truncated"

# Test 5: the routing parts reproduce using-propel/SKILL.md losslessly, in at
# most as many chunks as hooks.json registers.
M=$(sed -n 's/^## using-propel skill (part 1 of \([0-9][0-9]*\))$/\1/p' "$PART_DIR/routing1")
if [ -z "$M" ]; then
    echo "FAIL: routing1 has no '## using-propel skill (part 1 of M)' line"
    exit 1
fi
: > "$TMPFILE"
for n in $(seq 1 "$ROUTING_REGISTERED"); do
    if [ "$n" -le "$M" ]; then
        assert_contains "$PART_DIR/routing$n" "## using-propel skill (part $n of $M)" "routing$n chunk heading"
        tail -n +5 "$PART_DIR/routing$n" >> "$TMPFILE"
    elif [ -s "$PART_DIR/routing$n" ]; then
        echo "FAIL: routing$n should print nothing when SKILL.md has only $M chunks"
        exit 1
    fi
done
if ! diff -q "$TMPFILE" "$PLUGIN_DIR/skills/using-propel/SKILL.md" >/dev/null; then
    echo "FAIL: routing parts concatenated do not reproduce using-propel/SKILL.md"
    exit 1
fi
echo "PASS: routing parts reproduce using-propel/SKILL.md losslessly in $M of $ROUTING_REGISTERED chunks"

# Test 6: Version line — "unknown" without a manifest, the manifest's otherwise
(
    cd "$PROJ_DIR"
    OUT=$(bash "$HOOK_SCRIPT" state 2>/dev/null) || { echo "FAIL: exit non-zero in empty project"; exit 1; }
    case "$(printf '%s\n' "$OUT" | head -1)" in
        *"[propel:session-start state] Propel unknown "*) ;;
        *) echo "FAIL: version should be 'unknown' with no manifest"; exit 1 ;;
    esac
    case "$OUT" in
        *"enabled (default"*) ;;
        *) echo "FAIL: Codex state should default to enabled with no codex.json"; exit 1 ;;
    esac
    case "$OUT" in
        *"not selected yet"*) ;;
        *) echo "FAIL: mode should be 'not selected yet' with no mode.json"; exit 1 ;;
    esac
    case "$OUT" in
        *"mode_selection_needed: true"*) ;;
        *) echo "FAIL: mode_selection_needed should be true with no mode.json"; exit 1 ;;
    esac
    mkdir -p .propel
    printf '{\n  "schema": 1,\n  "propel_version": "9.8.7",\n  "files": {}\n}\n' > .propel/manifest.json
    for part in $PARTS; do
        OUT=$(bash "$HOOK_SCRIPT" "$part" 2>/dev/null) || { echo "FAIL: exit non-zero with manifest"; exit 1; }
        [ -n "$OUT" ] || continue
        case "$(printf '%s\n' "$OUT" | head -1)" in
            *"[propel:session-start $part] Propel 9.8.7 "*) ;;
            *) echo "FAIL: part '$part' version line should show the manifest's propel_version"; exit 1 ;;
        esac
    done
    rm -rf .propel
) || exit 1
echo "PASS: version comes from .propel/manifest.json, 'unknown' without one"

# Test 7: state edge cases — a huge profile is truncated under the cap, a
# mode.json without a non-empty "mode" still needs selection, a non-boolean
# "enabled" does not disable Codex, and CLAUDE_PROJECT_DIR wins over the cwd.
(
    cd "$PROJ_DIR"
    mkdir -p .propel sub
    for i in $(seq 1 600); do echo "- profile line $i: the training loop uses a cosine schedule"; done > .propel/profile.md
    echo '{"mode": "", "selected_by": "auto"}' > .propel/mode.json
    echo '{"enabled": "false", "available": "yes"}' > .propel/codex.json
    OUT=$(cd sub && CLAUDE_PROJECT_DIR="$PROJ_DIR" bash "$HOOK_SCRIPT" state 2>/dev/null) || { echo "FAIL: state exited non-zero with a huge profile"; exit 1; }
    SIZE=$(printf '%s\n' "$OUT" | wc -c | tr -d '[:space:]')
    [ "$SIZE" -le 9000 ] || { echo "FAIL: state part is $SIZE bytes with a huge profile (max 9,000)"; exit 1; }
    for needle in "## Project profile" "profile line 1:" "(profile truncated — full text at .propel/profile.md)" \
                  "## Registry entries" "mode_selection_needed: true" "enabled: true, available: null"; do
        case "$OUT" in *"$needle"*) ;; *) echo "FAIL: state edge case missing '$needle'"; exit 1 ;; esac
    done
    rm -rf .propel sub
) || exit 1
echo "PASS: state truncates a huge profile, reads mode/codex strictly, honours CLAUDE_PROJECT_DIR"

# Test 8: state stays under the cap with a huge mode.json and 10 registry
# entries with 200-character names (plus 5 long-named investigations).
(
    cd "$PROJ_DIR"
    mkdir -p .propel
    { printf '{"mode": "engineer", "notes": "'; head -c 50000 /dev/zero | tr '\0' 'x'; printf '"}\n'; } > .propel/mode.json
    LONG=$(head -c 200 /dev/zero | tr '\0' 'r')
    for i in 0 1 2 3 4 5 6 7 8 9; do mkdir -p "scratch/registry/$i$LONG"; done
    for i in 0 1 2 3 4; do mkdir -p "scratch/$i$LONG"; echo x > "scratch/$i$LONG/README.md"; done
    OUT=$(bash "$HOOK_SCRIPT" state 2>/dev/null) || { echo "FAIL: state exited non-zero with a huge mode.json"; exit 1; }
    SIZE=$(printf '%s\n' "$OUT" | wc -c | tr -d '[:space:]')
    [ "$SIZE" -lt 9000 ] || { echo "FAIL: state part is $SIZE bytes with a huge mode.json (max 9,000)"; exit 1; }
    for needle in '{"mode": "engineer"' "(truncated — full file at .propel/mode.json)" "mode_selection_needed: false" \
                  "(more in scratch/registry/)" "## Empty repo"; do
        case "$OUT" in *"$needle"*) ;; *) echo "FAIL: state with huge inputs missing '$needle'"; exit 1 ;; esac
    done
    REG=$(printf '%s\n' "$OUT" | sed -n '/^## Registry entries$/,$p' | tail -n +3 | wc -c | tr -d '[:space:]')
    [ "$REG" -le 1500 ] || { echo "FAIL: state registry listing is $REG bytes (max 1,500)"; exit 1; }
    WM=$(bash "$WM_SCRIPT" 2>/dev/null) || { echo "FAIL: working-memory exited non-zero with long registry names"; exit 1; }
    SIZE=$(printf '%s\n' "$WM" | wc -c | tr -d '[:space:]')
    [ "$SIZE" -lt 10000 ] || { echo "FAIL: working-memory output is $SIZE bytes with long registry names"; exit 1; }
    case "$WM" in *"(more in scratch/registry/)"*) ;; *) echo "FAIL: working-memory did not mark the omitted registry entries"; exit 1 ;; esac
    REG=$(printf '%s\n' "$WM" | sed -n '/^## Recent registry entries$/,$p' | tail -n +3 | wc -c | tr -d '[:space:]')
    [ "$REG" -le 1500 ] || { echo "FAIL: working-memory registry listing is $REG bytes (max 1,500)"; exit 1; }
    rm -rf .propel scratch
) || exit 1
echo "PASS: state and working-memory stay under the cap with a huge mode.json and long registry names"

# Test 9: an unknown part (e.g. a user's own `session-start.sh --mine`
# registration) prints nothing and exits 0.
for part in --mine bogus routing; do
    OUT=$(cd "$PLUGIN_DIR" && bash "$HOOK_SCRIPT" "$part" 2>&1) || { echo "FAIL: unknown part '$part' exited non-zero"; exit 1; }
    [ -z "$OUT" ] || { echo "FAIL: unknown part '$part' printed output: $OUT"; exit 1; }
done
echo "PASS: unknown session-start parts print nothing and exit 0"

echo ""
echo "Testing: hooks/working-memory.sh"
echo "================================"
(
    cd "$PROJ_DIR"
    OUT=$(bash "$WM_SCRIPT" 2>/dev/null) || { echo "FAIL: working-memory exited non-zero"; exit 1; }
    if [ -n "$OUT" ]; then
        echo "FAIL: working-memory should print nothing when every source is empty"
        exit 1
    fi
    mkdir -p scratch/working-memory
    printf '# Experiments\n- 2026-11-01 lr sweep: diverged above 3e-4\n' > scratch/working-memory/experiments.md
    OUT=$(bash "$WM_SCRIPT" 2>/dev/null) || { echo "FAIL: working-memory exited non-zero"; exit 1; }
    for needle in "[propel:working-memory]" "## Experiments log" "lr sweep" \
                  "## Architectures log" "## Recent registry entries"; do
        case "$OUT" in
            *"$needle"*) ;;
            *) echo "FAIL: working-memory output missing '$needle'"; exit 1 ;;
        esac
    done
    if [ "${OUT:0:1}" = "{" ]; then
        echo "FAIL: working-memory output starts with '{'"
        exit 1
    fi
    # A 20 KB log is cut to its tail so the hook stays under the per-hook cap.
    for i in $(seq 1 400); do echo "- 2026-11-01 experiment $i: lr sweep diverged above 3e-4"; done \
        | head -c 20000 > scratch/working-memory/experiments.md
    OUT=$(bash "$WM_SCRIPT" 2>/dev/null) || { echo "FAIL: working-memory exited non-zero on a 20 KB log"; exit 1; }
    SIZE=$(printf '%s\n' "$OUT" | wc -c | tr -d '[:space:]')
    [ "$SIZE" -lt 10000 ] || { echo "FAIL: working-memory output is $SIZE bytes on a 20 KB log"; exit 1; }
    case "$OUT" in
        *"(earlier entries omitted — full log at scratch/working-memory/experiments.md)"*) ;;
        *) echo "FAIL: working-memory did not mark the omitted entries"; exit 1 ;;
    esac
    rm -rf scratch
) || exit 1
echo "PASS: working-memory is silent when empty, prints its sections otherwise, and caps long logs"

echo ""
echo "Testing: every hook with no python3 on PATH"
echo "================================"
NOPY_BIN=$(mktemp -d)
for tool in bash sh cat date ls find head tail sort grep sed dirname basename tr wc \
            stat mkdir git awk cut printf env rm; do
    TOOL_PATH=$(command -v "$tool" 2>/dev/null || true)
    case "$TOOL_PATH" in
        /*) ln -s "$TOOL_PATH" "$NOPY_BIN/$tool" ;;
    esac
done
if [ -e "$NOPY_BIN/python3" ]; then
    echo "FAIL: test setup — python3 leaked into the no-python3 PATH"
    rm -rf "$NOPY_BIN"; exit 1
fi
(
    cd "$PROJ_DIR"
    mkdir -p .propel scratch/working-memory
    echo '{"enabled": false, "available": null}' > .propel/codex.json
    echo '{"mode": "engineer", "selected_by": "auto"}' > .propel/mode.json
    printf -- '- an experiment\n' > scratch/working-memory/experiments.md
    BASH_BIN="$NOPY_BIN/bash"

    for part in "" $PARTS; do
        RC=0
        OUT=$(env -i PATH="$NOPY_BIN" "$BASH_BIN" "$HOOK_SCRIPT" $part < /dev/null 2>/dev/null) || RC=$?
        [ "$RC" -eq 0 ] || { echo "FAIL: session-start '${part:-<no arg>}' exited $RC without python3"; exit 1; }
        [ "${OUT:0:1}" != "{" ] || { echo "FAIL: session-start '${part:-<no arg>}' output starts with '{' without python3"; exit 1; }
        case "${part:-state}" in
            state)
                case "$OUT" in *"enabled: false"*) ;; *) echo "FAIL: session-start grep fallback misread codex.json"; exit 1 ;; esac
                case "$OUT" in *"mode_selection_needed: false"*) ;; *) echo "FAIL: session-start misread mode.json without python3"; exit 1 ;; esac ;;
            core)
                case "$OUT" in *"## Core principles"*) ;; *) echo "FAIL: session-start lost core principles without python3"; exit 1 ;; esac ;;
            routing1)
                case "$OUT" in *"## using-propel skill (part 1 of"*) ;; *) echo "FAIL: session-start lost the using-propel skill without python3"; exit 1 ;; esac ;;
        esac
    done

    RC=0
    OUT=$(env -i PATH="$NOPY_BIN" "$BASH_BIN" "$WM_SCRIPT" < /dev/null 2>/dev/null) || RC=$?
    [ "$RC" -eq 0 ] || { echo "FAIL: working-memory exited $RC without python3"; exit 1; }
    case "$OUT" in *"## Experiments log"*) ;; *) echo "FAIL: working-memory lost its log without python3"; exit 1 ;; esac

    RC=0
    OUT=$(env -i PATH="$NOPY_BIN" "$BASH_BIN" "$PLUGIN_DIR/hooks/route.sh" < /dev/null 2>/dev/null) || RC=$?
    [ "$RC" -eq 0 ] || { echo "FAIL: route.sh exited $RC without python3"; exit 1; }
    case "$OUT" in *"[propel:routing]"*) ;; *) echo "FAIL: route.sh lost the routing card without python3"; exit 1 ;; esac

    RC=0
    OUT=$(echo '{"tool_name":"Edit","tool_input":{"file_path":"src/models/vq_loss.py"}}' \
      | env -i PATH="$NOPY_BIN" "$BASH_BIN" "$PLUGIN_DIR/hooks/auditor-dispatch.sh" 2>/dev/null) || RC=$?
    [ "$RC" -eq 0 ] || { echo "FAIL: auditor-dispatch.sh exited $RC without python3"; exit 1; }
    # Without python3 the payload cannot be parsed; the documented degradation
    # is silence. Any output it does produce must still be a hook JSON object.
    if [ -n "$OUT" ]; then
        case "$OUT" in *hookSpecificOutput*) ;; *) echo "FAIL: auditor-dispatch emitted malformed output without python3"; exit 1 ;; esac
    fi
    rm -rf .propel scratch
) || { rm -rf "$NOPY_BIN"; exit 1; }
rm -rf "$NOPY_BIN"
echo "PASS: all 4 hooks exit 0 and keep their output shape without python3"

echo ""
echo "Testing: version agreement"
echo "================================"
PLUGIN_VERSION=$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$PLUGIN_DIR/.claude-plugin/plugin.json" \
    | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
PKG_VERSION=$(grep -E '^__version__[[:space:]]*=' "$PLUGIN_DIR/src/propel_cli/__init__.py" \
    | head -1 | sed -E "s/^__version__[[:space:]]*=[[:space:]]*['\"]([^'\"]*)['\"].*/\1/")
if [ -z "$PLUGIN_VERSION" ] || [ "$PLUGIN_VERSION" != "$PKG_VERSION" ]; then
    echo "FAIL: .claude-plugin/plugin.json version '$PLUGIN_VERSION' != __version__ '$PKG_VERSION'"
    exit 1
fi
echo "PASS: plugin.json and propel_cli.__version__ agree ($PKG_VERSION)"

echo ""
echo "================================"
echo "All tests passed!"

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
    printf 'test brief' | env HOME="$NOCLI_HOME" PATH=/usr/bin:/bin bash "$PLUGIN_DIR/scripts/codex-consult.sh" \
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
    | env HOME="$NOCLI_HOME" PATH=/usr/bin:/bin bash "$PLUGIN_DIR/scripts/codex-consult.sh" \
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
    ( printf 'x' | env HOME="$NOCLI_HOME" PATH=/usr/bin:/bin bash "$PLUGIN_DIR/scripts/codex-consult.sh" $FLAG ) \
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
    | env HOME="$NOCLI_HOME" PATH=/usr/bin:/bin bash "$PLUGIN_DIR/scripts/codex-consult.sh" \
        --label "Gate 2" --question "is this safe" >/dev/null
  printf 'CONTEXT\nQUESTION\n  PRIVATE_TOKEN = ghp_NEVER_LOG_THIS\n\nQUESTION\n  the real one\n' \
    | env HOME="$NOCLI_HOME" PATH=/usr/bin:/bin bash "$PLUGIN_DIR/scripts/codex-consult.sh" \
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
  env HOME="$NOCLI_HOME" PATH=/usr/bin:/bin bash "$SEG" | grep -q 'no cli' \
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
echo "Testing: Codex scripts with HOME unset"
echo "================================"
# The scripts look in $HOME/.local/bin under `set -u`; an unset HOME (cron,
# env -i) must still degrade, never abort.
(
  D=$(mktemp -d); cd "$D"; mkdir -p .propel; echo '{"enabled": true}' > .propel/codex.json
  OUT=$(printf 'x' | env -i PATH=/usr/bin:/bin bash "$PLUGIN_DIR/scripts/codex-consult.sh" --label t 2>&1); RC=$?
  if [ "$RC" -ne 0 ] || ! printf '%s' "$OUT" | grep -q "CODEX UNAVAILABLE"; then
    echo "FAIL: codex-consult.sh with HOME unset (exit $RC)"; rm -rf "$D"; exit 1
  fi
  [ -s .propel/codex-log.jsonl ] || { echo "FAIL: no ledger entry with HOME unset"; rm -rf "$D"; exit 1; }
  SEG_OUT=$(env -i PATH=/usr/bin:/bin bash "$PLUGIN_DIR/scripts/codex-statusline.sh" 2>&1); RC=$?
  if [ "$RC" -ne 0 ] || ! printf '%s' "$SEG_OUT" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
    echo "FAIL: codex-statusline.sh with HOME unset (exit $RC): $SEG_OUT"; rm -rf "$D"; exit 1
  fi
  rm -rf "$D"
  echo "PASS: Codex scripts degrade with HOME unset"
) || exit 1

echo ""
echo "================================"
echo "All extended tests passed!"
