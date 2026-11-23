#!/usr/bin/env bash
# Propel session-start hook
#
# Injects Propel's context on startup / resume / clear / compact as PLAIN TEXT.
# Claude Code adds plain-text SessionStart stdout to the model's context; stdout
# that looks like a JSON object is parsed as hook JSON instead, and a custom
# object without hookSpecificOutput is dropped. So this output must never start
# with `{`.
#
# Claude Code replaces a SessionStart hook's stdout above ~10,000 characters with
# a short preview plus a file path. The cap is per hook, so "inject everything"
# is split into parts, each registered as its own hook entry in hooks.json:
#
#   bash hooks/session-start.sh <part>
#
#   state     Codex state, mode (+ policy), investigations, project profile,
#             empty repo, registry entries
#   (none)    a legacy registration, from a session that was open across an
#             upgrade (Claude Code snapshots hook registrations at session
#             start): the state part, then a notice to restart Claude Code and,
#             until then, to read CORE.md, CODEX.md and the using-propel skill
#   tasks     open tasks from the task ledger (.propel/tasks/, via
#             scripts/task-queue.sh), at most 20 rows; prints nothing when there
#             are none. Also exports PROPEL_SESSION (the session_id on stdin)
#             through CLAUDE_ENV_FILE, so task-queue.sh in the Bash tool knows
#             which session it is in
#   core      core/CORE.md
#   codex     core/CODEX.md
#   routing1..routing4
#             skills/using-propel/SKILL.md, split at "## " headings into chunks
#             of at most 9,000 characters
#
# Never blocks a session: no `set -e`, exit 0 on every path, and python3 is only
# used (behind a guard) to read JSON fields, with a grep fallback.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
# Resolve project-relative state from the project root, even when Claude Code
# was started in a subdirectory.
cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || true

SKILL_FILE="$PLUGIN_DIR/skills/using-propel/SKILL.md"
CORE_FILE="$PLUGIN_DIR/core/CORE.md"
CODEX_FILE="$PLUGIN_DIR/core/CODEX.md"

