# Full Workflow Guide

This guide walks through the complete Propel research workflow with all five gates.

## Overview

```
User idea → Gate 0 → Questioner Q0 → Investigation → Gate 1 → Questioner Q1 → Design → Gate 2 → Implementation → Gate 3 (loop) → Debug → Gate 4 → Training → Retrospective
```

## Modes and Phase Filtering

Not every session uses the full pipeline. Propel's three modes filter which phases and gates are active:

```
                    Researcher          Engineer            Trainer
                    ──────────          ────────            ───────
Gate 0  Intake      ██████████          ██████████
                        │                   │
  Q0    Questioner      ◆◆◆◆◆◆◆◆◆◆          ◆◆◆◆◆◆◆◆◆◆
        (grounding)     │                   │
        Investigation   ██████████          ██████████
                        │                   │
Gate 1  Post-Invest.    ██████████          ██████████
                        │                   │
  Q1    Questioner      ◆◆◆◆◆◆◆◆◆◆          ◆◆◆◆◆◆◆◆◆◆
        (details)                           │
        Design                              ██████████
                                            │
Gate 2  Post-Design                         ██████████
                                            │
        Implementation                      ██████████
                                            │
Gate 3  Mid-Impl.                           ██████████
                                            │
        Validation                          ██████████
                                                            ┌──────────┐
        Training                            ██████████      │ scan,    │
                                            │               │ launch,  │
        Debugging                           ██████████      │ monitor  │
                                            │               └────┬─────┘
Gate 4  Post-Debug                          ██████████           │
                                            │               ██████████
        Retrospective   ██████████          ██████████      (runtime only)
                                                            ██████████
```

- **Researcher**: Stays in the understanding phase. Literature, investigation, and retrospective. Gates 0 and 1 only.
- **Engineer**: Full pipeline. All phases and gates. This is the default and matches the workflow described below.
- **Trainer**: Skips to training execution. Scans for training commands, launches in screen sessions, fixes runtime bugs (CUDA, OOM, paths, imports). Gate 4 for runtime bugs only — logic changes redirect to Engineer Mode.

Choose a mode at session start (via `/intro`) or switch anytime with `/switch researcher`, `/switch engineer`, or `/switch trainer`. Mode persists in `.propel/mode.json` and survives `/clear`.

The rest of this guide describes the full **Engineer Mode** workflow. Researcher Mode uses Phases 1-4 only. Trainer Mode uses its own dedicated skill.

---

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
  6. Current mode + mode_selection_needed (.propel/mode.json)
  7. Empty repo flag (whether to use progressive CLAUDE.md building)
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
| **Mode state** | `.propel/mode.json` injected by hook — controls which skills and gates are active | SessionStart hook reads it |
| **Empty repo flag** | `empty_repo` boolean — triggers progressive CLAUDE.md building instead of scan-and-draft | SessionStart hook checks for source files |

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

## Phase 2.5: Questioner Q0 — Grounding Before Investigation

> **Why this exists**: Claude is great at looking at one thing and morphing it into something you want, but bad at creating something new from scratch when the problem is unconstrained. Vague requests like "build a can transport task with robosuite" lead to plausible-looking but wrong implementations — Claude fills gaps with training-data averages instead of asking. The Questioner forces the user to provide concrete reference points before Claude investigates.

After Gate 0 confirms scope but **before investigation begins**, Claude asks structured questions to ground the work in concrete examples. These are NOT the same as Gate 0 questions (which scope the *what*) — Q0 questions ground the *how* by identifying existing reference points.

### Q0 Questions (asked one at a time)

1. **Reference implementation**: "Is there an existing codebase or repo I should use as a starting point? If so, which files or modules are most relevant?"
2. **Architecture template**: "Is there a known architecture or design pattern you want to follow? (e.g., a specific paper's approach, an existing task implementation in the codebase, a framework's canonical example)"
3. **Example to copy from**: "Is there a similar task/feature already implemented in this project or another project that I should study and adapt from?"
4. **Benchmark / ground truth**: "What benchmark, test case, or expected behavior should I use to verify correctness? Is there a known-good output I can compare against?"
5. **Framework constraints**: "Are there specific APIs, libraries, or framework conventions I must use? (e.g., 'use robosuite's SingleArmEnv base class', 'follow the MuJoCo MJX wrapper pattern')"

