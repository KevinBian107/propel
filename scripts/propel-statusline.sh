#!/usr/bin/env bash
# Propel — status line: claude-hud, plus a Codex task block beneath it.
#
# claude-hud is the status line; this only wraps it. It runs hud with whatever
# stdin Claude Code provided, prints hud's output unchanged, then appends
# Propel's Codex block underneath.
#
# Wrapping rather than extending is a deliberate trade. hud's own `--extra-cmd`
# hook yields exactly one label on the session line and sanitizes ANSI out of it,
# so it cannot produce a separate, coloured block. The cost is that this script
# has to keep working if hud changes -- which is why every step below degrades
# instead of failing:
#
#   hud missing or broken  -> print the Codex block alone
#   Codex block broken     -> print hud's output alone
#   both broken            -> print nothing, exit 0
#
# A status line that errors or hangs is worse than one that is missing.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD=$(cat 2>/dev/null || true)

# ── claude-hud: newest installed version, same discovery the plugin ships with ──
HUD_OUT=""
PLUGIN_DIR=$(ls -d "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/plugins/cache/*/claude-hud/*/ 2>/dev/null \
  | awk -F/ '{ print $(NF-1) "\t" $0 }' \
  | grep -E '^[0-9]+\.[0-9]+\.[0-9]+[[:space:]]' \
  | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | tail -1 | cut -f2-)

if [ -n "$PLUGIN_DIR" ] && [ -f "${PLUGIN_DIR}dist/index.js" ]; then
  NODE_BIN=$(command -v node || echo /usr/local/bin/node)
  if [ -x "$NODE_BIN" ]; then
    # The redirect itself fails when there is no controlling terminal, and bash
    # reports that -- so the whole group needs its stderr suppressed, not stty's.
    cols=$( { stty size </dev/tty; } 2>/dev/null | awk '{print $2}')
    export COLUMNS=$(( ${cols:-120} > 4 ? ${cols:-120} - 4 : 1 ))

    # Keep hud's own segment too: the label answers "is Codex on, and how much
    # today", the block below answers "what is it doing right now". Different
    # questions, both worth a glance.
    SEGMENT="$SCRIPT_DIR/codex-statusline.sh"
    HUD_ARGS=()
    [ -f "$SEGMENT" ] && HUD_ARGS=(--extra-cmd "bash $SEGMENT")

    HUD_OUT=$(printf '%s' "$PAYLOAD" \
      | "$NODE_BIN" "${PLUGIN_DIR}dist/index.js" "${HUD_ARGS[@]+"${HUD_ARGS[@]}"}" 2>/dev/null || true)
  fi
fi

CODEX_OUT=$(bash "$SCRIPT_DIR/codex-tasks.sh" 2>/dev/null || true)

[ -n "$HUD_OUT" ] && printf '%s\n' "$HUD_OUT"
[ -n "$CODEX_OUT" ] && printf '%s\n' "$CODEX_OUT"
exit 0
