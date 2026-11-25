#!/usr/bin/env bash
# Propel working-memory hook
#
# On SessionStart, injects a summary of prior experiments and
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
# Output is PLAIN TEXT (Claude Code adds plain-text SessionStart stdout to
# context). All files are optional; if every source is empty or missing, this
# prints nothing at all. No python3 needed. Exits 0 on every path.
#
# Claude Code truncates a SessionStart hook's stdout above ~10,000 characters,
# so each log is cut to its LAST 3,500 characters (at a line boundary) and the
# registry listing to 1,500 characters, keeping the total under 9,000.

set -uo pipefail

# Resolve project-relative state from the project root, even when Claude Code
# was started in a subdirectory.
cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || true

LOG_MAX=3500
REGISTRY_MAX=1500   # max characters for the registry listing

# Print the last LOG_MAX characters of a log, cut at a line boundary, preceded by
# an omitted-entries line when anything was cut.
print_log_tail() {  # <file>
  LC_ALL=C awk -v max="$LOG_MAX" -v name="$(basename "$1")" '
    { lines[NR] = $0 }
    END {
      n = 0; first = NR + 1
      for (i = NR; i >= 1; i--) {
        if (n + length(lines[i]) + 1 > max) break
        n += length(lines[i]) + 1; first = i
      }
      if (first > 1) print "(earlier entries omitted — full log at scratch/working-memory/" name ")"
      if (first > NR && NR > 0) {
        # A single last line longer than the budget: keep its tail.
        print substr(lines[NR], length(lines[NR]) - max + 2)
      }
      for (i = first; i <= NR; i++) print lines[i]
    }' "$1" 2>/dev/null
}

EXPERIMENTS_FILE="scratch/working-memory/experiments.md"
ARCHITECTURES_FILE="scratch/working-memory/architectures.md"

EXPERIMENTS=""
if [ -f "$EXPERIMENTS_FILE" ]; then
  EXPERIMENTS=$(cat "$EXPERIMENTS_FILE" 2>/dev/null)
fi
ARCHITECTURES=""
if [ -f "$ARCHITECTURES_FILE" ]; then
  ARCHITECTURES=$(cat "$ARCHITECTURES_FILE" 2>/dev/null)
fi

# Recent registry entries: directory names only, newest first, up to 10.
RECENT_REGISTRY=""
if [ -d "scratch/registry" ]; then
  RECENT_REGISTRY=$(find scratch/registry -maxdepth 1 -mindepth 1 -type d 2>/dev/null \
    | sort -r \
    | head -10)
fi

# Nothing to say → say nothing (empty stdout is valid hook output).
if [ -z "$(printf '%s' "$EXPERIMENTS" | tr -d '[:space:]')" ] \
  && [ -z "$(printf '%s' "$ARCHITECTURES" | tr -d '[:space:]')" ] \
  && [ -z "$RECENT_REGISTRY" ]; then
  exit 0
fi

# Heuristic freshness flag — warn Claude if working-memory files haven't been
# touched in 14+ days, which usually means they're stale.
STALE="false"
if [ -f "$EXPERIMENTS_FILE" ] || [ -f "$ARCHITECTURES_FILE" ]; then
  NEWEST=$(find scratch/working-memory -maxdepth 1 -type f -name "*.md" -mtime -14 2>/dev/null | head -1)
  if [ -z "$NEWEST" ]; then
    STALE="true"
  fi
fi

echo "[propel:working-memory] Before proposing a new experiment or architecture, consult the entries below. If a proposal overlaps with prior work, either reuse/extend it, or state explicitly why a fresh attempt is warranted."
echo ""
if [ "$STALE" = "true" ]; then
  echo "WARNING: the working-memory logs have not been updated in 14+ days and may be stale."
  echo ""
fi

echo "## Experiments log"
echo ""
if [ -n "$(printf '%s' "$EXPERIMENTS" | tr -d '[:space:]')" ]; then
  print_log_tail "$EXPERIMENTS_FILE"
else
  echo "(empty)"
fi
echo ""

echo "## Architectures log"
echo ""
if [ -n "$(printf '%s' "$ARCHITECTURES" | tr -d '[:space:]')" ]; then
  print_log_tail "$ARCHITECTURES_FILE"
else
  echo "(empty)"
fi
echo ""

echo "## Recent registry entries"
echo ""
if [ -n "$RECENT_REGISTRY" ]; then
  # The whole listing, or as many entries as fit before "(more in
  # scratch/registry/)" — never more than REGISTRY_MAX characters in total.
  printf '%s\n' "$RECENT_REGISTRY" | LC_ALL=C awk -v max="$REGISTRY_MAX" -v more="(more in scratch/registry/)" '
    { lines[NR] = "- " $0; total += length(lines[NR]) + 1 }
    END {
      if (total <= max) { for (i = 1; i <= NR; i++) print lines[i]; exit }
      n = length(more) + 1
      for (i = 1; i <= NR; i++) { n += length(lines[i]) + 1; if (n > max) break; print lines[i] }
      print more
    }'
else
  echo "(none)"
fi

exit 0
