---
name: c-review
description: >
  [Propel] Connect-to-Review — wraps the official Anthropic code-review plugin
  (https://github.com/anthropics/claude-code/tree/main/plugins/code-review) and
  runs it alongside Propel's own domain auditors during code review. Use when
  the user says "/c-review", "run the code-review plugin", "anthropic review",
  or during Gate 3 on non-trivial diffs. The plugin provides a broad correctness
  + style rubric; Propel's agents provide depth (silent bugs, paper alignment,
  regression). This skill merges both into one Gate 3 card — the plugin NEVER
  speaks to the user unfiltered.
---

# C-Review — Bridge to the Anthropic Code-Review Plugin

The Anthropic `code-review` plugin ships a mature, general-purpose review
rubric maintained by the Claude Code team. Propel's `code-reviewer` agent and
domain auditors (`silent-bug-detector`, `paper-alignment-auditor`,
`jax-logic-auditor`, `regression-guard`) go deeper on research-specific
concerns but cover less general ground.

Running both gives the widest coverage. This skill is the contract that keeps
them from stepping on each other.

## When to Activate

`/c-review` is appropriate in exactly these contexts:

- **Gate 3 audit** on a non-trivial diff (roughly: >30 lines changed, or any
  diff touching model / loss / data / training-loop code).
- **Pre-PR review** before `gh pr create`, when the user explicitly wants an
  external-rubric pass.
- **Explicit user request** ("run the anthropic review", "what does the plugin
  say about this").

Do NOT auto-fire on every edit — the plugin has a token cost and overlaps
with Propel's always-on auditors. Propel's own `code-reviewer` remains the
default for routine reviews.

## First-Run Setup

If this is the first `/c-review` invocation in this repo:

1. Check whether the code-review plugin is installed (look for its slash
   command registration in `.claude/` or the user's global Claude settings,
   or a `code-review` entry in installed plugins).
2. If not installed, point the user to
   `https://github.com/anthropics/claude-code/tree/main/plugins/code-review`
   with the install instruction from that README, and pause. Do not proceed
   until setup is confirmed.
3. If the plugin's slash command name / invocation differs from the default,
   ask the user to confirm the exact command before calling it.

Never fabricate plugin command syntax. When unclear, ask.

## The Interaction Contract (non-negotiable)

The plugin is a tool, not a voice to the user. Every `/c-review` exchange
follows this shape:

1. **Claude assembles the review target.** Identify the diff in scope
   (uncommitted, staged, commit range, or PR). List the files. State one
   line of context on what the diff implements. No speculation.
2. **Claude runs the plugin** against that target using its documented
   invocation. Capture the raw output.
3. **Claude runs Propel's domain auditors in parallel** — pick the relevant
   ones from the auto-dispatch table (silent-bug-detector always; plus
   paper-alignment-auditor / jax-logic-auditor / regression-guard as the
   diff requires).
4. **Claude merges and de-duplicates findings.** Plugin + auditor findings
   often overlap. One finding, one line. Tag each with its source.
5. **Claude presents a unified Gate 3 card.** User decides what to act on.

Under no circumstance is the plugin's raw output passed through to the user
unfiltered, nor used to silently rewrite code.

## Output Format

```
┌─ /c-review — Gate 3 ──────────────────────────────────────┐
│ Diff in scope:                                            │
│   <files, line counts>                                    │
│                                                           │
│ Findings (merged, de-duplicated):                         │
│   • [plugin]    <finding> — file:line (severity)          │
│   • [silent-bug] <finding> — file:line (severity)         │
│   • [both]      <finding> — file:line (severity)          │
│                                                           │
│ Disagreements:                                            │
│   • <plugin says X, auditor says Y — Claude's read>       │
│                                                           │
│ Not worth acting on (noted, filtered):                    │
│   • <finding> — reason                                    │
│                                                           │
│ Recommended action:                                       │
│   <1–2 lines, ordered by severity>                        │
└───────────────────────────────────────────────────────────┘
```

Attribution matters. The user must see which signal came from which source so
they can calibrate trust.

## Relationship to Propel's Own code-reviewer

`agents/code-reviewer.md` is Propel's native reviewer — research-aware,
auto-dispatched on every code change. The plugin does not replace it.

| Situation | Use |
|-----------|-----|
| Every code change (auto) | Propel `code-reviewer` agent |
| Gate 3 on a substantive diff | `/c-review` (both, merged) |
| Pre-PR pass | `/c-review` |
| Trivial one-line edit | Neither — skip |

If the plugin and Propel's agent contradict each other, surface the
disagreement explicitly (see output card). Do not silently pick one.

## Guardrails

- **Do not auto-fire.** `/c-review` is explicit-invocation or Gate 3 only.
  Routine edits use Propel's own auditors.
- **Do not let plugin output bypass synthesis.** No "the plugin says…" dumps.
  Findings go through the merge step.
- **Do not let the plugin write to the repo.** Plugin proposes; Claude (under
  user approval) implements. Same rule as `/c-codex`.
- **De-duplicate aggressively.** If plugin and `silent-bug-detector` raise
  the same issue, it's one finding tagged `[both]`, not two.
- **Filter noise.** Style nits that conflict with the project's established
  conventions go in "Not worth acting on" with a reason — don't propagate
  them as findings just because the plugin surfaced them.
- **Respect the gate.** `/c-review` produces a Gate 3 card; it does not
  auto-approve the transition. User still decides.

## Related

- `/c-codex` — divergent-model review (different model, different biases).
  Pair with `/c-review` for the widest coverage on high-stakes diffs.
- `code-reviewer` agent — Propel's always-on reviewer. `/c-review` runs
  alongside it, not instead of it.
- `silent-bug-detector`, `paper-alignment-auditor`, `jax-logic-auditor`,
  `regression-guard` — domain auditors merged into the `/c-review` card.
- Gate 3 (in `using-propel`) — the natural host for `/c-review`.
