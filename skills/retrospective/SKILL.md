---
name: retrospective
description: >
  [Propel] Captures experiment learnings into a reusable skill registry after a session.
  Use when the user says "retrospective", "capture what we learned", "save this for next time",
  "what did we learn", "log this experiment", or at the end of a training/debugging session.
  Extracts what worked, what failed, hyperparameters, and creates a registry entry.
  NOT for mid-session notes — use investigation scratch/ for that.
  AUTO-SUGGESTS when a session runs longer than ~20 messages without a retrospective.
---

# Experiment Retrospective

## Auto-Suggestion Trigger

If the conversation has run for approximately 20 substantive turns without a retrospective being captured, proactively suggest:

> "We've been working for a while without capturing learnings. Consider running a retrospective before /clear — the failed attempts table is the most valuable artifact, and it won't survive a context reset."

This is a suggestion, not a gate — the user can decline. But always offer.

## Instructions

1. Read the full conversation history and any scratch/ artifacts from this session.
2. Create a registry entry in `scratch/registry/{YYYY-MM-DD}-{experiment-short-name}/SKILL.md`.
3. The registry entry must follow the format below exactly.
4. Registry entries are **searchable by the investigation skill** — when a new investigation starts, matching entries are auto-surfaced. Write descriptions and tags accordingly.
5. Apply the **`concise`** skill to the entry.
6. Consult Codex before the entry is final — see below.

## Codex Consult on the Conclusions (automatic)

After the entry is written and `concise` is applied, dispatch **`codex-bridge`**
(per the `codex-consult` skill) with the entry's conclusions inlined (or
summarized) and these two questions — one call, which also counts as the
writeup review:

> "Which of these conclusions does the evidence not actually support?"
>
> "Compare the draft and the rewrite at <the draft path the `concise` skill gives
> (under `.propel/concise/`)> and `scratch/registry/<entry>/SKILL.md`: is any claim, caveat or evidence item lost
> or changed, and, within a section, where does a reader meet evidence before the
> claim it supports? The section order is fixed by the registry format; do not
> flag it. Name passages by heading, or say 'no additional findings'."

Only the second question gets paths instead of inlined content; ask Codex to
answer it under the heading `Writeup review:`. If the entry or draft holds
secrets, credentials or unpublished data, drop the second question and say so.
Omit `CLAUDE'S POSITION` from the brief — Claude wrote the entry — and present
the result in `codex-consult`'s card format. Announce it first:

```
◆ Consulting Codex — Retrospective: "Which of these conclusions does the evidence not actually support? + writeup review"
```

A retrospective is written by the model that ran the session, so it inherits that
session's reading of the evidence — the conclusions most likely to be wrong are
the ones it never thought to doubt. Registry entries are surfaced automatically
by later investigations, so what goes into one is the human's decision:

1. Present the Codex card first, verified and `[codex · unverified]` items alike.
2. Ask one disjunctive question naming which verified findings to fold in, e.g.
   "Fold all 3 verified findings, fold only the one naming the warmup schedule,
   or fold none and keep the entry as drafted?", with what each choice changes in
   the entry.
3. Write only the findings the human picks, each with `[codex]` attribution.
   Never write a `[codex · unverified]` item into the entry; it stays in the card.
4. Re-run the `concise` check (`claim-check.sh` on the draft vs the final entry)
   so the fold-in did not drop evidence, then delete the draft (`concise` step 8:
   the answer to this question is the acceptance).

When no fold-in question is asked (Codex disabled or unavailable, or nothing
verified), present the entry; the human's next reply about it is the acceptance,
and the draft is deleted then. Never ask a fold-in question with nothing to fold.

If `.propel/codex.json` has `"enabled": false`, skip it (one `◇ Codex disabled`
line at the session's first gate); if the CLI is missing, say so once and proceed
single-model.

## Registry Entry Format

```markdown
---
name: {experiment-short-name}
description: >
  {One-line description of what was tried and the outcome.
  Include specific trigger conditions: model type, dataset, framework, technique.
  Be hyper-specific — not "pruning experiments" but "pruning errors on ModelX with ZeRO2".}
---

# {Experiment Name}

## Setup
- **Model**: [architecture, size, variant]
- **Dataset**: [name, size, preprocessing]
- **Framework**: [JAX/PyTorch/etc, key libraries and versions]
- **Hardware**: [GPUs, memory, distributed setup]
- **Config**: [path to config file or inline key parameters]

## What Worked
- [Specific thing that worked with exact hyperparameters]
- [Copy-paste ready commands or config values]

## Failed Attempts

| Attempt | What We Tried | What Happened | Why It Failed |
|---------|--------------|---------------|---------------|
| 1 | [specific change] | [specific result] | [root cause] |
| 2 | ... | ... | ... |

**This table is the most valuable part of the entry.** Be specific about exact values, not vague descriptions.

## Key Hyperparameters
[Copy-paste ready — exact values, not "use a small learning rate"]

| Parameter | Value | Notes |
|-----------|-------|-------|
| learning_rate | 3e-4 | [why this value] |
| ... | ... | ... |

## Findings
- [Key insight 1]
- [Key insight 2]

## Next Steps
- [What to try next based on these results]
```

## Important

- **Failed attempts are more valuable than successes** — they prevent repeating mistakes across `/clear` boundaries and across team members.
- **Hyperparameters must be exact** — "3e-4" not "small learning rate". "batch_size=256" not "large batch".
- **Trigger conditions must be specific** — the description field determines when this skill gets surfaced. Make it match the exact scenario where this knowledge is relevant.
- The registry lives in scratch/ (gitignored). When patterns are mature enough, distill them into the main codebase or docs/.
- Before starting a new experiment, check `scratch/registry/` for past entries with similar setups.
