---
name: c-codex
description: >
  [Propel] Connect-to-Codex — brings OpenAI Codex into the loop as a second-opinion
  peer reviewer during planning or code review. Use when the user says "/c-codex",
  "get codex's take", "ask codex", "second opinion from codex", "cross-check with codex",
  or when starting a plan / code review where divergent-model critique reduces
  confirmation bias. Uses https://github.com/openai/codex-plugin-cc. Codex NEVER
  works alone — Claude always summarizes first, sends a specific question, and
  synthesizes Codex's reply back for the user.
---

# C-Codex — Connect to Codex as a Peer Reviewer

Codex is a second model with different training biases than Claude. Using it as
a peer reviewer during the two highest-leverage moments — **planning** and
**code review** — catches blind spots that a single model would miss.

This skill enforces a specific interaction contract. Codex is not an autonomous
worker here; it is a critic invited into a conversation Claude is leading.

## Scope: Where This Skill Applies

Activate `/c-codex` in exactly two contexts. Detect which one from the
conversation before dispatching.

### Planning context
Signals:
- EnterPlanMode was used, or the `writing-plans` skill is active
- User is designing an approach before writing code ("how should we…",
  "what's the plan for…", a plan document is being drafted)
- No diff or staged changes are being discussed

### Code review context
Signals:
- A PR, diff, commit range, or specific changed files are in focus
- User says "review", "audit", "check this", or is running `code-reviewer`
- `git diff` / `gh pr` output is in recent context

If neither applies, ask the user which context they mean. Do not default silently.

## First-Run Setup

If this is the first time the user invokes `/c-codex` in this repo:

1. Check whether `codex-plugin-cc` is installed (look for its CLI or MCP server
   registration in `.claude/` or the user's claude settings).
2. If not installed, point the user to
   `https://github.com/openai/codex-plugin-cc` with a short install + login
   instruction, and pause. Do not proceed until setup is confirmed.
3. If auth is expired, surface the re-auth command from the plugin's README and
   pause.

Never fabricate Codex command syntax. If the plugin's exact invocation is
unclear, ask the user to confirm how their installation is wired up.

## The Interaction Contract (non-negotiable)

Codex never works alone. Every `/c-codex` exchange follows this shape:

1. **Claude frames the question.** Summarize the current state in 5–12 lines:
   what's being planned or reviewed, what Claude's current position is, what
   the specific decision / concern is. No rambling context dumps — Codex should
   be able to respond usefully from the summary alone.
2. **Claude sends a sharp question to Codex.** Not "what do you think", but:
   - Planning: "Does this plan have a gap? Propose the single strongest
     counter-approach and one failure mode I haven't listed."
   - Review: "Here are the lines I flagged. What did I miss? Name bugs by
     file:line or say 'no additional findings'."
3. **Codex replies.** Do not auto-accept. Treat Codex's output as one input.
4. **Claude synthesizes.** Produce a structured comparison:
   - Points Claude and Codex agree on
   - Points they disagree on (and Claude's current read on who is right)
   - New points Codex raised that Claude hadn't considered
5. **Claude presents to the user.** User decides what to act on.

Under no circumstance should Codex's output be passed through to the user
unfiltered or used to silently rewrite the plan / diff. Claude owns the
synthesis step.

## Output Format

Return a structured card like:

```
┌─ /c-codex — <planning | code-review> ─────────────────────┐
│ Question sent to Codex:                                   │
│   <one line>                                              │
│                                                           │
│ Agreement:                                                │
│   • <point>                                               │
│                                                           │
│ Disagreement (Claude's read):                             │
│   • <point> — Claude: <position>. Codex: <position>.      │
│                                                           │
│ New from Codex:                                           │
│   • <point> (severity: high/med/low)                      │
│                                                           │
│ Recommended action:                                       │
│   <1–2 lines>                                             │
└───────────────────────────────────────────────────────────┘
```

## Guardrails

- **Do not invoke `/c-codex` for trivial questions.** It costs tokens and a
  round-trip. Reserve for real decisions.
- **Do not let Codex write code directly into the repo.** Codex proposes;
  Claude (under user approval) implements.
- **Do not bias the question.** Ask Codex to find problems — don't ask it to
  confirm Claude's position. That defeats the point.
- **If Codex and Claude fully agree, say so plainly** and note that agreement
  across models is weaker evidence than divergence investigated.
- **Privacy:** anything sent to Codex leaves the local context. If the
  conversation contains secrets, redact before sending.

## Optional Flag: codex-lead

By default Claude synthesizes. If the user arms `/codex-lead` for this
exchange, the contract flips: Codex produces the primary output and Claude
becomes the adversarial checker (verifying every file:line claim against the
actual repo, flagging false positives, adding missed findings). The flag is
ephemeral — single-use per invocation — and must be re-armed each time. See
the `codex-lead` skill for the full flipped contract.

## Related

- `codex-lead` — complementary flag that switches this exchange to Codex-primary
  mode. Only meaningful alongside `/c-codex`.
- `think-deeply` — internal anti-sycophancy. `/c-codex` is the external
  equivalent: a second model instead of a second pass.
- `code-reviewer` agent — Claude's own review. Pair with `/c-codex` for the
  highest-coverage review.
- `writing-plans` — the natural host for `/c-codex` during planning.
