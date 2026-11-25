#!/usr/bin/env bash
# Propel — session-scoped task ledger
#
# An on-disk record of tasks in flight (GPU training jobs, plan implementation
# tasks, monitor loops) so a later Claude session can see what is still open.
# This script is the ONLY writer of the ledger: a model that wants a task on
# record calls it, and nothing else edits the files.
#
# Layout: one file per Claude Code session, .propel/tasks/<session>.jsonl, of
# append-only JSONL events (start | update | done | carry). A task's state is
# the fold of its events. Every event for a task -- including updates and carries
# made from other sessions -- is appended to the file that holds its `start`
# event, so one file always tells a task's whole story.
#
# Usage:
#   task-queue.sh start --kind train|impl|validate|monitor|other --title T
#         [--session S] [--ref R] [--screen NAME] [--log PATH]
#         [--exit-file PATH] [--cmd CMD] [--progress P] [--note N]
#         -> prints the new task id on stdout
#   task-queue.sh update ID [--progress P] [--note N] [--status running|blocked]
#   task-queue.sh done ID --status done|failed|blocked|abandoned [--note N]
#   task-queue.sh abandon ID [--note N]
#   task-queue.sh carry ID [--session S]
#   task-queue.sh list [--open] [--sessions N] [--days D] [--table] [--session S]
#   task-queue.sh count [--session S]      -> "<open_here> <open_earlier>"
#   task-queue.sh unlock                   clear a lock left by a dead writer
#   task-queue.sh help
#
# Session: --session wins, else $PROPEL_SESSION. start and carry need one.
#
# Statuses. Recorded: running, blocked, done, failed, abandoned. A train task
# whose recorded status is running gets a derived status instead:
#   exit file with a numeric first line -> done (0) / failed (other)
#   else screen/tmux name recorded      -> running (alive) / lost (not alive) /
#                                          unknown (neither tool installed)
#   else                                -> unknown (never running without evidence)
# Open = running | blocked | lost | unknown. Open tasks are always listed: the
# --sessions/--days window only drops files that hold no open task.
# Settle on read: when a reader derives done/failed from an exit file, it
# appends a done event to the owner file (best effort: one lock attempt, no
# wait), so the result outlives the exit file and the file stops counting as
# open. Readers that cannot read part of the ledger print what they could read
# and exit 5.
#
# Needs only bash (3.2+), coreutils-level tools and a POSIX awk -- no python3,
# jq, flock or mktemp. Concurrency is a mkdir lock around every append;
# PROPEL_TQ_LOCK_TRIES (default 20, 0.1 s apart) sets the wait budget. A lock
# is never cleared automatically; `unlock` clears one whose owner is dead.
# Known limit (accepted at Gate 3): unlock checks the owner and then removes the
# path; without an atomic compare-and-swap, two unlocks racing can remove a lock
# a live writer took in between. unlock is a manual, run-once recovery command.
#
# Exit codes: 0 ok, 1 interrupted by a signal, 2 usage / no session / event too
# large, 3 ledger busy (or: unlock refused, owner alive), 4 unknown id, 5 I/O
# or permission failure.
# Errors are one line on stderr.

set -uo pipefail

PROG="task-queue"

die() {  # <code> <message>
  printf '%s: %s\n' "$PROG" "$2" >&2
  exit "$1"
}

usage() {
  cat <<'EOF'
task-queue.sh — Propel session task ledger (.propel/tasks/<session>.jsonl)

  start --kind train|impl|validate|monitor|other --title T
        [--session S] [--ref R] [--screen NAME] [--log PATH]
        [--exit-file PATH] [--cmd CMD] [--progress P] [--note N]
                                 record a new task; prints its id
  update ID [--progress P] [--note N] [--status running|blocked]
  done ID --status done|failed|blocked|abandoned [--note N]
  abandon ID [--note N]          same as: done ID --status abandoned
  carry ID [--session S]         mark an earlier session's task as resumed here
  list [--open] [--sessions N] [--days D] [--table] [--session S]
  count [--session S]            prints "<open_here> <open_earlier>"
  unlock                         remove .propel/tasks/.lock if its owner pid is
                                 not running (refuses, exit 3, if it is).
                                 Run it once, by hand: two concurrent unlocks
                                 can remove a lock a live writer just took.
  help

Session: --session wins, else $PROPEL_SESSION.
Statuses: running, blocked, done, failed, abandoned; a running train task is
shown as derived from its exit file / screen / tmux: done, failed, running,
lost (session gone) or unknown (no evidence). Open = running, blocked, lost,
unknown; open tasks are always listed, whatever --sessions/--days say.
A done/failed result read from an exit file is recorded on read.
--sessions: 1-1000; --session "" means no session (start/carry then exit 2).
Exit codes: 0 ok, 1 signal, 2 usage / no session / event too large,
3 ledger busy / unlock refused, 4 unknown id, 5 I/O or permission failure.
EOF
}

