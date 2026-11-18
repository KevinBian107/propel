#!/usr/bin/env bash
# Propel — scripts/codex-consult.sh without python3, the ledger format its two
# writers share, and the cost of a large brief or reply on bash 3.2.
#
#   bash tests/test_codex_consult.sh
#   /bin/bash tests/test_codex_consult.sh
#
# Every consult runs in a throwaway project dir against a fake `codex`, so the
# suite never spends a real Codex call and never touches the repo's own ledger.
# A python3 OUTSIDE the no-python3 PATH validates what the script wrote.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONSULT="$ROOT/scripts/codex-consult.sh"
RUN_BASH="${BASH:-bash}"          # the interpreter running this suite
SLOW_BASH=/bin/bash               # macOS ships bash 3.2 here; the speed cases use it
[ -x "$SLOW_BASH" ] || SLOW_BASH="$RUN_BASH"

T=$(mktemp -d "${TMPDIR:-/tmp}/propel-consult-test.XXXXXX") || { echo "FAIL: test setup — mktemp -d"; exit 1; }
cleanup() { cd / 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

RUNS=0
fail() {
    echo "FAIL: $*"
    if [ -f "$T/out" ]; then
        echo "---- consult output (first 20 lines) ----"
        head -n 20 "$T/out"
    fi
    exit 1
}
pass() { echo "PASS: $*"; }

SYS_PY=$(command -v python3 2>/dev/null || true)
[ -n "$SYS_PY" ] || { [ -x /usr/bin/python3 ] && SYS_PY=/usr/bin/python3; }
[ -n "$SYS_PY" ] || fail "test setup — a python3 outside the no-python3 PATH is needed to validate the JSON"

# ── no-python3 PATH: symlinks to just the tools the script and the stub use ──
NOPY_BIN="$T/nopy-bin"
mkdir -p "$NOPY_BIN"
for tool in bash sh cat head tail tr wc date mkdir grep sed sleep kill mktemp rm \
            iconv pwd env printf ls; do
    TOOL_PATH=$(type -P "$tool" 2>/dev/null || true)
    case "$TOOL_PATH" in
        /*) ln -s "$TOOL_PATH" "$NOPY_BIN/$tool" ;;
    esac
done
for tool in cat head tr wc date mkdir grep sleep mktemp rm; do
    [ -e "$NOPY_BIN/$tool" ] || fail "test setup — $tool not found for the no-python3 PATH"
done
if [ -e "$NOPY_BIN/python3" ] || env -i PATH="$NOPY_BIN" "$RUN_BASH" -c 'command -v python3' >/dev/null 2>&1; then
    fail "test setup — python3 leaked into the no-python3 PATH"
fi
EMPTY_HOME="$T/home"          # no ~/.local/bin/codex to fall back on
mkdir -p "$EMPTY_HOME"

# ── fake codex: records the call, drains the brief, answers per the mode file ──
FAKE_BIN="$T/fake-bin"
STUB_MODE="$T/stub-mode"; STUB_MARK="$T/stub-called"
STUB_REPLY="$T/stub-reply"; STUB_SNAP="$T/stub-running"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/codex" <<EOF
#!/bin/sh
: > '$STUB_MARK'
cat .propel/codex-running.json > '$STUB_SNAP' 2>/dev/null
cat > /dev/null
case "\$(cat '$STUB_MODE' 2>/dev/null)" in
  empty) ;;
  blank) printf ' \n\t \n' ;;
  401)   echo 'Error: 401 Unauthorized -- token sk-CANARY-401 rejected' >&2; exit 1 ;;
  *)     cat '$STUB_REPLY' ;;
esac
EOF
chmod +x "$FAKE_BIN/codex"

# ── ledger / marker validator (system python3) ──
CHECK="$T/check.py"
cat > "$CHECK" <<'PY'
import json, os, re, sys

KEYS = ["ts", "label", "outcome", "detail", "question", "model", "duration_s", "cwd"]
RUN_KEYS = ["label", "question", "started", "timeout", "pid"]


def fail(msg):
    print("FAIL: " + msg)
    sys.exit(1)


def env(name, default=None):
    return os.environ.get(name, default)


def is_number(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def read_lines(path):
    try:
        raw = open(path, "rb").read()
    except OSError as e:
        fail(f"cannot read {path}: {e}")
    try:
        text = raw.decode("utf-8")          # strict: a half-cut character fails here
    except UnicodeDecodeError as e:
        fail(f"{path} is not valid UTF-8 ({e})")
    if not text.endswith("\n"):
        fail(f"{path} does not end with a newline")
    return text[:-1].split("\n")


def parse(line, where, keys):
    try:
        pairs = json.loads(line, object_pairs_hook=lambda p: p)
    except ValueError as e:
        fail(f"{where} is not JSON ({e}): {line[:200]!r}")
    got = [k for k, _ in pairs]
    if got != keys:
        fail(f"{where} has keys {got}, expected {keys}")
    if len(line.splitlines()) != 1:
        fail(f"{where} breaks under str.splitlines(), which the ledger readers use")
    return dict(pairs)


def check_ledger(path):
    writer = env("CK_WRITER", "bash")
    lines = read_lines(path)
    count = int(env("CK_COUNT", "0"))
    if count and len(lines) != count:
        fail(f"expected {count} ledger line(s), found {len(lines)}")
    rows = [parse(l, f"ledger line {i}", KEYS) for i, l in enumerate(lines, 1)]
    for i, r in enumerate(rows, 1):
        for k in ("ts", "label", "outcome", "detail", "question", "model", "cwd"):
            if not isinstance(r[k], str):
                fail(f"ledger line {i}: {k} is {type(r[k]).__name__}, not a string")
        if r["duration_s"] is not None and not is_number(r["duration_s"]):
            fail(f"ledger line {i}: duration_s is {r['duration_s']!r}")
    row, line, where = rows[-1], lines[-1], f"ledger line {len(lines)}"
    if env("CK_EXACT", "1") == "1":
        want = json.dumps(row, ensure_ascii=(writer == "py"))
        if want != line:
            fail(f"{where} is not what json.dumps writes:\n  got  {line!r}\n  want {want!r}")
    if not re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d{4}", row["ts"]):
        fail(f"{where}: ts {row['ts']!r} is not %Y-%m-%dT%H:%M:%S%z")
    if env("CK_CWD") is not None and row["cwd"] != os.path.realpath(env("CK_CWD")):
        fail(f"{where}: cwd {row['cwd']!r} is not the physical project dir")
    for key, var in (("outcome", "CK_OUTCOME"), ("label", "CK_LABEL"), ("detail", "CK_DETAIL")):
        if env(var) is not None and row[key] != env(var):
            fail(f"{where}: {key} {row[key]!r}, expected {env(var)!r}")
    if env("CK_NOT") and env("CK_NOT") in line:
        fail(f"{where} contains {env('CK_NOT')!r}, which must never reach the ledger")
    if env("CK_DURATION") == "number" and not is_number(row["duration_s"]):
        fail(f"{where}: duration_s {row['duration_s']!r} is not a number")
    if env("CK_QRAW") is not None:
        want, got = " ".join(env("CK_QRAW").split())[:240], row["question"]
        if env("CK_QMODE", "exact") == "exact":
            if got != want:
                fail(f"{where}: question {got!r}, python's writer gives {want!r}")
        elif not (int(env("CK_QMIN", "1")) <= len(got) <= 240 and want.startswith(got)):
            fail(f"{where}: truncated question ({len(got)} chars) is not a prefix of python's: {got!r}")


def check_running(path, ledger):
    lines = read_lines(path)
    if len(lines) != 1:
        fail(f"codex-running.json has {len(lines)} lines, expected 1")
    m = parse(lines[0], "codex-running.json", RUN_KEYS)
    led = parse(read_lines(ledger)[-1], "ledger", KEYS)
    if env("CK_LABEL") is not None and m["label"] != env("CK_LABEL"):
        fail(f"codex-running.json label {m['label']!r}, expected {env('CK_LABEL')!r}")
    if m["question"] != led["question"]:
        fail(f"codex-running.json question {m['question']!r} differs from the ledger's {led['question']!r}")
    if not is_number(m["started"]) or m["started"] <= 0:
        fail(f"codex-running.json started {m['started']!r}")
    if m["timeout"] != int(env("CK_TIMEOUT", "240")):
        fail(f"codex-running.json timeout {m['timeout']!r}")
    if not isinstance(m["pid"], int) or isinstance(m["pid"], bool) or m["pid"] <= 1:
        fail(f"codex-running.json pid {m['pid']!r}")


def check_same(a, b):          # first line of each: the same consult, two writers
    ra = parse(read_lines(a)[0], a, KEYS)
    rb = parse(read_lines(b)[0], b, KEYS)
    for k in ("label", "outcome", "question"):
        if ra[k] != rb[k]:
            fail(f"bash and python writers disagree on {k}: {ra[k]!r} vs {rb[k]!r}")


def check_codexjson(path):
    raw = open(path, "rb").read().decode("utf-8")
    want = {"enabled": True, "available": False,
            "unavailable_reason": "codex CLI not found on PATH"}
    if json.loads(raw) != want:
        fail(f"codex.json is {raw!r}")
    if raw != json.dumps(want, indent=2) + "\n":
        fail(f"codex.json differs from the python writer's bytes: {raw!r}")


mode = sys.argv[1]
if mode == "ledger":
    check_ledger(sys.argv[2])
elif mode == "running":
    check_running(sys.argv[2], sys.argv[3])
elif mode == "same":
    check_same(sys.argv[2], sys.argv[3])
elif mode == "codexjson":
    check_codexjson(sys.argv[2])
else:
    fail(f"check.py: unknown mode {mode}")
PY

# check_ledger <writer: bash|py> <count> <outcome> [CK_NAME=value ...]
check_ledger() {
    local writer="$1" count="$2" outcome="$3"; shift 3
    env CK_WRITER="$writer" CK_COUNT="$count" CK_OUTCOME="$outcome" CK_CWD="$PWD" "$@" \
        "$SYS_PY" -I "$CHECK" ledger .propel/codex-log.jsonl || exit 1
}

N=0
new_proj() {   # fresh project dir, cd into it; [enabled] writes codex.json
    N=$((N + 1)); P="$T/proj.$N"; mkdir -p "$P"; cd "$P" || fail "cd $P"
    if [ $# -gt 0 ]; then
        mkdir -p .propel; printf '%s\n' "$1" > .propel/codex.json
    fi
}

# consult <nopy|py> <bash> <stdin-file> [flags...] -> OUT, RC
# Uses CPATH (PATH for the run) and LOC (LC_ALL, empty = C via env -i). Every
# run must exit 0, and a watchdog turns a hang into a failure instead of a
# stuck suite.
LOC=""
CPATH=""
consult() {
    local kind="$1" sh="$2" in="$3" pid wd; shift 3
    rm -f "$STUB_MARK" "$STUB_SNAP" "$T/out"
    if [ "$kind" = nopy ]; then
        env -i PATH="$CPATH" HOME="$EMPTY_HOME" ${LOC:+LC_ALL=$LOC} \
            "$sh" "$CONSULT" "$@" <"$in" >"$T/out" 2>&1 &
    else
        env PATH="$CPATH" HOME="$EMPTY_HOME" ${LOC:+LC_ALL=$LOC} \
            "$sh" "$CONSULT" "$@" <"$in" >"$T/out" 2>&1 &
    fi
    pid=$!
    ( trap 'kill $s 2>/dev/null; exit 0' TERM; sleep 20 & s=$!; wait $s; kill -9 $pid ) >/dev/null 2>&1 &
    wd=$!
    wait "$pid"; RC=$?
    kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
    OUT=$(cat "$T/out")
    RUNS=$((RUNS + 1))
    [ "$RC" -eq 0 ] || fail "consult exited $RC (137 = killed by the 20 s watchdog: it hung)"
}

# timed_consult <args as for consult> -> MS (wall clock, milliseconds)
timed_consult() {
    local TIMEFORMAT=%R t
    { time consult "$@" ; } 2>"$T/time"
    t=$(tail -n 1 "$T/time"); t=${t/,/}; t=${t/./}
    case "$t" in ''|*[!0-9]*) fail "could not read the timing ($(cat "$T/time"))" ;; esac
    MS=$((10#$t))
}

UTF8_LOC=""
for l in C.UTF-8 en_US.UTF-8 C.utf8 en_US.utf8; do
    if locale -a 2>/dev/null | grep -qx "$l"; then UTF8_LOC=$l; break; fi
done

printf 'CONTEXT\n  a short brief\n\nQUESTION\n  is this right?\n' > "$T/in.brief"

echo ""
echo "Testing: codex-consult.sh with no python3 on PATH"
echo "================================"

# ── a. enabled:false is honoured without python3, and codex is never called ──
for cfg in '{"enabled": false}' '{"enabled":false,"available":null}' $'{\n  "enabled": false\n}' \
           $'{"enabled":\nfalse}' $'{\n  "enabled"\n  :\n\tfalse\n}'; do
    new_proj "$cfg"
    CPATH="$FAKE_BIN:$NOPY_BIN"; LOC=""
    consult nopy "$RUN_BASH" "$T/in.brief" --label "Gate 1 (findings)" --question "disabled path"
    case "$OUT" in *"reason: codex disabled for this project"*) ;; *) fail "enabled:false ignored without python3 (config: $cfg)" ;; esac
    [ ! -e "$STUB_MARK" ] || fail "codex was called although disabled (config: $cfg)"
    check_ledger bash 1 disabled CK_LABEL="Gate 1 (findings)" CK_QRAW="disabled path" CK_DURATION=number
done
# ...and only false: a lookalike value still consults.
new_proj '{"enabled": falsey}'
echo reply > "$STUB_MODE"; printf 'ok\n' > "$STUB_REPLY"
consult nopy "$RUN_BASH" "$T/in.brief" --label "Gate 1" --question "q"
[ -e "$STUB_MARK" ] || fail '"enabled": falsey was read as disabled'
pass "a. enabled:false honoured without python3 (incl. multi-line); codex not called; one 'disabled' ledger line"

# ── b. no CLI: UNAVAILABLE, availability recorded once, existing file kept ──
new_proj
CPATH="$NOPY_BIN"; LOC=""
[ ! -e "$NOPY_BIN/codex" ] && [ ! -e "$EMPTY_HOME/.local/bin/codex" ] || fail "test setup — codex reachable in the no-CLI env"
consult nopy "$RUN_BASH" "$T/in.brief" --label "Gate 4 (diagnosis)" --question "missing cli"
case "$OUT" in *"=== CODEX UNAVAILABLE ==="*"reason: codex CLI not found on PATH"*) ;; *) fail "missing CLI not reported UNAVAILABLE" ;; esac
check_ledger bash 1 unavailable CK_DETAIL="codex CLI not found on PATH" CK_DURATION=number
[ -f .propel/codex.json ] || fail "codex.json not created when the CLI is missing"
"$SYS_PY" -I "$CHECK" codexjson .propel/codex.json || exit 1
cp .propel/codex.json "$T/cfg.before"
consult nopy "$RUN_BASH" "$T/in.brief" --label "Gate 4 (diagnosis)"
case "$OUT" in *"=== CODEX UNAVAILABLE ==="*) ;; *) fail "second missing-CLI run not UNAVAILABLE" ;; esac
cmp -s "$T/cfg.before" .propel/codex.json || fail "codex.json rewritten on the second run"
check_ledger bash 2 unavailable
printf '{"enabled": true, "note": "written by the user"}\n' > .propel/codex.json
cp .propel/codex.json "$T/cfg.before"
consult nopy "$RUN_BASH" "$T/in.brief" --label "Gate 4 (diagnosis)"
cmp -s "$T/cfg.before" .propel/codex.json || fail "an existing codex.json was rewritten without python3"
check_ledger bash 3 unavailable
pass "b. missing CLI: UNAVAILABLE, codex.json created as python would, never rewritten"

# ── c. a reply, with a hostile question and label ──
Q=$'say "quotes" and a back\\slash\nthen a new line\tand a tab \x01ctl h\xc3\xa9llo \xe4\xb8\x96\xe7\x95\x8c \xe2\x9c\x93'
L='Gate "2": design \ review'
QLONG="x"; i=0
while [ $i -lt 300 ]; do QLONG="$QLONG"$'\xe7\x95\x8c'; i=$((i + 1)); done
LNASTY=$'ctl \x7f\x08\x0c\x1b ls\xe2\x80\xa8ps\xe2\x80\xa9nel\xc2\x85 end'
LCTL=$'ctl \x7f del \x08 bs \x0c ff \x1b esc \x02 end'   # byte-identical to json.dumps
SP5K=$(printf '%5000s' '')
QWS="$SP5K"$'\n\n\t\r\n'"$SP5K"'the actual question?   '
QMID="alpha$SP5K"$'\n'"$SP5K$SP5K"' omega'
QWORDS=$(yes 'lorem  ipsum dolor' | head -c 10000)
QEXOTIC=$'one\xe3\x80\x80two\xc2\xa0three\x1cfour\x0bfive'
printf 'a short reply from the fake codex\n' > "$STUB_REPLY"
echo reply > "$STUB_MODE"
FIRST_BASH_LEDGER=""
for LOC in "" $UTF8_LOC; do
    new_proj '{"enabled": true}'
    CPATH="$FAKE_BIN:$NOPY_BIN"
    consult nopy "$RUN_BASH" "$T/in.brief" --label "$L" --question "$Q" --timeout 30
    case "$OUT" in *"=== CODEX REPLY ==="*"a short reply from the fake codex"*"--- end ---"*) ;; *) fail "no REPLY block (LC_ALL=${LOC:-C})" ;; esac
    [ -e "$STUB_MARK" ] || fail "codex was not called (LC_ALL=${LOC:-C})"
    check_ledger bash 1 reply CK_LABEL="$L" CK_QRAW="$Q" CK_DURATION=number
    [ -f "$STUB_SNAP" ] || fail "no codex-running.json while codex ran (LC_ALL=${LOC:-C})"
    CK_LABEL="$L" CK_TIMEOUT=30 "$SYS_PY" -I "$CHECK" running "$STUB_SNAP" .propel/codex-log.jsonl || exit 1
    [ ! -e .propel/codex-running.json ] || fail "codex-running.json left behind after the consult"
    [ -n "$FIRST_BASH_LEDGER" ] || FIRST_BASH_LEDGER="$PWD/.propel/codex-log.jsonl"

    consult nopy "$RUN_BASH" "$T/in.brief" --label "long question" --question "$QLONG"
    check_ledger bash 2 reply CK_QRAW="$QLONG" CK_QMODE=prefix CK_QMIN=80

    consult nopy "$RUN_BASH" "$T/in.brief" --label "$LNASTY" --question "q"
    check_ledger bash 3 reply CK_LABEL="$LNASTY" CK_EXACT=0

    # Question and label semantics, on the disabled path (no poll, same writer).
    new_proj '{"enabled": false}'
    n=0
    for q in "$QWS" "$QMID" "$QWORDS" "$QEXOTIC"; do
        n=$((n + 1))
        consult nopy "$RUN_BASH" "$T/in.brief" --label "$LCTL" --question "$q"
        check_ledger bash $n disabled CK_LABEL="$LCTL" CK_QRAW="$q"
    done
done
LOC=""
pass "c. reply without python3: valid JSON lines, python's key order, question and escapes, numeric duration, running marker (C${UTF8_LOC:+ and $UTF8_LOC})"

echo ""
echo "Testing: codex-consult.sh with python3 (regression)"
echo "================================"

# ── d. the python writer still produces the same shape ──
new_proj '{"enabled": true}'
CPATH="$FAKE_BIN:$PATH"; LOC=""
consult py "$RUN_BASH" "$T/in.brief" --label "$L" --question "$Q" --timeout 30
case "$OUT" in *"=== CODEX REPLY ==="*"a short reply from the fake codex"*) ;; *) fail "no REPLY block on the python path" ;; esac
check_ledger py 1 reply CK_LABEL="$L" CK_QRAW="$Q" CK_DURATION=number
CK_LABEL="$L" CK_TIMEOUT=30 "$SYS_PY" -I "$CHECK" running "$STUB_SNAP" .propel/codex-log.jsonl || exit 1
"$SYS_PY" -I "$CHECK" same "$FIRST_BASH_LEDGER" .propel/codex-log.jsonl || exit 1
pass "d. python path: same key order, same label and question as the bash path"

echo ""
echo "Testing: codex-consult.sh failure paths without python3"
echo "================================"

# ── e. empty / blank reply, blank brief, unauthenticated CLI ──
CPATH="$FAKE_BIN:$NOPY_BIN"; LOC=""
for mode in empty blank; do
    new_proj '{"enabled": true}'
    echo "$mode" > "$STUB_MODE"
    consult nopy "$RUN_BASH" "$T/in.brief" --label "Gate 3" --question "q"
    case "$OUT" in *"=== CODEX UNAVAILABLE ==="*"reason: codex returned an empty response"*) ;; *) fail "$mode reply not reported as an empty response" ;; esac
    check_ledger bash 1 unavailable CK_DETAIL="codex returned an empty response"
done

new_proj '{"enabled": true}'
echo reply > "$STUB_MODE"
printf ' \n\t ' > "$T/in.blank"
consult nopy "$RUN_BASH" "$T/in.blank" --label "Gate 3" --question "q"
case "$OUT" in *"=== CODEX UNAVAILABLE ==="*"reason: empty brief"*) ;; *) fail "whitespace-only brief not rejected as empty" ;; esac
[ ! -e "$STUB_MARK" ] || fail "codex was called with a blank brief"
check_ledger bash 1 unavailable CK_DETAIL="empty brief"

new_proj '{"enabled": true}'
echo 401 > "$STUB_MODE"
consult nopy "$RUN_BASH" "$T/in.brief" --label "Gate 3" --question "q"
case "$OUT" in *"=== CODEX UNAVAILABLE ==="*"not authenticated"*) ;; *) fail "401 not reported as not authenticated" ;; esac
check_ledger bash 1 unavailable CK_DETAIL="codex exited 1 (not authenticated)" CK_NOT="Unauthorized"
grep -q "sk-CANARY-401" .propel/codex-log.jsonl && fail "codex stderr leaked into the ledger"
pass "e. empty and blank replies, blank brief and 401 degrade; stderr never reaches the ledger"

echo ""
echo "Testing: codex-consult.sh speed on a large brief ($SLOW_BASH, LC_ALL=${UTF8_LOC:-C})"
echo "================================"

# ── f. the blank checks are linear; ${X// } took ~5 s on 8 KB under bash 3.2 ──
# Any consult that reaches codex pays the wrapper's fixed 1 s poll interval, so
# the large run is measured against a 1-byte baseline rather than against 1 s.
CPATH="$FAKE_BIN:$NOPY_BIN"; LOC="$UTF8_LOC"
yes $'def f(x): return x + 1  # h\xc3\xa9llo, a "quoted" word and a tab\there' | head -c 40960 > "$T/in.big"
cp "$T/in.big" "$STUB_REPLY"
printf 'x' > "$T/in.tiny"
echo reply > "$STUB_MODE"

new_proj '{"enabled": true}'
timed_consult nopy "$SLOW_BASH" "$T/in.tiny" --label "speed baseline" --question "q"
BASE_MS=$MS
timed_consult nopy "$SLOW_BASH" "$T/in.big" --label "speed 40 KB" --question "q"
BIG_MS=$MS
case "$OUT" in *"=== CODEX REPLY ==="*"--- end ---"*) ;; *) fail "40 KB brief got no REPLY block" ;; esac
[ "${#OUT}" -ge 40000 ] || fail "40 KB reply not passed through (${#OUT} chars of output)"
[ $((BIG_MS - BASE_MS)) -lt 1000 ] || fail "40 KB brief + reply took ${BIG_MS} ms vs ${BASE_MS} ms for 1 byte"
check_ledger bash 2 reply

printf '%40960s' '' > "$T/in.wsbig"; printf '\n\t\n' >> "$T/in.wsbig"
new_proj '{"enabled": true}'
timed_consult nopy "$SLOW_BASH" "$T/in.wsbig" --label "speed blank" --question "q"
case "$OUT" in *"reason: empty brief"*) ;; *) fail "40 KB whitespace-only brief not rejected as empty" ;; esac
[ "$MS" -lt 1000 ] || fail "40 KB whitespace-only brief took ${MS} ms to reject"
pass "f. 40 KB brief + reply: ${BIG_MS} ms (1-byte baseline ${BASE_MS} ms); 40 KB blank brief rejected in ${MS} ms"

echo ""
echo "Testing: codex-consult.sh with a python3 that does not work"
echo "================================"

# ── h. a python3 that exists but fails must not cost the gate its guarantees ──
for kind in fail silent half; do
    D="$T/py-$kind"; mkdir -p "$D"
    case "$kind" in
        fail)   printf '#!/bin/sh\nexit 1\n' > "$D/python3" ;;
        silent) printf '#!/bin/sh\nexit 0\n' > "$D/python3" ;;
        half)   printf '#!/bin/sh\n[ "$1" = - ] && exit 3\nexec %s "$@"\n' "$SYS_PY" > "$D/python3" ;;
    esac
    chmod +x "$D/python3"
    LOC=""

    new_proj '{"enabled": false}'
    CPATH="$D:$FAKE_BIN:$NOPY_BIN"
    consult nopy "$RUN_BASH" "$T/in.brief" --label "Gate 1" --question "broken python"
    case "$OUT" in *"reason: codex disabled for this project"*) ;; *) fail "enabled:false ignored with a $kind python3" ;; esac
    [ ! -e "$STUB_MARK" ] || fail "codex called although disabled ($kind python3)"
    check_ledger bash 1 disabled CK_QRAW="broken python" CK_DURATION=number

    new_proj '{"enabled": true}'
    echo reply > "$STUB_MODE"; printf 'a reply\n' > "$STUB_REPLY"
    consult nopy "$RUN_BASH" "$T/in.brief" --label "Gate 2" --question "q" --timeout 30
    case "$OUT" in *"=== CODEX REPLY ==="*) ;; *) fail "no reply with a $kind python3" ;; esac
    check_ledger bash 1 reply CK_DURATION=number
    [ -f "$STUB_SNAP" ] || fail "no running marker with a $kind python3"
    CK_LABEL="Gate 2" CK_TIMEOUT=30 "$SYS_PY" -I "$CHECK" running "$STUB_SNAP" .propel/codex-log.jsonl || exit 1

    new_proj
    CPATH="$D:$NOPY_BIN"
    consult nopy "$RUN_BASH" "$T/in.brief" --label "Gate 4" --question "q"
    check_ledger bash 1 unavailable CK_DETAIL="codex CLI not found on PATH"
    "$SYS_PY" -I "$CHECK" codexjson .propel/codex.json || exit 1
done
pass "h. failing, silent and half-working python3: disabled honoured, exactly one ledger line, marker and codex.json still written"

# ── i. --timeout is normalized before it reaches a JSON writer ──
CPATH="$FAKE_BIN:$NOPY_BIN"; LOC=""
echo reply > "$STUB_MODE"
for pair in "008:8" "99999999999999999999:240" "0005:5"; do
    new_proj '{"enabled": true}'
    consult nopy "$RUN_BASH" "$T/in.brief" --label "t" --question "q" --timeout "${pair%%:*}"
    [ -f "$STUB_SNAP" ] || fail "no running marker for --timeout ${pair%%:*}"
    CK_TIMEOUT="${pair#*:}" "$SYS_PY" -I "$CHECK" running "$STUB_SNAP" .propel/codex-log.jsonl || exit 1
done
pass "i. --timeout 008 / 0005 / 20 digits land as valid JSON numbers (8 / 5 / 240)"

# ── j. the ledger fallback follows python's explicit signal, never a guess ──
CPATH="$FAKE_BIN:$NOPY_BIN"; LOC=""
echo reply > "$STUB_MODE"; printf 'a reply\n' > "$STUB_REPLY"
for kind in swallow empty3; do
    D="$T/py-$kind"; mkdir -p "$D"
    case "$kind" in
        # wrote its line, lost the WROTE signal, exited 1: must not write again
        swallow) printf '#!/bin/sh\n%s "$@" >/dev/null\nexit 1\n' "$SYS_PY" > "$D/python3" ;;
        # created the ledger, then failed before writing (exit 3): bash writes
        empty3)  printf '#!/bin/sh\nif [ "$1" = - ]; then mkdir -p .propel; : >> .propel/codex-log.jsonl; exit 3; fi\nexec %s "$@"\n' "$SYS_PY" > "$D/python3" ;;
    esac
    chmod +x "$D/python3"
    new_proj '{"enabled": false}'
    CPATH="$D:$FAKE_BIN:$NOPY_BIN"
    consult nopy "$RUN_BASH" "$T/in.brief" --label "Gate 1" --question "q"
    check_ledger "$([ $kind = swallow ] && echo py || echo bash)" 1 disabled
done
# A write-only (0200) ledger: python appends fine; exactly one line, both paths.
for path in py nopy; do
    new_proj '{"enabled": false}'
    : > .propel/codex-log.jsonl; chmod 200 .propel/codex-log.jsonl
    if [ $path = py ]; then CPATH="$FAKE_BIN:$PATH"; else CPATH="$FAKE_BIN:$NOPY_BIN"; fi
    consult "$path" "$RUN_BASH" "$T/in.brief" --label "Gate 1" --question "q"
    chmod 600 .propel/codex-log.jsonl
    check_ledger "$([ $path = py ] && echo py || echo bash)" 1 disabled
done
pass "j. ledger: lost WROTE signal never double-writes, exit 3 falls back, a 0200 ledger gets one line"

# ── k. only JSON false disables: "false" and null still consult ──
for cfg in '{"enabled": "false"}' '{"enabled": null}'; do
    for path in py nopy; do
        new_proj "$cfg"
        if [ $path = py ]; then CPATH="$FAKE_BIN:$PATH"; else CPATH="$FAKE_BIN:$NOPY_BIN"; fi
        consult "$path" "$RUN_BASH" "$T/in.brief" --label "Gate 1" --question "q"
        [ -e "$STUB_MARK" ] || fail "$cfg was read as disabled ($path)"
        check_ledger "$([ $path = py ] && echo py || echo bash)" 1 reply
    done
done
pass "k. {\"enabled\": \"false\"} and {\"enabled\": null} consult, with and without python3"

# ── g. ──
pass "g. all $RUNS consults exited 0"

echo ""
echo "================================"
echo "All codex-consult tests passed!"
