# Full Workflow Guide

This guide walks through the complete Propel research workflow with all five gates.

## Overview

```
User idea → Gate 0 → Investigation → Gate 1 → Design → Gate 2 → Implementation → Gate 3 (loop) → Debug → Gate 4 → Retrospective
```

## How Propel Ensures Claude Follows the Workflow

An unconstrained Claude will skip straight to implementation when you say "implement X." Propel prevents this through a layered injection system — here's exactly how it works.

### The mechanism

```
propel init
  ↓
Copies skills/, agents/, commands/, hooks/ into .claude/
Merges hook config into .claude/settings.local.json
  ↓
User starts `claude`
  ↓
SessionStart hook fires → runs session-start.sh
  ↓
Injects full using-propel/SKILL.md content as JSON into Claude's context
(Also injects: active investigations, project profile, registry entries)
  ↓
Claude's context now contains:
  1. The gate protocol (5 mandatory gates)
  2. The skill routing table (which skill for which trigger)
  3. The auditor dispatch rules (which agent after which code change)
  4. Active investigation state (scratch/ READMEs)
  5. Project profile (.propel/profile.md, if it exists)
```

### What each layer does

| Layer | What it provides | How it gets into context |
|-------|-----------------|------------------------|
| **SessionStart hook** | Injects using-propel skill + investigation state on every session start, resume, and compaction | `.claude/settings.local.json` → hooks config |
| **PreCompact hook** | Re-injects context before Claude compresses old messages, so the instructions survive compaction | Same hook, different trigger |
| **Skill descriptions** | Claude Code loads all `.claude/skills/*/SKILL.md` descriptions into the system prompt — Claude matches triggers against what the user says | Built-in Claude Code feature |
| **Agent descriptions** | Claude Code loads all `.claude/agents/*.md` descriptions — Claude dispatches agents based on description match | Built-in Claude Code feature |
| **CLAUDE.md** | Project-level instructions read on every session | Built-in Claude Code feature |
| **Project profile** | `.propel/profile.md` injected by hook — conventions Claude should follow silently | SessionStart hook reads it |

### Why this works (and what it can't guarantee)

**This is prompt-based, not mechanically enforced.** There is no code-level gate that blocks Claude from skipping Gate 0. Claude follows the workflow because:

1. The hook injects the full routing table into context before Claude sees your first message
2. The using-propel skill description says "activates before any action" — Claude Code's skill matching prioritizes this
3. The instructions are specific and structured (routing tables, not vague guidelines)
4. The PreCompact hook re-injects on compaction, so instructions survive long sessions

**In practice, this is reliable.** Claude Code's skill system is designed for exactly this pattern — skills with trigger descriptions that Claude matches against user input. The hook injection adds a second layer of certainty by putting the full instructions directly in context.

**When it might slip:**
- Very long sessions where context is heavily compressed (the PreCompact hook mitigates this)
- If the user explicitly says "skip the gates, just do it" (Claude will usually comply)
- Ambiguous requests that don't clearly match any routing table trigger

**If Claude skips a gate**, you can say: "You skipped Gate 0 — go back and ask scoping questions." Claude will see the instructions in its context and correct. You can also run `/primer` to reload full project context.

### The reinforcement loop

The system is designed so that multiple independent signals all point Claude toward the same behavior:

```
Skill description match → "activates before any action"
Hook injection → full routing table in context
CLAUDE.md → "This project uses the Propel research workflow"
Auditor dispatch rules → agents auto-run after code changes
```

No single layer is critical. If one fails, the others still constrain Claude. This redundancy is intentional — it's the difference between "please follow this process" and having the process embedded in every layer of Claude's context.

---

## Phase 1: Literature (Optional Starting Point)

If you're implementing from a paper, start by extracting a reference:

```
/read-paper path/to/paper.pdf
```

This creates `scratch/paper-notes/{paper-name}.md` with equations, architecture, hyperparameters, and implementation notes. This document becomes the ground truth for the paper-alignment-auditor later.

For broader surveys:
```
You: What approaches exist for discrete representation learning in robotics?
Claude: [deep-research skill activates — structured literature survey]
```

## Phase 2: Gate 0 — Intake

When you describe what you want to build, Claude does NOT start working immediately. Instead:

1. Claude asks 3-5 scoping questions, **one at a time**
2. Questions are specific to your project: "Should the new quantizer support the existing stickiness bias, or is this a chance to remove it?"
3. After enough answers, Claude writes a scope statement
4. You confirm: "Yes, that's what I want"

