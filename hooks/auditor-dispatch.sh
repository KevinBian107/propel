#!/usr/bin/env bash
# Propel — automatic auditor dispatch (PostToolUse on Edit|Write|MultiEdit|NotebookEdit)
#
# Propel's auditors used to be "auto-dispatched" only in the sense that a skill
# file told Claude to remember to dispatch them. Memory is not a mechanism. This
# hook makes the dispatch deterministic: the harness looks at what file was just
# written and states, as context, which auditors are now required before the
# change can be presented at Gate 3.
#
# When pages under docs/ or documentation/ mention the edited file's
# project-relative path, it adds one more line naming up to 3 of those pages and
# telling Claude to ask the user (make-documentations Step 0) before updating
# them, so stale docs are flagged deterministically. When .propel/docs.json turns
# docs prompts off (/disable-make-documentations), that line is never added.
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

# ── Docs staleness: docs pages that mention the edited file ──
# Only source/config files reach this point (a .md edit exited above). The
# path is made project-relative and searched for, as a fixed string, in at most
# 200 pages under docs/ and documentation/. No python3; bounded; silent on any
# failure. Adds one line naming up to 3 pages and the make-documentations
# question, unless docs prompts are off.
DOCS_LINE=""
PROJ="${CLAUDE_PROJECT_DIR:-$PWD}"

# The "enabled" rule for .propel/docs.json, the same fail-closed rule every
# Propel script applies to .propel/codex.json (see codex_flat_off in
# hooks/route.sh): OFF when "enabled" is JSON false, null or 0, or a string
# that, trimmed and lowercased, is "false", "0", "off", "no" or empty. A missing
# file or key leaves it ON. docs_flat_off <flat>: on the file with all
# whitespace removed; returns 0 (off) if any "enabled" value is off.
docs_flat_off() {
  local rest="$1" v t
  while :; do
    case "$rest" in
      *'"enabled":'*) rest=${rest#*'"enabled":'} ;;
      *) return 1 ;;
    esac
    case "$rest" in
      '"'*)
        v=${rest#?}; v=${v%%'"'*}
        # A JSON escape (\t, f...) is not decoded here, so fail closed: off.
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
DOCS_OFF=false
if [ -f "$PROJ/.propel/docs.json" ]; then
  # Globs on a flattened copy, not grep <<<: a here-string is a temp file on bash 3.2.
  DOCS_FLAT=$(head -c 8192 "$PROJ/.propel/docs.json" 2>/dev/null | LC_ALL=C tr -d '[:space:]' 2>/dev/null)
  docs_flat_off "$DOCS_FLAT" && DOCS_OFF=true
fi

REL="$FILE"
case "$REL" in "$PROJ"/*) REL="${REL#"$PROJ"/}" ;; esac
REL="${REL#./}"
case "$REL" in
  /*|"") ;;
  *)
    if [ "$DOCS_OFF" != true ] && { [ -d "$PROJ/docs" ] || [ -d "$PROJ/documentation" ]; }; then
      DOC_LIST=$(cd "$PROJ" 2>/dev/null && find docs documentation -type f -name '*.md' 2>/dev/null | head -n 200 | sort)
      if [ -n "$DOC_LIST" ]; then
        set --
        while IFS= read -r DOC_PAGE; do
          [ -n "$DOC_PAGE" ] && set -- "$@" "$DOC_PAGE"
        done <<DOCS_EOF
$DOC_LIST
DOCS_EOF
        STALE=""
        # Whole-path match: no path character directly before or after, so an
        # edit to train.py does not match src/train.py or mytrain.py.
        REL_RE=$(printf '%s' "$REL" | sed 's/[][\\.*^$+?(){}|/]/\\&/g')
        [ "$#" -gt 0 ] && STALE=$(cd "$PROJ" 2>/dev/null && LC_ALL=C grep -l -E -e "(^|[^A-Za-z0-9_./-])${REL_RE}(\$|[^A-Za-z0-9_])" -- "$@" 2>/dev/null)
        if [ -n "$STALE" ]; then
          N_STALE=$(printf '%s\n' "$STALE" | wc -l | tr -d ' ')
          SHOWN=$(printf '%s\n' "$STALE" | head -n 3 | tr '\n' ',' | sed 's/,$//; s/,/, /g')
          MORE=""
          [ "$N_STALE" -gt 3 ] 2>/dev/null && MORE=" and $((N_STALE - 3)) more"
          DOCS_LINE="[propel:docs] Docs pages mention ${REL}: ${SHOWN}${MORE}. When the change is presented as done, ask the user one question (make-documentations Step 0; in the same AskUserQuestion call as any gate question) whether to update them and what each update would cover, and do not edit them without an answer."
        fi
      fi
    fi ;;
esac
# JSON-escape the line (control characters become spaces; backslash and double quote), then start it on a new
# line of additionalContext with a JSON \n.
if [ -n "$DOCS_LINE" ]; then
  DOCS_LINE="\\n$(printf '%s' "$DOCS_LINE" | LC_ALL=C tr '\001-\037' ' ' | sed 's/[\\"]/\\&/g')"
fi
# The edited path goes into the JSON too: escape it the same way, so a path
# with a quote or backslash cannot produce invalid JSON.
FILE=$(printf '%s' "$FILE" | LC_ALL=C tr '\001-\037' ' ' | sed 's/[\\"]/\\&/g')

cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "[propel:auto-dispatch] You just modified ${FILE} (${KIND}). Before this change is presented at Gate 3 or described as done, these auditors are REQUIRED, dispatched as subagents in parallel: ${AUDITORS}. Trigger: ${REASONS}. If the component is paper-derived, add paper-alignment-auditor with the relevant scratch/paper-notes/ entry. If the accumulated diff is non-trivial (>=30 lines, or it touches model/loss/data/training-loop code), the Gate 3 Codex consult also applies — see the codex-consult skill; announce it with the '\\u25c6 Consulting Codex' line. Do not skip these because the change looked small, and do not present results to the user before they have run. If an auditor's finding turns out to be a false positive, say so with evidence rather than silently dropping it.${DOCS_LINE}"
  }
}
EOF
exit 0
