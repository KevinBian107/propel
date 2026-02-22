# Propel Documentation

## Guides

| Guide | Description |
|-------|-------------|
| [Quick Start](quickstart.md) | 5-minute setup — install, configure, first workflow |
| [Full Workflow](workflow.md) | Complete walkthrough with all 5 gates, 2 questioners, and examples |
| [Customization](customization.md) | Adding project-specific agents, skills, and commands |
| [Pitfalls](pitfall.md) | Known failure modes when working with Claude — living document |

## Skills Reference

### Meta
| Skill | Trigger | Description |
|-------|---------|-------------|
| [using-propel](../skills/using-propel/SKILL.md) | Always active | Routes to correct skill, enforces gate protocol |

### Literature Phase
| Skill | Trigger | Description |
|-------|---------|-------------|
| [deep-research](../skills/deep-research/SKILL.md) | "survey", "literature review" | Structured literature survey with checkpoints |
| [paper-extraction](../skills/paper-extraction/SKILL.md) | "process these papers" | Batch paper processing into database |

### Investigation Phase
| Skill | Trigger | Description |
|-------|---------|-------------|
| [investigation](../skills/investigation/SKILL.md) | "start investigation", "trace X" | Scaffolds scratch/ with living README |

### Design Phase
| Skill | Trigger | Description |
|-------|---------|-------------|
| [research-design](../skills/research-design/SKILL.md) | "propose how to implement" | Paper-to-code mapping, Gate 2 |
| [writing-plans](../skills/writing-plans/SKILL.md) | "write the plan" | Micro-task breakdown with auditor assignments |

### Implementation Phase
| Skill | Trigger | Description |
|-------|---------|-------------|
| [subagent-driven-research](../skills/subagent-driven-research/SKILL.md) | "go" (after plan approval) | Three-stage review per component |

### Validation Phase
| Skill | Trigger | Description |
|-------|---------|-------------|
| [research-validation](../skills/research-validation/SKILL.md) | "validate", "test this" | Shape/gradient/overfit/regression gates |
| [verification-before-completion](../skills/verification-before-completion/SKILL.md) | Before claiming "done" | No claims without evidence |

### Debugging Phase
| Skill | Trigger | Description |
|-------|---------|-------------|
| [systematic-debugging](../skills/systematic-debugging/SKILL.md) | Bug reports, failures | Root cause first, 3-strike limit, Gate 4 |

### Learning Phase
| Skill | Trigger | Description |
|-------|---------|-------------|
| [retrospective](../skills/retrospective/SKILL.md) | "retrospective", auto at ~20 turns | Experiment registry with failed attempts |

### Cross-cutting
| Skill | Trigger | Description |
|-------|---------|-------------|
| [think-deeply](../skills/think-deeply/SKILL.md) | Confirmation-seeking | Anti-sycophancy guard |
| [context-hygiene](../skills/context-hygiene/SKILL.md) | >15 turns, "getting long" | /clear discipline |
| [using-git-worktrees](../skills/using-git-worktrees/SKILL.md) | "create worktree" | Experiment branch isolation |

## Agents Reference

| Agent | Purpose | Auto? | Tools |
|-------|---------|-------|-------|
| [paper-alignment-auditor](../agents/paper-alignment-auditor.md) | Paper equation verification | Yes | Read, Grep, Glob |
| [jax-logic-auditor](../agents/jax-logic-auditor.md) | JAX transform correctness | Yes | Read, Grep, Glob |
| [silent-bug-detector](../agents/silent-bug-detector.md) | 11 silent failure categories | Yes | Read, Grep, Glob |
| [data-flow-tracer](../agents/data-flow-tracer.md) | End-to-end tensor tracing | No | Read, Grep, Glob |
| [regression-guard](../agents/regression-guard.md) | Backward compatibility | Yes | Read, Grep, Glob, Bash |
| [failure-mode-researcher](../agents/failure-mode-researcher.md) | Cross-domain failure search | No | Read, Grep, Glob, WebSearch, WebFetch, Task |
| [code-reviewer](../agents/code-reviewer.md) | General + research quality | No | Read, Grep, Glob |

## Commands Reference

| Command | Purpose |
|---------|---------|
| [/read-paper](../commands/read-paper.md) | Extract implementation reference from a paper |
| [/debug-training](../commands/debug-training.md) | Diagnose training issues (NaN, plateau, collapse) |
| [/trace-shapes](../commands/trace-shapes.md) | Quick shape annotation through code path |
| [/primer](../commands/primer.md) | Load project context |
| [/new-session](../commands/new-session.md) | Create and track a session |
