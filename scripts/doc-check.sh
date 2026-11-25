#!/usr/bin/env bash
# Propel — doc-check: mechanical checks on documentation pages.
#
#   bash scripts/doc-check.sh [--root DIR] [--] FILE...
#
# Used by the make-documentations skill on every page it writes, before the
# Codex fidelity consult. Every reported problem is fixed in the page.
#
# Checks, per markdown FILE:
#   link     a relative link ](path) or ](path#anchor) whose target does not
#            exist. A path is resolved against FILE's directory; a path that
#            starts with / against DIR. Links with a scheme (https:, mailto:)
#            are skipped.
#   anchor   ](path.md#anchor) or ](#anchor) whose anchor matches no heading of
#            the target .md file. Headings are slugged GitHub-style: lowercased
#            (ASCII), link targets dropped, punctuation other than - and _
#            removed, spaces to -, repeats suffixed -1, -2. Anchors into
#            non-.md targets are not checked.
#   path     a backticked repo path that does not exist under DIR. A backtick
#            span counts as a path when it is one token of letters, digits and
#            . _ / -, contains a /, does not start with /, and ends in / or in a
#            file extension (.md, .py, ...). A trailing :N or :N-M and anything
#            from :: on are dropped first.
#   scratch  any link, backticked path or bare path into scratch/ (scratch/x,
#            ../scratch/x). Naming the directory itself (`scratch/`) is fine.
#   marker   TODO, TBD or FIXME as a word.
#   emoji    any byte sequence starting \xF0\x9F.
#   status   a leaf page without a **Status** line carrying a YYYY-MM-DD date.
#            Every page is a leaf except hubs: files named README.md or
#            index.md.
# Fenced code blocks (``` or ~~~) are exempt from every check except emoji.
# Inline backtick spans are exempt from the link and marker checks.
#
# DIR defaults to the current directory (run from the repo root).
#
# Output: one line per problem, in file order, then line order:
#   FILE:LINE: KIND: DETAIL
#
# Exit: 0  no problems
#       1  problems found
#       2  usage error, or a FILE / DIR is missing or unreadable
#
# bash + awk only (no python3, no network), safe on macOS /bin/bash 3.2. Runs
# under LC_ALL=C, so it works byte by byte and its output is deterministic.

export LC_ALL=C

usage() {
  sed -n '2,/^# bash + awk only/p' "${BASH_SOURCE[0]}" 2>/dev/null | sed 's/^# \{0,1\}//'
}

die_usage() {
  printf 'doc-check: %s\n' "$1" >&2
  printf 'usage: doc-check.sh [--root DIR] [--] FILE... (--help for details)\n' >&2
  exit 2
}

ROOT=.
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      [ "$#" -eq 1 ] || die_usage "--help takes no arguments"
      usage; exit 0 ;;
    --root)
      [ "$#" -ge 2 ] || die_usage "--root needs a directory"
      ROOT="$2"; shift 2 ;;
    --root=*)
      ROOT="${1#--root=}"; shift ;;
    --)
      shift; break ;;
    -?*)
      die_usage "unknown option '$1'" ;;
    *)
      break ;;
  esac
done
[ "$#" -ge 1 ] || die_usage "no FILE given"
[ -n "$ROOT" ] && [ -d "$ROOT" ] || die_usage "--root '$ROOT' is not a directory"
ROOT="${ROOT%/}"; [ -n "$ROOT" ] || ROOT=/
for f in "$@"; do
  [ -f "$f" ] && [ -r "$f" ] || die_usage "cannot read '$f'"
done