# ── argument parsing ─────────────────────────────────────────────────────────
CMD="${1:-}"
[ $# -gt 0 ] && shift

KNOWN_FLAGS="--session --kind --title --ref --screen --log --exit-file --cmd --progress --note --status --sessions --days --open --table"
case "$CMD" in
  start)   ALLOWED="--session --kind --title --ref --screen --log --exit-file --cmd --progress --note"; NPOS=0 ;;
  update)  ALLOWED="--session --progress --note --status"; NPOS=1 ;;
  done)    ALLOWED="--session --status --note"; NPOS=1 ;;
  abandon) ALLOWED="--session --note"; NPOS=1 ;;
  carry)   ALLOWED="--session"; NPOS=1 ;;
  list)    ALLOWED="--session --open --sessions --days --table"; NPOS=0 ;;
  count)   ALLOWED="--session"; NPOS=0 ;;
  unlock)  ALLOWED=""; NPOS=0 ;;
  help|-h|--help) usage; exit 0 ;;
  '')      usage >&2; exit 2 ;;
  *)       die 2 "unknown command: $CMD (try: task-queue.sh help)" ;;
esac

RAW_ID="" NPOS_SEEN=0
SESSION_ARG="" SESSION_SET=0
KIND="" TITLE="" REF="" SCREEN="" LOGF="" EXITF="" CMDSTR="" PROGRESS="" NOTE="" STATUS=""
OPEN_ONLY=0 TABLE=0 NSESSIONS=10 NDAYS=14

while [ $# -gt 0 ]; do
  # Every branch consumes at least one argument or exits, so the loop can
  # never spin on a trailing flag.
  case "$1" in
    --*)
      FLAG="$1"
      case " $KNOWN_FLAGS " in *" $FLAG "*) ;; *) die 2 "unknown flag: $FLAG" ;; esac
      case " $ALLOWED " in *" $FLAG "*) ;; *) die 2 "flag $FLAG not valid for $CMD" ;; esac
      case "$FLAG" in
        --open)  OPEN_ONLY=1; shift; continue ;;
        --table) TABLE=1; shift; continue ;;
      esac
      [ $# -ge 2 ] || die 2 "flag $FLAG needs a value"
      VAL="$2"; shift 2
      case "$FLAG" in
        --session)   SESSION_ARG="$VAL"; SESSION_SET=1 ;;
        --kind)      KIND="$VAL" ;;
        --title)     TITLE="$VAL" ;;
        --ref)       REF="$VAL" ;;
        --screen)    SCREEN="$VAL" ;;
        --log)       LOGF="$VAL" ;;
        --exit-file) EXITF="$VAL" ;;
        --cmd)       CMDSTR="$VAL" ;;
        --progress)  PROGRESS="$VAL" ;;
        --note)      NOTE="$VAL" ;;
        --status)    STATUS="$VAL" ;;
        --sessions)  NSESSIONS="$VAL" ;;
        --days)      NDAYS="$VAL" ;;
      esac
      ;;
    *)
      NPOS_SEEN=$((NPOS_SEEN + 1))
      [ "$NPOS_SEEN" -le "$NPOS" ] || die 2 "unexpected argument: $1"
      RAW_ID="$1"; shift
      ;;
  esac
done

case "$NSESSIONS" in ''|*[!0-9]*) die 2 "--sessions must be a whole number" ;; esac
case "$NDAYS" in ''|*[!0-9]*) die 2 "--days must be a whole number" ;; esac
# Length checks first, so the numeric tests below cannot overflow.
{ [ "${#NSESSIONS}" -gt 4 ] || [ "$NSESSIONS" -gt 1000 ]; } && die 2 "--sessions must be at most 1000"
[ "${#NDAYS}" -gt 9 ] && die 2 "--days is too large"
[ "$NSESSIONS" -lt 1 ] && NSESSIONS=1
[ "$NDAYS" -lt 1 ] && NDAYS=1

LOCK_TRIES="${PROPEL_TQ_LOCK_TRIES:-20}"
case "$LOCK_TRIES" in ''|*[!0-9]*) LOCK_TRIES=20 ;; esac
[ "$LOCK_TRIES" -lt 1 ] && LOCK_TRIES=1

# Session id: [A-Za-z0-9._-], no leading dots (a dot-file would be invisible to
# the *.jsonl glob), at most 64 chars; empty after sanitizing = no session.
# An explicit --session wins even when empty: `--session ""` means "no
# session" and never falls back to $PROPEL_SESSION.
if [ "$SESSION_SET" -eq 1 ]; then
  SESSION="$SESSION_ARG"
else
  SESSION="${PROPEL_SESSION:-}"
fi
SESSION=$(printf '%s' "$SESSION" | LC_ALL=C tr -cd 'A-Za-z0-9._-')
while [ "${SESSION:0:1}" = "." ]; do SESSION="${SESSION#.}"; done
SESSION="${SESSION:0:64}"

if [ "$NPOS" -eq 1 ]; then
  [ -n "$RAW_ID" ] || die 2 "$CMD: missing task id"
fi
# Task ids are generated as t<YYMMDD>-<HHMMSS>-<hex>; anything else cannot match.
ID=$(printf '%s' "$RAW_ID" | LC_ALL=C tr -cd 'A-Za-z0-9-')
if [ "$NPOS" -eq 1 ] && [ -z "$ID" ]; then
  die 4 "unknown task id: $RAW_ID"
fi

