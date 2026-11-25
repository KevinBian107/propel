#!/usr/bin/env bash
# Propel — scripts/doc-check.sh: each check's positive and negative cases,
# output format, exit codes and determinism, all with no python3 on PATH.
#
#   bash tests/test_doc_check.sh
#   /bin/bash tests/test_doc_check.sh
#
# Every script run uses a PATH holding only the tools doc-check.sh may use.
# Stops at the first failure with a non-zero exit.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DC="$ROOT/scripts/doc-check.sh"
RUN_BASH="${BASH:-bash}"          # the interpreter running this suite

T=$(mktemp -d "${TMPDIR:-/tmp}/propel-doc-check-test.XXXXXX") || { echo "FAIL: test setup — mktemp -d"; exit 1; }
cleanup() { cd / 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

fail() {
    echo "FAIL: $*"
    if [ -f "$T/out" ]; then
        echo "---- doc-check output (first 20 lines) ----"
        head -n 20 "$T/out"
    fi
    exit 1
}
pass() { echo "PASS: $*"; }

# ── no-python3 PATH: symlinks to just the tools the script uses ──
NOPY_BIN="$T/nopy-bin"
mkdir -p "$NOPY_BIN"
for tool in bash awk sed; do
    TOOL_PATH=$(type -P "$tool" 2>/dev/null || true)
    case "$TOOL_PATH" in
        /*) ln -s "$TOOL_PATH" "$NOPY_BIN/$tool" ;;
        *)  fail "test setup — $tool not found for the no-python3 PATH" ;;
    esac
done
if [ -e "$NOPY_BIN/python3" ] || env -i PATH="$NOPY_BIN" "$RUN_BASH" -c 'command -v python3' >/dev/null 2>&1; then
    fail "test setup — python3 leaked into the no-python3 PATH"
fi

# A throwaway repo: docs/ plus the code the docs point at.
P="$T/repo"
mkdir -p "$P/docs/methods" "$P/src/models" "$P/configs"
printf 'x = 1\n' > "$P/src/models/encoder.py"
printf 'lr: 1\n' > "$P/configs/base.yaml"

# dc <args...> -> RC, output (stdout + stderr) in $T/out. Runs in $P with
# PATH=$NOPY_BIN under $DC_BASH (default: the suite's bash).
dc() {
    ( cd "$P" && exec env -i PATH="$NOPY_BIN" "${DC_BASH:-$RUN_BASH}" "$DC" "$@" ) >"$T/out" 2>&1
    RC=$?
}
expect_rc() { [ "$RC" -eq "$1" ] || fail "$2: exit $RC, expected $1"; }
has() { grep -qF -- "$1" "$T/out" || fail "$2 (missing '$1')"; }
hasnt() { if grep -qF -- "$1" "$T/out"; then fail "$2 (unexpected '$1')"; fi; }
count() { [ "$(grep -c -- "$1" "$T/out")" -eq "$2" ] || fail "$3: $(grep -c -- "$1" "$T/out") lines match '$1', expected $2"; }

STATUS='**Status** (2026-11-25): built and tested. **Why this design** It keeps one page per component.'

# ── a. a clean hub and a clean leaf: exit 0, no output ──
cat > "$P/docs/README.md" <<'EOF'
# Docs

| Page | Question |
|---|---|
| [Encoder](methods/encoder.md) | What does the encoder output? |
| [Encoder overview](methods/encoder.md#overview) | Where does it start? |
| [Hub top](#docs) | Back to the top |
| [Repo root](/src/models/) | Where is the code? |
| [Site](https://example.com/x) | External |

The history of these decisions lives in `scratch/`, outside version control.
EOF
cat > "$P/docs/methods/encoder.md" <<EOF
# Encoder: maps observations to latents

## Overview

The encoder maps [B, T, D] inputs to latents. Up: [docs](../README.md).

## Overview

A second heading with the same name: [link to it](#overview-1).

## Shapes & \`dtypes\` (float32)

Code: \`src/models/encoder.py\`, \`src/models/encoder.py:12\`, \`src/models/encoder.py::Encoder\`, \`src/models/\`, \`configs/base.yaml\`.
Not paths: \`[B, T, D]\`, \`1/2.5\`, \`e.g.\`, \`/usr/bin/env\`, \`bash run.sh --flag\`, \`TODO\`.
Plain words: TODOS, ATBD, FIXMEs.

\`\`\`
TODO inside a fence is exempt, so is [x](missing.md), \`src/gone.py\` and scratch/a/b.md
\`\`\`

$STATUS
EOF
dc docs/README.md docs/methods/encoder.md
expect_rc 0 "a. clean pages"
[ ! -s "$T/out" ] || fail "a. clean pages printed output"
dc --root . -- docs/README.md docs/methods/encoder.md
expect_rc 0 "a. clean pages with --root . --"
pass "a. clean hub and leaf: exit 0, no output (fences, plain words, non-path spans, duplicate headings, punctuation in headings, root-relative and URL links)"

# ── b. relative links: missing file, missing anchor, self anchor ──
cat > "$P/docs/links.md" <<EOF
# Links

[gone](methods/gone.md) and [gone dir](missing/) and [bad anchor](methods/encoder.md#nowhere).
[bad self](#nowhere-here) and [ok self](#links) and [anchor on non-md](../configs/base.yaml#x).
[root gone](/src/gone.py) and [ok](methods/encoder.md#shapes--dtypes-float32) and [ok dup](methods/encoder.md#overview-1).

$STATUS
EOF
dc docs/links.md
expect_rc 1 "b. broken links"
has "docs/links.md:3: link: target does not exist: methods/gone.md" "b. missing .md target"
has "docs/links.md:3: link: target does not exist: missing/" "b. missing directory target"
has "docs/links.md:3: anchor: no heading for #nowhere in methods/encoder.md" "b. missing anchor"
has "docs/links.md:4: anchor: no heading for #nowhere-here in this page" "b. missing self anchor"
has "docs/links.md:5: link: target does not exist: /src/gone.py" "b. missing root-relative target"
count ': link: \|: anchor: ' 5 "b. exactly the 5 broken links"
pass "b. relative, directory and root-relative links that do not resolve, and anchors (other page, this page) with no heading, are reported; GitHub-style slugs with punctuation and duplicates resolve"

# ── c. backticked paths ──
cat > "$P/docs/paths.md" <<EOF
# Paths

Code: \`src/models/decoder.py\`, \`src/data/\`, \`configs/missing.yaml:4\`, \`src/models/encoder.py\`.

$STATUS
EOF
dc docs/paths.md
expect_rc 1 "c. missing paths"
has "docs/paths.md:3: path: \`src/models/decoder.py\` does not exist under ." "c. missing file path"
has "docs/paths.md:3: path: \`src/data/\` does not exist under ." "c. missing directory path"
has "docs/paths.md:3: path: \`configs/missing.yaml\` does not exist under ." "c. path:line checked without its line"
hasnt "encoder.py" "c. an existing path was reported"
count ': path: ' 3 "c. exactly 3 missing paths"
# --root moves the base the paths are checked against.
mkdir -p "$P/sub/src/models"
printf 'y\n' > "$P/sub/src/models/decoder.py"
dc --root "$P/sub" docs/paths.md
has "\`src/models/encoder.py\` does not exist under $P/sub" "c. --root not used as the path base"
hasnt "decoder.py" "c. --root: decoder.py exists under the root"
pass "c. backticked repo paths (files, directories, path:line) that do not exist under the root are reported; --root changes the base"

# ── d. scratch/ ──
cat > "$P/docs/scratch.md" <<EOF
# Scratch

See [the log](../scratch/2026-11-01-x/README.md), \`scratch/registry/x/SKILL.md\` and scratch/notes.md.
History lives in \`scratch/\`, outside version control; a myscratch/x.md is not scratch.

$STATUS
EOF
dc docs/scratch.md
expect_rc 1 "d. scratch paths"
has "docs/scratch.md:3: scratch: path into scratch/: scratch/2026-11-01-x/README.md" "d. link into scratch/"
has "docs/scratch.md:3: scratch: path into scratch/: scratch/registry/x/SKILL.md" "d. backticked path into scratch/"
has "docs/scratch.md:3: scratch: path into scratch/: scratch/notes.md" "d. bare path into scratch/"
count ': scratch: ' 3 "d. exactly 3 scratch paths (naming scratch/ itself is fine)"
hasnt ": link: " "d. a scratch link was also reported as a broken link"
hasnt ": path: " "d. a scratch path was also reported as a missing path"
pass "d. links, backticked paths and bare paths into scratch/ are reported once each; naming scratch/ itself is not"

# ── e. TODO / TBD / FIXME ──
cat > "$P/docs/markers.md" <<EOF
# Markers

TODO: write this. The value is TBD.
(FIXME) here.
Not markers: TODOs, \`TODO\`, todo, ATBD.

$STATUS
EOF
dc docs/markers.md
expect_rc 1 "e. markers"
has "docs/markers.md:3: marker: TODO" "e. TODO"
has "docs/markers.md:3: marker: TBD" "e. TBD"
has "docs/markers.md:4: marker: FIXME" "e. FIXME"
count ': marker: ' 3 "e. exactly 3 markers"
pass "e. TODO, TBD and FIXME as words are reported; longer words, lowercase and backtick spans are not"

# ── f. emoji ──
printf '# Emoji\n\nDone \360\237\232\200 here.\n\n```\nalso \360\237\231\202 in a fence\n```\nArrows are fine: \342\206\222 and \342\200\224.\n\n%s\n' "$STATUS" > "$P/docs/emoji.md"
dc docs/emoji.md
expect_rc 1 "f. emoji"
has "docs/emoji.md:3: emoji: emoji in text" "f. emoji in prose"
has "docs/emoji.md:6: emoji: emoji in text" "f. emoji in a fence"
count ': emoji: ' 2 "f. exactly 2 emoji lines (arrows and dashes are not emoji)"
pass "f. emoji (\\xF0\\x9F...) are reported, also inside fences; other UTF-8 symbols are not"

# ── g. Status line on leaf pages ──
printf '# No status\n\nBody.\n' > "$P/docs/nostatus.md"
printf '# Undated\n\nBody.\n\n**Status:** built.\n' > "$P/docs/undated.md"
printf '# Dated\n\n**Status:** 2026-01-02, built.\n' > "$P/docs/dated.md"
printf '# Fenced\n\n```\n**Status** 2026-01-02\n```\n' > "$P/docs/fenced.md"
printf '# Hub\n\nNo status needed.\n' > "$P/docs/methods/index.md"
printf '# Hub\n\nNo status needed.\n' > "$P/docs/methods/README.md"
dc docs/nostatus.md docs/undated.md docs/dated.md docs/fenced.md docs/methods/index.md docs/methods/README.md
expect_rc 1 "g. status"
has "docs/nostatus.md:1: status: no **Status** line with a YYYY-MM-DD date (leaf page)" "g. missing Status"
has "docs/undated.md:5: status: **Status** line has no YYYY-MM-DD date" "g. undated Status"
has "docs/fenced.md:1: status: no **Status** line" "g. a Status line inside a fence does not count"
count ': status: ' 3 "g. exactly 3 status problems (dated leaf, index.md and README.md pass)"
pass "g. a leaf page needs a dated **Status** line; README.md and index.md hubs do not"

# ── h. output order, exit codes and usage ──
dc docs/nostatus.md docs/markers.md
expect_rc 1 "h. two files"
[ "$(sed -n '1p' "$T/out")" = "docs/nostatus.md:1: status: no **Status** line with a YYYY-MM-DD date (leaf page)" ] || fail "h. output not in argument order"
if grep -v '^[^:]*:[0-9][0-9]*: [a-z]*: ' "$T/out" >/dev/null; then fail "h. a line is not FILE:LINE: KIND: DETAIL"; fi
dc
expect_rc 2 "h. no FILE"
has "usage:" "h. no usage line"
dc docs/does-not-exist.md
expect_rc 2 "h. missing FILE"
dc --root "$P/nope" docs/dated.md
expect_rc 2 "h. --root not a directory"
dc --bogus docs/dated.md
expect_rc 2 "h. unknown option"
dc --help
expect_rc 0 "h. --help"
has "FILE:LINE: KIND: DETAIL" "h. --help prints the output format"
pass "h. one FILE:LINE: KIND: DETAIL line per problem in argument order; exit 0 / 1 / 2"

# ── i. deterministic, and the same under /bin/bash ──
ALL="docs/README.md docs/methods/encoder.md docs/links.md docs/paths.md docs/scratch.md docs/markers.md docs/emoji.md docs/nostatus.md docs/undated.md"
dc $ALL; cp "$T/out" "$T/run1"
dc $ALL; cmp -s "$T/out" "$T/run1" || fail "i. two runs differ"
if [ -x /bin/bash ]; then
    DC_BASH=/bin/bash dc $ALL
    cmp -s "$T/out" "$T/run1" || fail "i. /bin/bash output differs from $RUN_BASH"
fi
pass "i. output is identical across runs and under /bin/bash"

# ── j. a 2,000-line page finishes in under 5 s ──
{
    echo "# Big"
    i=0
    while [ "$i" -lt 2000 ]; do
        echo "Line $i: [enc](methods/encoder.md#overview), \`src/models/encoder.py\`, prose words."
        i=$((i + 1))
    done
    echo "$STATUS"
} > "$P/docs/big.md"
START=$(date +%s)
dc docs/big.md
SECS=$(( $(date +%s) - START ))
expect_rc 0 "j. big page"
[ "$SECS" -lt 5 ] || fail "j. 2,000-line page took ${SECS} s (limit 5)"
pass "j. a 2,000-line page with 4,000 references finished in ${SECS} s"

# ── k. a longer fence holds a shorter one; Setext headings give anchors ──
{
    echo "# Nested"
    echo ""
    echo "[o](#overview) and [d](#details)"
    echo ""
    echo "Overview"
    echo "========"
    echo ""
    echo "Details"
    echo "-------"
    echo ""
    echo '````md'
    echo '```'
    echo 'TODO inside the inner example'
    echo '```'
    echo '````'
    echo ""
    echo "$STATUS"
} > "$P/docs/nested.md"
dc docs/nested.md
expect_rc 0 "k. nested fence and Setext headings"
hasnt "marker" "k. a TODO inside a 4-backtick fence is exempt"
hasnt "anchor" "k. Setext headings resolve as anchors"
pass "k. a \`\`\` line inside a \`\`\`\` fence does not close it; Setext (=== / ---) headings resolve as anchors"

echo "All doc-check tests passed."