# No argument at all = a registration from before the split into parts.
LEGACY=false
if [ $# -eq 0 ]; then
  LEGACY=true
fi
PART="${1:-state}"

# Number of routing parts registered in hooks.json. If SKILL.md needs more
# chunks than this, the last part prints the remainder (and the test fails so
# a maintainer adds another entry).
ROUTING_PARTS=4
CHUNK_MAX=9000      # max characters per routing chunk
STATE_MAX=9000      # max characters for the state part
MODE_MAX=2000       # .propel/mode.json above this is cut, with a "(truncated)" line
LIST_MAX=1500       # max characters for each listing (investigations, registry)
POLICY_MAX=9500     # CORE.md / CODEX.md above this are truncated
TRUNC_KEEP=9000     # characters kept when they are
TASKS_MAX=8500      # max characters for the tasks part
TASKS_ROWS=20       # max open-task rows in the tasks part

# Printed after the state part on a no-argument (legacy) call.
LEGACY_NOTICE="[propel] Propel was updated while this session was open, so this session still runs its old hook registrations and did not receive the core policy, the Codex policy or skill routing. Restart Claude Code to load them. Until then, read .claude/core/CORE.md, .claude/core/CODEX.md and .claude/skills/using-propel/SKILL.md now."
if [ "$LEGACY" = true ]; then
  # The notice shares the state part's budget, so state + notice stay under
  # STATE_MAX (and the hook under Claude Code's per-hook cap).
  LEGACY_LEN=$(printf '\n%s\n' "$LEGACY_NOTICE" | wc -c | tr -d '[:space:]')
  STATE_MAX=$(( STATE_MAX - ${LEGACY_LEN:-0} ))
fi

HAVE_PYTHON=false
if command -v python3 >/dev/null 2>&1; then
  HAVE_PYTHON=true
fi

# ── Version, from the install manifest (grep/sed only) ──
VERSION="unknown"
if [ -f ".propel/manifest.json" ]; then
  V=$(grep -o '"propel_version"[[:space:]]*:[[:space:]]*"[^"]*"' ".propel/manifest.json" 2>/dev/null \
    | head -1 | sed 's/.*:[[:space:]]*"\([^"]*\)"/\1/')
  if [ -n "$V" ]; then
    VERSION="$V"
  fi
fi

print_header() {
  echo "[propel:session-start ${PART}] Propel ${VERSION} — part of the context injected at session start (other parts arrive separately)."
  echo ""
}

# Print the first <max> characters of a file, cut at a line boundary.
head_lines() {  # <file> <max>
  LC_ALL=C awk -v max="$2" '{ n += length($0) + 1; if (n > max) exit; print }' "$1" 2>/dev/null
}

# Print stdin lines as "- line". If the whole block would pass <max>
# characters, print as many as fit followed by <more>, all within <max>. Keeps a
# listing of long names (each up to NAME_MAX, more in UTF-8) bounded.
cap_list() {  # <max> <more>
  LC_ALL=C awk -v max="$1" -v more="$2" '
    { lines[NR] = "- " $0; total += length(lines[NR]) + 1 }
    END {
      if (total <= max) { for (i = 1; i <= NR; i++) print lines[i]; exit }
      n = length(more) + 1
      for (i = 1; i <= NR; i++) { n += length(lines[i]) + 1; if (n > max) break; print lines[i] }
      print more
    }'
}

# ── Policy parts: core / codex ──
print_policy() {  # <file> <heading> <repo-relative path>
  print_header
  if [ ! -f "$1" ]; then
    echo "[propel] $3 missing — reinstall with \`propel init\`"
    return
  fi
  echo "$2"
  echo ""
  SIZE=$(wc -c < "$1" 2>/dev/null | LC_ALL=C tr -d '[:space:]' 2>/dev/null)
  if [ "${SIZE:-0}" -gt "$POLICY_MAX" ]; then
    head_lines "$1" "$TRUNC_KEEP"
    echo "(truncated — read $3)"
  else
    cat "$1" 2>/dev/null
  fi
}

# ── Routing parts: using-propel SKILL.md in chunks ──
print_routing() {  # <n>
  N="$1"
  if [ ! -f "$SKILL_FILE" ]; then
    if [ "$N" = "1" ]; then
      print_header
      echo "[propel] using-propel/SKILL.md missing — reinstall with \`propel init\`"
    fi
    return
  fi
  # Units are whole "## " sections, or single lines of a section that alone
  # exceeds the chunk size. Units are packed greedily into chunks.
  BODY=$(LC_ALL=C awk -v want="$N" -v max="$CHUNK_MAX" -v parts="$ROUTING_PARTS" '
    { lines[NR] = $0 }
    END {
      ns = 0
      for (i = 1; i <= NR; i++) {
        if (i == 1 || lines[i] ~ /^## /) { ns++; sstart[ns] = i; slen[ns] = 0 }
        send[ns] = i; slen[ns] += length(lines[i]) + 1
      }
      nu = 0
      for (s = 1; s <= ns; s++) {
        if (slen[s] <= max) {
          nu++; ustart[nu] = sstart[s]; uend[nu] = send[s]; ulen[nu] = slen[s]
        } else {
          for (i = sstart[s]; i <= send[s]; i++) {
            nu++; ustart[nu] = i; uend[nu] = i; ulen[nu] = length(lines[i]) + 1
          }
        }
      }
      nc = 0; cur = 0
      for (u = 1; u <= nu; u++) {
        if (nc == 0 || (cur > 0 && cur + ulen[u] > max)) { nc++; cstart[nc] = ustart[u]; cur = 0 }
        cend[nc] = uend[u]; cur += ulen[u]
      }
      if (want > nc) exit
      last = want
      if (want == parts && nc > parts) last = nc
      if (last > want) {
        printf "## using-propel skill (parts %d-%d of %d)\n\n", want, last, nc
      } else {
        printf "## using-propel skill (part %d of %d)\n\n", want, nc
      }
      for (i = cstart[want]; i <= cend[last]; i++) print lines[i]
      printf "%s", "\001"
    }' "$SKILL_FILE" 2>/dev/null)
  # The \001 sentinel keeps $(...) from stripping the chunk's trailing newline.
  if [ -n "$BODY" ]; then
    print_header
    printf '%s' "${BODY%$'\001'}"
  fi
}

# ── State part ──
# The Codex "enabled" rule, identical in every Propel script that reads
# .propel/codex.json (see scripts/codex-consult.sh): OFF when "enabled" is JSON
# false, null or 0, or a string that, trimmed and lowercased, is "false", "0",
# "off", "no" or empty. A missing file or key leaves it ON.
# codex_flat_off <flat>: the fallback, on the file with all whitespace removed;
# returns 0 (off) if any "enabled" value is off.
codex_flat_off() {
  local rest="$1" v t
  while :; do
    case "$rest" in
      *'"enabled":'*) rest=${rest#*'"enabled":'} ;;
      *) return 1 ;;
    esac
    case "$rest" in
      '"'*)
        v=${rest#?}; v=${v%%'"'*}
        # A JSON escape (\t, \u0066...) is not decoded here, so fail closed: off.
        case "$v" in *\\*|''|0|[Ff][Aa][Ll][Ss][Ee]|[Oo][Ff][Ff]|[Nn][Oo]) return 0 ;; esac ;;
      *)
        v=${rest%%,*}; v=${v%%'}'*}; v=${v%%']'*}
        case "$v" in [Ff][Aa][Ll][Ss][Ee]|[Nn][Uu][Ll][Ll]) return 0 ;; esac
        t=${v#-}; t=${t%%[eE]*}
        case "$t" in
          0|0.*) t=${t#0}; t=${t#.}
                 case "$t" in *[!0]*) ;; *) return 0 ;; esac ;;
        esac ;;
    esac
  done
}

