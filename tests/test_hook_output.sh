#!/usr/bin/env bash
# Tests for Propel's hooks and Codex scripts.
#
# Usage: bash tests/test_hook_output.sh
#
# session-start.sh and working-memory.sh emit PLAIN TEXT: Claude Code adds
# plain-text SessionStart stdout to context, while stdout that starts with `{`
# is parsed as hook JSON (and a custom object is dropped). These tests verify:
# 1. every session-start part (state, tasks, core, codex, routing1-4) runs,
#    exits 0, is NOT a JSON object, and is under the ~10,000-character per-hook cap
# 2. CORE.md and CODEX.md arrive untruncated; the routing parts reproduce
#    using-propel/SKILL.md losslessly in no more chunks than are registered
# 3. the version line comes from .propel/manifest.json, "unknown" without one
# 4. the tasks part shows open ledger tasks (capped at 20 rows and 8,500
#    characters), prints nothing without any, and exports a sanitized
#    PROPEL_SESSION through CLAUDE_ENV_FILE exactly once
# 5. working-memory prints nothing when empty, its sections when not, and caps
#    long logs
# 6. every hook exits 0 with no python3 on PATH; route.sh reads mode/Codex
#    state without python3 and adds one tasks line when tasks are open
# 7. plugin.json and the package agree on the version

set -euo pipefail

# Hooks prefer CLAUDE_PROJECT_DIR over the cwd. Running this test from inside a
# Claude Code session exports it, which would point every hook run below at
# the real project instead of the throwaway dirs. Tests that need it set it.
# CLAUDE_ENV_FILE would let the tasks part write into the real session's env
# file; PROPEL_SESSION would leak a session into task-queue.sh runs.
unset CLAUDE_PROJECT_DIR CLAUDE_ENV_FILE PROPEL_SESSION

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