# Scanner: one file (DC_FILE) per run. Prints, tab-separated, in line order:
#   P <tab> LINE <tab> KIND <tab> DETAIL   a problem found by the scan itself
#   L <tab> LINE <tab> TARGET              a relative link to resolve
#   B <tab> LINE <tab> PATH                a backticked path to resolve
# In slug mode (DC_MODE=slugs) it prints the file's heading anchors instead.
SCAN='
function out(ln, kind, detail) { gsub(/\t/, " ", detail); printf "P\t%d\t%s\t%s\n", ln, kind, detail }
function slug(h,    s, i, c, r) {
  s = h
  while (match(s, /\]\([^)]*\)/)) s = substr(s, 1, RSTART) substr(s, RSTART + RLENGTH)
  s = tolower(s); r = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c ~ /[a-z0-9_-]/ || c > "\177") r = r c
    else if (c == " ") r = r "-"
  }
  if (r in seen) { seen[r]++; r = r "-" seen[r] } else seen[r] = 0
  return r
}
BEGIN {
  path = ENVIRON["DC_FILE"]; mode = ENVIRON["DC_MODE"]; leaf = (ENVIRON["DC_LEAF"] == "1")
  fence = ""; status_ok = 0; status_line = 0; ln = 0
  while ((rc = (getline line < path)) > 0) {
    ln++
    sub(/\r$/, "", line)
    if (mode != "slugs" && index(line, "\360\237")) out(ln, "emoji", "emoji in text")
    # Fences: remember the opening character and run length; only a run of the
    # same character at least that long, with nothing after it, closes it.
    if (match(line, /^[ \t]*(````*|~~~~*)/)) {
      run = substr(line, RSTART, RLENGTH); sub(/^[ \t]*/, "", run)
      f = substr(run, 1, 1); n = length(run)
      if (fence == "") { fence = f; fence_n = n; prev = ""; continue }
      if (f == fence && n >= fence_n && substr(line, RSTART + RLENGTH) ~ /^[ \t]*$/) { fence = ""; prev = ""; continue }
    }
    if (fence != "") continue
    if (mode == "slugs") {
      if (line ~ /^(   |  | )?#+[ \t]/ || line ~ /^(   |  | )?#+$/) {
        h = line
        sub(/^ *#+[ \t]*/, "", h); sub(/[ \t]+#+[ \t]*$/, "", h); sub(/[ \t]+$/, "", h)
        print slug(h); prev = ""
      } else if (prev != "" && (line ~ /^(   |  | )?=+[ \t]*$/ || line ~ /^(   |  | )?-+[ \t]*$/)) {
        # Setext heading: the text line above an === or --- underline.
        h = prev; sub(/^ */, "", h); sub(/[ \t]+$/, "", h)
        print slug(h); prev = ""
      } else if (line ~ /^[ \t]*$/) prev = ""
      else prev = line
      continue
    }
    # paths into scratch/, anywhere on the line (prose, links, backticks)
    rest = line
    while (match(rest, /(^|[^A-Za-z0-9_-])scratch\/[A-Za-z0-9_.-]/)) {
      tok = substr(rest, RSTART); sub(/^[^s]*/, "", tok); sub(/[] \t)`>"'"'"'].*$/, "", tok); sub(/[.,;:!?]+$/, "", tok)
      out(ln, "scratch", "path into scratch/: " tok)
      rest = substr(rest, RSTART + RLENGTH)
    }
    # status line
    if (line ~ /\*\*Status:?\*\*/) {
      if (line ~ /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) status_ok = 1
      else if (!status_line) status_line = ln
    }
    # backtick spans: path candidates, then blanked out of the prose
    rest = line; prose = ""
    while (match(rest, /`[^`]+`/)) {
      s = substr(rest, RSTART + 1, RLENGTH - 2)
      prose = prose substr(rest, 1, RSTART - 1) " "
      rest = substr(rest, RSTART + RLENGTH)
      t = s
      sub(/::.*$/, "", t); sub(/:[0-9]+(-[0-9]+)?$/, "", t)
      if (t ~ /^[A-Za-z0-9_.\/-]+$/ && index(t, "/") && t !~ /^\// && t !~ /(^|[^A-Za-z0-9_-])scratch\// \
          && (t ~ /\/$/ || t ~ /[A-Za-z0-9_-]\.[A-Za-z][A-Za-z0-9]*$/))
        printf "B\t%d\t%s\n", ln, t
    }
    prose = prose rest
    # TODO / TBD / FIXME as words
    rest = prose
    while (match(rest, /(^|[^A-Za-z0-9_])(TODO|TBD|FIXME)([^A-Za-z0-9_]|$)/)) {
      w = substr(rest, RSTART, RLENGTH); gsub(/[^A-Z]/, "", w)
      out(ln, "marker", w)
      rest = substr(rest, RSTART + RLENGTH - 1)
    }
    # links ](target)
    rest = prose
    while (match(rest, /\]\([^)]*\)/)) {
      t = substr(rest, RSTART + 2, RLENGTH - 3)
      rest = substr(rest, RSTART + RLENGTH)
      sub(/^[ \t]+/, "", t)
      if (t ~ /^</) { t = substr(t, 2); sub(/>.*$/, "", t) } else sub(/[ \t].*$/, "", t)
      if (t == "" || t ~ /^[A-Za-z][A-Za-z0-9+.-]*:/) continue
      if (t ~ /(^|[^A-Za-z0-9_-])scratch\//) continue
      gsub(/\t/, " ", t)
      printf "L\t%d\t%s\n", ln, t
    }
  }
  if (rc < 0) { print "doc-check: cannot read " path > "/dev/stderr"; exit 2 }
  if (mode != "slugs" && leaf && !status_ok) {
    if (status_line) out(status_line, "status", "**Status** line has no YYYY-MM-DD date")
    else out(1, "status", "no **Status** line with a YYYY-MM-DD date (leaf page)")
  }
}'

