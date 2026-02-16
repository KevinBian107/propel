# Propel

An agentic research skills framework for JAX/robotics/embodied AI development. Propel is a Claude Code plugin that enforces a structured research-to-implementation workflow for scientific computing.

## What Propel Does

Propel takes the insight that Claude needs **process discipline, not just prompts** and rebuilds it for research workflows where:

- **Understanding precedes design** — you read papers before you code
- **Verification is domain-specific** — "does this match equation 3?" matters more than "do the tests pass?"
- **Failure is silent** — the model trains, loss decreases, but the output is subtly wrong

The framework enforces five human-in-the-loop gates at every phase transition, dispatches specialized auditors after every code change, and maintains living documentation across `/clear` boundaries.

## The Five Gates

```
 GATE 0          GATE 1            GATE 2           GATE 3          GATE 4
 Intake     Post-Investigation   Post-Design    Mid-Implementation  Post-Debug
   │               │                 │                │                │
   ▼               ▼                 ▼                ▼                ▼
┌──────┐    ┌─────────────┐   ┌───────────┐   ┌─────────────┐  ┌──────────┐
│ User │    │Investigation│   │  Design   │   │ Implement   │  │  Debug   │
│ idea │───▶│  + Research │──▶│  + Plan   │──▶│  component  │──▶│ diagnose │
└──────┘    └─────────────┘   └───────────┘   │  by component│  └──────────┘
                                              └─────────────┘
```

At each gate, Claude stops and asks structured questions that reveal design assumptions — never "shall I proceed?" but "should we [A] or [B]? A means [trade-off], B means [trade-off]."

## Installation

```bash
# Clone and install
git clone https://github.com/KevinBian107/propel.git
cd propel && pip install -e .

# Initialize in any project
cd /path/to/your/project
propel init
```

`propel init` copies all skills, agents, commands, and hooks into your project's `.claude/` directory, configures the session-start hook in `settings.local.json`, and adds `scratch/` and `sessions/` to `.gitignore`.

Skills auto-trigger based on what you say. Once initialized, start Claude Code and go.

## Quick Start

See [docs/quickstart.md](docs/quickstart.md) for a 5-minute setup guide.

## Skills

| Category | Skill | Trigger |
|----------|-------|---------|
| **Meta** | [using-propel](skills/using-propel/SKILL.md) | Always active — routes to correct skill |
| **Literature** | [deep-research](skills/deep-research/SKILL.md) | "survey", "literature review", "compare methods" |
| | [paper-extraction](skills/paper-extraction/SKILL.md) | "process these papers", "build paper database" |
| **Investigation** | [investigation](skills/investigation/SKILL.md) | "start investigation", "trace X", "what touches X" |
| **Design** | [research-design](skills/research-design/SKILL.md) | "propose how to", "design the implementation" |
| | [writing-plans](skills/writing-plans/SKILL.md) | "write the plan", "break into tasks" |
| **Implementation** | [subagent-driven-research](skills/subagent-driven-research/SKILL.md) | User says "go" after plan approval |
| **Validation** | [research-validation](skills/research-validation/SKILL.md) | "validate this", "test the implementation" |
| | [verification-before-completion](skills/verification-before-completion/SKILL.md) | Before claiming "done" |
| **Debugging** | [systematic-debugging](skills/systematic-debugging/SKILL.md) | Bug reports, training failures |
| **Learning** | [retrospective](skills/retrospective/SKILL.md) | "retrospective", "capture learnings", auto-suggests at ~20 turns |
| **Cross-cutting** | [think-deeply](skills/think-deeply/SKILL.md) | Confirmation-seeking statements, leading questions |
| | [context-hygiene](skills/context-hygiene/SKILL.md) | >15 turns, "getting long" |
| | [using-git-worktrees](skills/using-git-worktrees/SKILL.md) | "create worktree", "experiment branch" |

## Agents (Auditors)

| Agent | Purpose | Auto-dispatched? |
|-------|---------|-----------------|
| [paper-alignment-auditor](agents/paper-alignment-auditor.md) | Cross-reference code against paper equations | Yes — after paper-derived components |
| [jax-logic-auditor](agents/jax-logic-auditor.md) | Trace shapes through JAX transforms | Yes — after JAX code changes |
| [silent-bug-detector](agents/silent-bug-detector.md) | Scan for 11 silent failure categories | Yes — after model/loss/data changes |
| [data-flow-tracer](agents/data-flow-tracer.md) | End-to-end tensor annotation | No — explicit invocation |
| [regression-guard](agents/regression-guard.md) | Verify existing configs unchanged | Yes — after any code change |
| [failure-mode-researcher](agents/failure-mode-researcher.md) | Internet search for training failures | No — explicit invocation |
| [code-reviewer](agents/code-reviewer.md) | General code quality with research awareness | No — invoked during review stage |

## Commands (Slash Commands)

| Command | Purpose |
|---------|---------|
| [/propel:intro](commands/propel/intro.md) | Introduction to Propel — lists all commands, skills, and agents |
| [/propel:read-paper](commands/propel/read-paper.md) | Extract structured reference from a paper |
| [/propel:debug-training](commands/propel/debug-training.md) | Diagnose training issues |
| [/propel:trace-shapes](commands/propel/trace-shapes.md) | Quick shape annotation through a code path |
| [/propel:primer](commands/propel/primer.md) | Load project context |
| [/propel:new-session](commands/propel/new-session.md) | Create and track a session |

## Session Management

```bash
# Create a new session and launch Claude Code
propel session launch "RVQ depth-2 rotation experiment"

# List past sessions
propel session list

# Save chat history
propel session save <session-id> <session-dir>
```

Sessions are stored in `sessions/` with chat history, prompt templates, and symlinks to investigation artifacts. See [docs/workflow.md](docs/workflow.md) for details.

## Documentation

- [Quick Start](docs/quickstart.md) — 5-minute setup
- [Full Workflow](docs/workflow.md) — Walkthrough with all 5 gates
- [Customization](docs/customization.md) — Adding project-specific agents/skills
- [Design Document](../propel/DESIGN.md) — Full specification (in code-manual repo)

## Acknowledgments

Propel combines ideas from three sources:

- **[obra/superpowers](https://github.com/obra/superpowers)** — Plugin architecture, discipline enforcement, verification gates, micro-task planning. Propel's plugin structure, hook system, and "check skills before acting" pattern come directly from Superpowers.

- **[code-manual](https://github.com/KevinBian107/code-manual)** — Research methodology, investigation skills, domain-specific agents, paper-alignment auditing, retrospective system. The investigation-first workflow, all auditor agents, and the literature skills originate from code-manual.

- **[scott-yj-yang/new-prompt](https://github.com/scott-yj-yang/new-prompt)** — Session management CLI. The `propel session` tool is adapted from new-prompt with auto-detection of project root, investigation artifact linking, and session indexing.

## License

MIT
