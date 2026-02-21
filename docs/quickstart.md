# Quick Start

Get Propel running in 5 minutes.

## 1. Install Propel

```bash
git clone https://github.com/KevinBian107/propel.git
cd propel && pip install -e .
```

## 2. Initialize in Your Project

```bash
cd /path/to/your/project
propel init
```

This copies all skills, agents, commands, and hooks into `.claude/`, configures the session-start hook in `settings.local.json`, and adds `scratch/`, `sessions/`, `.propel/`, `.claude/`, and `propel/` to `.gitignore`.

## 3. Start Claude and Run `/intro`

```bash
claude
```

Then inside Claude, run:

```
/intro
```

This does four things:
0. **Selects a mode** — choose how you want to work: **Researcher** (literature + investigation), **Engineer** (full pipeline, default), or **Trainer** (launch training + fix runtime errors). You can switch anytime with `/switch`.
1. **Introduces Propel** — shows all commands, skills, and agents with their triggers
2. **Drafts your CLAUDE.md** — scans your codebase and generates a project-specific `.claude/CLAUDE.md` with code style, conventions, and structure already filled in. You fill in the research-specific sections (research question, hypothesis, method) — these are the constraints that make Claude's output specific to your work instead of a generic average.
3. **Offers project customization** (optional) — analyzes your codebase to build a persistent profile in `.propel/` that captures naming conventions, domain context, commit patterns, and more. Claude references this silently on every session start, so you don't have to re-explain your conventions. Takes ~2-3 minutes; you can also run it anytime by saying "customize Propel".

Once your CLAUDE.md is set up, describe what you want to do. Propel will:

1. **Ask scoping questions** (Gate 0) — before investigating
2. **Scaffold an investigation** — in `scratch/{date}-{name}/README.md`
3. **Present findings** (Gate 1) — before design
4. **Propose a plan** (Gate 2) — before implementation
5. **Audit each component** (Gate 3) — during implementation
6. **Present diagnosis** (Gate 4) — before any bug fix

## Example First Session

```
You: /intro
Claude: How do you want to work today?
  1. Researcher  2. Engineer  3. Trainer

You: 2
Claude: Engineer Mode active. Full pipeline available.
Claude: [explains Propel, lists all commands, skills, and agents]

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

All Propel commands are marked with `[Propel]` in their description.

| Command | Use When |
|---------|----------|
| `/intro` | First time using Propel, or need a refresher |
| `/read-paper [path]` | Extract implementation reference from a paper |
| `/debug-training [symptom]` | Diagnose training issues |
| `/trace-shapes [entry point]` | Quick shape annotation |
| `/switch [mode]` | Switch mode (researcher, engineer, trainer) |
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
