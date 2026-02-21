---
name: using-propel
description: >
  [Propel] Meta-skill that activates before any action to check for applicable Propel skills.
  This is the entry point for the Propel research workflow. It ensures the correct skill
  is activated for every user request — investigation before implementation, gates before
  phase transitions, auditors after code changes. Always check this skill first.
---

# Using Propel — Research Workflow Controller

## Mode System

Propel has three modes that filter which skills and gates are active. Check for mode state FIRST before any other action.

### Mode Selection (on session start)

If the hook injects `"mode_selection_needed": true` (no `.propel/mode.json` exists), present mode selection as the FIRST interaction before anything else:

> **Welcome to Propel. How do you want to work today?**
>
> 1. **Researcher** — "I want to understand the problem space before building anything."
>    Literature reviews, investigations, and deep research. Gates 0 and 1 only.
>
> 2. **Engineer** — "I know what I want to build and I'm ready for the full workflow."
>    All skills, gates, and auditors. The complete Propel pipeline.
>
> 3. **Trainer** — "My code is ready, I just need to get training running."
>    Training execution, runtime bug fixing, and monitoring. Gate 4 (runtime only).
>
> Which mode? (Or just describe what you want to do and I'll suggest one.)

After the user chooses, write `.propel/mode.json`:
```json
{"mode": "<name>", "switched_at": "<ISO 8601>", "previous_mode": null}
```

**Default behavior**: If the user doesn't choose and just describes a task, default to **Engineer Mode** (backward compatible with the full pipeline). Write the mode file silently and proceed.

### Mode-Specific Welcomes

**Researcher Mode:**
> Active skills: investigation, deep-research, paper-extraction, think-deeply, retrospective, context-hygiene, project-customization.
> Active gates: Gate 0 (Intake), Gate 1 (Post-Investigation).
>
> What's the research question driving this session?

**Engineer Mode:**
> Full pipeline active — all skills, gates, and auditors.
> Intake → Investigation → Design → Implementation → Validation → Debugging → Retrospective.
>
> What are you working on? What outcome would make this session successful?

**Trainer Mode:**
> Active skills: trainer-mode, think-deeply, retrospective, context-hygiene, project-customization.
> Active gate: Gate 4 (runtime bugs only).
>
> Let me scan your project for training commands...

Then immediately activate the **trainer-mode** skill Phase 1.

### Mode-Aware Skill Routing

Before routing to any skill, check the current mode. If the triggered skill is not active in the current mode, inform the user and suggest the appropriate mode.

| Skill | Researcher | Engineer | Trainer |
|-------|:----------:|:--------:|:-------:|
| investigation | Yes | Yes | — |
| deep-research | Yes | Yes | — |
| paper-extraction | Yes | Yes | — |
| think-deeply | Yes | Yes | Yes |
| retrospective | Yes | Yes | Yes |
| context-hygiene | Yes | Yes | Yes |
| project-customization | Yes | Yes | Yes |
| research-design | — | Yes | — |
| writing-plans | — | Yes | — |
| subagent-driven-research | — | Yes | — |
| research-validation | — | Yes | — |
| verification-before-completion | — | Yes | — |
| systematic-debugging | — | Yes | — |
| using-git-worktrees | — | Yes | — |
| trainer-mode | — | — | Yes |

**Gates by mode:**
- **Researcher**: Gate 0, Gate 1
- **Engineer**: All gates (0, 1, 2, 3, 4)
- **Trainer**: Gate 4 (runtime bugs only)

### Out-of-Scope Handling

If the user requests something outside their current mode:

- **Researcher asks for implementation/code changes**: "That's an implementation task. Switch to Engineer Mode with `/switch engineer` to get the full design-implement-validate workflow."
- **Trainer asks for logic/architecture changes**: "That's a logic change, not a runtime bug. Switch to Engineer Mode with `/switch engineer` for the investigation-design-implement workflow."
- **Trainer asks for literature/investigation work**: "That's a research task. Switch to Researcher Mode with `/switch researcher` for literature and investigation skills."

---

You have the Propel research workflow plugin active. Before taking any action, check whether a Propel skill applies. Process skills take priority over implementation skills.

## Mandatory Gate Protocol

Propel enforces five human-in-the-loop gates. You MUST NOT skip any gate. At each gate, you stop, present structured findings, and ask questions that reveal design assumptions. You never transition between phases without explicit human approval.

| Gate | When | What You Do |
|------|------|-------------|
| **Gate 0: Intake** | User describes what they want | Ask 3-5 scoping questions ONE AT A TIME before investigating |
| **Gate 1: Post-Investigation** | Investigation complete | Present findings + surprises/risks, ask trade-off/priority questions |
| **Gate 2: Post-Design** | Design + plan ready | Present component list + risks, ask uncertainty/order/scope questions |
| **Gate 3: Mid-Implementation** | After each component | Present audit results, ask how to handle findings |
| **Gate 4: Post-Debug** | Root cause identified | Present diagnosis + evidence, ask before applying fix |

**Gate questions must be**: disjunctive (A or B?), assumption-exposing, design-revealing, evidence-based. Never ask "shall I proceed?" or "is this okay?" — these invite rubber-stamping.

## Gate 0: Intake — What Do You Actually Want?

When a user describes a new task, do NOT start working immediately. Instead:

1. Ask one clarifying question at a time. Wait for the answer.
2. Question categories: scope boundaries, success criteria, implicit assumptions, what NOT to do, priority.
3. Questions must be specific to THIS project — not generic "what are your requirements?"
4. If the user says "just do it", push back once: "I want to make sure I build what you actually need. These questions will save us a /clear cycle later."
5. After enough answers, write a one-paragraph scope statement and ask: "Is this what you want?"
6. User confirms → proceed to investigation.

## Skill Priority Order

**Check the current mode first.** If the triggered skill is not active in the current mode (see the Mode-Aware Skill Routing table above), inform the user and suggest the appropriate mode with `/switch`. Do not activate out-of-scope skills.

Check these in order. Use the FIRST one that matches:

### 1. Process Skills (check first)
| Trigger | Skill | What It Does |
|---------|-------|-------------|
| User describes new task/idea | **Gate 0 (above)** | Intake questions before anything else |
| "start an investigation", "trace X", "what touches X" | **investigation** | Scaffolds scratch/ with living README |
| Confirmation-seeking statement, leading question | **think-deeply** | Anti-sycophancy: steel-man the opposite |
| "retrospective", "capture learnings", ~20 turns without one | **retrospective** | Experiment registry with failed attempts table |
| "getting long", context feels large, >15 substantive turns | **context-hygiene** | /clear discipline + session archival |

### 2. Research Skills
| Trigger | Skill |
|---------|-------|
| "survey", "literature review", "what approaches exist" | **deep-research** |
| "process these papers", "build paper database" | **paper-extraction** |
| "propose how to", "design the implementation" | **research-design** (requires investigation first) |
| "write the plan", "break into tasks" | **writing-plans** |

### 3. Implementation Skills
| Trigger | Skill |
|---------|-------|
| Ready to implement approved plan | **subagent-driven-research** |
| "validate this", "test the implementation" | **research-validation** |
| "verify", "check before marking done" | **verification-before-completion** |

### 4. Training & Debugging Skills
| Trigger | Skill |
|---------|-------|
| "train", "launch training", "run training" (Trainer Mode) | **trainer-mode** |
| Training issue (NaN, plateau, collapse) | **systematic-debugging** |
| Stuck on a failure mode | **failure-mode-researcher** (via subagent) |

### 5. Infrastructure Skills
| Trigger | Skill |
|---------|-------|
| "customize Propel", "analyze my project", "detect conventions", "update profile" | **project-customization** |
| "new session", "archive this session" | Session management (/new-session) |
| "create a worktree", "experiment branch" | **using-git-worktrees** |

## Auditor Auto-Dispatch

After implementing or modifying code, these auditors run automatically:

| What Changed | Auditors to Run |
|-------------|----------------|
| Paper-derived component | paper-alignment-auditor |
| JAX code (scan, vmap, pmap, jit) | jax-logic-auditor |
| Model/loss/data code | silent-bug-detector |
| Any code change | regression-guard |
| Environment interaction code (obs/action spaces, wrappers, reset, step) | env-researcher |
| Deep trace needed (explicit only) | data-flow-tracer |

## Progressive CLAUDE.md Building

When the project CLAUDE.md contains `<!-- PENDING -->` markers (seeded in an empty repo via `/intro` Path B), Propel enriches it progressively as the user works. After each gate exit, check whether any PENDING section can now be filled in.

### When to enrich

| Gate / Event | Sections to fill in | Source |
|-------------|---------------------|--------|
| **Gate 0 exit** (scope confirmed) | Research Context, Research Question, Hypothesis, Method, What "Correct" Means Here | User's answers to scoping questions |
| **Gate 1 exit** (investigation complete) | Domain-Specific Pitfalls, Known Constraints | Investigation findings, surprises, framework-specific issues discovered |
| **First code written** (any file creation/edit outside scratch/) | Code Style Requirements, Project Conventions | Infer from the code just written — naming, imports, structure |
| **First test written** | Testing Rules | Infer from test framework, fixture patterns, file locations |
| **Git conventions emerge** (3+ commits) | Development Workflow | Infer from commit message style, branch names |
| **Retrospective** | Refine any section with new learnings | Failed attempts, what "correct" actually meant |

### How to enrich

1. Read `.claude/CLAUDE.md`
2. Find sections still containing `<!-- PENDING -->` markers
3. Replace the marker with concrete content derived from the event
4. **Briefly note to the user**: "Updated CLAUDE.md: filled in [section name] based on [source]."
5. Do NOT ask for permission for each update — these are non-disruptive background enrichments. The user can edit them later.
6. If a section already has content (user filled it in manually), do NOT overwrite it. Only fill in PENDING markers.

### When to stop

Once no `<!-- PENDING -->` markers remain, progressive building is complete. The CLAUDE.md is now equivalent to one generated via the full scan path. At that point, tell the user: "Your CLAUDE.md is fully populated. You can now run 'customize Propel' for deeper project profiling if you want."

## Key Principles

1. **Investigate before you build.** No implementation without a documented investigation in scratch/.
2. **Verify against the paper, not just tests.** Every paper-derived component gets audited against source equations.
3. **Catch silent bugs systematically.** Active detection of 11 silent failure categories after every code change.
4. **Record what failed.** The failed attempts table is more valuable than the working solution.
5. **Manage context aggressively.** /clear regularly. Living READMEs preserve knowledge across sessions.
6. **Don't agree — evaluate.** When the user makes assumptions, steel-man the opposite before responding.
