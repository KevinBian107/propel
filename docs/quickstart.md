# Quick Start

Get Propel running in 5 minutes.

## 1. Install the Plugin

```bash
claude plugin add propel
```

This registers all skills, agents, and commands. Skills auto-trigger based on what you say — no additional configuration needed.

## 2. (Optional) Install Session Management

```bash
cd propel/cli
pip install -e .
```

This gives you the `propel-session` CLI for archiving and indexing Claude Code chat history.

## 3. Add Scratch and Sessions to .gitignore

```bash
echo "scratch/" >> .gitignore
echo "sessions/" >> .gitignore
```

Propel uses `scratch/` for investigation artifacts and `sessions/` for archived chat history. Both are working directories that shouldn't be committed.

## 4. Start Working

```bash
claude
```

Describe what you want to do. Propel will:

1. **Ask scoping questions** (Gate 0) — before investigating
2. **Scaffold an investigation** — in `scratch/{date}-{name}/README.md`
3. **Present findings** (Gate 1) — before design
4. **Propose a plan** (Gate 2) — before implementation
5. **Audit each component** (Gate 3) — during implementation
6. **Present diagnosis** (Gate 4) — before any bug fix

## Example First Session

```
You: I want to implement residual vector quantization from this paper [link]

Claude: [Gate 0 fires — asks scoping questions one at a time]
  "Are you replacing the existing VQ entirely, or adding RVQ as an alternative?"
  "What depth? Is 2 a hard choice or should it support arbitrary depth?"
  ...

You: [answer questions]

Claude: [writes scope statement, gets confirmation]
Claude: [investigates codebase, creates scratch/2026-02-16-rvq/README.md]
Claude: [Gate 1 — presents findings, asks design direction questions]

You: [make design decisions]

Claude: [research-design produces paper-to-code mapping]
Claude: [writing-plans breaks into micro-tasks]
Claude: [Gate 2 — presents plan, asks about uncertainties]

You: go

Claude: [implements component 1, runs auditors]
Claude: [Gate 3 — presents audit results]
...
```

## Key Slash Commands

| Command | Use When |
|---------|----------|
| `/read-paper [path]` | Extract implementation reference from a paper |
| `/debug-training [symptom]` | Diagnose training issues |
| `/trace-shapes [entry point]` | Quick shape annotation |
| `/primer` | Load project context after /clear |
| `/new-session [description]` | Start a tracked session |

## What to Do After /clear

1. Run `/primer` to reload project context
2. Read your investigation README: `scratch/{investigation}/README.md`
3. Check the plan for where you left off: `scratch/{investigation}/plan.md`
4. Continue from the "Next Steps" section

## Next Steps

- [Full Workflow Guide](workflow.md) — detailed walkthrough with all 5 gates
- [Customization](customization.md) — adding project-specific agents and skills
