#!/usr/bin/env bash
# Propel — claim-check: did a rewrite keep the draft's evidence tokens?
#
#   bash scripts/claim-check.sh [--list] [--] FILE    list FILE's evidence tokens
#   bash scripts/claim-check.sh [--] BEFORE AFTER     tokens BEFORE has that AFTER lost
#   bash scripts/claim-check.sh --save-draft [--] FILE
#                                 copy FILE to its draft path (below); refuses
#                                 to overwrite a draft that already exists
#
# Used by the concise skill: save the draft, rewrite it, then run this on the
# pair. Every token it reports missing is restored in the rewrite.
#
# WHAT EXIT 0 MEANS: "no extracted token is missing". It never means "no
# evidence lost". A rewrite can keep every token and still change the meaning
# (swap which result passed, drop a "not" or an "only", lose a caveat, drop a
# bare integer or a unit not listed below). Those are not tokens; read for them.
#
# Draft path (--save-draft): run from the repo root. FILE's path relative to
# the current directory (symlinks in its directory resolved; ./, ../ and
# absolute forms all give the same answer) with every / replaced by __, plus
# .draft.md, under .propel/concise/:
#   scratch/2026-11-18-x/README.md -> .propel/concise/scratch__2026-11-18-x__README.md.draft.md
# A FILE outside the current directory is a usage error.
#
# Evidence tokens. Lines are read one at a time (a trailing CR is dropped) and
# matched in this order; URL, tag, path:line, ratio and hash matches are blanked
# before the later classes run, so one piece of text is not counted twice:
#   backtick  a `...` span on one line, backticks included (its contents are
#             still scanned for the classes below)
#   url       http:// or https:// up to whitespace, quote, bracket or backtick;
#             trailing . , ; : ! ? * stripped, and a trailing ) stripped only
#             when the URL has more ) than (
#   tag       [claude] [codex] [both], and [codex ...] / [claude ...] /
#             [both ...] with a qualifier, e.g. [codex · unverified]
#   path:line NAME:N or NAME:N-M, where NAME is made of letters, digits and
#             . / _ - ~, contains a letter, and contains one of . / _ -
#   ratio     N/M or N/M/K (125/125, 0/0/0), not inside a word or a path
#   hash      a whole word of 7-40 lowercase hex characters with at least one
#             digit and at least one letter
#   number    digits not preceded by a letter, digit, _ or . (a + or - sign is
#             kept when it follows the line start, a space, ( or =) that have
#             a decimal point (0.5, 1.2.3) or an exponent (3e-4, 2.5E+3), are
#             followed by %, or are followed by a unit word: ms s sec secs
#             seconds min mins minutes h hr hrs hours d days B KB MB GB TB kB
#             KiB MiB GiB bytes k M x px lines files tests steps epochs
#             iterations tokens chars characters words calls turns runs
#             Hz kHz MHz GHz. Recorded as "N unit", "Nx" or "N%".
#   result    a number followed by a result word: passed failed failures
#             errors error skipped xfailed xpassed warnings warning. Recorded
#             as "N word".
# Between a number and its unit or result word, any run of spaces and tabs is
# one space, and a line break is allowed (the word is the next line's first),
# so reflowing a paragraph does not change a token.
# Bare integers without a unit (exit 2, Gate 1, 21 -> 22) are not tokens.
#
# Output (tab-separated, in order of first appearance):
#   one file:  COUNT  CLASS  TOKEN
#   two files: missing   CLASS  TOKEN  line N  (before B, after 0)
#              fewer     CLASS  TOKEN  line N  (before B, after A)   [information]
#              unquoted  CLASS  TOKEN  line N  (inner text kept)   [information]
#              N is the token's first line in BEFORE. "missing" means the token
#              is gone from AFTER; "fewer" means it is kept with a lower count
#              (cutting a restatement does that); "unquoted" means a backtick
#              span lost its backticks but its text is still in AFTER. Only
#              "missing" lines affect the exit status.
# Nothing from either file is printed except the tokens themselves.
#
# Exit: 0  no extracted token missing (list mode: always 0; --save-draft: saved)
#       1  some token missing from AFTER (--save-draft: the draft already exists)
#       2  usage error, or a file is missing / unreadable / a directory
#       3  internal error (awk failed)
#
# bash + awk only (no python3), safe on macOS /bin/bash 3.2. Runs under
# LC_ALL=C, so it works byte by byte and is linear in the number of lines
# (a single very long line with many tokens costs more: awk copies strings).