state_pre() {
  # Codex state
  echo "## Codex state"
  echo ""
  CODEX_CONFIG=".propel/codex.json"
  if [ -f "$CODEX_CONFIG" ]; then
    CODEX_STATE=""
    if [ "$HAVE_PYTHON" = true ]; then
      # Prints nothing when the file is not a JSON object: the fallback decides.
      CODEX_STATE=$(python3 -c "
import json
def off(v):
    if v is None or v is False:
        return True
    if isinstance(v, bool):
        return False
    if isinstance(v, (int, float)):
        return v == 0
    if isinstance(v, str):
        return v.strip().lower() in ('false', '0', 'off', 'no', '')
    return False
try:
    d = json.load(open('$CODEX_CONFIG'))
except Exception:
    d = None
if isinstance(d, dict):
    available = d.get('available', None)
    print('enabled: %s, available: %s' % (
        'false' if off(d.get('enabled', True)) else 'true',
        ('true' if available else 'false') if isinstance(available, bool) else 'null'))
" 2>/dev/null || echo "")
    fi
    if [ -z "$CODEX_STATE" ]; then
      # Matched with all whitespace removed, so a value on its own line
      # ({"enabled":\nfalse}) is still seen.
      CODEX_FLAT=$(head -c 8192 "$CODEX_CONFIG" 2>/dev/null | LC_ALL=C tr -d '[:space:]' 2>/dev/null)
      ENABLED="true"
      if codex_flat_off "$CODEX_FLAT"; then
        ENABLED="false"
      fi
      AVAILABLE="null"
      # Globs, not grep <<<: a here-string is a temp file on bash 3.2.
      case "$CODEX_FLAT" in
        *'"available":false'[!a-zA-Z0-9_]*|*'"available":false') AVAILABLE="false" ;;
        *'"available":true'[!a-zA-Z0-9_]*|*'"available":true')   AVAILABLE="true" ;;
      esac
      CODEX_STATE="enabled: ${ENABLED}, available: ${AVAILABLE}"
    fi
    echo "$CODEX_STATE"
  else
    echo "enabled (default — no .propel/codex.json yet; disable with /disable-codex)"
  fi
  echo ""

  # Mode
  echo "## Mode"
  echo ""
  if [ -f ".propel/mode.json" ]; then
    MODE_SIZE=$(wc -c < ".propel/mode.json" 2>/dev/null | LC_ALL=C tr -d '[:space:]' 2>/dev/null)
    if [ "${MODE_SIZE:-0}" -gt "$MODE_MAX" ]; then
      # Byte cap, then drop a multi-byte character the cut may have split
      # (iconv -c); without iconv, the raw bytes pass through.
      head -c "$MODE_MAX" ".propel/mode.json" 2>/dev/null \
        | { iconv -c -f UTF-8 -t UTF-8 2>/dev/null || cat; }
      echo ""
      echo "(truncated — full file at .propel/mode.json)"
    else
      cat ".propel/mode.json" 2>/dev/null
      echo ""
    fi
  else
    echo "not selected yet"
  fi
  echo ""
  echo "Mode selection policy: AUTO. When mode_selection_needed is true, do NOT present a menu and do NOT block. Infer the mode from the user's first substantive message using the routing table in the using-propel skill, announce the choice in one line with the reason, write .propel/mode.json with \"selected_by\": \"auto\", and continue with the work. Only present the four-mode menu if the user opens with /intro, asks which modes exist, or the message is too ambiguous to classify."
  # Matched with all whitespace removed, as for codex.json, so a value on the
  # line after "mode": still counts (route.sh's python path reads it too).
  MODE_FLAT=""
  if [ -f ".propel/mode.json" ]; then
    MODE_FLAT=$(tr -d '[:space:]' < ".propel/mode.json" 2>/dev/null)
  fi
  case "$MODE_FLAT" in
    *'"mode":"'[!\"]*) echo "mode_selection_needed: false" ;;
    *)                 echo "mode_selection_needed: true" ;;
  esac
  echo ""

  # Active investigations
  echo "## Active investigations"
  echo ""
  INVESTIGATIONS=""
  if [ -d "scratch" ]; then
    INVESTIGATIONS=$(find scratch -maxdepth 2 -mindepth 2 -name "README.md" -path "scratch/*/README.md" \
        -not -path "scratch/registry/*" -not -path "scratch/working-memory/*" 2>/dev/null \
      | sort -r \
      | head -5)
  fi
  if [ -n "$INVESTIGATIONS" ]; then
    printf '%s\n' "$INVESTIGATIONS" | cap_list "$LIST_MAX" "(more in scratch/)"
  else
    echo "none"
  fi
  echo ""
}

