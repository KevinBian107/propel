---
name: codex-lead
description: >
  [Propel] Complementary flag for /c-codex — switches the next /c-codex exchange
  from "Codex as peer critic" (default) to "Codex as primary, Claude as adversarial
  checker". Use when the user says "/codex-lead", "let codex drive", "codex-primary",
  "codex leads this review", or "codex-lead: <task>". ONLY meaningful alongside
  /c-codex. Outside /c-codex, this skill refuses and redirects. Ephemeral — arms
  the flag for exactly one /c-codex exchange, then reverts to default.
---

# Codex-Lead — Primary-Mode Flag for /c-codex

By default, `/c-codex` keeps Claude in charge of the synthesis step: Claude
frames the question, Codex critiques, Claude produces the comparison card.
That is correct when Claude has strong repo context and Codex is being brought
in for a divergent perspective.

But sometimes Codex is genuinely stronger on the task at hand — particularly
code review in languages or patterns where its training dominates. In those
cases, the synthesis bottleneck can dilute Codex's findings. `/codex-lead`
flips the contract for one exchange: Codex leads, Claude becomes the
adversarial checker.

## Scope (non-negotiable)

This skill only makes sense inside a `/c-codex` exchange. If the user invokes
`/codex-lead` without an active or pending `/c-codex` call, respond with:

> `/codex-lead` is a flag for `/c-codex`. It has no effect on its own. Either
> invoke `/c-codex` with the `codex-lead` flag set, or drop the flag.

Do not let Codex take over any workflow that is not routed through `/c-codex`.

## How the Flag Works

The flag is **ephemeral** — single-use per invocation. After one `/c-codex`
exchange under codex-lead, the contract reverts to the Claude-synthesizes
default. This is deliberate: a persistent flag would let the user forget they
were in lead mode and end up trusting unverified Codex output.

**To activate**: user says `/codex-lead` in the same turn as (or immediately
before) `/c-codex`, or says something like "let codex lead this review, go
/c-codex".

**To re-use**: user must re-arm the flag every time.

## The Flipped Contract

Under codex-lead, the five-step interaction becomes:

1. **Claude provides a minimal brief** (not a synthesis). Pure facts: the diff,
   the plan, the files in scope, no opinions on what's right or wrong. Codex
   shouldn't be anchored by Claude's reading.
2. **Codex produces the primary output.** Full review, full plan critique —
   Codex drives the substance.
3. **Claude verifies every concrete claim against the repo.** This is the
   load-bearing step. For each file:line reference or behavioral claim Codex
   makes, Claude opens the file and checks. Codex can hallucinate file paths,
   line numbers, and even function names — Claude is the ground-truth filter.
4. **Claude adds adversarial findings.** Things Codex missed, false positives
   Codex raised, anywhere Codex's claim contradicts the actual code.
5. **Claude presents the merged output** to the user, clearly attributed:

```
┌─ /c-codex (codex-lead) — <planning | code-review> ────────┐
│ Codex's primary findings (verified):                      │
│   ✓ <point>  [verified against file:line]                 │
│   ✓ <point>  [verified against file:line]                 │
│                                                           │
│ Codex raised, Claude could not verify / disputes:         │
│   ✗ <point> — Codex cited <X>. Actual: <Y>.               │
│                                                           │
│ Claude adds (missed by Codex):                            │
│   + <point> at file:line                                  │
│                                                           │
│ Recommended action:                                       │
│   <1–2 lines>                                             │
└───────────────────────────────────────────────────────────┘
```

Attribution in the output matters. The user must always be able to see who
said what, not a blended voice.

## When codex-lead Is Appropriate

- **Code review on a self-contained diff** — Codex can read the diff and flag
  bugs without needing deep repo context.
- **Style / idiom review in a language where Codex is strong.**
- **When Claude notices itself anchoring** — e.g., Claude already proposed the
  change being reviewed, so its own review is biased.

## When codex-lead Is NOT Appropriate

- **Planning that depends on repo history, team conventions, or prior
  decisions** — Claude has that context (via working-memory hook, registry,
  CLAUDE.md); Codex doesn't. Default /c-codex is better there.
- **Reviews where diffs reference symbols defined far from the changed lines**
  — Codex is more likely to hallucinate; verification burden goes up.
- **Anything touching production infra or irreversible state.** Lead mode
  doesn't change the rule: destructive actions still require explicit user
  approval.

If the user requests codex-lead in an inappropriate context, surface the
concern once and let them decide. Don't silently override.

## Guardrails

- **Verification is not optional.** Every Codex file:line claim is checked
  against the actual file. Unverifiable claims go in the "could not verify"
  section, not the "verified" section.
- **Attribution is not optional.** The output must separate Codex's findings
  from Claude's additions. No blended voice.
- **One exchange only.** The flag does not persist across `/clear`, across the
  session, or across multiple `/c-codex` calls. Re-arm each time.
- **Claude still owns the guardrails.** Codex leads the *substance*; Claude
  still owns the safety layer (no destructive writes without approval, no
  secrets leaked to Codex, no silent rewrites of code or plans).

## Related

- `/c-codex` — the host skill. `/codex-lead` is meaningless without it.
- `code-reviewer` agent — Claude's own review. Pair with `/c-codex --lead`
  for the highest-coverage, divergent-first review.
- `think-deeply` — useful complement when Claude notices itself anchoring.
