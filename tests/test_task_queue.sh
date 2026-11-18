#!/usr/bin/env bash
# Tests for scripts/task-queue.sh, Propel's session-scoped task ledger.
#
# Usage: bash tests/test_task_queue.sh      (or /bin/bash tests/test_task_queue.sh)
#
# The script under test is run with the same bash that runs this file. Every
# test uses a throwaway project dir. Covers: session handling, id format and
# line shape, JSON escaping, cross-session appends to the owner file, unknown
# ids, carry, training-job liveness (exit file, screen, tmux, no evidence) with
# stub binaries, path anchoring, the line cap, concurrent appends, locks and
# `unlock`, settle on read and its races, a no-python3 PATH (bash 3.2 + BWK awk on macOS), the
# --sessions/--days window, root discovery, strict argument checks, corrupt
# lines, and a timing bound for `count` on a seeded ledger.

set -euo pipefail

# The script prefers CLAUDE_PROJECT_DIR and reads PROPEL_SESSION; a Claude Code
# session may export either, which would point runs at the real project.
unset CLAUDE_PROJECT_DIR PROPEL_SESSION PROPEL_TQ_LOCK_TRIES

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
TQ="$PLUGIN_DIR/scripts/task-queue.sh"
SH_BASH="${BASH:-bash}"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

FAILS=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }
check() {  # <label> <command...>   pass if the command succeeds
    local label="$1"; shift
    if "$@"; then pass "$label"; else fail "$label"; fi
}

tq() { "$SH_BASH" "$TQ" "$@"; }

# run <command...>: never aborts; sets RC, OUT, ERR.
run() {
    RC=0
    OUT=$("$@" 2>"$WORK/.err") || RC=$?
    ERR=$(cat "$WORK/.err")
}

ID_RE='^t[0-9]{6}-[0-9]{6}-[0-9a-f]{4}$'
is_id() { printf '%s' "$1" | grep -Eq "$ID_RE"; }
nlines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }

# A bin dir holding only the tools the script is allowed to use: no python3,
# no jq, no flock, no mktemp, and no screen/tmux unless a test adds stubs. On
# macOS, bash and awk are pinned to /bin/bash (3.2) and /usr/bin/awk (BWK).
NOPY_BIN="$WORK/nopy-bin"
mkdir -p "$NOPY_BIN"
for tool in bash sh cat date ls find head tail sort grep sed awk cut tr wc \
            mkdir rmdir rm printf stat dirname basename env git sleep; do
    TOOL_PATH=$(command -v "$tool" 2>/dev/null || true)
    case "$tool" in
        bash) [ -x /bin/bash ] && TOOL_PATH=/bin/bash ;;
        awk)  [ -x /usr/bin/awk ] && TOOL_PATH=/usr/bin/awk ;;
    esac
    case "$TOOL_PATH" in
        /*) ln -s "$TOOL_PATH" "$NOPY_BIN/$tool" ;;
    esac
done
for banned in python3 jq flock mktemp screen tmux; do
    if [ -e "$NOPY_BIN/$banned" ]; then
        echo "FAIL: test setup — $banned leaked into the restricted PATH"; exit 1
    fi
done

# Run the script under a restricted PATH: tq_in <path> <args...>
tq_in() {
    local bin="$1"; shift
    env -i PATH="$bin" HOME="$WORK" ${PROPEL_SESSION:+PROPEL_SESSION="$PROPEL_SESSION"} \
        "$NOPY_BIN/bash" "$TQ" "$@"
}

new_proj() {  # -> PROJ (a fresh dir with an empty .propel/), and cd there
    PROJ=$(mktemp -d "$WORK/proj.XXXXXX")
    mkdir -p "$PROJ/.propel"
    cd "$PROJ"
}

stamp_ago() {  # <BSD date -v offset, e.g. 30d or 2H> <GNU phrase> -> touch -t stamp
    date -v-"$1" +%Y%m%d%H%M 2>/dev/null || date -d "$2" +%Y%m%d%H%M
}

echo "Testing: scripts/task-queue.sh ($("$SH_BASH" -c 'echo bash $BASH_VERSION'))"
echo "================================"

# ── 1. sessions ──────────────────────────────────────────────────────────────
new_proj
run tq start --kind impl --title "x"
if [ "$RC" -eq 2 ] && [ ! -e .propel/tasks ] && [ "$(printf '%s\n' "$ERR" | wc -l | tr -d ' ')" = "1" ]; then
    pass "start without a session exits 2, writes nothing, one stderr line"
else
    fail "start without a session: rc=$RC err='$ERR'"
fi
run tq start --session "..." --kind impl --title "x"
check "a session of only dots is no session (exit 2, nothing written)" \
    test "$RC" -eq 2 -a ! -e .propel/tasks
run tq start --session ".hid" --kind impl --title "x"
check "leading dots are stripped from a session id" \
    test "$RC" -eq 0 -a -f .propel/tasks/hid.jsonl -a ! -e .propel/tasks/.hid.jsonl

# ── 2. id and line shape ─────────────────────────────────────────────────────
run tq start --session s1 --kind impl --title "first"
if [ "$RC" -eq 0 ] && is_id "$OUT" && [ "$(nlines .propel/tasks/s1.jsonl)" = "1" ] \
   && grep -Eq '^\{"v":1,"ts":"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z","ev":"start"' .propel/tasks/s1.jsonl; then
    pass "start prints an id matching $ID_RE and writes one {\"v\":1,\"ts\":\"...Z\" line"
else
    fail "start id/line shape: rc=$RC id='$OUT' file=$(cat .propel/tasks/s1.jsonl 2>/dev/null)"
fi
if tq list --table --session s1 | grep -Eq '\| [0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}Z \| s1 \(this\) \|$'; then
    pass "Started is shown as MM-DD HH:MMZ (UTC)"
else
    fail "UTC display: $(tq list --table --session s1)"
fi

# ── 3. escaping ──────────────────────────────────────────────────────────────
TITLE=$(printf 'say "hi" back\\slash\ttab\nnewline | pipe')
run tq start --session esc --kind impl --title "$TITLE"
F=.propel/tasks/esc.jsonl
if [ "$(nlines "$F")" = "1" ] && grep -qF '"title":"say \"hi\" back\\slash\ttab\nnewline | pipe"' "$F"; then
    pass "special characters are escaped into a single JSON line"
else
    fail "escaping: $(cat "$F")"
fi
if command -v python3 >/dev/null 2>&1; then
    if python3 -c 'import json,sys
for l in sys.stdin:
    d = json.loads(l)
    assert d["title"] == "say \"hi\" back\\slash\ttab\nnewline | pipe", d["title"]' < "$F" 2>/dev/null; then
        pass "python3 json.loads round-trips the title exactly"
    else
        fail "python3 could not round-trip the escaped line"
    fi
else
    echo "SKIP: python3 not available for JSON validation"
fi
run tq list --table --session esc
case "$OUT" in
    *'| say "hi" back\slash tab newline \| pipe |'*) pass "list --table shows the title with | escaped" ;;
    *) fail "list --table title: $OUT" ;;
esac

# ── 4. cross-session update/done ─────────────────────────────────────────────
run tq start --session own --kind impl --title "owned"; ID="$OUT"
run env PROPEL_SESSION=other "$SH_BASH" "$TQ" update "$ID" --progress "half" --note "n1"; R1=$RC
run env PROPEL_SESSION=other "$SH_BASH" "$TQ" done "$ID" --status done --note "finished"; R2=$RC
if [ "$R1" -eq 0 ] && [ "$R2" -eq 0 ] && [ ! -e .propel/tasks/other.jsonl ] \
   && [ "$(nlines .propel/tasks/own.jsonl)" = "3" ] \
   && tail -n 1 .propel/tasks/own.jsonl | grep -qF '"ev":"done","id":"'"$ID"'","session":"other","status":"done"'; then
    pass "update/done from another session append to the owner's file"
else
    fail "cross-session append: rc=$R1/$R2 own=$(cat .propel/tasks/own.jsonl)"
fi
run tq list --session own
case "$OUT" in *"$ID	done	impl	own	"*) pass "the fold reflects the done status" ;; *) fail "fold after done: $OUT" ;; esac

# abandon
run tq start --session own --kind impl --title "to drop"; ID="$OUT"
run tq abandon "$ID" --note "not needed"
if [ "$RC" -eq 0 ] && tail -n 1 .propel/tasks/own.jsonl | grep -qF '"status":"abandoned","note":"not needed"' \
   && tq list --session own | grep -qF "$ID	abandoned	"; then
    pass "abandon records status abandoned"
else
    fail "abandon: rc=$RC $(tail -n 1 .propel/tasks/own.jsonl)"
fi
# (the other sessions' tasks in this project are still open: they count as earlier)
check "abandoned and done tasks are not open" test "$(tq count --session own)" = "0 3"

# ── 5. unknown id ────────────────────────────────────────────────────────────
run tq update t000000-000000-dead --note x; R1=$RC
run env PROPEL_SESSION=x "$SH_BASH" "$TQ" done t000000-000000-dead --status done; R2=$RC
check "unknown id exits 4 (update and done)" test "$R1" -eq 4 -a "$R2" -eq 4
new_proj
run tq carry t000000-000000-dead --session zz
check "an unknown id creates no .propel/tasks directory" test "$RC" -eq 4 -a ! -e .propel/tasks

# ── 6. carry ─────────────────────────────────────────────────────────────────
new_proj
run tq start --session sessA --kind monitor --title "watch loop"; ID="$OUT"
run tq carry "$ID" --session sessB
CB=$(tq count --session sessB) || true; CC=$(tq count --session sessC) || true; CA=$(tq count --session sessA) || true
if [ "$RC" -eq 0 ] && [ "$CB" = "1 0" ] && [ "$CC" = "0 1" ] && [ "$CA" = "1 0" ] && [ ! -e .propel/tasks/sessB.jsonl ]; then
    pass "carry makes a task 'here' for the carrying session and 'earlier' for others"
else
    fail "carry counts: rc=$RC B='$CB' C='$CC' A='$CA'"
fi
check "list --table marks a task carried into this session as (carried here)" \
    sh -c "'$SH_BASH' '$TQ' list --table --session sessB | grep -qF '| sessA (carried here) |'"
check "list --table marks the owner's own task as (this)" \
    sh -c "'$SH_BASH' '$TQ' list --table --session sessA | grep -qF '| sessA (this) |'"
run tq carry "$ID"
check "carry without a session exits 2" test "$RC" -eq 2

# ── 7. liveness ──────────────────────────────────────────────────────────────
new_proj
STUB_RUN="$WORK/stub-running"; STUB_NONE="$WORK/stub-none"; STUB_TMUX="$WORK/stub-tmux"
mkdir -p "$STUB_RUN" "$STUB_NONE" "$STUB_TMUX"
cat > "$STUB_RUN/screen" <<'EOF'
#!/bin/sh
printf 'There are screens on:\n\t12345.myrun\t(Detached)\n\t12346.exp.train\t(Detached)\n\t23456.deadrun\t(Dead ???)\n3 Sockets in /tmp/screens/S-u.\n'
exit 1
EOF
cat > "$STUB_NONE/screen" <<'EOF'
#!/bin/sh
printf 'No Sockets found in /tmp/screens/S-u.\n'
exit 1
EOF
cat > "$STUB_TMUX/tmux" <<'EOF'
#!/bin/sh
[ "$1" = "has-session" ] && [ "$2" = "-t" ] && [ "$3" = "=exp_tm" ] && exit 0
exit 1
EOF
chmod +x "$STUB_RUN/screen" "$STUB_NONE/screen" "$STUB_TMUX/tmux"

printf 'epoch 1 loss 0.9\nepoch 2 loss 0.5\n\n' > "$PROJ/train.log"
printf 'epoch 3\r 10%%|#    |\r 55%%|#####|' > "$PROJ/cr.log"
export PROPEL_SESSION=live
T_OK=$(tq_in "$NOPY_BIN" start --kind train --title ok --exit-file "$PROJ/exit-ok") || true
T_BAD=$(tq_in "$NOPY_BIN" start --kind train --title bad --exit-file "$PROJ/exit-bad") || true
T_EMPTY=$(tq_in "$NOPY_BIN" start --kind train --title empty --exit-file "$PROJ/exit-empty") || true
T_NOEV=$(tq_in "$NOPY_BIN" start --kind train --title "no evidence") || true
T_RUN=$(tq_in "$NOPY_BIN" start --kind train --title run --screen myrun --log "$PROJ/train.log") || true
T_CR=$(tq_in "$NOPY_BIN" start --kind train --title cr --screen myrun --log "$PROJ/cr.log") || true
T_NEAR=$(tq_in "$NOPY_BIN" start --kind train --title near --screen myru) || true
T_DOT=$(tq_in "$NOPY_BIN" start --kind train --title dot --screen train) || true
T_DEAD=$(tq_in "$NOPY_BIN" start --kind train --title dead --screen deadrun) || true
T_BEAT=$(tq_in "$NOPY_BIN" start --kind train --title beat --screen myrun --exit-file "$PROJ/exit-beat") || true
T_TMUX=$(tq_in "$NOPY_BIN" start --kind train --title tm --screen exp.tm) || true
unset PROPEL_SESSION
echo 0 > "$PROJ/exit-ok"; echo 1 > "$PROJ/exit-bad"; : > "$PROJ/exit-empty"; echo 0 > "$PROJ/exit-beat"

status_of() {  # <path> <id>
    tq_in "$1" list --session live | awk -F '\t' -v id="$2" '$1 == id { print $2 }'
}
row_of() {  # <path> <id>
    tq_in "$1" list --table --session live | grep -F "$2" || true
}
expect_status() {  # <label> <path> <id> <expected>
    local got; got=$(status_of "$2" "$3") || true
    if [ "$got" = "$4" ]; then pass "$1"; else fail "$1 (got '$got')"; fi
}
expect_status "exit file 0 -> done"                        "$NOPY_BIN" "$T_OK" done
expect_status "exit file 1 -> failed"                      "$NOPY_BIN" "$T_BAD" failed
case "$(row_of "$NOPY_BIN" "$T_BAD")" in *'| exit 1 |'*) pass "a failed exit file reports 'exit <code>' as progress" ;;
    *) fail "exit code progress: $(row_of "$NOPY_BIN" "$T_BAD")" ;; esac
expect_status "an empty exit file is treated as absent (-> unknown)" "$NOPY_BIN" "$T_EMPTY" unknown
expect_status "a train task with no exit file and no screen -> unknown, never running" "$STUB_RUN:$NOPY_BIN" "$T_NOEV" unknown
expect_status "screen -ls lists .myrun -> running"         "$STUB_RUN:$NOPY_BIN" "$T_RUN" running
expect_status "screen name match is exact (.myru does not match .myrun)" "$STUB_RUN:$NOPY_BIN" "$T_NEAR" lost
expect_status "12346.exp.train does not match a session named train" "$STUB_RUN:$NOPY_BIN" "$T_DOT" lost
expect_status "a (Dead ???) screen line -> lost"           "$STUB_RUN:$NOPY_BIN" "$T_DEAD" lost
expect_status "an exit file beats a live screen"           "$STUB_RUN:$NOPY_BIN" "$T_BEAT" done
expect_status "tmux has-session on the ._-mapped name -> running" "$STUB_TMUX:$NOPY_BIN" "$T_TMUX" running
expect_status "tmux installed but no such session -> lost" "$STUB_TMUX:$NOPY_BIN" "$T_RUN" lost
case "$(row_of "$STUB_RUN:$NOPY_BIN" "$T_RUN")" in *'| epoch 2 loss 0.5 |'*) pass "a running job's progress is the last non-empty log line" ;;
    *) fail "log progress: $(row_of "$STUB_RUN:$NOPY_BIN" "$T_RUN")" ;; esac
case "$(row_of "$STUB_RUN:$NOPY_BIN" "$T_CR")" in *'|  55%\|#####\| |'*) pass "a \\r progress-bar log shows its newest segment" ;;
    *) fail "\\r log progress: $(row_of "$STUB_RUN:$NOPY_BIN" "$T_CR")" ;; esac
expect_status "screen without the session and no tmux -> lost" "$STUB_NONE:$NOPY_BIN" "$T_RUN" lost
expect_status "no screen and no tmux -> unknown"          "$NOPY_BIN" "$T_RUN" unknown
C=$(tq_in "$STUB_RUN:$NOPY_BIN" count --session live) || true
# open: empty(unknown) noev(unknown) run cr near(lost) dot(lost) dead(lost) tmux(lost) = 8
check "count treats lost/unknown as open and done/failed as closed (8 0)" test "$C" = "8 0"
O=$(tq_in "$STUB_RUN:$NOPY_BIN" list --open --session live | wc -l | tr -d ' ') || true
check "list --open keeps only open tasks" test "$O" = "8"

# existing exit file is refused
echo 0 > "$PROJ/old.code"
run tq start --session live --kind train --title stale --exit-file "$PROJ/old.code"
check "an exit file that already exists is refused (exit 2, nothing written)" \
    test "$RC" -eq 2 -a "$ERR" = "task-queue: exit file already exists (a finished run may still be recorded against it); pass a fresh --exit-file path"
check "the refused start wrote nothing" test "$(grep -c '"ev":"start"' .propel/tasks/live.jsonl || true)" = "11"

# relative paths are anchored at start time
new_proj; mkdir -p sub
run tq start --session rel --kind train --title rel --exit-file rel.code --log rel.log; ID="$OUT"
echo 0 > "$PROJ/rel.code"
check "relative --exit-file/--log are stored as absolute paths" \
    grep -qF "\"log\":\"$PROJ/rel.log\",\"exit_file\":\"$PROJ/rel.code\"" .propel/tasks/rel.jsonl
GOT=$(cd sub && "$SH_BASH" "$TQ" list --session rel | awk -F '\t' '{ print $2 }') || true
check "a task started from the root reads its exit file when listed from sub/" test "$GOT" = "done"

# ── line cap ─────────────────────────────────────────────────────────────────
new_proj
LONG="$PROJ/$(printf 'd%.0s' $(seq 1 380))/exit.code"   # > 400 chars
LONG="${LONG:0:405}"
run tq start --session cap --kind train --title "cap" --exit-file "$LONG" --note "$(printf 'n%.0s' $(seq 1 600))"
check "a 405-char exit path is stored intact (${#LONG} chars)" \
    grep -qF "\"exit_file\":\"$LONG\"" .propel/tasks/cap.jsonl
check "the capped event is at most 1,500 bytes" test "$(head -n 1 .propel/tasks/cap.jsonl | wc -c | tr -d ' ')" -le 1501
P800="$PROJ/$(printf 'p%.0s' $(seq 1 800))"
run tq start --session cap --kind train --title "too big" --log "$P800.log" --exit-file "$P800.code"
check "an event that cannot fit with full paths is rejected (exit 2, 'event too large')" \
    test "$RC" -eq 2 -a "$ERR" = "task-queue: event too large"
check "the rejected event wrote nothing" test "$(nlines .propel/tasks/cap.jsonl)" = "1"

# ── 8. concurrency ───────────────────────────────────────────────────────────
new_proj
for i in 1 2 3 4 5 6 7 8 9 10; do
    ( RC=0; PROPEL_TQ_LOCK_TRIES=100 "$SH_BASH" "$TQ" start --session conc --kind other --title "job $i" \
        > "$WORK/conc.$i" 2>&1 || RC=$?; echo "$RC" > "$WORK/conc.rc.$i" ) &
done
wait
F=.propel/tasks/conc.jsonl
BADRC=$(cat "$WORK"/conc.rc.* | grep -vc '^0$' || true)
LINES=$(nlines "$F")
GOOD=$(grep -c '^{"v":1' "$F" || true)
DISTINCT=$(cat "$WORK"/conc.[0-9]* | grep -E "$ID_RE" | sort -u | wc -l | tr -d ' ') || true
FILE_IDS=$(grep -o '"id":"[^"]*"' "$F" | sort -u | wc -l | tr -d ' ') || true
if [ "$BADRC" = "0" ] && [ "$LINES" = "10" ] && [ "$GOOD" = "10" ] && [ "$DISTINCT" = "10" ] \
   && [ "$FILE_IDS" = "10" ] && [ ! -e .propel/tasks/.lock ]; then
    pass "10 concurrent starts all exit 0 -> 10 well-formed lines, 10 distinct ids, no leftover lock"
else
    fail "concurrency: nonzero-rc=$BADRC lines=$LINES good=$GOOD printed-ids=$DISTINCT file-ids=$FILE_IDS"
    cat "$WORK"/conc.[0-9]*
fi

# ── 9. locks are never cleared automatically; `unlock` clears dead ones ─────
LOCK=.propel/tasks/.lock
BUSY_HINT="If no task-queue is running, run: task-queue.sh unlock"
# (a) dead owner pid
mkdir "$LOCK"; echo "999999 $(( $(date +%s) - 7200 ))" > "$LOCK/owner"
run tq start --session conc --kind other --title "dead owner"
case "$ERR" in
    "task-queue: ledger busy (.propel/tasks/.lock held by pid 999999 since "*"Z). $BUSY_HINT")
        check "a dead owner's lock is not cleared automatically: start exits 3 and names unlock" \
            test "$RC" -eq 3 -a -d "$LOCK" ;;
    *) fail "dead-owner busy message: rc=$RC err='$ERR'" ;;
esac
run tq unlock
check "unlock removes a lock whose owner pid is not running" \
    test "$RC" -eq 0 -a "$OUT" = "unlocked (owner pid 999999 not running)" -a ! -e "$LOCK"
run tq start --session conc --kind other --title "after unlock"
check "start succeeds after unlock" sh -c "[ $RC -eq 0 ] && printf '%s' '$OUT' | grep -Eq '$ID_RE'"
# (b) live owner pid
sleep 30 & SLEEP_PID=$!
mkdir "$LOCK"; echo "$SLEEP_PID $(date +%s)" > "$LOCK/owner"
run tq unlock
check "unlock refuses a lock held by a live pid (exit 3) and leaves it in place" \
    test "$RC" -eq 3 -a "$ERR" = "task-queue: lock held by live pid $SLEEP_PID" -a -f "$LOCK/owner"
kill "$SLEEP_PID" 2>/dev/null || true; wait "$SLEEP_PID" 2>/dev/null || true
rm -rf "$LOCK"
# (c) ownerless lock, plus a leftover rename target from an older version
mkdir "$LOCK" .propel/tasks/.lock.stale.4242
run tq unlock
check "unlock removes an ownerless lock and leftover .lock.stale.* dirs" \
    test "$RC" -eq 0 -a "$OUT" = "unlocked (no owner record)" -a ! -e "$LOCK" -a ! -e .propel/tasks/.lock.stale.4242
# (d) no lock
run tq unlock
check "unlock with no lock prints 'not locked', rc 0" test "$RC" -eq 0 -a "$OUT" = "not locked"
mkdir -p "$WORK/nolock-proj/.propel"
NL=$(cd "$WORK/nolock-proj" && "$SH_BASH" "$TQ" unlock) || NL="rc=$?"
check "unlock with no .propel/tasks at all prints 'not locked'" test "$NL" = "not locked"
# (e) no flags, no arguments
run tq unlock --session x
check "unlock rejects any flag (exit 2)" test "$RC" -eq 2
run tq unlock --force
check "unlock rejects an unknown flag (exit 2)" test "$RC" -eq 2
run tq unlock now
check "unlock rejects a positional argument (exit 2)" test "$RC" -eq 2

# ── 10. fresh locks ──────────────────────────────────────────────────────────
mkdir "$LOCK"
T0=$(date +%s)
run tq start --session conc --kind other --title "blocked"
T1=$(date +%s)
check "an ownerless lock -> exit 3 within 5 s ($((T1 - T0)) s), message without pid, lock kept" \
    test "$RC" -eq 3 -a $((T1 - T0)) -le 5 -a -d "$LOCK" \
         -a "$ERR" = "task-queue: ledger busy (.propel/tasks/.lock). $BUSY_HINT"
echo "99999 $(date +%s)" > "$LOCK/owner"
run tq start --session conc --kind other --title "blocked again"
case "$ERR" in
    "task-queue: ledger busy (.propel/tasks/.lock held by pid 99999 since "*) RIGHT_MSG=1 ;;
    *) RIGHT_MSG=0 ;;
esac
check "an owned lock -> exit 3 naming its pid, and the lock is left intact" \
    test "$RC" -eq 3 -a "$RIGHT_MSG" -eq 1 -a "$(cut -d' ' -f1 "$LOCK/owner" 2>/dev/null)" = "99999"
rm -rf "$LOCK"
check "busy starts wrote nothing" test "$(nlines "$F")" = "11"

# ── 11. identical results without python3 (bash 3.2 + BWK awk on macOS) ─────
scenario() {  # <runner...>  runs the core commands in the current dir
    local a b
    a=$("$@" start --session alpha --kind impl --title "build it" --ref "Task 3" --progress "1/4")
    "$@" update "$a" --progress "2/4" --note "halfway" --session beta
    b=$("$@" start --session alpha --kind validate --title "check | it")
    "$@" done "$b" --status failed --note "no"
    "$@" carry "$a" --session beta
    "$@" list --table --session beta
    "$@" list --table --open --session gamma
    "$@" list --session alpha | cut -f 2,3,4
    "$@" count --session beta
    "$@" count --session gamma
    "$@" count
}
normalize() { sed -E 's/t[0-9]{6}-[0-9]{6}-[0-9a-f]{4}/ID/g; s/[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}Z/STAMP/g'; }
new_proj; RC=0; FULL=$(scenario tq 2>&1 | normalize) || RC=$?
new_proj; NOPY=$(scenario tq_in "$NOPY_BIN" 2>&1 | normalize) || RC=$?
if [ "$RC" -eq 0 ] && [ -n "$FULL" ] && [ "$FULL" = "$NOPY" ]; then
    pass "start/update/done/carry/list/count give identical output without python3"
else
    fail "no-python3 run differs (rc=$RC)"
    printf -- '--- full PATH\n%s\n--- restricted PATH\n%s\n' "$FULL" "$NOPY"
fi
case "$FULL" in
    *'| ID | build it (Task 3) | impl | running | 2/4 | STAMP | alpha (carried here) |'*) pass "scenario table has the expected row" ;;
    *) fail "scenario table row: $FULL" ;;
esac

# ── 12. --sessions / --days window ───────────────────────────────────────────
new_proj
run tq start --session oldc --kind impl --title "old closed"; run tq done "$OUT" --status done
run tq start --session oldo --kind impl --title "old open"
run tq start --session new --kind impl --title "new closed"; run tq done "$OUT" --status done
touch -t "$(stamp_ago 30d '30 days ago')" .propel/tasks/oldc.jsonl .propel/tasks/oldo.jsonl
L_DEF=$(tq list --session now | cut -f 4 | sort | tr '\n' ' ') || true
L_60=$(tq list --session now --days 60 | cut -f 4 | sort | tr '\n' ' ') || true
L_S1=$(tq list --session now --days 60 --sessions 1 | cut -f 4 | sort | tr '\n' ' ') || true
C_DEF=$(tq count --session now) || true
check "a 30-day-old file with only closed tasks is dropped by default ('$L_DEF')" test "$L_DEF" = "new oldo "
check "--days 60 brings it back ('$L_60')" test "$L_60" = "new oldc oldo "
check "--sessions 1 keeps the newest file plus files with open tasks ('$L_S1')" test "$L_S1" = "new oldo "
check "count always sees open tasks in old files ('$C_DEF')" test "$C_DEF" = "0 1"
run tq list --table --session oldc --days 1 --sessions 1
case "$OUT" in *"| old closed |"*) pass "the current session's file is always read" ;; *) fail "current file: $OUT" ;; esac
mkdir -p "$WORK/empty-proj/.propel"
NONE=$(cd "$WORK/empty-proj" && "$SH_BASH" "$TQ" list --table) || true
check "an empty ledger prints 'No tasks recorded.'" test "$NONE" = "No tasks recorded."
NOOPEN=$(cd "$WORK/empty-proj" && "$SH_BASH" "$TQ" list --table --open) || true
check "an empty --open list prints 'No open tasks.'" test "$NOOPEN" = "No open tasks."

# ── 13. root discovery ───────────────────────────────────────────────────────
new_proj; mkdir -p "$PROJ/src/deep/er"; cd "$PROJ/src/deep/er"
run tq start --session sub --kind impl --title "from below"
check "running from a subdirectory writes to the project's .propel/tasks/" \
    test "$RC" -eq 0 -a -f "$PROJ/.propel/tasks/sub.jsonl" -a ! -e "$PROJ/src/deep/er/.propel"
ANCESTOR_PROPEL=""
d="$WORK"; while [ "$d" != "/" ]; do d=$(dirname "$d"); [ -d "$d/.propel" ] && ANCESTOR_PROPEL="$d"; done
if ! command -v git >/dev/null 2>&1; then
    echo "SKIP: git not available for the git-root test"
elif [ -n "$ANCESTOR_PROPEL" ]; then
    echo "SKIP: git-root test ($ANCESTOR_PROPEL/.propel is an ancestor of the temp dir)"
else
    G=$(mktemp -d "$WORK/git.XXXXXX"); git -C "$G" init -q . || true; mkdir -p "$G/a/b"; cd "$G/a/b"
    run tq start --session g --kind impl --title "git root"
    check "without .propel/, the git top level is the root" test -f "$G/.propel/tasks/g.jsonl"
fi

# ── strict input: every exit-2 path ──────────────────────────────────────────
new_proj
run tq start --session v --kind impl --title "ok"; ID="$OUT"
expect_rc2() {  # <label> <expected-stderr-substring> <args...>
    local label="$1" want="$2"; shift 2
    run tq "$@"
    case "$ERR" in
        *"$want"*) [ "$RC" -eq 2 ] && { pass "$label"; return; } ;;
    esac
    fail "$label (rc=$RC err='$ERR')"
}
expect_rc2 "bad --kind -> exit 2"           "invalid --kind"        start --session v --kind gpu --title x
expect_rc2 "missing --title -> exit 2"      "--title is required"   start --session v --kind impl
expect_rc2 "bad done --status -> exit 2"    "invalid --status"      done "$ID" --status finished
expect_rc2 "missing done --status -> exit 2" "--status is required" done "$ID"
expect_rc2 "bad update --status -> exit 2"  "must be running or blocked" update "$ID" --status done
expect_rc2 "unknown flag -> exit 2"         "unknown flag: --bogus" list --bogus
expect_rc2 "flag not valid for the command -> exit 2" "flag --kind not valid for list" list --kind train
expect_rc2 "--days is not valid for count -> exit 2"  "flag --days not valid for count" count --days 3
expect_rc2 "unknown command -> exit 2"      "unknown command: frobnicate" frobnicate
expect_rc2 "missing id -> exit 2"           "done: missing task id" done --status done
expect_rc2 "a second positional -> exit 2"  "unexpected argument: extra" update "$ID" extra --note x
expect_rc2 "update with nothing to record -> exit 2" "at least one non-empty" update "$ID"
expect_rc2 "a flag missing its value -> exit 2" "needs a value" update "$ID" --note
check "rejected commands wrote nothing" test "$(nlines .propel/tasks/v.jsonl)" = "1"
run tq help
check "help exits 0 and lists lost/unknown and exit code 5" \
    sh -c "[ $RC -eq 0 ] && printf '%s' \"\$1\" | grep -q 'lost' && printf '%s' \"\$1\" | grep -q '5 I/O'" _ "$OUT"

# ── corrupt lines ────────────────────────────────────────────────────────────
printf '%s\n' 'not json at all' '{"v":1,"ts":"x","ev":"start","id":"tbroken' '{"v":2,"ev":"start","id":"tv2"}' \
    '{"v":1,"ts":"2026-01-01T00:00:00Z","ev":"done","id":"'"$ID"'","status":"done"' >> .propel/tasks/v.jsonl
run tq list --session v
if [ "$RC" -eq 0 ] && [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = "1" ] \
   && printf '%s' "$OUT" | grep -qF "$ID	running	"; then
    pass "corrupt, foreign-version and truncated lines are skipped"
else
    fail "corrupt lines: rc=$RC out='$OUT'"
fi

# ── strict values (round 2) ──────────────────────────────────────────────────
V_BEFORE=$(nlines .propel/tasks/v.jsonl)
expect_rc2 "non-numeric --sessions -> exit 2"  "--sessions must be a whole number" list --sessions abc
expect_rc2 "non-numeric --days -> exit 2"      "--days must be a whole number"     list --days 1.5
expect_rc2 "--sessions over 1000 -> exit 2"    "--sessions must be at most 1000"   list --sessions 1001
expect_rc2 "update with only empty values -> exit 2" "at least one non-empty" update "$ID" --note "" --progress ""
expect_rc2 "a tab in --exit-file -> exit 2"    "path contains a control character" \
    start --session v --kind train --title t --exit-file "$(printf 'a\tb')"
expect_rc2 "a newline in --screen -> exit 2"   "path contains a control character" \
    start --session v --kind train --title t --screen "$(printf 'a\nb')"
run env PROPEL_SESSION=v "$SH_BASH" "$TQ" start --session "" --kind impl --title x
check "an explicit --session \"\" on start exits 2 even with PROPEL_SESSION set" test "$RC" -eq 2
run env PROPEL_SESSION=v "$SH_BASH" "$TQ" carry "$ID" --session ""
check "an explicit --session \"\" on carry exits 2" test "$RC" -eq 2
run env PROPEL_SESSION=v "$SH_BASH" "$TQ" count --session ""
check "count --session \"\" means no session, not \$PROPEL_SESSION ('$OUT')" test "$RC" -eq 0 -a "$OUT" = "0 1"
check "rejected commands still wrote nothing" test "$(nlines .propel/tasks/v.jsonl)" = "$V_BEFORE"

# ── settle on read (D3) ──────────────────────────────────────────────────────
new_proj
run tq start --session st --kind train --title settle --exit-file "$PROJ/E"; T1="$OUT"
echo 0 > "$PROJ/E"
run tq list --session st; FIRST="$OUT"
check "list derives done from the exit file" sh -c "printf '%s' '$FIRST' | grep -qF '$T1	done	'"
check "the read appended a settling done event to the owner file" \
    grep -qF "\"ev\":\"done\",\"id\":\"$T1\",\"session\":\"st\",\"status\":\"done\",\"progress\":\"exit 0\",\"note\":\"settled from exit file (exit 0)\"" .propel/tasks/st.jsonl
rm -f "$PROJ/E"
run tq list --session st
check "after the exit file is removed the task still shows done" test "$RC" -eq 0 -a "$OUT" = "$FIRST"
run tq list --session st
check "a settled task is not settled again" test "$(grep -c '"ev":"done"' .propel/tasks/st.jsonl || true)" = "1"

new_proj
run tq start --session sb --kind train --title busy --exit-file "$PROJ/E"; T2="$OUT"
echo 1 > "$PROJ/E"
mkdir .propel/tasks/.lock; echo "99999 $(date +%s)" > .propel/tasks/.lock/owner
T0=$(date +%s)
run tq list --table --session sb; BUSY_OUT="$OUT"; BUSY_RC=$RC
T1s=$(date +%s)
check "with the lock held, list still shows failed, rc 0, without waiting ($((T1s - T0)) s)" \
    sh -c "[ $BUSY_RC -eq 0 ] && [ $((T1s - T0)) -le 1 ] && printf '%s' \"\$1\" | grep -qF '| failed | exit 1 |'" _ "$BUSY_OUT"
check "with the lock held, nothing is written and the lock is untouched" \
    test "$(nlines .propel/tasks/sb.jsonl)" = "1" -a "$(cut -d' ' -f1 .propel/tasks/.lock/owner)" = "99999"
rm -rf .propel/tasks/.lock
run tq list --table --session sb
check "the read output is the same whether or not the settle write happened" test "$OUT" = "$BUSY_OUT"
check "the next read with a free lock settles it" grep -qF '"status":"failed","progress":"exit 1"' .propel/tasks/sb.jsonl

new_proj
run tq start --session old3 --kind train --title "old run" --exit-file "$PROJ/E"; T3="$OUT"
echo 0 > "$PROJ/E"
touch -t "$(stamp_ago 30d '30 days ago')" .propel/tasks/old3.jsonl
run tq list --session now
check "an old file holding a running train task is shown (open as of the fold)" \
    sh -c "printf '%s' '$OUT' | grep -qF '$T3	done	'"
# The settle write refreshes the file's mtime; age it again to test the window.
touch -t "$(stamp_ago 30d '30 days ago')" .propel/tasks/old3.jsonl
run tq list --session now
check "once settled, the old file drops out of the default window" test "$RC" -eq 0 -a -z "$OUT"

# ── settle races (D4) ────────────────────────────────────────────────────────
# A recorded terminal status always wins over the exit file.
new_proj
run tq start --session rc --kind train --title "abandoned first" --exit-file "$PROJ/E0"; TQ0="$OUT"
echo 0 > "$PROJ/E0"
run tq done "$TQ0" --status abandoned
run tq list --session rc
check "a task abandoned before the read shows abandoned" sh -c "printf '%s' '$OUT' | grep -qF '$TQ0	abandoned	'"
check "... and no settle line is appended" \
    test "$(grep -c 'settled from exit file' .propel/tasks/rc.jsonl || true)" = "0"

# The real race: an event lands between this read's fold and its settle.
# PROPEL_TQ_TEST_PRE_SETTLE is a test-only hook in the script that runs a
# command at exactly that point (see the comment beside it in cmd_list).
run tq start --session rc --kind train --title "raced" --exit-file "$PROJ/E1"; TQ1="$OUT"
echo 0 > "$PROJ/E1"
run env PROPEL_TQ_TEST_PRE_SETTLE="'$SH_BASH' '$TQ' abandon $TQ1 --note raced" "$SH_BASH" "$TQ" list --session rc
check "the racing read prints its own snapshot (done from the exit file)" \
    sh -c "printf '%s' '$OUT' | grep -qF '$TQ1	done	'"
check "the settle is skipped when the task was abandoned after the fold" \
    test "$(grep -c 'settled from exit file' .propel/tasks/rc.jsonl || true)" = "0"
run tq list --session rc
check "the next read shows abandoned" sh -c "printf '%s' '$OUT' | grep -qF '$TQ1	abandoned	'"

run tq start --session rc --kind train --title "late note" --exit-file "$PROJ/E2"; TQ2="$OUT"
echo 0 > "$PROJ/E2"
run env PROPEL_TQ_TEST_PRE_SETTLE="'$SH_BASH' '$TQ' update $TQ2 --note late" "$SH_BASH" "$TQ" list --session rc
check "the settle is skipped when the event count changed, even if still running" \
    test "$(grep -c 'settled from exit file' .propel/tasks/rc.jsonl || true)" = "0"
run tq list --session rc
check "a later undisturbed read settles it" \
    grep -qF "\"ev\":\"done\",\"id\":\"$TQ2\",\"session\":\"rc\",\"status\":\"done\"" .propel/tasks/rc.jsonl

# ── more exit-file values ────────────────────────────────────────────────────
new_proj
run tq start --session ef --kind train --title abc --exit-file "$PROJ/abc.code"; TA="$OUT"
run tq start --session ef --kind train --title big --exit-file "$PROJ/big.code"; TB="$OUT"
echo abc > "$PROJ/abc.code"; echo 12345678901 > "$PROJ/big.code"
run tq list --session ef
check "a non-numeric exit file ('abc') falls through (-> unknown)" \
    sh -c "printf '%s' '$OUT' | grep -qF '$TA	unknown	'"
check "an exit code longer than 10 digits counts as non-numeric (-> unknown)" \
    sh -c "printf '%s' '$OUT' | grep -qF '$TB	unknown	'"
check "non-numeric exit files settle nothing" test "$(grep -c '"ev":"done"' .propel/tasks/ef.jsonl || true)" = "0"

# ── screen names (round 2) ───────────────────────────────────────────────────
new_proj
STUB_MORE="$WORK/stub-more"; mkdir -p "$STUB_MORE"
cat > "$STUB_MORE/screen" <<'EOF'
#!/bin/sh
printf 'There are screens on:\n\t12347.DeadlineRun\t(Detached)\n\t12348.a b\t(Detached)\n2 Sockets in /tmp/screens/S-u.\n'
exit 1
EOF
chmod +x "$STUB_MORE/screen"
export PROPEL_SESSION=scr
run tq_in "$NOPY_BIN" start --kind train --title dl --screen DeadlineRun; TD="$OUT"
run tq_in "$NOPY_BIN" start --kind train --title ab --screen a; TAB="$OUT"
run tq_in "$NOPY_BIN" start --kind train --title "a b" --screen "a b"; TAB2="$OUT"
unset PROPEL_SESSION
expect_status_s() {  # <label> <id> <expected>
    local got; got=$(tq_in "$STUB_MORE:$NOPY_BIN" list --session scr | awk -F '\t' -v id="$2" '$1 == id { print $2 }') || true
    if [ "$got" = "$3" ]; then pass "$1"; else fail "$1 (got '$got')"; fi
}
expect_status_s "a live 12347.DeadlineRun line is running (only the status text is checked for Dead)" "$TD" running
expect_status_s "a live session 'a b' does not count for --screen a" "$TAB" lost
expect_status_s "a live session 'a b' counts for --screen 'a b'" "$TAB2" running

# ── partial last line ────────────────────────────────────────────────────────
new_proj
run tq start --session pl --kind impl --title partial; TP="$OUT"
printf '%s' '{"v":1,"ts":"2026-01-01T00:00:00Z","ev":"upd' >> .propel/tasks/pl.jsonl
run tq update "$TP" --progress "after the cut"
run tq list --table --session pl
case "$OUT" in *'| after the cut |'*) pass "an update after a truncated last line starts on a new line and is read" ;;
    *) fail "partial last line: $OUT / $(cat .propel/tasks/pl.jsonl)" ;; esac
check "the fragment stays on its own line" test "$(nlines .propel/tasks/pl.jsonl)" = "3"

# ── unreadable ledger parts -> exit 5 ────────────────────────────────────────
new_proj
run tq start --session r1 --kind impl --title one
run tq start --session r2 --kind impl --title two
run tq start --session r3 --kind impl --title three
chmod 000 .propel/tasks/r2.jsonl
if [ -r .propel/tasks/r2.jsonl ]; then
    echo "SKIP: unreadable-file test (running with privileges that ignore chmod 000)"
else
    run tq count --session r1
    check "one unreadable file of three: count still counts the other two ('$OUT')" test "$OUT" = "1 1"
    check "... and exits 5 with one stderr line" \
        sh -c "[ $RC -eq 5 ] && printf '%s' \"\$1\" | grep -q 'cannot read' && [ \$(printf '%s\n' \"\$1\" | wc -l) -eq 1 ]" _ "$ERR"
    run tq list --session r1
    check "list also prints what it could read and exits 5" \
        sh -c "[ $RC -eq 5 ] && [ \$(printf '%s\n' \"\$1\" | wc -l) -eq 2 ]" _ "$OUT"
    chmod 644 .propel/tasks/r2.jsonl
    chmod 000 .propel/tasks
    run tq count --session r1
    chmod 755 .propel/tasks
    check "an unreadable .propel/tasks -> count prints '0 0' and exits 5" test "$RC" -eq 5 -a "$OUT" = "0 0"
fi
chmod 755 .propel/tasks 2>/dev/null || true; chmod 644 .propel/tasks/r2.jsonl 2>/dev/null || true

# ── performance ──────────────────────────────────────────────────────────────
new_proj; mkdir -p .propel/tasks
for s in 0 1 2 3 4 5 6 7 8 9; do
    awk -v s="$s" 'BEGIN {
        for (i = 0; i < 150; i++) {
            id = sprintf("t261117-%06d-%04x", s, i)
            printf "{\"v\":1,\"ts\":\"2026-11-17T00:00:00Z\",\"ev\":\"start\",\"id\":\"%s\",\"session\":\"s%d\",\"kind\":\"impl\",\"title\":\"seeded task %d with a moderately long title\",\"status\":\"running\",\"ref\":\"plan task %d\"}\n", id, s, i, i
            printf "{\"v\":1,\"ts\":\"2026-11-17T00:00:01Z\",\"ev\":\"done\",\"id\":\"%s\",\"session\":\"s%d\",\"status\":\"done\",\"note\":\"finished cleanly\"}\n", id, s
        }
    }' > ".propel/tasks/s$s.jsonl"
done
run tq start --session s0 --kind impl --title "still open"
T0=$(date +%s)
RC=0; C=$("$SH_BASH" "$TQ" count --session s0 < /dev/null) || RC=$?
T1=$(date +%s)
check "count on a 10 x 300-line ledger is correct ('$C') and takes <= 1 s ($((T1 - T0)) s)" \
    test "$RC" -eq 0 -a "$C" = "1 0" -a $((T1 - T0)) -le 1

cd "$PLUGIN_DIR"

echo ""
if [ "$FAILS" -gt 0 ]; then
    echo "$FAILS test(s) FAILED"
    exit 1
fi
echo "All task-queue tests passed."