profile_enabled() {
  PROFILE_FILE=".propel/profile.md"
  [ -f "$PROFILE_FILE" ] || return 1
  CONFIG_FILE=".propel/config.json"
  if [ -f "$CONFIG_FILE" ]; then
    if [ "$HAVE_PYTHON" = true ]; then
      E=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('enabled', True))" 2>/dev/null || echo "True")
      if [ "$E" = "False" ]; then
        return 1
      fi
    elif grep -q '"enabled"[[:space:]]*:[[:space:]]*false' "$CONFIG_FILE" 2>/dev/null; then
      return 1
    fi
  fi
  return 0
}

state_post() {
  # Empty repo: no source files to scan — just Propel scaffolding
  SOURCE_COUNT=$(find . -maxdepth 3 \
    \( -path ./.claude -o -path ./scratch -o -path ./.propel -o -path ./sessions \
       -o -path ./node_modules -o -path ./.git \) -prune -o \
    \( -name "*.py" -o -name "*.js" -o -name "*.ts" -o -name "*.rs" -o -name "*.go" \
       -o -name "*.java" -o -name "*.cpp" -o -name "*.c" -o -name "*.jl" -o -name "*.r" -o -name "*.R" \) \
    -print 2>/dev/null | head -1 | wc -l | tr -d '[:space:]')
  echo "## Empty repo"
  echo ""
  if [ "${SOURCE_COUNT:-0}" = "0" ]; then
    echo "true"
  else
    echo "false"
  fi
  echo ""

  # Registry entries
  echo "## Registry entries"
  echo ""
  REGISTRY=""
  if [ -d "scratch/registry" ]; then
    REGISTRY=$(find scratch/registry -maxdepth 1 -mindepth 1 -type d 2>/dev/null \
      | sort -r \
      | head -10)
  fi
  if [ -n "$REGISTRY" ]; then
    printf '%s\n' "$REGISTRY" | cap_list "$LIST_MAX" "(more in scratch/registry/)"
  else
    echo "none"
  fi
}

print_state() {
  PRE="$(print_header; state_pre)"
  POST="$(state_post)"
  printf '%s\n\n' "$PRE"
  if profile_enabled; then
    PROFILE_NOTE="(profile truncated — full text at .propel/profile.md)"
    # Budget: everything else, the section heading, the note, and newlines.
    USED=$(printf '%s\n\n## Project profile\n\n\n%s\n\n%s\n' "$PRE" "$PROFILE_NOTE" "$POST" | wc -c | tr -d '[:space:]')
    BUDGET=$(( STATE_MAX - ${USED:-0} ))
    SIZE=$(wc -c < ".propel/profile.md" 2>/dev/null | LC_ALL=C tr -d '[:space:]' 2>/dev/null)
    echo "## Project profile"
    echo ""
    if [ "${SIZE:-0}" -le "$BUDGET" ]; then
      cat ".propel/profile.md" 2>/dev/null
    else
      if [ "$BUDGET" -gt 0 ]; then
        head_lines ".propel/profile.md" "$BUDGET"
      fi
      echo "$PROFILE_NOTE"
    fi
    echo ""
  fi
  printf '%s\n' "$POST"
}