# ── project root ─────────────────────────────────────────────────────────────
find_root() {
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "${CLAUDE_PROJECT_DIR}/.propel" ]; then
    ROOT="$CLAUDE_PROJECT_DIR"; return
  fi
  local d="$PWD"
  while :; do
    if [ -d "$d/.propel" ]; then ROOT="$d"; return; fi
    [ "$d" = "/" ] || [ -z "$d" ] && break
    d=$(dirname "$d")
  done
  ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
  [ -n "$ROOT" ] && [ -d "$ROOT" ] || ROOT="$PWD"
}
find_root
TASKDIR="$ROOT/.propel/tasks"
LOCKDIR="$TASKDIR/.lock"

# ── lock ─────────────────────────────────────────────────────────────────────
# mkdir is the atomic test-and-set; $LOCKDIR/owner holds "<pid> <epoch>" so a
# lock can be attributed (see unlock), and so we only ever release our own.
HAVE_LOCK=0

# read_owner: OWNER_PID / OWNER_EPOCH from $LOCKDIR/owner ("" when the file is
# missing, unreadable or malformed). Silent on every path.
read_owner() {
  OWNER_PID="" OWNER_EPOCH=""
  local p="" e=""
  if [ -r "$LOCKDIR/owner" ]; then
    { read -r p e < "$LOCKDIR/owner"; } 2>/dev/null || true
  fi
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  OWNER_PID="$p"
  case "$e" in ''|*[!0-9]*) ;; *) OWNER_EPOCH="$e" ;; esac
  return 0
}

release_lock() {
  if [ "$HAVE_LOCK" -eq 1 ]; then
    HAVE_LOCK=0
    # Only ever remove a lock whose owner record is ours.
    if read_owner && [ "$OWNER_PID" = "$$" ]; then
      rm -f "$LOCKDIR/owner" 2>/dev/null
      rmdir "$LOCKDIR" 2>/dev/null
    fi
  fi
  return 0
}
trap release_lock EXIT
trap 'exit 1' INT TERM HUP

# Record ownership right after a successful mkdir. On failure the lock is
# removed again, so a failed writer never leaves an ownerless lock behind.
claim_lock() {
  if printf '%s %s\n' "$$" "$(date +%s)" > "$LOCKDIR/owner" 2>/dev/null; then
    HAVE_LOCK=1; return 0
  fi
  rm -f "$LOCKDIR/owner" 2>/dev/null
  rmdir "$LOCKDIR" 2>/dev/null
  return 1
}

# A lock is never cleared automatically: no age rule can tell a dead writer
# from a slow one without racing it. A lock that outlives its writer is
# cleared by a human with `task-queue.sh unlock`, which checks the owner pid.
acquire_lock() {  # TASKDIR must exist
  local tries=0 held="" since=""
  while [ "$tries" -lt "$LOCK_TRIES" ]; do
    if mkdir "$LOCKDIR" 2>/dev/null; then
      claim_lock || die 5 "cannot write $LOCKDIR/owner"
      return 0
    fi
    [ -d "$TASKDIR" ] || die 5 "cannot create $LOCKDIR"
    tries=$((tries + 1))
    sleep 0.1 2>/dev/null || true
  done
  if read_owner; then
    held=" held by pid $OWNER_PID"
    if [ -n "$OWNER_EPOCH" ]; then
      since=$(date -u -r "$OWNER_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) \
        || since=$(date -u -d "@$OWNER_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || since=""
      [ -n "$since" ] && held="$held since $since"
    fi
  fi
  die 3 "ledger busy (.propel/tasks/.lock$held). If no task-queue is running, run: task-queue.sh unlock"
}

# One mkdir attempt, no waiting: for best-effort writes made by readers
# (settle on read), which must never delay or fail a read.
try_lock_once() {
  [ -d "$TASKDIR" ] || return 1
  mkdir "$LOCKDIR" 2>/dev/null || return 1
  claim_lock
}

pid_alive() {  # <pid>: kill -0 works, or fails only for lack of permission
  local err
  err=$(kill -0 "$1" 2>&1) && return 0
  case "$err" in *[Pp]ermitted*|*[Pp]ermission*) return 0 ;; esac
  return 1
}

cmd_unlock() {
  # Leftover rename targets from older versions' stale-lock breaking.
  rm -rf "$TASKDIR"/.lock.stale.* 2>/dev/null
  if [ ! -d "$LOCKDIR" ]; then
    echo "not locked"; return 0
  fi
  if read_owner; then
    pid_alive "$OWNER_PID" && die 3 "lock held by live pid $OWNER_PID"
    rm -rf "$LOCKDIR" 2>/dev/null || die 5 "cannot remove $LOCKDIR"
    [ -e "$LOCKDIR" ] && die 5 "cannot remove $LOCKDIR"
    echo "unlocked (owner pid $OWNER_PID not running)"
  else
    rm -rf "$LOCKDIR" 2>/dev/null || die 5 "cannot remove $LOCKDIR"
    [ -e "$LOCKDIR" ] && die 5 "cannot remove $LOCKDIR"
    echo "unlocked (no owner record)"
  fi
}

