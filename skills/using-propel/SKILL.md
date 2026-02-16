---
name: using-propel
description: >
  Meta-skill that activates before any action to check for applicable Propel skills.
  This is the entry point for the Propel research workflow. It ensures the correct skill
  is activated for every user request — investigation before implementation, gates before
  phase transitions, auditors after code changes. Always check this skill first.
---

# Using Propel — Research Workflow Controller

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

### 4. Debugging Skills
| Trigger | Skill |
|---------|-------|
| Training issue (NaN, plateau, collapse) | **systematic-debugging** |
| Stuck on a failure mode | **failure-mode-researcher** (via subagent) |

### 5. Infrastructure Skills
| Trigger | Skill |
|---------|-------|
| "new session", "archive this session" | Session management (/propel:new-session) |
| "create a worktree", "experiment branch" | **using-git-worktrees** |

## Auditor Auto-Dispatch

After implementing or modifying code, these auditors run automatically:

| What Changed | Auditors to Run |
|-------------|----------------|
| Paper-derived component | paper-alignment-auditor |
| JAX code (scan, vmap, pmap, jit) | jax-logic-auditor |
| Model/loss/data code | silent-bug-detector |
| Any code change | regression-guard |
| Deep trace needed (explicit only) | data-flow-tracer |

## Key Principles

1. **Investigate before you build.** No implementation without a documented investigation in scratch/.
2. **Verify against the paper, not just tests.** Every paper-derived component gets audited against source equations.
3. **Catch silent bugs systematically.** Active detection of 11 silent failure categories after every code change.
4. **Record what failed.** The failed attempts table is more valuable than the working solution.
5. **Manage context aggressively.** /clear regularly. Living READMEs preserve knowledge across sessions.
6. **Don't agree — evaluate.** When the user makes assumptions, steel-man the opposite before responding.