usage() {
  sed -n '2,/^# bash + awk only/p' "${BASH_SOURCE[0]}" 2>/dev/null | sed 's/^# \{0,1\}//'
}

die_usage() {
  printf 'claim-check: %s\n' "$1" >&2
  printf 'usage: claim-check.sh [--list] [--] FILE | claim-check.sh [--] BEFORE AFTER | claim-check.sh --save-draft [--] FILE (--help for details)\n' >&2
  exit 2
}

readable() {
  [ -f "$1" ] && [ -r "$1" ] || die_usage "cannot read '$1'"
}

MODE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      [ "$#" -eq 1 ] && [ -z "$MODE" ] || die_usage "--help takes no arguments"
      usage; exit 0 ;;
    --list|--save-draft)
      [ -z "$MODE" ] || die_usage "only one of --list / --save-draft"
      MODE="${1#--}"; shift ;;
    --)
      shift; break ;;
    -?*)
      die_usage "unknown option '$1'" ;;
    *)
      break ;;
  esac
done
case "$MODE:$#" in
  list:1|save-draft:1) ;;
  list:*|save-draft:*) die_usage "--$MODE takes exactly one FILE" ;;
  :1) MODE=list ;;
  :2) MODE=compare ;;
  *) die_usage "expected one or two files, got $#" ;;
esac

