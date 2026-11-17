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
#             empty repo, registry entries                (default, no argument)
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
  SIZE=$(wc -c < "$1" 2>/dev/null | tr -d '[:space:]')
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
state_pre() {
  # Codex state
  echo "## Codex state"
  echo ""
  CODEX_CONFIG=".propel/codex.json"
  if [ -f "$CODEX_CONFIG" ]; then
    CODEX_STATE=""
    if [ "$HAVE_PYTHON" = true ]; then
      CODEX_STATE=$(python3 -c "
import json
try:
    d = json.load(open('$CODEX_CONFIG'))
except Exception:
    d = {}
if not isinstance(d, dict):
    d = {}
available = d.get('available', None)
print('enabled: %s, available: %s' % (
    'false' if d.get('enabled') is False else 'true',
    ('true' if available else 'false') if isinstance(available, bool) else 'null'))
" 2>/dev/null || echo "")
    fi
    if [ -z "$CODEX_STATE" ]; then
      ENABLED="true"
      if grep -Eq '"enabled"[[:space:]]*:[[:space:]]*false([^a-zA-Z0-9_]|$)' "$CODEX_CONFIG" 2>/dev/null; then
        ENABLED="false"
      fi
      AVAILABLE="null"
      if grep -q '"available"[[:space:]]*:[[:space:]]*false' "$CODEX_CONFIG" 2>/dev/null; then
        AVAILABLE="false"
      elif grep -q '"available"[[:space:]]*:[[:space:]]*true' "$CODEX_CONFIG" 2>/dev/null; then
        AVAILABLE="true"
      fi
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
    MODE_SIZE=$(wc -c < ".propel/mode.json" 2>/dev/null | tr -d '[:space:]')
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
  if grep -Eq '"mode"[[:space:]]*:[[:space:]]*"[^"]+' ".propel/mode.json" 2>/dev/null; then
    echo "mode_selection_needed: false"
  else
    echo "mode_selection_needed: true"
  fi
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
    SIZE=$(wc -c < ".propel/profile.md" 2>/dev/null | tr -d '[:space:]')
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

case "$PART" in
  state)   print_state ;;
  core)    print_policy "$CORE_FILE" "## Core principles" "core/CORE.md" ;;
  codex)   print_policy "$CODEX_FILE" "## Dual-model (Codex) policy" "core/CODEX.md" ;;
  routing[1-9]|routing[1-9][0-9])
           print_routing "${PART#routing}" ;;
  # Anything else — e.g. a user's own `session-start.sh --mine` registration —
  # prints nothing: a notice here would be injected into every session.
  *)       ;;
esac

exit 0
