---
name: c-review
description: >
  [Propel] Connect-to-Review — wraps the official Anthropic code-review plugin
  (https://github.com/anthropics/claude-code/tree/main/plugins/code-review) and
  runs it alongside Propel's own domain auditors during code review. Use when
  Fires AUTOMATICALLY at Gate 3 on non-trivial diffs, before a PR, and whenever
  a deeper or more thorough review is asked for ("really check this", "ultrathink
  this review") — as well as on "/c-review", "run the code-review plugin",
  "anthropic review". Degrades to auditors + Codex when the plugin is absent. The plugin provides a broad correctness
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

**This fires automatically — the user does not invoke it.** Like the Codex
consult, it is scheduled, not requested:

- **Gate 3** on a non-trivial diff (roughly: >30 lines changed, or any diff
  touching model / loss / data / training-loop code).
- **Pre-PR**, before `gh pr create`.
- **Any request for a deeper or more thorough review** — "really check this",
  "go deep on this diff", "ultrathink this review". A request for more rigour is
  a request for every signal available, and this is one of them.
- **Explicit request**, obviously ("run the anthropic review").

Do NOT fire on every edit. The plugin costs ~2.5k tokens per invocation and
overlaps heavily with Propel's always-on auditors, so on a three-line change it
buys nothing and trains the user to ignore the card. Propel's own
`code-reviewer` remains the default for routine reviews.

## Availability — degrade, don't pause

The plugin is optional. Check once per session:

```bash
claude plugin list --json
```

- **Present** (`code-review@claude-plugins-official`, `enabled: true`) → use it.
  No announcement needed beyond the `[plugin]` tag on its findings.
- **Absent** → run the rest of the review — Propel's auditors and the Codex
  consult — and add **one** line to the card:
  > `[plugin] not installed — this card is auditors + Codex only. `propel launch` adds it.`

  Then continue. Do **not** pause, and do not repeat the notice at the next
  Gate 3.

This is deliberately different from how the skill used to behave. Blocking a
review because an optional rubric is missing trades a complete-but-narrower
review for no review at all, which is the worse outcome every time. The same
reasoning governs a missing Codex CLI.

Never fabricate plugin command syntax. If the invocation is unclear, read the
plugin's own skill rather than guessing.

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
4. **Claude dispatches `codex-bridge` on the same diff.** The Gate 3 Codex
   consult is automatic anyway; running it inside `/c-review` means one merged
   card instead of two overlapping ones. Skip it only if a Gate 3 consult
   already ran on this exact diff.
5. **Claude merges and de-duplicates findings.** Plugin, auditor, and Codex
   findings overlap heavily. One finding, one line. Tag each with its source.
6. **Claude presents a unified Gate 3 card.** User decides what to act on.

Under no circumstance is the plugin's raw output passed through to the user
unfiltered, nor used to silently rewrite code.

## Output Format

```
┌─ /c-review — Gate 3 ──────────────────────────────────────┐
│ Diff in scope:                                            │
│   <files, line counts>                                    │
│                                                           │
│ Findings (merged, de-duplicated):                         │
│   • [plugin]     <finding> — file:line (severity)         │
│   • [silent-bug] <finding> — file:line (severity)         │
│   • [codex]      <finding> — file:line (severity)         │
│   • [all three]  <finding> — file:line (severity)         │
│                                                           │
│ Codex claimed, could not verify:                          │
│   • [codex · unverified] <claim> — <why not confirmed>    │
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
| Gate 3 on a substantive diff | `c-review` (plugin + auditors + Codex, merged) |
| Pre-PR pass | `c-review` |
| "go deeper / ultrathink this review" | `c-review`, plus the Codex consult |
| Trivial one-line edit | Neither — skip |

If the plugin and Propel's agent contradict each other, surface the
disagreement explicitly (see output card). Do not silently pick one.

## Guardrails

- **Do not auto-fire.** `/c-review` is explicit-invocation or Gate 3 only.
  Routine edits use Propel's own auditors.
- **Do not let plugin output bypass synthesis.** No "the plugin says…" dumps.
  Findings go through the merge step.
- **Do not let the plugin write to the repo.** Plugin proposes; Claude (under
  user approval) implements. Same rule as Codex.
- **De-duplicate aggressively.** If plugin and `silent-bug-detector` raise
  the same issue, it's one finding tagged `[both]`, not two.
- **Filter noise.** Style nits that conflict with the project's established
  conventions go in "Not worth acting on" with a reason — don't propagate
  them as findings just because the plugin surfaced them.
- **Respect the gate.** `/c-review` produces a Gate 3 card; it does not
  auto-approve the transition. User still decides.

## Related

- `codex-consult` — the automatic dual-model layer. `/c-review` folds its Gate 3
  consult into the same card rather than firing a second one.
- `code-reviewer` agent — Propel's always-on reviewer. `/c-review` runs
  alongside it, not instead of it.
- `silent-bug-detector`, `paper-alignment-auditor`, `jax-logic-auditor`,
  `regression-guard` — domain auditors merged into the `/c-review` card.
- Gate 3 (in `using-propel`) — the natural host for `/c-review`.
