Introduce the user to Propel and explain what's available.

## What to tell the user

Propel is a research workflow framework for Claude Code. It adds structured skills, specialized auditor agents, and slash commands that enforce an investigation-first methodology with human-in-the-loop gates.

### How it works

Propel enforces five gates at every phase transition. You (Claude) stop and ask the user structured questions before moving to the next phase — never "shall I proceed?" but "should we [A] or [B]?"

```
Intake → Investigation → Design → Implementation → Debug
  G0         G1            G2          G3             G4
```

Skills auto-trigger based on what the user says. You don't need to memorize triggers — just describe what you want to do.

### Slash commands

| Command | What it does |
|---------|-------------|
| `/propel` | This command — shows what Propel can do |
| `/primer` | Load project context after /clear (reads CLAUDE.md, README, project structure) |
| `/new-session [description]` | Create a tracked session directory with UUID and index entry |
| `/read-paper [path]` | Extract structured implementation reference from a paper |
| `/debug-training [symptom]` | Diagnose training issues (NaN, plateau, mode collapse) |
| `/trace-shapes [entry point]` | Quick shape annotation through a code path |

### Skills (auto-triggered)

| Category | Skill | Say something like... |
|----------|-------|-----------------------|
| Investigation | investigation | "start investigation", "trace X", "what touches X" |
| Literature | deep-research | "survey", "literature review", "compare methods" |
| Literature | paper-extraction | "process these papers", "build paper database" |
| Design | research-design | "propose how to", "design the implementation" |
| Planning | writing-plans | "write the plan", "break into tasks" |
| Implementation | subagent-driven-research | Say "go" after approving a plan |
| Validation | research-validation | "validate this", "test the implementation" |
| Debugging | systematic-debugging | Bug reports, training failures |
| Learning | retrospective | "retrospective", "capture learnings" |
| Thinking | think-deeply | Challenges assumptions when you make leading statements |
| Context | context-hygiene | "getting long" or auto after ~15 turns |
| Git | using-git-worktrees | "create worktree", "experiment branch" |

### Auditor agents (auto-dispatched after code changes)

| Agent | When it runs |
|-------|-------------|
| paper-alignment-auditor | After paper-derived components |
| jax-logic-auditor | After JAX code changes |
| silent-bug-detector | After model/loss/data changes |
| regression-guard | After any code change |
| data-flow-tracer | Explicit invocation only |
| failure-mode-researcher | Explicit invocation only |
| code-reviewer | During review stage |

### Tips

- Start any new task by just describing what you want — Gate 0 will fire automatically
- Use `/primer` after every `/clear` to reload context
- Investigations go in `scratch/` — these are gitignored working directories
- Say "retrospective" periodically to capture what worked and what didn't