# A fresh bin dir holding the tools the hooks (and scripts/task-queue.sh, which
# the tasks part and route.sh call) may use, and no python3. Prints its path.
make_nopy_bin() {
    local dir tool tool_path
    dir=$(mktemp -d)
    for tool in bash sh cat date ls find head tail sort grep sed dirname basename tr wc \
                stat mkdir rmdir git awk cut printf env rm sleep; do
        tool_path=$(command -v "$tool" 2>/dev/null || true)
        case "$tool_path" in
            /*) ln -s "$tool_path" "$dir/$tool" ;;
        esac
    done
    printf '%s\n' "$dir"
}

# closed_stdin <command...>: run with stdin closed, killed after 10 s so a hook
# that blocks fails here instead of stalling the suite. Returns the command's
# status (137 when killed). The <&- is on the background command itself: an
# `&` command otherwise gets /dev/null as stdin.
closed_stdin() {
    local pid watch rc=0
    "$@" <&- >/dev/null 2>&1 &
    pid=$!
    ( sleep 10; kill -9 "$pid" ) >/dev/null 2>&1 &
    watch=$!
    wait "$pid" || rc=$?
    kill "$watch" 2>/dev/null || true
    wait "$watch" 2>/dev/null || true   # reaped quietly: no "Terminated" line
    return "$rc"
}

# open_pipe <out-file> <payload> <command...>: run the command with stdin from a
# FIFO that delivers <payload> and then stays open, without EOF, for 8 s.
# stdout goes to <out-file>; OP_SECS is set to the wall seconds taken. Killed
# after 10 s (status 137), so a hook that waits for EOF fails instead of hanging.
open_pipe() {
    local out="$1" payload="$2" d w pid watch start rc=0
    shift 2
    d=$(mktemp -d)
    mkfifo "$d/fifo"
    ( printf '%s' "$payload"; sleep 8 ) > "$d/fifo" 2>/dev/null &
    w=$!
    start=$(date +%s)
    "$@" < "$d/fifo" > "$out" 2>/dev/null &
    pid=$!
    ( sleep 10; kill -9 "$pid" ) >/dev/null 2>&1 &
    watch=$!
    wait "$pid" || rc=$?
    OP_SECS=$(( $(date +%s) - start ))
    kill "$watch" "$w" 2>/dev/null || true
    wait "$watch" 2>/dev/null || true
    wait "$w" 2>/dev/null || true
    rm -rf "$d"
    return "$rc"
}

# A 200 KB prompt payload carrying session id <id>: big_payload <id>
big_payload() {
    printf '{"session_id":"%s","prompt":"' "$1"
    head -c 200000 /dev/zero | tr '\0' 'x'
    printf '"}'
}

echo "Testing: hooks/session-start.sh"
echo "================================"

# Test 1: Script exists and is executable
if [ ! -x "$HOOK_SCRIPT" ]; then
    echo "FAIL: $HOOK_SCRIPT is not executable"
    exit 1
fi
echo "PASS: Script is executable"

PARTS="state tasks core codex routing1 routing2 routing3 routing4"
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
# The tasks part reads stdin, so stdin is /dev/null here (an inherited pipe
# that never closes would stall it); with no ledger it prints nothing.
for part in $PARTS; do
    ( cd "$PLUGIN_DIR" && bash "$HOOK_SCRIPT" "$part" < /dev/null > "$PART_DIR/$part" 2>/dev/null ) || {
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
        OUT=$(bash "$HOOK_SCRIPT" "$part" < /dev/null 2>/dev/null) || { echo "FAIL: exit non-zero with manifest"; exit 1; }
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
echo "Testing: session-start tasks part"
echo "================================"
TQ_SCRIPT="$PLUGIN_DIR/scripts/task-queue.sh"
tq() { bash "$TQ_SCRIPT" "$@" < /dev/null 2>/dev/null; }
TASKS_DIR=$(mktemp -d)
TASKS_NOPY=$(make_nopy_bin)
# hook_tasks <env-file or "">: run the tasks part in the cwd with the caller's
# stdin, with python3 on PATH (TQ_RUN=py) or under env -i with none (nopy).
hook_tasks() {
    if [ "$TQ_RUN" = nopy ]; then
        env -i PATH="$TASKS_NOPY" ${1:+CLAUDE_ENV_FILE="$1"} "$TASKS_NOPY/bash" "$HOOK_SCRIPT" tasks 2>/dev/null
    else
        env ${1:+CLAUDE_ENV_FILE="$1"} bash "$HOOK_SCRIPT" tasks 2>/dev/null
    fi
}
(
    cd "$TASKS_DIR"
    if [ -e "$TASKS_NOPY/python3" ]; then echo "FAIL: test setup — python3 leaked into the no-python3 PATH"; exit 1; fi
    S2_JSON='{"session_id":"S2","transcript_path":"/tmp/t.jsonl","cwd":"/tmp","hook_event_name":"SessionStart","source":"startup"}'

    # Ledgers, built once and read by both runs below.
    mkdir -p main/.propel noledger/.propel closed/.propel many/.propel long/.propel
    ID1=$(cd main && tq start --session S1 --kind impl --title "implement the vq loss")
    [ -n "$ID1" ] || { echo "FAIL: test setup — task-queue.sh start printed no id"; exit 1; }
    ID_CLOSED=$(cd closed && tq start --session S1 --kind impl --title "closed task")
    (cd closed && tq abandon "$ID_CLOSED") || { echo "FAIL: test setup — task-queue.sh abandon failed"; exit 1; }
    for i in $(seq 1 25); do (cd many && tq start --session S1 --kind other --title "task number $i" >/dev/null); done
    mkdir -p many21/.propel
    for i in $(seq 1 21); do (cd many21 && tq start --session S1 --kind other --title "task number $i" >/dev/null); done
    # Titles and progress made of '|' are escaped to '\|' in the table, so 20
    # rows of them would pass the 8,500-character budget.
    PIPES=$(head -c 200 /dev/zero | tr '\0' '|')
    for i in $(seq 1 25); do
        (cd long && tq start --session S1 --kind other --title "$i$PIPES" --progress "$PIPES" >/dev/null)
    done

    for TQ_RUN in py nopy; do
        E="$TASKS_DIR/env-$TQ_RUN"

        # (a) another session sees S1's task, not as its own; the part opens
        # with its header; PROPEL_SESSION=S2 is exported once over two runs.
        for run in 1 2; do
            RC=0
            OUT=$(cd main && printf '%s' "$S2_JSON" | hook_tasks "$E-a") || RC=$?
            [ "$RC" -eq 0 ] || { echo "FAIL [$TQ_RUN]: tasks part exited $RC (run $run)"; exit 1; }
        done
        case "$OUT" in
            "[propel:session-start tasks] Propel "*) ;;
            *) echo "FAIL [$TQ_RUN]: tasks part does not open with its header line"; exit 1 ;;
        esac
        for needle in "## Open tasks" ".propel/tasks/" "bash .claude/scripts/task-queue.sh" \
                      "task-queue.sh carry ID" "task-queue.sh abandon ID" "check-progress" \
                      "| ID | Task | Kind | Status | Progress | Started | Session |" \
                      "| $ID1 | implement the vq loss | impl | running |" \
                      "Statuses lost, unknown and blocked need a decision."; do
            case "$OUT" in *"$needle"*) ;; *) echo "FAIL [$TQ_RUN]: tasks part missing '$needle'"; exit 1 ;; esac
        done
        case "$OUT" in *"S1 (this)"*) echo "FAIL [$TQ_RUN]: S1's task is marked '(this)' in session S2"; exit 1 ;; esac
        [ "$(cat "$E-a" 2>/dev/null)" = "export PROPEL_SESSION=S2" ] \
            || { echo "FAIL [$TQ_RUN]: env file should hold exactly one 'export PROPEL_SESSION=S2'"; exit 1; }
        # An env file whose last line has no newline gets a line of its own.
        printf 'export OTHER=1' > "$E-a2"
        (cd main && printf '%s' "$S2_JSON" | hook_tasks "$E-a2" >/dev/null) || { echo "FAIL [$TQ_RUN]: tasks part exited non-zero"; exit 1; }
        [ "$(cat "$E-a2")" = "export OTHER=1
export PROPEL_SESSION=S2" ] || { echo "FAIL [$TQ_RUN]: export glued onto an unterminated env-file line"; exit 1; }

        # (b) the owning session sees its row marked "(this)".
        OUT=$(cd main && printf '{"session_id":"S1","source":"resume"}' | hook_tasks "") \
            || { echo "FAIL [$TQ_RUN]: tasks part exited non-zero as S1"; exit 1; }
        ROW=$(printf '%s\n' "$OUT" | grep -F "| $ID1 |" || true)
        case "$ROW" in *"| S1 (this) |"*) ;; *) echo "FAIL [$TQ_RUN]: the owning session's row is not marked '(this)': $ROW"; exit 1 ;; esac

        # (c) no stdin (empty or closed): exit 0, table still shown, nothing exported.
        RC=0
        OUT=$(cd main && hook_tasks "$E-c" < /dev/null) || RC=$?
        [ "$RC" -eq 0 ] || { echo "FAIL [$TQ_RUN]: tasks part exited $RC with stdin from /dev/null"; exit 1; }
        [ ! -e "$E-c" ] || { echo "FAIL [$TQ_RUN]: tasks part exported a session with no stdin"; exit 1; }
        case "$OUT" in *"| $ID1 |"*) ;; *) echo "FAIL [$TQ_RUN]: tasks part lost the table with no stdin"; exit 1 ;; esac
        case "$OUT" in *" (this) |"*) echo "FAIL [$TQ_RUN]: a row is marked '(this)' with no session"; exit 1 ;; esac
        RC=0
        (cd main && closed_stdin hook_tasks "$E-c") || RC=$?
        [ "$RC" -eq 0 ] || { echo "FAIL [$TQ_RUN]: tasks part exited $RC with stdin closed (137 = hung)"; exit 1; }
        [ ! -e "$E-c" ] || { echo "FAIL [$TQ_RUN]: tasks part exported a session with stdin closed"; exit 1; }

        # (d) no ledger, or no open task: no output at all — the session id is
        # still exported.
        for dir in noledger closed; do
            RC=0
            OUT=$(cd "$dir" && printf '%s' "$S2_JSON" | hook_tasks "$E-d-$dir") || RC=$?
            [ "$RC" -eq 0 ] || { echo "FAIL [$TQ_RUN]: tasks part exited $RC ($dir)"; exit 1; }
            [ -z "$OUT" ] || { echo "FAIL [$TQ_RUN]: tasks part printed output with no open task ($dir)"; exit 1; }
            [ "$(cat "$E-d-$dir" 2>/dev/null)" = "export PROPEL_SESSION=S2" ] \
                || { echo "FAIL [$TQ_RUN]: PROPEL_SESSION not exported when there are no open tasks ($dir)"; exit 1; }
        done

        # (e) 25 open tasks: 20 rows and a "5 more" line; with rows too long
        # for the budget, fewer rows, the "more" line counting the rest, and
        # the whole part within 8,500 characters either way.
        OUT=$(cd many && printf '{"session_id":"S1"}' | hook_tasks "") || { echo "FAIL [$TQ_RUN]: exit non-zero with 25 tasks"; exit 1; }
        ROWS=$(printf '%s\n' "$OUT" | grep -c '^| t[0-9]' || true)
        [ "$ROWS" -eq 20 ] || { echo "FAIL [$TQ_RUN]: 25 open tasks should show 20 rows, showed $ROWS"; exit 1; }
        [ "$(printf '%s\n' "$OUT" | tail -n 1)" = "(5 more open tasks — run check-progress)" ] \
            || { echo "FAIL [$TQ_RUN]: 25 open tasks should end with '(5 more open tasks — run check-progress)'"; exit 1; }
        OUT=$(cd long && printf '{"session_id":"S1"}' | hook_tasks "") || { echo "FAIL [$TQ_RUN]: exit non-zero with long rows"; exit 1; }
        SIZE=$(printf '%s\n' "$OUT" | wc -c | tr -d '[:space:]')
        [ "$SIZE" -le 8500 ] || { echo "FAIL [$TQ_RUN]: tasks part is $SIZE bytes with long rows (max 8,500)"; exit 1; }
        ROWS=$(printf '%s\n' "$OUT" | grep -c '^| t[0-9]' || true)
        [ "$ROWS" -lt 20 ] || { echo "FAIL [$TQ_RUN]: long rows should have been dropped to fit 8,500 characters"; exit 1; }
        [ "$(printf '%s\n' "$OUT" | tail -n 1)" = "($((25 - ROWS)) more open tasks — run check-progress)" ] \
            || { echo "FAIL [$TQ_RUN]: long rows should end with '($((25 - ROWS)) more open tasks — run check-progress)'"; exit 1; }
        for needle in "| ID | Task | Kind | Status | Progress | Started | Session |" "|---|---|---|---|---|---|---|"; do
            case "$OUT" in *"$needle"*) ;; *) echo "FAIL [$TQ_RUN]: capped table lost its header line '$needle'"; exit 1 ;; esac
        done

        # 21 open tasks: one omitted, in the singular.
        OUT=$(cd many21 && printf '{"session_id":"S1"}' | hook_tasks "") || { echo "FAIL [$TQ_RUN]: exit non-zero with 21 tasks"; exit 1; }
        [ "$(printf '%s\n' "$OUT" | tail -n 1)" = "(1 more open task — run check-progress)" ] \
            || { echo "FAIL [$TQ_RUN]: 21 open tasks should end with '(1 more open task — run check-progress)'"; exit 1; }

        # (h) a stdin pipe that stays open without EOF: the part finishes in
        # under 3 s and still uses the session id that arrived.
        RC=0
        (cd main && open_pipe "$E-h.out" '{"session_id":"OP1","source":"startup"}' hook_tasks "$E-h"
         echo "$OP_SECS" > "$E-h.secs") || RC=$?
        [ "$RC" -eq 0 ] || { echo "FAIL [$TQ_RUN]: tasks part exited $RC on an open stdin pipe (137 = hung)"; exit 1; }
        [ "$(cat "$E-h.secs")" -lt 3 ] || { echo "FAIL [$TQ_RUN]: tasks part took $(cat "$E-h.secs") s on an open stdin pipe"; exit 1; }
        [ "$(cat "$E-h" 2>/dev/null)" = "export PROPEL_SESSION=OP1" ] \
            || { echo "FAIL [$TQ_RUN]: session id lost on an open stdin pipe"; exit 1; }
        grep -qF "| $ID1 |" "$E-h.out" || { echo "FAIL [$TQ_RUN]: table lost on an open stdin pipe"; exit 1; }

        # (i) a 200 KB payload: the writer is drained (no EPIPE / SIGPIPE),
        # and the session id from the first 4,096 bytes is used.
        RC=0
        (cd main && big_payload BIG1 | hook_tasks "$E-i" > /dev/null; echo "${PIPESTATUS[*]}" > "$E-i.ps") || RC=$?
        [ "$(cat "$E-i.ps")" = "0 0" ] || { echo "FAIL [$TQ_RUN]: 200 KB payload: writer/hook statuses $(cat "$E-i.ps") (writer must not get EPIPE)"; exit 1; }
        [ "$(cat "$E-i" 2>/dev/null)" = "export PROPEL_SESSION=BIG1" ] \
            || { echo "FAIL [$TQ_RUN]: session id lost with a 200 KB payload"; exit 1; }

        # (j) sessions A, B, A against one env file: A is what sourcing yields.
        for sid in SA SB SA; do
            (cd noledger && printf '{"session_id":"%s"}' "$sid" | hook_tasks "$E-j" >/dev/null) \
                || { echo "FAIL [$TQ_RUN]: tasks part exited non-zero ($sid)"; exit 1; }
        done
        [ "$(unset PROPEL_SESSION; . "$E-j"; printf '%s' "${PROPEL_SESSION:-}")" = "SA" ] \
            || { echo "FAIL [$TQ_RUN]: after sessions A, B, A the env file does not leave PROPEL_SESSION=A"; exit 1; }

        # (f) hostile session ids: nothing executes, and what is exported is a
        # bare [A-Za-z0-9._-] token without leading dots — or nothing at all.
        for raw in '../evil' 'a$(touch PWNED)b' 'x\"y' '..' '`touch PWNED`'; do
            rm -f "$E-f"
            RC=0
            (cd main && printf '{"session_id":"%s","source":"startup"}' "$raw" | hook_tasks "$E-f" >/dev/null) || RC=$?
            [ "$RC" -eq 0 ] || { echo "FAIL [$TQ_RUN]: tasks part exited $RC for session id $raw"; exit 1; }
            if [ "$raw" = ".." ]; then
                [ ! -e "$E-f" ] || { echo "FAIL [$TQ_RUN]: session id '..' should export nothing"; exit 1; }
                continue
            fi
            [ "$(grep -c '' "$E-f" 2>/dev/null || true)" = 1 ] || { echo "FAIL [$TQ_RUN]: session id $raw should export one line"; exit 1; }
            VAL=$(sed -n 's/^export PROPEL_SESSION=//p' "$E-f")
            case "$VAL" in
                ''|.*|*[!A-Za-z0-9._-]*) echo "FAIL [$TQ_RUN]: session id $raw exported as '$VAL'"; exit 1 ;;
            esac
        done
        if [ -n "$(find "$TASKS_DIR" -name PWNED 2>/dev/null)" ]; then
            echo "FAIL [$TQ_RUN]: a hostile session id was executed"; exit 1
        fi
    done

    # The exported id is the ledger's file stem: task-queue.sh, given the same
    # raw id, names its file exactly what the hook exports.
    LONGID=$(head -c 70 /dev/zero | tr '\0' 'L')
    n=0
    for raw in '../evil' 'a$(touch PWNED)b' '...lead' "$LONGID" '550e8400-e29b-41d4-a716-446655440000'; do
        n=$((n + 1))
        mkdir -p "stem$n/.propel"
        (cd "stem$n" && tq start --session "$raw" --kind other --title t >/dev/null)
        STEM=$(ls "stem$n/.propel/tasks" | sed -n 's/\.jsonl$//p')
        (cd "stem$n" && printf '{"session_id":"%s"}' "$raw" | TQ_RUN=py hook_tasks "$TASKS_DIR/env-stem$n" >/dev/null)
        [ -n "$STEM" ] && [ "$(cat "$TASKS_DIR/env-stem$n")" = "export PROPEL_SESSION=$STEM" ] \
            || { echo "FAIL: session id $raw exported as '$(cat "$TASKS_DIR/env-stem$n" 2>/dev/null)', ledger file stem is '$STEM'"; exit 1; }
    done
    if [ -n "$(find "$TASKS_DIR" -name PWNED 2>/dev/null)" ]; then
        echo "FAIL: a hostile session id was executed"; exit 1
    fi
) || { rm -rf "$TASKS_DIR" "$TASKS_NOPY"; exit 1; }
rm -rf "$TASKS_DIR" "$TASKS_NOPY"
echo "PASS: tasks part lists open tasks (20 rows, 8,500 characters max), is silent without any, and exports a sanitized PROPEL_SESSION once — with and without python3"

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
NOPY_BIN=$(make_nopy_bin)
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

# route.sh drains stdin (the prompt payload), so it gets /dev/null here.
ROUTE_OUT=$(bash "$PLUGIN_DIR/hooks/route.sh" < /dev/null) || {
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

# Without python3, route.sh reads mode and Codex state with grep — the same
# answers as the python path — and honours CLAUDE_PROJECT_DIR.
ROUTE_DIR=$(mktemp -d)
ROUTE_NOPY=$(make_nopy_bin)
route_nopy() { env -i PATH="$ROUTE_NOPY" "$@" "$ROUTE_NOPY/bash" "$PLUGIN_DIR/hooks/route.sh" 2>/dev/null; }
route_py() { bash "$PLUGIN_DIR/hooks/route.sh" 2>/dev/null; }
(
    cd "$ROUTE_DIR"
    if [ -e "$ROUTE_NOPY/python3" ]; then echo "FAIL: test setup — python3 leaked into the no-python3 PATH"; exit 1; fi
    mkdir -p .propel sub
    echo '{"mode": "debugger", "selected_by": "auto", "previous_mode": "engineer"}' > .propel/mode.json
    echo '{"enabled": false}' > .propel/codex.json
    RC=0
    OUT=$(route_nopy < /dev/null) || RC=$?
    [ "$RC" -eq 0 ] || { echo "FAIL: route.sh exited $RC without python3"; exit 1; }
    case "$OUT" in *"mode: debugger (selected_by: auto) — "*) ;; *) echo "FAIL: route.sh misread mode.json without python3"; exit 1 ;; esac
    case "$OUT" in *"codex: OFF — "*) ;; *) echo "FAIL: route.sh missed a disabled Codex without python3"; exit 1 ;; esac
    if command -v python3 >/dev/null 2>&1; then
        [ "$OUT" = "$(bash "$PLUGIN_DIR/hooks/route.sh" < /dev/null)" ] \
            || { echo "FAIL: route.sh's python and grep paths disagree (Codex disabled)"; exit 1; }
    fi
    OUT=$(cd sub && route_nopy CLAUDE_PROJECT_DIR="$ROUTE_DIR" < /dev/null) || { echo "FAIL: route.sh exited non-zero from a subdirectory"; exit 1; }
    case "$OUT" in *"mode: debugger (selected_by: auto) — "*) ;; *) echo "FAIL: route.sh ignored CLAUDE_PROJECT_DIR"; exit 1 ;; esac
    echo '{"enabled": true, "available": false}' > .propel/codex.json
    OUT=$(route_nopy < /dev/null) || { echo "FAIL: route.sh exited non-zero without python3"; exit 1; }
    case "$OUT" in *"codex: enabled but CLI unavailable — "*) ;; *) echo "FAIL: route.sh missed an unavailable Codex CLI without python3"; exit 1 ;; esac
    if command -v python3 >/dev/null 2>&1; then
        [ "$OUT" = "$(bash "$PLUGIN_DIR/hooks/route.sh" < /dev/null)" ] \
            || { echo "FAIL: route.sh's python and grep paths disagree (CLI unavailable)"; exit 1; }
    fi
    # A value on its own line is still seen by both grep fallbacks.
    printf '{"enabled":\n  false}\n' > .propel/codex.json
    OUT=$(route_nopy < /dev/null) || { echo "FAIL: route.sh exited non-zero without python3"; exit 1; }
    case "$OUT" in *"codex: OFF — "*) ;; *) echo "FAIL: route.sh missed a split-line \"enabled\": false without python3"; exit 1 ;; esac
    OUT=$(env -i PATH="$ROUTE_NOPY" "$ROUTE_NOPY/bash" "$HOOK_SCRIPT" state < /dev/null 2>/dev/null) || { echo "FAIL: state exited non-zero without python3"; exit 1; }
    case "$OUT" in *"enabled: false, available: null"*) ;; *) echo "FAIL: state missed a split-line \"enabled\": false without python3"; exit 1 ;; esac
    printf '{"enabled": true,\n "available":\n false}\n' > .propel/codex.json
    OUT=$(route_nopy < /dev/null) || { echo "FAIL: route.sh exited non-zero without python3"; exit 1; }
    case "$OUT" in *"codex: enabled but CLI unavailable — "*) ;; *) echo "FAIL: route.sh missed a split-line \"available\": false without python3"; exit 1 ;; esac
    OUT=$(env -i PATH="$ROUTE_NOPY" "$ROUTE_NOPY/bash" "$HOOK_SCRIPT" state < /dev/null 2>/dev/null) || { echo "FAIL: state exited non-zero without python3"; exit 1; }
    case "$OUT" in *"enabled: true, available: false"*) ;; *) echo "FAIL: state missed a split-line \"available\": false without python3"; exit 1 ;; esac
    # Only JSON false turns Codex off: null leaves it on, with and without python3.
    echo '{"enabled": null}' > .propel/codex.json
    OUT=$(route_nopy < /dev/null) || { echo "FAIL: route.sh exited non-zero without python3"; exit 1; }
    case "$OUT" in *"codex: on (automatic at every gate)"*) ;; *) echo "FAIL: route.sh treats \"enabled\": null as off without python3"; exit 1 ;; esac
    if command -v python3 >/dev/null 2>&1; then
        OUT=$(bash "$PLUGIN_DIR/hooks/route.sh" < /dev/null) || { echo "FAIL: route.sh exited non-zero"; exit 1; }
        case "$OUT" in *"codex: on (automatic at every gate)"*) ;; *) echo "FAIL: route.sh treats \"enabled\": null as off with python3"; exit 1 ;; esac
    fi
) || { rm -rf "$ROUTE_DIR" "$ROUTE_NOPY"; exit 1; }
echo "PASS: route.sh reads mode and Codex state without python3, and honours CLAUDE_PROJECT_DIR"

# The tasks line: one line after `codex:`, only when tasks are open; nothing
# else in the card changes.
(
    cd "$ROUTE_DIR"
    rm -f .propel/codex.json
    NO_LEDGER=$(bash "$PLUGIN_DIR/hooks/route.sh" < /dev/null) || { echo "FAIL: route.sh exited non-zero"; exit 1; }
    case "$NO_LEDGER" in *"tasks:"*) echo "FAIL: route.sh printed a tasks line with no ledger"; exit 1 ;; esac
    T1=$(tq start --session S1 --kind impl --title "this session")
    T2=$(tq start --session S0 --kind impl --title "earlier one")
    T3=$(tq start --session S0 --kind impl --title "earlier two")
    [ -n "$T1" ] && [ -n "$T2" ] && [ -n "$T3" ] || { echo "FAIL: test setup — task-queue.sh start printed no id"; exit 1; }
    LINE_S1="tasks: 1 open in this session, 2 from earlier sessions — run check-progress"
    for runner in py nopy; do
        R="route_$runner"
        OUT=$(printf '{"session_id":"S1","prompt":"go on"}' | $R) || { echo "FAIL [$runner]: route.sh exited non-zero with a session"; exit 1; }
        [ "$(printf '%s\n' "$OUT" | sed -n 4p)" = "$LINE_S1" ] \
            || { echo "FAIL [$runner]: route.sh line 4 should be '$LINE_S1'"; exit 1; }
        case "$(printf '%s\n' "$OUT" | sed -n 3p)" in "codex: "*) ;; *) echo "FAIL [$runner]: the tasks line is not right after codex:"; exit 1 ;; esac
        [ "$(printf '%s\n' "$OUT" | grep -v '^tasks: ')" = "$NO_LEDGER" ] \
            || { echo "FAIL [$runner]: route.sh changed lines other than adding the tasks line"; exit 1; }
        # A session_id inside the (escaped) prompt text is not the session.
        OUT=$(printf '{"prompt":"say \\"session_id\\": \\"S1\\"","session_id":"S0"}' | $R) || { echo "FAIL [$runner]: route.sh exited non-zero"; exit 1; }
        case "$OUT" in *"tasks: 2 open in this session, 1 from earlier sessions — run check-progress"*) ;;
            *) echo "FAIL [$runner]: route.sh took the session id from inside the prompt"; exit 1 ;; esac
        RC=0
        OUT=$($R < /dev/null) || RC=$?
        [ "$RC" -eq 0 ] || { echo "FAIL [$runner]: route.sh exited $RC with no stdin"; exit 1; }
        case "$OUT" in *"tasks: 3 open — run check-progress"*) ;; *) echo "FAIL [$runner]: route.sh with no session should count 3 open"; exit 1 ;; esac
        # A stdin pipe that stays open without EOF: done in under 3 s, and the
        # session id that arrived is used.
        RC=0
        open_pipe "$ROUTE_DIR/op.out" '{"session_id":"S1","prompt":"go on"}' "$R" || RC=$?
        [ "$RC" -eq 0 ] || { echo "FAIL [$runner]: route.sh exited $RC on an open stdin pipe (137 = hung)"; exit 1; }
        [ "$OP_SECS" -lt 3 ] || { echo "FAIL [$runner]: route.sh took $OP_SECS s on an open stdin pipe"; exit 1; }
        [ "$(sed -n 4p "$ROUTE_DIR/op.out")" = "$LINE_S1" ] || { echo "FAIL [$runner]: route.sh lost the session id on an open stdin pipe"; exit 1; }
        # A 200 KB payload is drained: the writer never gets EPIPE.
        big_payload S1 | "$R" > "$ROUTE_DIR/big.out"; PS="${PIPESTATUS[*]}"
        [ "$PS" = "0 0" ] || { echo "FAIL [$runner]: 200 KB payload: writer/hook statuses $PS (writer must not get EPIPE)"; exit 1; }
        [ "$(sed -n 4p "$ROUTE_DIR/big.out")" = "$LINE_S1" ] || { echo "FAIL [$runner]: route.sh lost the session id in a 200 KB payload"; exit 1; }
        RC=0
        closed_stdin "$R" || RC=$?
        [ "$RC" -eq 0 ] || { echo "FAIL [$runner]: route.sh exited $RC with stdin closed (137 = hung)"; exit 1; }
        RC=0
        printf '{"session_id":"a$(touch PWNED)b`touch PWNED`"}' | $R >/dev/null || RC=$?
        [ "$RC" -eq 0 ] && [ ! -e PWNED ] || { echo "FAIL [$runner]: route.sh mishandled a hostile session id"; exit 1; }
    done
    tq abandon "$T1" && tq abandon "$T2" && tq abandon "$T3" || { echo "FAIL: test setup — task-queue.sh abandon failed"; exit 1; }
    for runner in py nopy; do
        R="route_$runner"
        for stdin in '{"session_id":"S1"}' ''; do
            OUT=$(printf '%s' "$stdin" | $R) || { echo "FAIL [$runner]: route.sh exited non-zero with no open task"; exit 1; }
            case "$OUT" in *"tasks:"*) echo "FAIL [$runner]: route.sh printed a tasks line with no open task"; exit 1 ;; esac
        done
    done
) || { rm -rf "$ROUTE_DIR" "$ROUTE_NOPY"; exit 1; }
rm -rf "$ROUTE_DIR" "$ROUTE_NOPY"
echo "PASS: route.sh adds one tasks line after codex: when tasks are open, and none otherwise"

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
echo "Testing: scripts/codex-consult.sh without python3 (tests/test_codex_consult.sh)"
echo "================================"
"${BASH:-bash}" "$PLUGIN_DIR/tests/test_codex_consult.sh" < /dev/null > /dev/null 2>&1 || {
    echo "FAIL: tests/test_codex_consult.sh — run it directly for details"; exit 1; }
echo "PASS: codex-consult.sh works without python3 and never stalls on a large brief"

echo ""
echo "================================"
echo "All extended tests passed!"
