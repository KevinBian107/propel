#!/usr/bin/env bash
# Propel — automatic auditor dispatch (PostToolUse on Edit|Write|MultiEdit|NotebookEdit)
#
# Propel's auditors used to be "auto-dispatched" only in the sense that a skill
# file told Claude to remember to dispatch them. Memory is not a mechanism. This
# hook makes the dispatch deterministic: the harness looks at what file was just
# written and states, as context, which auditors are now required before the
# change can be presented at Gate 3.
#
# Reads the PostToolUse JSON payload on stdin. Always exits 0 — a hook that can
# fail a write is a hook that will eventually eat someone's work.

set -uo pipefail

PAYLOAD=$(cat 2>/dev/null || echo '{}')

FILE=$(printf '%s' "$PAYLOAD" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    ti = d.get("tool_input") or {}
    print(ti.get("file_path") or ti.get("notebook_path") or "")
except Exception:
    print("")
' 2>/dev/null || echo "")

[ -z "$FILE" ] && exit 0

# ── Ignore Propel's own working surfaces and anything not source ──
case "$FILE" in
  */scratch/*|scratch/*|*/sessions/*|sessions/*|*/.propel/*|.propel/*) exit 0 ;;
  */.claude/*|.claude/*|*/node_modules/*|*/.git/*|*/website/*) exit 0 ;;
esac

EXT="${FILE##*.}"
KIND=""
case "$EXT" in
  py|jl|rs|go|c|cc|cpp|h|hpp|ts|tsx|js|jsx|java|m|mm|cu|ipynb) KIND="source" ;;
  yaml|yml|toml|ini|cfg)                                       KIND="config" ;;
  json)
    case "$FILE" in
      *package.json|*tsconfig.json) KIND="config" ;;
      *)                            KIND="config" ;;
    esac ;;
  *) exit 0 ;;
esac

BASE=$(basename "$FILE" | tr '[:upper:]' '[:lower:]')
AUDITORS="regression-guard"
REASONS="any code change"

if [ "$KIND" = "source" ]; then
  # Model / loss / data surfaces — where silent bugs actually live.
  case "$BASE" in
    *model*|*net*|*loss*|*objective*|*policy*|*actor*|*critic*|*reward*|\
    *encoder*|*decoder*|*vq*|*embed*|*attention*|*transformer*|*diffusion*|\
    *data*|*dataset*|*loader*|*sampler*|*collate*|*augment*|*normaliz*|\
    *train*|*trainer*|*optim*|*sched*)
      AUDITORS="silent-bug-detector, $AUDITORS"
      REASONS="model/loss/data/training surface; $REASONS"
      ;;
  esac

  # JAX transforms — read the file rather than guessing from the name.
  if [ -f "$FILE" ] && grep -qE '(^|[^a-zA-Z_])(jax|jnp)\.|@jit|jax\.jit|vmap|pmap|lax\.scan|jax\.lax' "$FILE" 2>/dev/null; then
    AUDITORS="jax-logic-auditor, $AUDITORS"
    REASONS="JAX transforms present; $REASONS"
  fi

  # Environment interaction surfaces.
  case "$BASE" in
    *env*|*wrapper*|*gym*|*mujoco*|*mjx*|*sim*|*robot*)
      AUDITORS="env-researcher, $AUDITORS"
      REASONS="environment interaction; $REASONS"
      ;;
  esac
fi

cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "[propel:auto-dispatch] You just modified ${FILE} (${KIND}). Before this change is presented at Gate 3 or described as done, these auditors are REQUIRED, dispatched as subagents in parallel: ${AUDITORS}. Trigger: ${REASONS}. If the component is paper-derived, add paper-alignment-auditor with the relevant scratch/paper-notes/ entry. If the accumulated diff is non-trivial (>=30 lines, or it touches model/loss/data/training-loop code), the Gate 3 Codex consult also applies — see the codex-consult skill; announce it with the '\\u25c6 Consulting Codex' line. Do not skip these because the change looked small, and do not present results to the user before they have run. If an auditor's finding turns out to be a false positive, say so with evidence rather than silently dropping it."
  }
}
EOF
exit 0
