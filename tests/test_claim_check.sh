#!/usr/bin/env bash
# Propel — scripts/claim-check.sh: token classes, BEFORE/AFTER reporting,
# exit codes, and speed on a large file, all with no python3 on PATH.
#
#   bash tests/test_claim_check.sh
#   /bin/bash tests/test_claim_check.sh
#
# Every script run uses a PATH holding only the tools claim-check.sh may use.
# Stops at the first failure with a non-zero exit.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CC="$ROOT/scripts/claim-check.sh"
RUN_BASH="${BASH:-bash}"          # the interpreter running this suite
SLOW_BASH=/bin/bash               # macOS ships bash 3.2 here; the speed case uses it
[ -x "$SLOW_BASH" ] || SLOW_BASH="$RUN_BASH"

T=$(mktemp -d "${TMPDIR:-/tmp}/propel-claim-check-test.XXXXXX") || { echo "FAIL: test setup — mktemp -d"; exit 1; }
cleanup() { cd / 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

fail() {
    echo "FAIL: $*"
    if [ -f "$T/out" ]; then
        echo "---- claim-check output (first 20 lines) ----"
        head -n 20 "$T/out"
    fi
    exit 1
}
pass() { echo "PASS: $*"; }

# ── no-python3 PATH: symlinks to just the tools the script uses ──
NOPY_BIN="$T/nopy-bin"
mkdir -p "$NOPY_BIN"
for tool in bash awk sed cat mkdir; do
    TOOL_PATH=$(type -P "$tool" 2>/dev/null || true)
    case "$TOOL_PATH" in
        /*) ln -s "$TOOL_PATH" "$NOPY_BIN/$tool" ;;
        *)  fail "test setup — $tool not found for the no-python3 PATH" ;;
    esac
done
if [ -e "$NOPY_BIN/python3" ] || env -i PATH="$NOPY_BIN" "$RUN_BASH" -c 'command -v python3' >/dev/null 2>&1; then
    fail "test setup — python3 leaked into the no-python3 PATH"
fi

# cc <bash> <args...> -> RC, output (stdout + stderr) in $T/out. Runs in
# $CC_CWD (default: the current dir) with PATH=$CC_PATH (default: $NOPY_BIN).
cc() {
    local sh="$1"; shift
    ( cd "${CC_CWD:-$PWD}" && exec env -i PATH="${CC_PATH:-$NOPY_BIN}" "$sh" "$CC" "$@" ) >"$T/out" 2>&1
    RC=$?
}
expect_rc() { [ "$RC" -eq "$1" ] || fail "$2: exit $RC, expected $1"; }
has() { grep -qF -- "$1" "$T/out" || fail "$2 (missing '$1')"; }
hasnt() { if grep -qF -- "$1" "$T/out"; then fail "$2 (unexpected '$1')"; fi; }

# ── a. every token class is extracted ──
cat > "$T/draft.md" <<'EOF'
# Findings

The loader drops the last batch (src/data/loader.py:118).
The fix spans src/data/loader.py:118-131 and `drop_last=False`.
[codex] agreed; [claude] verified; [both] signed off; [codex · unverified] suspects the sampler.
Step time fell from 412 ms to 0.38 s, a 12% cut, 3x faster on 40 KB batches.
Fixed in 28636a3; see https://example.com/issues/7.
Not tokens: exit 2, Gate 1, 21 -> 22, the time 10:30, the word deadbeef.
EOF
cc "$RUN_BASH" --list "$T/draft.md"
expect_rc 0 "a. --list"
for want in \
    "1	path:line	src/data/loader.py:118" \
    "1	path:line	src/data/loader.py:118-131" \
    "1	backtick	\`drop_last=False\`" \
    "1	tag	[codex]" "1	tag	[claude]" "1	tag	[both]" "1	tag	[codex · unverified]" \
    "1	number	412 ms" "1	number	0.38 s" "1	number	12%" "1	number	3x" "1	number	40 KB" \
    "1	hash	28636a3" \
    "1	url	https://example.com/issues/7"; do
    has "$want" "a. token class not extracted"
done
if grep -E '	(1|2|21|22|10|30|10:30|deadbeef|time 10:30)$' "$T/out" >/dev/null; then
    fail "a. a bare integer, a time or a hex-only word was extracted"
fi
[ "$(wc -l < "$T/out")" -eq 14 ] || fail "a. expected exactly 14 tokens, got $(wc -l < "$T/out")"
cc "$RUN_BASH" "$T/draft.md"
expect_rc 0 "a. one file without --list"
has "1	hash	28636a3" "a. one file lists like --list"
pass "a. path:line, ranges, backticks, the four tags, numbers with units / % / decimals, hashes and URLs are extracted; bare integers, times and hex-only words are not"

# ── b. a dropped token of each class is reported with its first draft line ──
drop() {  # <label> <sed expression> <expected report line>
    sed "$2" "$T/draft.md" > "$T/rewrite.md"
    cc "$RUN_BASH" "$T/draft.md" "$T/rewrite.md"
    expect_rc 1 "b. dropped $1"
    has "$3" "b. dropped $1 not reported with its line"
    [ "$(grep -c '^missing' "$T/out")" -eq 1 ] || fail "b. dropping $1 reported $(grep -c '^missing' "$T/out") tokens, expected 1"
}
drop "path:line" 's| (src/data/loader.py:118)\.|.|' \
    "missing	path:line	src/data/loader.py:118	line 3	(before 1, after 0)"
drop "number"    's|0\.38 s|less|' \
    "missing	number	0.38 s	line 6	(before 1, after 0)"
drop "backtick"  's|`drop_last=False`|the flag|' \
    "missing	backtick	\`drop_last=False\`	line 4	(before 1, after 0)"
drop "tag"       's|\[codex · unverified\]|Codex|' \
    "missing	tag	[codex · unverified]	line 5	(before 1, after 0)"
drop "URL"       's|; see https://example.com/issues/7||' \
    "missing	url	https://example.com/issues/7	line 7	(before 1, after 0)"
drop "hash"      's|Fixed in 28636a3;|Fixed;|' \
    "missing	hash	28636a3	line 7	(before 1, after 0)"
has "Restore them" "b. no restore notice on stderr"
pass "b. a dropped path:line, number, backtick span, tag, URL and hash are each reported with their draft line; exit 1"

# ── c. a rewrite that only reorders and rewords keeps exit 0 ──
{
    echo "# Findings (reordered)"
    sed -n '7p;6p;5p;4p;3p' "$T/draft.md"
    echo "Prose changed, tokens kept."
} > "$T/rewrite.md"
cc "$RUN_BASH" "$T/draft.md" "$T/rewrite.md"
expect_rc 0 "c. reorder"
hasnt "missing	" "c. reorder reported a token"
has "no extracted token missing" "c. exit-0 message"
has "Meaning can still have changed" "c. exit-0 message must not claim no evidence was lost"
pass "c. reordering lines and rewording prose keeps every token: exit 0, and the message says meaning can still change"

# ── d. a count decrease is information, not a failure (cutting a restatement does it) ──
printf 'Run a.py:3 then a.py:3 again, 5 ms each, 5 ms total.\n' > "$T/twice.md"
printf 'Run a.py:3 twice, 5 ms each.\n' > "$T/once.md"
cc "$RUN_BASH" "$T/twice.md" "$T/once.md"
expect_rc 0 "d. count decrease alone"
has "fewer	path:line	a.py:3	line 1	(before 2, after 1)" "d. path:line count decrease"
has "fewer	number	5 ms	line 1	(before 2, after 1)" "d. number count decrease"
has "2 with a lower count" "d. summary counts the lower-count tokens"
hasnt "missing	" "d. a lower count was reported as missing"
cc "$RUN_BASH" "$T/once.md" "$T/twice.md"
expect_rc 0 "d. count increase is not a loss"
hasnt "fewer	" "d. a higher count was reported"
printf 'Run a.py:3 twice.\n' > "$T/nonum.md"
cc "$RUN_BASH" "$T/twice.md" "$T/nonum.md"
expect_rc 1 "d. a lower count plus a missing token"
has "fewer	path:line	a.py:3" "d. fewer line next to a missing one"
has "missing	number	5 ms	line 1	(before 2, after 0)" "d. a token gone entirely is still missing"
pass "d. a lower count prints a 'fewer' line and keeps exit 0; only a token gone entirely exits 1"

# ── e. usage errors and unreadable files exit 2 ──
for args in "" "--list" "a b c" "--bogus x" "--list $T/draft.md extra" "--save-draft" "--list --save-draft $T/draft.md" "-- a b c"; do
    # shellcheck disable=SC2086
    cc "$RUN_BASH" $args
    expect_rc 2 "e. usage '$args'"
    has "usage:" "e. usage '$args' prints usage"
done
cc "$RUN_BASH" "$T/nope.md"
expect_rc 2 "e. missing file"
cc "$RUN_BASH" "$T/draft.md" "$T/nope.md"
expect_rc 2 "e. missing AFTER"
cc "$RUN_BASH" "$T" "$T/draft.md"
expect_rc 2 "e. directory as BEFORE"
cc "$RUN_BASH" --help
expect_rc 0 "e. --help"
has 'never means "no' "e. --help must say exit 0 is not \"no evidence lost\""
: > "$T/empty.md"
cc "$RUN_BASH" "$T/empty.md" "$T/draft.md"
expect_rc 0 "e. empty BEFORE"
cc "$RUN_BASH" "$T/draft.md" "$T/empty.md"
expect_rc 1 "e. empty AFTER"
pass "e. no file, three files, a bad option, a missing file or a directory exit 2 with usage; --help exits 0; empty files are handled"

# ── f. file contents never leak beyond the tokens ──
printf 'SECRET-PROSE-CANARY sits beside a.py:9 and 2.5 s.\n' > "$T/leak.md"
cc "$RUN_BASH" "$T/leak.md" "$T/empty.md"
hasnt "SECRET-PROSE-CANARY" "f. prose leaked into the comparison output"
cc "$RUN_BASH" --list "$T/leak.md"
hasnt "SECRET-PROSE-CANARY" "f. prose leaked into the list output"
pass "f. only tokens are printed, never the surrounding text"

# ── h. ratios, result counts, exponents, signs, and URLs with parentheses ──
cat > "$T/more.md" <<'EOF'
Suite: 125/125 green, then 0/0/0 skipped; 3 failed, 125 passed, 12 errors.
lr=3e-4, eps 1e-6, 2.5E+3, a shift of -0.5 and (+3%), slots 21-22 s.
See https://en.wikipedia.org/wiki/Foo_(bar)) and (https://example.org/a).
Not tokens: path a/1/2, v1/2, 2 failuresome, v5.5, x-1.
EOF
cc "$RUN_BASH" --list "$T/more.md"
expect_rc 0 "h. --list"
for want in "1	ratio	125/125" "1	ratio	0/0/0" "1	result	3 failed" "1	result	125 passed" "1	result	12 errors" \
    "1	number	3e-4" "1	number	1e-6" "1	number	2.5E+3" "1	number	-0.5" "1	number	+3%" "1	number	22 s" \
    "1	url	https://en.wikipedia.org/wiki/Foo_(bar)" "1	url	https://example.org/a"; do
    has "$want" "h. token not extracted"
done
for bad in "	1/2" "	-22 s" "	21-22 s" "a)	" "/a)"; do hasnt "$bad" "h. wrong token"; done
[ "$(wc -l < "$T/out")" -eq 13 ] || fail "h. expected exactly 13 tokens, got $(wc -l < "$T/out")"
sed 's|3 failed|three failed|; s|125/125 green|all green|' "$T/more.md" > "$T/more2.md"
cc "$RUN_BASH" "$T/more.md" "$T/more2.md"
expect_rc 1 "h. dropped ratio and result"
has "missing	ratio	125/125	line 1" "h. dropped ratio"
has "missing	result	3 failed	line 1" "h. dropped result count"
pass "h. N/M[/K] ratios, 'N passed/failed/errors' counts, 3e-4 / 2.5E+3, signs after space ( =, and balanced-paren URLs are tokens"

# ── i. reflowing a number away from its unit is not a change ──
printf 'The step took 412\nms and moved 40 KB.\n' > "$T/flow1.md"
printf 'The step took 412 ms and moved 40\n   KB.\n' > "$T/flow2.md"
cc "$RUN_BASH" --list "$T/flow1.md"
has "1	number	412 ms" "i. unit on the next line not joined"
cc "$RUN_BASH" "$T/flow1.md" "$T/flow2.md"
expect_rc 0 "i. reflow"
hasnt "missing	" "i. a reflow reported a token"
printf 'Took 412    ms.\n' > "$T/flow3.md"
cc "$RUN_BASH" "$T/flow1.md" "$T/flow3.md"
hasnt "missing	number	412 ms" "i. runs of spaces between number and unit not normalised"
pass "i. a number and its unit split by a line break or extra spaces is the same token"

# ── j. dropping only the backticks is information, not a missing token ──
printf 'Set `drop_last=False` and run `make eval`.\n' > "$T/bt1.md"
printf 'Set drop_last=False and run the evaluation.\n' > "$T/bt2.md"
cc "$RUN_BASH" "$T/bt1.md" "$T/bt2.md"
expect_rc 1 "j. one span unquoted, one gone"
has "unquoted	backtick	\`drop_last=False\`	line 1	(inner text kept)" "j. unquoted span"
has "missing	backtick	\`make eval\`	line 1	(before 1, after 0)" "j. gone span"
[ "$(grep -c '^missing' "$T/out")" -eq 1 ] || fail "j. the unquoted span was counted as missing"
pass "j. a backtick span whose text survives is reported 'unquoted' and does not fail; a span gone entirely does"

# ── k. CRLF line endings, and -- before file names ──
printf 'Took 0.5 s at a.py:3.\r\nEnd 12%%\r\n' > "$T/crlf.md"
printf 'Took 0.5 s at a.py:3.\nEnd 12%%\n' > "$T/lf.md"
cc "$RUN_BASH" "$T/crlf.md" "$T/lf.md"
expect_rc 0 "k. CRLF against LF"
cc "$RUN_BASH" "$T/lf.md" "$T/crlf.md"
expect_rc 0 "k. LF against CRLF"
cp "$T/lf.md" "$T/-dash.md"
cc "$RUN_BASH" -- "$T/lf.md" "$T/-dash.md"
expect_rc 0 "k. -- then two files"
CC_CWD="$T" cc "$RUN_BASH" --list -- -dash.md
expect_rc 0 "k. --list -- -dash.md"
has "1	number	0.5 s" "k. --list -- reads the file"
pass "k. CRLF files compare equal to LF files; -- ends option parsing"

# ── l. awk failing is exit 3, not a verdict ──
BROKEN_BIN="$T/broken-bin"
mkdir -p "$BROKEN_BIN"
for tool in bash sed cat mkdir; do ln -s "$(type -P "$tool")" "$BROKEN_BIN/$tool"; done
printf '#!/bin/sh\necho "awk: simulated crash" >&2\nexit 2\n' > "$BROKEN_BIN/awk"
chmod +x "$BROKEN_BIN/awk"
CC_PATH="$BROKEN_BIN" cc "$RUN_BASH" "$T/lf.md" "$T/crlf.md"
expect_rc 3 "l. awk exiting 2"
CC_PATH="$BROKEN_BIN" cc "$RUN_BASH" --list "$T/lf.md"
expect_rc 3 "l. awk exiting 2 in --list"
pass "l. an awk failure exits 3, distinct from usage (2) and missing tokens (1)"

# ── m. --save-draft: path from the repo-relative path, never overwrites ──
P="$T/proj"; mkdir -p "$P/scratch/2026-11-18-x" "$P/docs"
printf 'draft one, 0.5 s\n' > "$P/scratch/2026-11-18-x/README.md"
printf 'other README\n' > "$P/docs/README.md"
D1=".propel/concise/scratch__2026-11-18-x__README.md.draft.md"
CC_CWD="$P" cc "$RUN_BASH" --save-draft scratch/2026-11-18-x/README.md
expect_rc 0 "m. save a draft"
[ "$(cat "$T/out")" = "$D1" ] || fail "m. printed '$(cat "$T/out")', expected '$D1'"
cmp -s "$P/$D1" "$P/scratch/2026-11-18-x/README.md" || fail "m. draft is not a copy of the artifact"
CC_CWD="$P" cc "$RUN_BASH" --save-draft ./docs/README.md
expect_rc 0 "m. a second README with the same file name"
[ -f "$P/.propel/concise/docs__README.md.draft.md" ] || fail "m. docs/README.md draft not at docs__README.md.draft.md"
printf 'rewritten\n' > "$P/scratch/2026-11-18-x/README.md"
CC_CWD="$P" cc "$RUN_BASH" --save-draft scratch/2026-11-18-x/README.md
expect_rc 1 "m. a pending draft"
has "already pending at $D1" "m. refusal names the pending draft"
grep -q 'draft one' "$P/$D1" || fail "m. the pending draft was overwritten"
CC_CWD="$P" cc "$RUN_BASH" --save-draft "$P/docs/README.md"
expect_rc 1 "m. absolute path under the repo maps to the same draft"
has "docs__README.md.draft.md" "m. absolute path not made repo-relative"
printf 'top\n' > "$P/NOTES.md"
CC_CWD="$P" cc "$RUN_BASH" --save-draft NOTES.md
expect_rc 0 "m. a file at the repo root"
[ "$(cat "$T/out")" = ".propel/concise/NOTES.md.draft.md" ] || fail "m. root file draft path is '$(cat "$T/out")'"
printf 'x\n' > "$T/outside.md"
CC_CWD="$P" cc "$RUN_BASH" --save-draft ../outside.md
expect_rc 2 "m. a file outside the repo"
CC_CWD="$P" cc "$RUN_BASH" --save-draft "$T/outside.md"
expect_rc 2 "m. an absolute path outside the repo"
pass "m. --save-draft writes .propel/concise/<path with / as __>.draft.md, keeps same-named files apart, and refuses to overwrite a pending draft"

# ── g. a 1 MB file finishes in under 2 s on $SLOW_BASH ──
yes 'Step 3 read src/models/vq_loss.py:42-57 with `loss.backward()` [codex] in 0.25 s (12% of 40 KB), commit 1a2b3c4d, https://example.com/x and prose words.' \
    | head -c 1048576 > "$T/big.md"
sed 's|0\.25 s|fast|' "$T/big.md" > "$T/big2.md"
TIMEFORMAT=%R
{ time cc "$SLOW_BASH" "$T/big.md" "$T/big2.md" ; } 2>"$T/time"
t=$(tail -n 1 "$T/time"); t=${t/,/}; t=${t/./}
case "$t" in ''|*[!0-9]*) fail "g. could not read the timing ($(cat "$T/time"))" ;; esac
MS=$((10#$t))
expect_rc 1 "g. 1 MB comparison"
has "missing	number	0.25 s	line 1" "g. 1 MB comparison missed the dropped number"
[ "$MS" -lt 2000 ] || fail "g. 1 MB comparison took ${MS} ms (limit 2000)"
pass "g. 1 MB BEFORE/AFTER comparison finished in ${MS} ms on $SLOW_BASH"

echo "All claim-check tests passed."
