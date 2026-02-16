#!/usr/bin/env bash
# Propel session-start hook
# Reads the using-propel skill and injects it as JSON context on startup/resume/clear/compact.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
SKILL_FILE="$PLUGIN_DIR/skills/using-propel/SKILL.md"

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

# Output JSON context for Claude Code to consume
cat <<EOF
{
  "plugin": "propel",
  "version": "0.1.0",
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