# ── JSON encoding ────────────────────────────────────────────────────────────
# Literal replace-all via prefix/suffix stripping. Pattern substitution
# (${s//a/b}) treats backslashes and & in the replacement differently across
# bash 3.2 / 4 / 5.2, so it is avoided for anything involving backslashes.
replace_all() {  # <string> <from> <to>  -> REPLY
  local s="$1" from="$2" to="$3" out=""
  if [ -z "$from" ]; then REPLY="$s"; return 0; fi
  while :; do
    case "$s" in
      *"$from"*) out="$out${s%%"$from"*}$to"; s="${s#*"$from"}" ;;
      *) break ;;
    esac
  done
  REPLY="$out$s"
}

json_escape() {  # <string> -> REPLY
  local s="$1"
  replace_all "$s" '\' '\\';      s="$REPLY"
  replace_all "$s" '"' '\"';      s="$REPLY"
  replace_all "$s" $'\n' '\n';    s="$REPLY"
  replace_all "$s" $'\t' '\t';    s="$REPLY"
  replace_all "$s" $'\r' '\r';    s="$REPLY"
  case "$s" in
    *[[:cntrl:]]*) s=$(printf '%s' "$s" | LC_ALL=C tr -d '\001-\037\177') ;;
  esac
  REPLY="$s"
}

