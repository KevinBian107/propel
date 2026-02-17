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