**What makes a good Gate 0 question:**
- "You mentioned depth=2. Is that a hard design choice, or do you want arbitrary depth?" (assumption-exposing)
- "If we discover the paper's approach has a known failure mode for your use case, do you want alternatives or implement it anyway?" (priority-revealing)

## Phase 3: Investigation

Claude creates `scratch/{date}-{name}/README.md` and investigates:

- Traces code paths and data flow
- Documents architecture and dependencies
- Records findings as they emerge
- Auto-checks `scratch/registry/` for past experiment entries

The README is a **living document** — it gets updated throughout the session and survives `/clear` boundaries.

## Phase 4: Gate 1 — Post-Investigation

Claude presents:

```markdown
## Investigation Summary

### What I Found
- [3-5 bullet findings]

### Surprises / Risks
- [Unexpected complications]

### Open Questions — I Need Your Input
1. [Trade-off question]
2. [Architecture choice]
3. [Priority question]
```

You make design decisions. Claude records them in the README under "Design Decisions (Human-Approved)".

## Phase 5: Design

The research-design skill activates:

1. Reads investigation README + paper notes
2. Creates paper-equation-to-code mapping: which equation → which function → which file
3. Identifies regression risks
4. Proposes config flags (new features opt-in)

## Phase 6: Gate 2 — Post-Design

Claude presents:

```markdown
## Implementation Plan Summary

### Components (in order)
1. [Component] — maps to paper eq. [X] — touches files [Y, Z]

### Regression Risk Assessment
- [What could break and how we're protecting it]

### What I'm Uncertain About
1. [Uncertainty + two options + trade-offs]

### Estimated Scope
- [N components, M files modified, K new files]
```

You can approve, modify, or reject parts of the plan. When ready: "go".

## Phase 7: Implementation

For each component in the plan:

### Stage 1: Implement
Subagent implements the specific task from the plan.

### Stage 2: Review
- Spec compliance: does it match the plan?
- Paper alignment: does it match the source paper?

### Stage 3: Audit
Parallel auditors check for:
- Paper equation mismatches
- JAX transform bugs
- Silent failure patterns (11 categories)
- Regressions in existing behavior

### Gate 3: Present Results

**Clean pass:**
> "All auditors passed for component 3. Spec ✓, Paper ✓, JAX ✓, Silent bugs ✓, Regression ✓. Moving to component 4?"

**Issues found:**
```markdown
## Component 3 Audit Results

### Issues Found
- ✗ Silent Bug Detector: commitment loss applied to combined residual, not per-depth
  - Paper specifies per-depth (Section 3.2, Eq. 5)
  - Severity: Critical

### Question
Should I fix this to match the paper (per-depth commitment), or was the combined approach an intentional simplification?
```

**Every 3 components:** Claude offers a pause point for `/clear`.

## Phase 8: Validation

After implementation, four validation gates:

1. **Shape gate**: Forward pass produces expected output shapes
2. **Gradient gate**: All trainable parameters receive non-zero gradients
3. **Overfit gate**: Model can memorize 5 samples in 100 steps
4. **Regression gate**: Existing configs produce identical results

If the overfit test fails, nothing else matters — there's a fundamental bug.

## Phase 9: Debugging (When Needed)

If training fails, the systematic-debugging skill activates:

1. Characterize the symptom precisely
2. Form ranked hypotheses
3. Gather evidence for each (write diagnostic scripts to `scratch/debug/`)
4. **Gate 4**: Present diagnosis + proposed fix before changing code

The 3-strike limit prevents loops: if the same approach fails 3 times, Claude stops and re-examines its assumptions.

## Phase 10: Retrospective

After a session, capture what was learned:

```
You: retrospective
Claude: [creates scratch/registry/{date}-{name}/SKILL.md]
```

The most valuable part: the **failed attempts table**. This prevents repeating mistakes after `/clear`, across sessions, and across team members.

Claude auto-suggests a retrospective after ~20 turns without one.

## Phase 11: Context Management

Claude proactively manages context:

- Suggests updating the README before `/clear`
- Offers retrospective capture
- Triggers session archival
- Adds "Next Steps" to the README for resumption

After `/clear`, the session-start hook re-injects Propel context and surfaces active investigations.

## Tips

- **Use `/read-paper` before investigating** — paper notes become the auditor's ground truth
- **Answer Gate 0 questions seriously** — 5 minutes here saves hours of wrong implementation
- **Don't skip Gate 3 for "trivial" changes** — most silent bugs come from changes that seemed trivial
- **Run retrospectives even for failed experiments** — especially for failed experiments
- **Clear context proactively** — Claude degrades before you notice