# ── Tasks part: open tasks from the task ledger ──
# Session id from the hook's stdin JSON, sanitized exactly as
# scripts/task-queue.sh sanitizes it, so the exported id equals the ledger's
# file stem: [A-Za-z0-9._-], no leading dots, at most 64 characters. Empty after
# sanitizing = no session.
#
# read_hook_input: at most 4,096 bytes of stdin into HOOK_INPUT, bounded in wall
# time so a pipe that stays open without EOF cannot hang the session.
# - A terminal is not read, nor a closed stdin (`true 3<&0` fails).
# - Chunks end at each `"` (read -d '"'), each read waits at most 1 s, and the
#   loop stops after 2 s. bash 3.2 drops a timed-out read's partial data, so
#   ending chunks at quotes keeps every complete JSON string — session_id
#   included — that arrived before the writer stalled.
# - LC_ALL=C while reading, so -n and ${#} count bytes.
# - Past 4,096 bytes the rest is drained by a background cat, killed after 1 s,
#   so a writer that closes after its payload never gets EPIPE.
# Normal payload + EOF: no waiting. Worst case: about 3-4 s extra (a 1 s read
# timeout, a 2 s loop cap counted in whole SECONDS, and the 1 s drain window).
# Accepted limit: a writer that resumes writing after the drain window can
# still get EPIPE.
read_hook_input() {
  HOOK_INPUT=""
  if [ -t 0 ] || ! { true 3<&0; } 2>/dev/null; then
    return 0
  fi
  RH_LC_SET="${LC_ALL+1}"; RH_LC="${LC_ALL-}"
  LC_ALL=C
  RH_START=$SECONDS; RH_FULL=0
  while :; do
    RH_LEFT=$(( 4096 - ${#HOOK_INPUT} ))
    if [ "$RH_LEFT" -le 0 ]; then RH_FULL=1; break; fi
    [ $(( SECONDS - RH_START )) -lt 2 ] || break
    RH_CHUNK=""
    if IFS= read -r -t 1 -d '"' -n "$RH_LEFT" RH_CHUNK; then
      if [ "${#RH_CHUNK}" -ge "$RH_LEFT" ]; then
        HOOK_INPUT="$HOOK_INPUT$RH_CHUNK"; RH_FULL=1; break
      fi
      HOOK_INPUT="$HOOK_INPUT$RH_CHUNK\""
    else
      HOOK_INPUT="$HOOK_INPUT$RH_CHUNK"; break   # EOF (partial chunk kept) or timeout
    fi
  done
  if [ -n "$RH_LC_SET" ]; then LC_ALL="$RH_LC"; else unset LC_ALL; fi
  if [ "$RH_FULL" = 1 ]; then
    exec 3<&0
    cat <&3 >/dev/null 2>&1 &
    RH_CAT=$!
    exec 3<&-
    ( sleep 1; kill "$RH_CAT" ) </dev/null >/dev/null 2>&1 &
    RH_WD=$!
    wait "$RH_CAT" 2>/dev/null
    kill "$RH_WD" 2>/dev/null; wait "$RH_WD" 2>/dev/null
  fi
  return 0
}

read_session_id() {
  SESSION_ID=""
  read_hook_input
  S=$(printf '%s' "$HOOK_INPUT" \
    | LC_ALL=C grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' 2>/dev/null | head -1 \
    | sed 's/^"session_id"[[:space:]]*:[[:space:]]*"//; s/"$//')
  S=$(printf '%s' "$S" | LC_ALL=C tr -cd 'A-Za-z0-9._-')
  while [ "${S:0:1}" = "." ]; do S="${S#.}"; done
  SESSION_ID="${S:0:64}"
}

# Append `export PROPEL_SESSION=<id>` to CLAUDE_ENV_FILE (Claude Code sources it
# before every Bash tool command) unless that exact line is already there —
# SessionStart refires on resume, /clear and compaction. Best effort: a file
# that is missing, unwritable or not a regular file is left alone.
export_session() {
  [ -n "$SESSION_ID" ] || return 0
  ENV_FILE="${CLAUDE_ENV_FILE:-}"
  [ -n "$ENV_FILE" ] || return 0
  ENV_LINE="export PROPEL_SESSION=$SESSION_ID"
  if [ -f "$ENV_FILE" ]; then
    [ -w "$ENV_FILE" ] || return 0
    # Skip only if the effective (last) PROPEL_SESSION line is already this
    # one: after A, B, A the file must end with A.
    LAST=$(grep '^export PROPEL_SESSION=' "$ENV_FILE" 2>/dev/null | tail -n 1)
    if [ "$LAST" = "$ENV_LINE" ]; then
      return 0
    fi
    # A last line without its newline would get this one glued onto it.
    if [ -s "$ENV_FILE" ] && [ -n "$(tail -c 1 "$ENV_FILE" 2>/dev/null)" ]; then
      ENV_LINE=$'\n'"$ENV_LINE"
    fi
  elif [ -e "$ENV_FILE" ] || [ ! -w "$(dirname "$ENV_FILE" 2>/dev/null)" ]; then
    return 0
  fi
  { printf '%s\n' "$ENV_LINE" >> "$ENV_FILE"; } 2>/dev/null || true
}

# Its own function: bash 3.2 mis-parses quotes in a heredoc inside $(...).
tasks_note() {
  cat <<'EOF'
Tasks recorded in the task ledger (.propel/tasks/), which is written only via `bash .claude/scripts/task-queue.sh`. Rows whose Session is not marked "(this)" or "(carried here)" are from earlier sessions and are NOT resumed automatically: show them to the user and ask one disjunctive question for the whole batch: carry them into this session (`task-queue.sh carry ID`), abandon them (`task-queue.sh abandon ID`), or leave them open for later — never change a task's state on your own. Statuses lost, unknown and blocked need a decision. The check-progress skill shows full status.
EOF
}

print_tasks() {
  read_session_id
  export_session
  [ -d ".propel/tasks" ] || return 0
  TQ="$PLUGIN_DIR/scripts/task-queue.sh"
  [ -f "$TQ" ] || return 0
  # list may append a settle event (one lock try, never waits); its exit
  # status is ignored — whatever it printed is what can be shown.
  TABLE=$("${BASH:-bash}" "$TQ" list --open --table --session "$SESSION_ID" \
    --sessions 10 --days 14 < /dev/null 2>/dev/null)
  case "$TABLE" in
    "| ID | Task |"*) ;;
    *) return 0 ;;   # "No open tasks.", nothing, or anything unexpected
  esac
  PRE="$(print_header; echo "## Open tasks"; echo ""; tasks_note)"
  # Budget for the table: everything else plus the newlines printed after PRE.
  USED=$(printf '%s\n\n' "$PRE" | wc -c | tr -d '[:space:]')
  BUDGET=$(( TASKS_MAX - ${USED:-0} ))
  printf '%s\n\n' "$PRE"
  # Keep the two header lines; at most TASKS_ROWS rows, then drop trailing
  # rows at line boundaries until the table and its "more" line fit BUDGET.
  # The "more" line is budgeted at its longest (all rows omitted).
  printf '%s\n' "$TABLE" | LC_ALL=C awk -v max="$BUDGET" -v rows="$TASKS_ROWS" \
      -v tail=" more open tasks — run check-progress)" \
      -v tail1=" more open task — run check-progress)" '
    { l[NR] = $0 }
    END {
      n = NR - 2
      keep = (n > rows) ? rows : n
      used = length(l[1]) + length(l[2]) + 2
      for (i = 3; i <= keep + 2; i++) used += length(l[i]) + 1
      if (keep == n && used <= max) { for (i = 1; i <= NR; i++) print l[i]; exit }
      used = length(l[1]) + length(l[2]) + 2 + length("(" n tail) + 1
      for (k = 0; k < keep; k++) {
        if (used + length(l[k + 3]) + 1 > max) break
        used += length(l[k + 3]) + 1
      }
      print l[1]; print l[2]
      for (i = 3; i < k + 3; i++) print l[i]
      print "(" (n - k) ((n - k == 1) ? tail1 : tail)
    }'
}

case "$PART" in
  state)   print_state
           if [ "$LEGACY" = true ]; then
             printf '\n%s\n' "$LEGACY_NOTICE"
           fi ;;
  tasks)   print_tasks ;;
  core)    print_policy "$CORE_FILE" "## Core principles" "core/CORE.md" ;;
  codex)   print_policy "$CODEX_FILE" "## Dual-model (Codex) policy" "core/CODEX.md" ;;
  routing[1-9]|routing[1-9][0-9])
           print_routing "${PART#routing}" ;;
  # Anything else — e.g. a user's own `session-start.sh --mine` registration —
  # prints nothing: a notice here would be injected into every session.
  *)       ;;
esac

exit 0