### What happens

- Claude asks these **one at a time**, skipping any already answered during Gate 0
- If the user provides a reference codebase, Claude records it in the investigation README under "Reference Sources"
- If the user says "no reference, build from scratch" — Claude flags this as **high-risk unconstrained implementation** and notes it in the README. Investigation will be more thorough to compensate
- The answers directly shape what gets investigated in Phase 3

### Example

```
User: I want to build a can transport task with robosuite.
[Gate 0 confirms scope: single-arm can transport, dense reward, sim only]

Claude (Q0-1): Is there an existing task in robosuite I should use as a
               starting point? For example, PickPlace or Lift?
User: Yeah, look at PickPlace in robosuite/environments/manipulation/

Claude (Q0-2): Got it. Is there a specific architecture pattern — should this
               follow the same reward structure as PickPlace, or do you have
               a different reward design in mind?
User: Same structure, but add a transport phase between pick and place.

Claude (Q0-3): For verification — is there a known trajectory or benchmark
               I should test against, or should I use the PickPlace test suite
               as a baseline?
User: Use PickPlace tests as baseline, plus a manual trajectory I'll provide.

[Claude records all three reference points in scratch/README.md and proceeds to investigation]
```

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

## Phase 4.5: Questioner Q1 — Nailing Down Implementation Details

> **Why this exists**: After investigation, Claude has findings and the user has made high-level design decisions. But there's a dangerous gap: Claude may still fill in critical implementation details with plausible defaults instead of asking. Q1 catches these before design begins.

After Gate 1 confirms investigation findings but **before design begins**, Claude asks implementation-detail questions. While Q0 grounded the *what to look at*, Q1 grounds the *how to build it* — specific details that determine whether the implementation is correct or subtly wrong.

### Q1 Questions (asked one at a time)

1. **Interface contracts**: "Based on the investigation, here are the key interfaces I found: [list]. Should the new code match these exactly, or are we changing the API?"
2. **Data format specifics**: "The reference uses [format/shape/convention]. Should we follow the same convention, or does your use case need something different?"
3. **Configuration approach**: "Should this be configurable via [config file / constructor args / env vars]? What should the defaults be?"
4. **Edge cases and failure modes**: "During investigation I found these edge cases: [list]. How should each be handled — error, fallback, or ignore?"
5. **Integration points**: "This will need to connect to [existing modules]. Should I modify those modules or create adapters?"
6. **Scope confirmation**: "Based on what I found, the minimal implementation needs [X, Y, Z]. Should I also include [A, B] which I noticed in the reference, or keep it minimal?"

### What happens

- Claude asks only the questions relevant to what was discovered during investigation
- Answers are recorded in the investigation README under "Implementation Decisions (Human-Approved)"
- These answers become **binding constraints** for the design phase — Claude must not deviate without asking
- If the user is unsure about a detail, Claude flags it as an **open question** to revisit during implementation (Gate 3)

### Example

```
User: [After Gate 1, approved investigation findings for can transport task]

Claude (Q1-1): PickPlace uses a 4-phase reward: reach → grasp → lift → place.
               For can transport, I'd add a "transport" phase between lift and
               place. Should I keep the same reward scale (0-1 per phase) or
               re-weight for 5 phases?
User: Keep 0-1 per phase, so total reward range becomes 0-5 instead of 0-4.

Claude (Q1-2): PickPlace accepts a single placement target. Transport implies
               a waypoint. Should the waypoint be a constructor parameter, or
               computed from start/end positions?
User: Constructor parameter. I want to be able to set it per episode.

Claude (Q1-3): The PickPlace test suite checks gripper-to-object distance.
               For transport, should I also check object-to-waypoint distance
               during the transport phase?
User: Yes, that's the key metric for the new phase.

[Claude records all decisions and proceeds to design with concrete constraints]
```

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