NL='
'
PROBLEMS=0
report() {  # <file> <line> <kind> <detail>
  printf '%s:%s: %s: %s\n' "$1" "$2" "$3" "$4"
  PROBLEMS=$((PROBLEMS + 1))
}

# slugs_of <file>: set SLUGS to the file's heading anchors, one per line.
# Cached per file for the run (bash 3.2 has no associative arrays).
NCACHE=0
slugs_of() {
  local i=1 key
  while [ "$i" -le "$NCACHE" ]; do
    eval "key=\$CACHE_KEY_$i"
    if [ "$key" = "$1" ]; then eval "SLUGS=\$CACHE_SLUGS_$i"; return; fi
    i=$((i + 1))
  done
  SLUGS=$(DC_FILE="$1" DC_MODE=slugs awk "$SCAN" 2>/dev/null)
  NCACHE=$((NCACHE + 1))
  eval "CACHE_KEY_$NCACHE=\$1; CACHE_SLUGS_$NCACHE=\$SLUGS"
}

for FILE in "$@"; do
  case "$FILE" in
    */*) FDIR="${FILE%/*}"; [ -n "$FDIR" ] || FDIR=/ ;;
    *)   FDIR=. ;;
  esac
  BASE="${FILE##*/}"
  case "$BASE" in README.md|index.md) LEAF=0 ;; *) LEAF=1 ;; esac
  SCANNED=$(DC_FILE="$FILE" DC_LEAF="$LEAF" DC_MODE=scan awk "$SCAN"; printf '%s' "rc=$?")
  case "$SCANNED" in *rc=0) ;; *) die_usage "cannot scan '$FILE'" ;; esac
  SCANNED="${SCANNED%rc=0}"
  while IFS='	' read -r TAG LN A B; do
    case "$TAG" in
      P) report "$FILE" "$LN" "$A" "$B" ;;
      B) [ -e "$ROOT/$A" ] || report "$FILE" "$LN" path "\`$A\` does not exist under $ROOT" ;;
      L)
        TARGET="$A"; T="$A"; ANCHOR=""
        case "$T" in *'#'*) ANCHOR="${T#*#}"; T="${T%%#*}" ;; esac
        T="${T%%\?*}"
        while case "$T" in *%20*) true ;; *) false ;; esac; do T="${T%%%20*} ${T#*%20}"; done
        if [ -z "$T" ]; then
          TF="$FILE"
        else
          case "$T" in
            /*) TF="$ROOT$T" ;;
            *)  TF="$FDIR/$T" ;;
          esac
        fi
        if [ ! -e "$TF" ]; then
          report "$FILE" "$LN" link "target does not exist: $TARGET"
          continue
        fi
        if [ -n "$ANCHOR" ] && [ -f "$TF" ]; then
          case "$TF" in
            *.md|*.MD|*.markdown)
              slugs_of "$TF"
              case "$NL$SLUGS$NL" in
                *"$NL$ANCHOR$NL"*) ;;
                *) report "$FILE" "$LN" anchor "no heading for #$ANCHOR in ${T:-this page}" ;;
              esac ;;
          esac
        fi ;;
    esac
  done <<EOF
$SCANNED
EOF
done

[ "$PROBLEMS" -eq 0 ] && exit 0
exit 1
