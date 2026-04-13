#!/usr/bin/env bash
# Propel working-memory hook
#
# On SessionStart / PreCompact, injects a summary of prior experiments and
# architecture/method designs so Claude doesn't re-propose work that has
# already been tried or already been built.
#
# Reads from:
#   scratch/working-memory/experiments.md    (append-only log of experiments)
#   scratch/working-memory/architectures.md  (append-only log of method designs)
#
# Also pulls recent registry entries (scratch/registry/*) as secondary source
# of truth for experiments, since /retrospective writes there.
#
# All files are optional. Missing files are treated as empty, never as errors.

set -euo pipefail

read_or_empty() {
  if [ -f "$1" ]; then
    cat "$1"
  else
    echo ""
  fi
}

json_escape() {
  python3 -c 'import sys, json; print(json.dumps(sys.stdin.read()))'
}

EXPERIMENTS=$(read_or_empty "scratch/working-memory/experiments.md" | json_escape)
ARCHITECTURES=$(read_or_empty "scratch/working-memory/architectures.md" | json_escape)

# Recent registry entries: directory names only, newest first, up to 10.
if [ -d "scratch/registry" ]; then
  RECENT_REGISTRY=$(
    find scratch/registry -maxdepth 1 -mindepth 1 -type d 2>/dev/null \
      | sort -r \
      | head -10 \
      | python3 -c '
import sys, json
paths = [line.strip() for line in sys.stdin if line.strip()]
print(json.dumps(paths))
'
  )
else
  RECENT_REGISTRY='[]'
fi

# Heuristic freshness flag — warn Claude if working-memory files haven't been
# touched in 14+ days, which usually means they're stale.
STALE="false"
if [ -f "scratch/working-memory/experiments.md" ] || [ -f "scratch/working-memory/architectures.md" ]; then
  NEWEST=$(find scratch/working-memory -maxdepth 1 -type f -name "*.md" -mtime -14 2>/dev/null | head -1)
  if [ -z "$NEWEST" ]; then
    STALE="true"
  fi
fi

cat <<EOF
{
  "plugin": "propel",
  "hook": "working-memory",
  "guidance": "Before proposing a new experiment or architecture, consult the entries below. If a proposal overlaps with prior work, either reuse/extend it, or state explicitly why a fresh attempt is warranted.",
  "experiments_log": ${EXPERIMENTS},
  "architectures_log": ${ARCHITECTURES},
  "recent_registry_entries": ${RECENT_REGISTRY},
  "stale": ${STALE}
}
EOF