LINE=""
add_field() {  # <key> <value> [char-limit]   (no limit = never truncated)
  [ -z "$2" ] && return 0
  local v="$2"
  if [ $# -ge 3 ]; then
    local lim="$3"
    [ "$lim" -lt 1 ] && lim=1
    v="${v:0:$lim}"
  fi
  json_escape "$v"
  LINE="$LINE,\"$1\":\"$REPLY\""
}

# build_event <ev> <id> <session> <status> -> LINE (≤ 1,500 bytes)
# Field values come from the E_* globals. If escaping pushes the line over the
# cap, the free-text limits are halved and the line rebuilt. screen, log and
# exit_file are never cut (a cut path points at the wrong file), and session is
# always 64; if the line cannot fit with those intact, the event is refused.
build_event() {
  local ev="$1" id="$2" sess="$3" st="$4" div=1 ts bytes
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  while :; do
    LINE="{\"v\":1,\"ts\":\"$ts\",\"ev\":\"$ev\",\"id\":\"$id\""
    add_field session   "$sess"     64
    add_field kind      "$E_KIND"   32
    add_field title     "$E_TITLE"  $((200 / div))
    add_field status    "$st"       32
    add_field progress  "$E_PROG"   $((120 / div))
    add_field note      "$E_NOTE"   $((300 / div))
    add_field ref       "$E_REF"    $((300 / div))
    add_field screen    "$E_SCREEN"
    add_field log       "$E_LOG"
    add_field exit_file "$E_EXIT"
    add_field cmd       "$E_CMD"    $((300 / div))
    LINE="$LINE}"
    bytes=$(printf '%s' "$LINE" | wc -c | tr -d ' ')
    [ "$bytes" -le 1500 ] && return 0
    [ "$div" -ge 64 ] && die 2 "event too large"
    div=$((div * 2))
  done
}

E_KIND="" E_TITLE="" E_PROG="" E_NOTE="" E_REF="" E_SCREEN="" E_LOG="" E_EXIT="" E_CMD=""

# write_line <file>: append LINE (caller holds the lock). A writer killed
# mid-append can leave a last line without its newline; one is added first so
# the new event never gets glued onto the fragment. ($(tail -c 1) is empty
# exactly when the last byte is a newline: command substitution strips it.)
write_line() {
  if [ -s "$1" ] && [ -n "$(tail -c 1 "$1" 2>/dev/null)" ]; then
    printf '\n' >> "$1" 2>/dev/null || return 1
  fi
  printf '%s\n' "$LINE" >> "$1" 2>/dev/null
}

append_line() {  # <file>   (caller holds the lock)
  write_line "$1" || die 5 "cannot write $1"
}

need_session() {
  [ -n "$SESSION" ] || die 2 "no session id (set PROPEL_SESSION or pass --session); nothing recorded"
}

# Owning file of a task = the file holding its start event. Start events never
# move, so this lookup needs no lock, and an unknown id creates nothing.
OWNER_FILE=""
find_owner() {
  OWNER_FILE=""
  local f
  for f in "$TASKDIR"/*.jsonl; do
    [ -f "$f" ] || continue
    if grep -q -F "\"ev\":\"start\",\"id\":\"$ID\"" "$f" 2>/dev/null; then
      OWNER_FILE="$f"; return 0
    fi
  done
  die 4 "unknown task id: $ID"
}

id_exists() {
  local f
  for f in "$TASKDIR"/*.jsonl; do
    [ -f "$f" ] || continue
    grep -q -F "\"id\":\"$1\"" "$f" 2>/dev/null && return 0
  done
  return 1
}

new_id() {
  local stamp hex n=0
  while :; do
    stamp=$(date -u +%y%m%d-%H%M%S)
    hex=$(printf '%04x' $(( ((RANDOM << 1) ^ RANDOM ^ $$) & 65535 )))
    NEW_ID="t$stamp-$hex"
    id_exists "$NEW_ID" || return 0
    n=$((n + 1))
    [ "$n" -ge 50 ] && die 3 "ledger busy (could not allocate a unique id)"
  done
}

has_cntrl() {  # <string>: true if it holds a control char (0x01-0x1F, 0x7F)
  case "$1" in *[[:cntrl:]]*) return 0 ;; esac
  return 1
}

# Path fields are stored byte-for-byte (never truncated, never escaped away),
# so a value with a control character is refused rather than altered.
abs_path() {  # <flag> <path> -> REPLY (relative paths are anchored at $PWD)
  has_cntrl "$2" && die 2 "$1: path contains a control character"
  case "$2" in
    ''|/*) REPLY="$2" ;;
    *)     has_cntrl "$PWD" && die 2 "$1: path contains a control character (in the current directory)"
           REPLY="$PWD/$2" ;;
  esac
}

# ── commands that write ──────────────────────────────────────────────────────
cmd_start() {
  case "$KIND" in
    train|impl|validate|monitor|other) ;;
    '') die 2 "start: --kind is required (train|impl|validate|monitor|other)" ;;
    *)  die 2 "start: invalid --kind '$KIND' (train|impl|validate|monitor|other)" ;;
  esac
  [ -n "$TITLE" ] || die 2 "start: --title is required"
  need_session
  # Paths are made absolute so a later `list` from another directory reads the
  # same files.
  abs_path --exit-file "$EXITF"; EXITF="$REPLY"
  abs_path --log "$LOGF";        LOGF="$REPLY"
  has_cntrl "$SCREEN" && die 2 "--screen: path contains a control character"
  # An exit file that already exists would report a previous run's result as
  # this one's.
  if [ -n "$EXITF" ] && [ -e "$EXITF" ]; then
    die 2 "exit file already exists (a finished run may still be recorded against it); pass a fresh --exit-file path"
  fi
  E_KIND="$KIND" E_TITLE="$TITLE" E_PROG="$PROGRESS" E_NOTE="$NOTE" E_REF="$REF"
  E_SCREEN="$SCREEN" E_LOG="$LOGF" E_EXIT="$EXITF" E_CMD="$CMDSTR"
  # Size check before touching the disk: an oversized event writes nothing.
  build_event start t000000-000000-0000 "$SESSION" running
  mkdir -p "$TASKDIR" 2>/dev/null || die 5 "cannot create $TASKDIR"
  acquire_lock
  new_id
  build_event start "$NEW_ID" "$SESSION" running
  append_line "$TASKDIR/$SESSION.jsonl"
  release_lock
  printf '%s\n' "$NEW_ID"
}

cmd_update() {
  case "$STATUS" in
    ''|running|blocked) ;;
    *) die 2 "update: --status must be running or blocked" ;;
  esac
  # Empty values are omitted from events, so they would record nothing.
  [ -n "$PROGRESS$NOTE$STATUS" ] \
    || die 2 "update: give at least one non-empty --progress, --note or --status"
  E_PROG="$PROGRESS" E_NOTE="$NOTE"
  find_owner
  build_event update "$ID" "$SESSION" "$STATUS"
  acquire_lock
  append_line "$OWNER_FILE"
  release_lock
}

cmd_done() {
  case "$STATUS" in
    done|failed|blocked|abandoned) ;;
    '') die 2 "done: --status is required (done|failed|blocked|abandoned)" ;;
    *)  die 2 "done: invalid --status '$STATUS' (done|failed|blocked|abandoned)" ;;
  esac
  E_NOTE="$NOTE"
  find_owner
  build_event done "$ID" "$SESSION" "$STATUS"
  acquire_lock
  append_line "$OWNER_FILE"
  release_lock
}

cmd_carry() {
  need_session
  find_owner
  build_event carry "$ID" "$SESSION" ""
  acquire_lock
  append_line "$OWNER_FILE"
  release_lock
}

# ── fold ─────────────────────────────────────────────────────────────────────
# Prints the stems of the window: the newest NSESSIONS files by mtime that were
# modified in the last NDAYS days, plus the current session's file. The window
# only decides which files with no open task are shown; files that hold an open
# task are always shown (decided inside the fold).
window_stems() {
  local recent f
  recent=$(cd "$TASKDIR" 2>/dev/null && find . -maxdepth 1 -type f -name '*.jsonl' -mtime "-$NDAYS" 2>/dev/null)
  ls -t "$TASKDIR" 2>/dev/null | grep -E '^[A-Za-z0-9._-]+\.jsonl$' | head -n "$NSESSIONS" |
  while IFS= read -r f; do
    case "$recent" in
      *"./$f"*) printf '%s\n' "${f%.jsonl}" ;;
    esac
  done
  [ -n "$SESSION" ] && printf '%s\n' "$SESSION"
}

# The fold. Input: ledger files (relative names, read from inside TASKDIR).
# Vars: WIN = " stem stem " window; OPENF = 1 to emit only maybe-open tasks;
# ONLY = a task id to re-fold alone (prints "<recorded status> <event count>").
# Each event for a task in its owner file counts once toward <event count>.
FOLD_AWK='
# Parses only the output of this script (flat object, string values, one
# numeric "v"); foreign or corrupt lines are skipped.
function jstr(s, i,    out, rest, p, c, e) {
  # s at position i is the opening quote. Sets JS, returns index after close.
  i++; out = ""
  while (1) {
    rest = substr(s, i)
    p = match(rest, /["\\]/)
    if (p == 0) { JERR = 1; return length(s) + 1 }
    out = out substr(rest, 1, p - 1)
    c = substr(rest, p, 1)
    i += p
    if (c == "\"") { JS = out; return i }
    e = substr(s, i, 1); i++
    if (e == "n" || e == "t" || e == "r" || e == "b" || e == "f") out = out " "
    else if (e == "u") { out = out "?"; i += 4 }
    else out = out e
  }
}
function jparse(s,    i, n, c, key, num) {
  split("", F); JERR = 0
  n = length(s)
  if (substr(s, 1, 1) != "{") return 0
  i = 2
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == "}") return 1
    if (c == "," || c == " ") { i++; continue }
    if (c != "\"") return 0
    i = jstr(s, i); if (JERR) return 0
    key = JS
    if (substr(s, i, 1) != ":") return 0
    i++
    c = substr(s, i, 1)
    if (c == "\"") {
      i = jstr(s, i); if (JERR) return 0
      F[key] = JS
    } else {
      num = ""
      while (i <= n && index("0123456789.-+eE", substr(s, i, 1)) > 0) { num = num substr(s, i, 1); i++ }
      if (num == "") return 0
      F[key] = num
    }
  }
  return 0
}
function clean(v) { gsub(US, " ", v); return v }
function stem(path,    s) { s = path; sub(/\.jsonl$/, "", s); return s }
function maybe_open(st) { return st == "running" || st == "blocked" }
BEGIN { US = sprintf("%c", 31); n = 0 }
{
  # Cheap reject before the char-level parse.
  if (substr($0, 1, 6) != "{\"v\":1") next
  if (!jparse($0)) next
  if (F["v"] != "1") next
  ev = F["ev"]; id = F["id"]
  if (id == "") next
  if (ev == "start") {
    if (id in OWN) next
    OWN[id] = FILENAME; ORDER[++n] = id
    KIND[id] = F["kind"]; TITLE[id] = F["title"]; REF[id] = F["ref"]
    SCR[id] = F["screen"]; LOGP[id] = F["log"]; EXF[id] = F["exit_file"]; CMDS[id] = F["cmd"]
    TS[id] = F["ts"]; OWNER[id] = stem(FILENAME)
    ST[id] = (F["status"] != "") ? F["status"] : "running"
    PR[id] = F["progress"]; NT[id] = F["note"]; CAR[id] = ""; CNT[id] = 1
    next
  }
  if (!(id in OWN) || OWN[id] != FILENAME) next
  CNT[id]++
  if (ev == "update" || ev == "done") {
    if (F["status"] != "") ST[id] = F["status"]
    if (F["progress"] != "") PR[id] = F["progress"]
    if (F["note"] != "") NT[id] = F["note"]
  } else if (ev == "carry") {
    if (F["session"] != "") CAR[id] = F["session"]
  }
}
END {
  if (ONLY != "") {                     # re-fold of one task: "<status> <events>"
    if (ONLY in OWN) printf "%s %d\n", ST[ONLY], CNT[ONLY]
    exit
  }
  for (k = 1; k <= n; k++) { id = ORDER[k]; if (maybe_open(ST[id])) HASOPEN[OWNER[id]] = 1 }
  for (k = 1; k <= n; k++) {
    id = ORDER[k]
    if (OPENF == 1 && !maybe_open(ST[id])) continue
    if (!(OWNER[id] in HASOPEN) && index(WIN, " " OWNER[id] " ") == 0) continue
    printf "%s%s%08d%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%d\n", \
      clean(TS[id]), US, k, US, clean(id), US, clean(KIND[id]), US, clean(TITLE[id]), US, \
      clean(REF[id]), US, clean(SCR[id]), US, clean(LOGP[id]), US, clean(EXF[id]), US, \
      clean(CMDS[id]), US, clean(OWNER[id]), US, clean(ST[id]), US, clean(PR[id]), US, \
      clean(NT[id]), US, clean(CAR[id]), US, CNT[id]
  }
}'

# Emits one record per task, \037-separated, newest first (seq = file order,
# which breaks ties between tasks started in the same second):
#   started seq id kind title ref screen log exit_file cmd owner status progress note carried nev
# With OPEN_FILTER=1 only rows that can be open reach the caller: recorded
# running/blocked (a running train task's derived status may still change).
fold_records() {
  [ -d "$TASKDIR" ] || return 0
  local win open_filter=0
  win=" $(window_stems | tr '\n' ' ') "
  { [ "$CMD" = "count" ] || [ "$OPEN_ONLY" -eq 1 ]; } && open_filter=1
  (
    cd "$TASKDIR" 2>/dev/null || exit 0
    set --
    for f in *.jsonl; do
      case "$f" in *[!A-Za-z0-9._-]*|.*) continue ;; esac
      # Unreadable files are left out (cmd_list reports them and exits 5), so
      # one bad file cannot abort awk and zero out every other file.
      [ -f "$f" ] && [ -r "$f" ] && set -- "$@" "$f"
    done
    [ $# -gt 0 ] || exit 0
    awk -v WIN="$win" -v OPENF="$open_filter" -v ONLY="" "$FOLD_AWK" "$@" 2>/dev/null
  ) | LC_ALL=C sort -r
}

# ── derived liveness ─────────────────────────────────────────────────────────
SCREEN_LS="" SCREEN_LS_DONE=0
screen_alive() {  # <name>; `screen -ls` is run once per invocation
  local name="$1" line l pid rest
  if [ "$SCREEN_LS_DONE" -eq 0 ]; then
    SCREEN_LS=$(screen -ls 2>/dev/null)
    SCREEN_LS_DONE=1
  fi
  # screen -ls lines look like "\t<pid>.<name>\t(<date>)\t(<state>)". The name
  # may contain spaces and dots, so it must be followed by a TAB or the end of
  # the line, and only the text after it is checked for "(Dead".
  local tab=$'\t' after
  while IFS= read -r line; do
    l="${line#"${line%%[![:space:]]*}"}"           # strip leading whitespace
    pid="${l%%.*}"
    case "$pid" in ''|*[!0-9]*) continue ;; esac  # "<digits>.NAME" only
    rest="${l#*.}"
    case "$rest" in
      "$name") return 0 ;;
      "$name$tab"*)
        after="${rest#"$name"}"
        case "$after" in *"(Dead"*) continue ;; esac
        return 0 ;;
    esac
  done <<EOF
$SCREEN_LS
EOF
  return 1
}

# derive: sets EFF_STATUS / EFF_PROGRESS. Inputs are the caller's loop
# variables, read through bash's dynamic scope: kind, status, progress,
# screen, log, exitf.
# SETTLE_CODE is set to the exit code when the status came from the exit file
# (the caller then settles the task on disk, see settle_all).
derive() {
  EFF_STATUS="$status"; EFF_PROGRESS="$progress"; SETTLE_CODE=""
  [ "$kind" = "train" ] && [ "$status" = "running" ] || return 0
  if [ -n "$exitf" ] && [ -f "$exitf" ]; then
    local code digits
    code=$(head -n 1 "$exitf" 2>/dev/null | tr -d ' \t\r')
    digits="${code#-}"
    # More than 10 digits is not an exit code (and would overflow below).
    [ "${#digits}" -gt 10 ] && digits="x"
    case "$digits" in
      ''|*[!0-9]*) ;;                                # empty / non-numeric: absent
      *)
        if [ "$digits" = "$code" ] && [ "$((10#$digits))" -eq 0 ]; then
          EFF_STATUS="done"
        else
          EFF_STATUS="failed"
        fi
        [ -z "$EFF_PROGRESS" ] && EFF_PROGRESS="exit $code"
        SETTLE_CODE="$code"
        return 0 ;;
    esac
  fi
  if [ -n "$screen" ]; then
    local have_screen=0 have_tmux=0 tname
    command -v screen >/dev/null 2>&1 && have_screen=1
    command -v tmux >/dev/null 2>&1 && have_tmux=1
    tname="${screen//./_}"; tname="${tname//:/_}"   # tmux rewrites . and : to _
    if [ "$have_screen" -eq 1 ] && screen_alive "$screen"; then
      EFF_STATUS="running"
    elif [ "$have_tmux" -eq 1 ] && tmux has-session -t "=$tname" >/dev/null 2>&1; then
      EFF_STATUS="running"
    elif [ "$have_screen" -eq 0 ] && [ "$have_tmux" -eq 0 ]; then
      EFF_STATUS="unknown"
    else
      EFF_STATUS="lost"
    fi
  else
    EFF_STATUS="unknown"                              # no evidence either way
  fi
  if [ "$EFF_STATUS" = "running" ] && [ -n "$log" ] && [ -f "$log" ] && [ -r "$log" ]; then
    local last
    # Progress bars redraw with \r, so the newest state is after the last \r.
    last=$(tail -c 8192 "$log" 2>/dev/null | LC_ALL=C tr '\r' '\n' | awk 'NF { l = $0 } END { print l }')
    last=$(printf '%s' "$last" | LC_ALL=C tr -d '\000-\037\177')
    [ -n "$last" ] && EFF_PROGRESS="${last:0:120}"
  fi
  return 0
}

is_open() {
  case "$1" in running|blocked|lost|unknown) return 0 ;; esac
  return 1
}

escape_pipe() {  # -> REPLY
  replace_all "$1" '|' '\|'
}

# settle_all: settle on read. Every task whose done/failed status was just
# derived from its exit file (lines "<id> <owner> <status> <code> <p|-> <nev>"
# in SETTLE, nev = the task's event count at fold time)
# gets a done event in its owner file, so the result survives the exit file
# and the file stops counting as open. Best effort by design: one mkdir
# attempt, no waiting; if the ledger is busy nothing is written and a later
# read settles it. Never affects the reader's output or exit code.
settle_all() {
  [ -n "$SETTLE" ] || return 0
  try_lock_once || return 0
  local sid sowner sst scode sp snev f now
  while read -r sid sowner sst scode sp snev; do
    [ -n "$sid" ] || continue
    f="$TASKDIR/$sowner.jsonl"
    [ -f "$f" ] && [ -w "$f" ] || continue
    # Re-fold the task under the lock. Another writer may have recorded an
    # event (abandoned, an update, a settle) after this reader's fold; settle
    # only if nothing at all happened to the task since then.
    now=$(cd "$TASKDIR" 2>/dev/null && awk -v WIN="" -v OPENF=0 -v ONLY="$sid" "$FOLD_AWK" "$sowner.jsonl" 2>/dev/null) || continue
    [ "$now" = "running $snev" ] || continue
    E_KIND="" E_TITLE="" E_PROG="" E_REF="" E_SCREEN="" E_LOG="" E_EXIT="" E_CMD=""
    E_NOTE="settled from exit file (exit $scode)"
    [ "$sp" = "p" ] && E_PROG="exit $scode"
    build_event done "$sid" "$SESSION" "$sst"
    write_line "$f" || true
  done <<EOF
$SETTLE
EOF
  release_lock
  return 0
}

# Sets READ_FAIL to the first ledger path that cannot be read ("" if none).
check_readable() {
  READ_FAIL=""
  [ -e "$TASKDIR" ] || return 0
  if [ ! -d "$TASKDIR" ] || [ ! -r "$TASKDIR" ] || [ ! -x "$TASKDIR" ]; then
    READ_FAIL="$TASKDIR"; return 0
  fi
  local f
  for f in "$TASKDIR"/*.jsonl; do
    [ -f "$f" ] || continue
    case "${f##*/}" in *[!A-Za-z0-9._-]*|.*) continue ;; esac
    if [ ! -r "$f" ]; then READ_FAIL="$f"; return 0; fi
  done
}

