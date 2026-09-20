#!/usr/bin/env bash
# Propel session-start hook
# Reads the using-propel skill and injects it as JSON context on startup/resume/clear/compact.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
SKILL_FILE="$PLUGIN_DIR/skills/using-propel/SKILL.md"
CORE_FILE="$PLUGIN_DIR/core/CORE.md"
CODEX_FILE="$PLUGIN_DIR/core/CODEX.md"

if [ ! -f "$SKILL_FILE" ]; then
  echo '{"error": "using-propel/SKILL.md not found"}'
  exit 1
fi

# Read the skill file and escape for JSON
SKILL_CONTENT=$(cat "$SKILL_FILE")

# Escape special characters for JSON embedding
ESCAPED=$(printf '%s' "$SKILL_CONTENT" | python3 -c '
import sys, json
content = sys.stdin.read()
print(json.dumps(content))
')

# Read core principles (injected every session — non-negotiable)
if [ -f "$CORE_FILE" ]; then
  CORE_ESCAPED=$(printf '%s' "$(cat "$CORE_FILE")" | python3 -c '
import sys, json
content = sys.stdin.read()
print(json.dumps(content))
')
else
  CORE_ESCAPED='null'
fi

# Read the dual-model policy (injected every session — non-negotiable while Codex is on)
if [ -f "$CODEX_FILE" ]; then
  CODEX_ESCAPED=$(printf '%s' "$(cat "$CODEX_FILE")" | python3 -c '
import sys, json
content = sys.stdin.read()
print(json.dumps(content))
')
else
  CODEX_ESCAPED='null'
fi

# Output JSON context for Claude Code to consume
cat <<EOF
{
  "plugin": "propel",
  "version": "0.1.0",
  "core_principles": ${CORE_ESCAPED},
  "codex_policy": ${CODEX_ESCAPED},
  "codex_state": $(
    CODEX_CONFIG=".propel/codex.json"
    if [ -f "$CODEX_CONFIG" ]; then
      python3 -c "
import json
try:
    d = json.load(open('$CODEX_CONFIG'))
except Exception:
    d = {}
d.setdefault('enabled', True)
if 'available' not in d:
    d['available'] = None
print(json.dumps(d))
" 2>/dev/null || echo '{"enabled": true, "available": null}'
    else
      echo '{"enabled": true, "available": null, "note": "no .propel/codex.json yet — dual-model layer is ON by default; disable with /disable-codex"}'
    fi
  ),
  "context": ${ESCAPED},
  "active_investigations": $(
    if [ -d "scratch" ]; then
      find scratch -maxdepth 2 -name "README.md" -path "*/scratch/*/README.md" 2>/dev/null \
        | sort -r \
        | head -5 \
        | python3 -c '
import sys, json
paths = [line.strip() for line in sys.stdin if line.strip()]
print(json.dumps(paths))
'
    else
      echo '[]'
    fi
  ),
  "project_profile": $(
    PROFILE_FILE=".propel/profile.md"
    if [ -f "$PROFILE_FILE" ]; then
      CONFIG_FILE=".propel/config.json"
      ENABLED=true
      if [ -f "$CONFIG_FILE" ]; then
        ENABLED=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('enabled', True))" 2>/dev/null || echo "true")
      fi
      if [ "$ENABLED" = "True" ] || [ "$ENABLED" = "true" ]; then
        python3 -c '
import sys, json
content = open("'"$PROFILE_FILE"'").read()
print(json.dumps(content))
'
      else
        echo 'null'
      fi
    else
      echo 'null'
    fi
  ),
  "empty_repo": $(
    # A repo is "empty" if there are no source files to scan — just Propel scaffolding
    SOURCE_COUNT=$(find . -maxdepth 3 \
      \( -name "*.py" -o -name "*.js" -o -name "*.ts" -o -name "*.rs" -o -name "*.go" \
         -o -name "*.java" -o -name "*.cpp" -o -name "*.c" -o -name "*.jl" -o -name "*.r" -o -name "*.R" \) \
      -not -path "./.claude/*" -not -path "./scratch/*" -not -path "./.propel/*" \
      -not -path "./sessions/*" -not -path "./node_modules/*" -not -path "./.git/*" \
      2>/dev/null | head -1 | wc -l)
    if [ "$SOURCE_COUNT" -eq 0 ]; then
      echo 'true'
    else
      echo 'false'
    fi
  ),
  "mode": $(
    MODE_FILE=".propel/mode.json"
    if [ -f "$MODE_FILE" ]; then
      cat "$MODE_FILE" | python3 -c '
import sys, json
data = json.load(sys.stdin)
print(json.dumps(data))
'
    else
      echo 'null'
    fi
  ),
  "mode_selection_needed": $(
    if [ -f ".propel/mode.json" ]; then
      echo 'false'
    else
      echo 'true'
    fi
  ),
  "mode_selection_policy": "AUTO. When mode_selection_needed is true, do NOT present a menu and do NOT block. Infer the mode from the user's first substantive message using the routing table in the using-propel skill, announce the choice in one line with the reason, write .propel/mode.json with \"selected_by\": \"auto\", and continue with the work. Only present the four-mode menu if the user opens with /intro, asks which modes exist, or the message is too ambiguous to classify.",
  "registry_entries": $(
    if [ -d "scratch/registry" ]; then
      find scratch/registry -maxdepth 1 -mindepth 1 -type d 2>/dev/null \
        | sort -r \
        | head -10 \
        | python3 -c '
import sys, json
paths = [line.strip() for line in sys.stdin if line.strip()]
print(json.dumps(paths))
'
    else
      echo '[]'
    fi
  )
}
EOF