if [ "$MODE" = save-draft ]; then
  readable "$1"
  # Resolve FILE's directory and the current directory physically (pwd -P),
  # so ./x, ../repo/x, an absolute path and a symlinked TMPDIR all agree.
  case "$1" in */*) F_DIR="${1%/*}"; [ -n "$F_DIR" ] || F_DIR=/ ;; *) F_DIR=. ;; esac
  F_BASE="${1##*/}"
  F_ABS=$(cd -- "$F_DIR" 2>/dev/null && pwd -P) || die_usage "cannot resolve the directory of '$1'"
  ROOT_ABS=$(pwd -P) || die_usage "cannot resolve the current directory"
  case "$F_ABS/" in
    "$ROOT_ABS"/*) REL="${F_ABS#"$ROOT_ABS"}/$F_BASE"; REL="${REL#/}" ;;
    *) die_usage "'$1' is not under the current directory (run from the repo root)" ;;
  esac
  DRAFT=".propel/concise/$(printf '%s' "$REL" | sed 's|/|__|g').draft.md"
  if [ -e "$DRAFT" ]; then
    printf 'claim-check: a draft is already pending at %s. Finish that rewrite first: get the user to accept it, then delete the draft.\n' "$DRAFT" >&2
    exit 1
  fi
  mkdir -p .propel/concise 2>/dev/null || { printf 'claim-check: cannot create .propel/concise\n' >&2; exit 2; }
  # noclobber: if another run created the draft since the check, fail instead
  # of overwriting it.
  if ! ( set -o noclobber; cat -- "$1" > "$DRAFT" ) 2>/dev/null; then
    printf 'claim-check: could not write %s (it may have just been created); not overwritten.\n' "$DRAFT" >&2
    exit 1
  fi
  printf '%s\n' "$DRAFT"
  exit 0
fi

if [ "$MODE" = list ]; then
  readable "$1"
  BEFORE="$1"; AFTER=""
else
  readable "$1"; readable "$2"
  BEFORE="$1"; AFTER="$2"
fi

# Paths go through the environment, not awk -v, which would rewrite backslashes.
# The program ends with exit 10 / 11 / 12 for 0 / 1 / 2; any other status is
# awk itself failing, reported as 3.
CC_BEFORE="$BEFORE" CC_AFTER="$AFTER" CC_MODE="$MODE" LC_ALL=C awk '
function add(cls, tok) {
  gsub(/\t/, " ", tok)
  if (side == 1) {
    if (!(tok in bcount)) { order[++n] = tok; bclass[tok] = cls; bline[tok] = lineno }
    bcount[tok]++
  } else {
    acount[tok]++
  }
}
function lastch(str) { return str == "" ? "" : substr(str, length(str), 1) }
function nparen(str, c,    t) { t = str; return gsub(c, "", t) }
function scan(s, nxt,    rest, out, tok, pre, name, w, r, prev, prev2, num, unit, nl) {
  # backtick spans: recorded, not blanked
  rest = s
  while (match(rest, /`[^`]+`/)) {
    add("backtick", substr(rest, RSTART, RLENGTH))
    rest = substr(rest, RSTART + RLENGTH)
  }
  # urls
  rest = s; out = ""
  while (match(rest, /https?:\/\/[^] \t"<>`[]+/)) {
    tok = substr(rest, RSTART, RLENGTH)
    while (1) {
      if (tok ~ /[.,;:!?*]$/) tok = substr(tok, 1, length(tok) - 1)
      else if (tok ~ /\)$/ && nparen(tok, "\\)") > nparen(tok, "\\(")) tok = substr(tok, 1, length(tok) - 1)
      else break
    }
    if (tok !~ /:\/\/$/) add("url", tok)
    out = out substr(rest, 1, RSTART - 1) " "
    rest = substr(rest, RSTART + RLENGTH)
  }
  s = out rest
  # attribution tags
  rest = s; out = ""
  while (match(rest, /\[(claude|codex|both)( [^]]*)?\]/)) {
    add("tag", substr(rest, RSTART, RLENGTH))
    out = out substr(rest, 1, RSTART - 1) " "
    rest = substr(rest, RSTART + RLENGTH)
  }
  s = out rest
  # path:line and path:line-line
  rest = s; out = ""
  while (match(rest, /[A-Za-z0-9_.\/~-]+:[0-9]+(-[0-9]+)?/)) {
    tok = substr(rest, RSTART, RLENGTH)
    name = tok; sub(/:[0-9]+(-[0-9]+)?$/, "", name)
    if (name ~ /[A-Za-z]/ && name ~ /[._\/-]/) {
      add("path:line", tok)
      out = out substr(rest, 1, RSTART - 1) " "
    } else {
      out = out substr(rest, 1, RSTART + RLENGTH - 1)
    }
    rest = substr(rest, RSTART + RLENGTH)
  }
  s = out rest
  # ratios N/M and N/M/K, not part of a word or a path
  rest = s; out = ""
  while (match(rest, /[0-9]+\/[0-9]+(\/[0-9]+)?/)) {
    tok = substr(rest, RSTART, RLENGTH)
    pre = out substr(rest, 1, RSTART - 1)
    r = substr(rest, RSTART + RLENGTH, 1)
    if (lastch(pre) !~ /[A-Za-z0-9_.\/]/ && r !~ /[A-Za-z0-9_\/]/) {
      add("ratio", tok); out = pre " "
    } else {
      out = pre tok
    }
    rest = substr(rest, RSTART + RLENGTH)
  }
  s = out rest
  # git hashes: whole words only
  rest = s; out = ""
  while (match(rest, /[A-Za-z0-9_]+/)) {
    w = substr(rest, RSTART, RLENGTH)
    if (RLENGTH >= 7 && RLENGTH <= 40 && w !~ /[^0-9a-f]/ && w ~ /[0-9]/ && w ~ /[a-f]/) {
      add("hash", w)
      out = out substr(rest, 1, RSTART - 1) " "
    } else {
      out = out substr(rest, 1, RSTART + RLENGTH - 1)
    }
    rest = substr(rest, RSTART + RLENGTH)
  }
  s = out rest
  # numbers: decimal point, exponent, %, unit word, or result word
  nl = nxt; sub(/^[ \t]+/, "", nl)
  rest = s; out = ""
  while (match(rest, /[0-9]+(\.[0-9]+)*([eE][+-]?[0-9]+)?/)) {
    num = substr(rest, RSTART, RLENGTH)
    pre = out substr(rest, 1, RSTART - 1)
    out = pre num
    rest = substr(rest, RSTART + RLENGTH)
    prev = lastch(pre)
    if (prev == "+" || prev == "-") {
      prev2 = lastch(substr(pre, 1, length(pre) - 1))
      if (prev2 == "" || prev2 ~ /[ \t(=]/) { num = prev num; prev = prev2 }
    }
    if (prev ~ /[A-Za-z0-9_.]/) continue
    if (substr(rest, 1, 1) == "%") { add("number", num "%"); continue }
    r = rest
    sub(/^[ \t]+/, "", r)
    if (r == "") r = nl
    if (match(r, /^[A-Za-z]+/)) {
      unit = substr(r, 1, RLENGTH)
      if (substr(r, RLENGTH + 1, 1) !~ /[A-Za-z0-9_]/) {
        if (unit in units) { add("number", (unit == "x") ? num "x" : num " " unit); continue }
        if (unit in results) { add("result", num " " unit); continue }
      }
    }
    if (num ~ /[.eE]/) add("number", num)
  }
}
# scanfile(path): scan every line, giving scan() the next line for lookahead
function scanfile(path,    rc, cur, nxt, have) {
  lineno = 0; have = 0
  while ((rc = (getline nxt < path)) > 0) {
    sub(/\r$/, "", nxt)
    if (have) { lineno++; scan(cur, nxt) }
    cur = nxt; have = 1
  }
  if (rc < 0) { print "claim-check: cannot read " path > "/dev/stderr"; exit 12 }
  if (have) { lineno++; scan(cur, "") }
  close(path)
}
BEGIN {
  before = ENVIRON["CC_BEFORE"]; after = ENVIRON["CC_AFTER"]; mode = ENVIRON["CC_MODE"]
  split("ms s sec secs seconds min mins minutes h hr hrs hours d days B KB MB GB TB kB KiB MiB GiB bytes k M x px lines files tests steps epochs iterations tokens chars characters words calls turns runs Hz kHz MHz GHz", ul, " ")
  for (i in ul) units[ul[i]] = 1
  split("passed failed failures errors error skipped xfailed xpassed warnings warning", rl, " ")
  for (i in rl) results[rl[i]] = 1
  n = 0
  side = 1; scanfile(before)
  if (mode == "list") {
    for (i = 1; i <= n; i++) printf "%d\t%s\t%s\n", bcount[order[i]], bclass[order[i]], order[i]
    exit 10
  }
  side = 2; scanfile(after)
  # A backtick span gone from AFTER whose inner text is still there lost only
  # its formatting: one more pass over AFTER, only for those spans.
  nq = 0
  for (i = 1; i <= n; i++) {
    t = order[i]
    if (bclass[t] == "backtick" && !(t in acount)) { q[++nq] = t; inner[t] = substr(t, 2, length(t) - 2) }
  }
  if (nq > 0) {
    while ((getline line < after) > 0) {
      for (j = 1; j <= nq; j++) if (!(q[j] in kept) && index(line, inner[q[j]])) kept[q[j]] = 1
    }
    close(after)
  }
  miss = 0; few = 0
  for (i = 1; i <= n; i++) {
    t = order[i]; a = (t in acount) ? acount[t] : 0
    if (a == 0 && (t in kept)) {
      printf "unquoted\t%s\t%s\tline %d\t(inner text kept)\n", bclass[t], t, bline[t]
    } else if (a == 0) {
      printf "missing\t%s\t%s\tline %d\t(before %d, after 0)\n", bclass[t], t, bline[t], bcount[t]
      miss++
    } else if (a < bcount[t]) {
      printf "fewer\t%s\t%s\tline %d\t(before %d, after %d)\n", bclass[t], t, bline[t], bcount[t], a
      few++
    }
  }
  if (miss > 0) {
    printf "claim-check: %d of %d token(s) missing from the rewrite. Restore them.\n", miss, n > "/dev/stderr"
    exit 11
  }
  printf "claim-check: no extracted token missing (%d checked%s). Meaning can still have changed: read for negations, caveats and swapped results.\n", n, (few ? ", " few " with a lower count" : "") > "/dev/stderr"
  exit 10
}'
RC=$?
case "$RC" in 10) exit 0 ;; 11) exit 1 ;; 12) exit 2 ;; *) exit 3 ;; esac