cmd_list() {
  check_readable
  fold_records | {
    rows=0 here_n=0 earlier_n=0 SETTLE=""
    while IFS=$'\037' read -r started seq id kind title ref screen log exitf cmd owner status progress note carried nev; do
      [ -n "$id" ] || continue
      derive
      if [ -n "$SETTLE_CODE" ]; then
        # p = the task had no progress of its own, so "exit N" is recorded as
        # its progress too (later reads must show what this one shows).
        if [ -z "$progress" ]; then sp=p; else sp=-; fi
        SETTLE="$SETTLE$id $owner $EFF_STATUS $SETTLE_CODE $sp $nev
"
      fi
      if [ "$CMD" = "count" ] || [ "$OPEN_ONLY" -eq 1 ]; then
        is_open "$EFF_STATUS" || continue
      fi
      here=0
      if [ -n "$SESSION" ] && { [ "$owner" = "$SESSION" ] || [ "$carried" = "$SESSION" ]; }; then
        here=1
      fi
      if [ "$CMD" = "count" ]; then
        if [ "$here" -eq 1 ]; then here_n=$((here_n + 1)); else earlier_n=$((earlier_n + 1)); fi
        continue
      fi
      rows=$((rows + 1))
      if [ "$TABLE" -eq 0 ]; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$EFF_STATUS" "$kind" "$owner" "$started" "$title"
        continue
      fi
      [ "$rows" -eq 1 ] && {
        printf '%s\n' "| ID | Task | Kind | Status | Progress | Started | Session |"
        printf '%s\n' "|---|---|---|---|---|---|---|"
      }
      task="${title:0:60}"
      if [ -n "$ref" ] && [ $(( ${#task} + ${#ref} + 3 )) -le 60 ]; then
        task="$task ($ref)"
      fi
      escape_pipe "$task"; task="$REPLY"
      escape_pipe "$EFF_PROGRESS"; cell_prog="$REPLY"
      sess="${owner:0:8}"
      if [ -n "$SESSION" ] && [ "$owner" = "$SESSION" ]; then
        sess="$sess (this)"
      elif [ -n "$SESSION" ] && [ "$carried" = "$SESSION" ]; then
        sess="$sess (carried here)"
      fi
      printf '| %s | %s | %s | %s | %s | %s | %s |\n' \
        "$id" "$task" "$kind" "$EFF_STATUS" "$cell_prog" "${started:5:5} ${started:11:5}Z" "$sess"
    done
    if [ "$CMD" = "count" ]; then
      printf '%s %s\n' "$here_n" "$earlier_n"
    elif [ "$TABLE" -eq 1 ] && [ "$rows" -eq 0 ]; then
      if [ "$OPEN_ONLY" -eq 1 ]; then echo "No open tasks."; else echo "No tasks recorded."; fi
    fi
    # TEST-ONLY hook: tests/test_task_queue.sh sets PROPEL_TQ_TEST_PRE_SETTLE to
    # a command that lands a competing event between this read's fold and its
    # settle, the one interleaving a shell test cannot otherwise hit on demand.
    # Nothing else sets it; unset, it does nothing.
    if [ -n "${PROPEL_TQ_TEST_PRE_SETTLE:-}" ]; then
      sh -c "$PROPEL_TQ_TEST_PRE_SETTLE" >/dev/null 2>&1 || true
    fi
    settle_all >/dev/null 2>&1
    true
  }
  # What could be read has been printed; an unreadable part of the ledger
  # still has to be reported, or a partial count would pass for a full one.
  [ -z "$READ_FAIL" ] || die 5 "cannot read $READ_FAIL (output above is incomplete)"
}

# ── dispatch ─────────────────────────────────────────────────────────────────
case "$CMD" in
  start)   cmd_start ;;
  update)  cmd_update ;;
  done)    cmd_done ;;
  abandon) STATUS="abandoned"; cmd_done ;;
  carry)   cmd_carry ;;
  list)    cmd_list ;;
  count)   cmd_list ;;
  unlock)  cmd_unlock ;;
esac
exit 0
