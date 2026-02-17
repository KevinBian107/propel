[Propel] Introduce the user to Propel and generate a project-specific CLAUDE.md.

This command does three things:
1. Explain what Propel is and what commands/skills/agents are available
2. Analyze the codebase and draft a CLAUDE.md tailored to this project
3. Offer automatic project customization (optional)

---

## Part 1: Tell the user what Propel is

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
| `/intro` | This command — introduces Propel and drafts your CLAUDE.md |
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
| Verification | verification-before-completion | Auto-checks before claiming "done" or "fixed" |
| Debugging | systematic-debugging | Bug reports, training failures |
| Learning | retrospective | "retrospective", "capture learnings" |
| Thinking | think-deeply | Challenges assumptions when you make leading statements |
| Context | context-hygiene | "getting long" or auto after ~15 turns |
| Git | using-git-worktrees | "create worktree", "experiment branch" |
| Customization | project-customization | "customize Propel", "analyze my project", "detect conventions" |

### Auditor agents (auto-dispatched after code changes)

| Agent | When it runs |
|-------|-------------|
| paper-alignment-auditor | After paper-derived components |
| jax-logic-auditor | After JAX code changes |
| silent-bug-detector | After model/loss/data changes |
| regression-guard | After any code change |
| env-researcher | During investigation of environment-dependent code |
| data-flow-tracer | Explicit invocation only |
| failure-mode-researcher | Explicit invocation only |
| code-reviewer | During review stage |

### Tips

- Start any new task by just describing what you want — Gate 0 will fire automatically
- Use `/primer` after every `/clear` to reload context
- Investigations go in `scratch/` — these are gitignored working directories
- Say "retrospective" periodically to capture what worked and what didn't

---

## Part 2: Analyze the codebase and draft CLAUDE.md

After presenting the intro above, do the following:

### Step 1: Scan the project

Use subagents or direct tools to gather:
- Run `tree` (depth 3) to understand project structure
- Read `README.md` if it exists
- Read any existing `CLAUDE.md` or `.claude/CLAUDE.md`
- Read `pyproject.toml`, `setup.py`, `setup.cfg`, `Cargo.toml`, `package.json`, or equivalent to identify the language, framework, and dependencies
- Skim 2-3 key source files to identify patterns (code style, imports, architecture)
- Check for `tests/`, `docs/`, config files, CI configuration
- Identify the domain (ML/JAX/PyTorch/robotics/web/etc.) from imports and structure

### Step 2: Draft CLAUDE.md

Generate a project-specific `.claude/CLAUDE.md` that fills in these sections with concrete, specific content derived from the scan. Follow this structure:

```markdown
# CLAUDE.md

This project uses the [Propel](https://github.com/KevinBian107/propel) research workflow.
Skills, agents, and commands are in `.claude/` (installed via `propel init`).

## Project Overview

[What this project does, key packages/modules, how it fits into a larger ecosystem if applicable]

## Code Style Requirements

[Formatting tools (ruff, black, prettier), docstring style (Google, NumPy), type hint conventions, import order, framework-specific conventions (e.g. "use jax.numpy over numpy in JIT code")]

## Development Workflow

[Branching strategy, commit conventions, PR process, CI expectations — infer from existing git history and config]

## Testing Rules

[Test framework, fixture conventions, where tests live, mocking policy — infer from existing tests/]

## Research Context

[LEAVE AS PLACEHOLDER — ask the user to fill this in]
<!-- What is this project's research context? What problem does it solve? -->

## Research Question

[LEAVE AS PLACEHOLDER — ask the user to fill this in]
<!-- What are you testing or building? Be specific. -->

## Hypothesis

[LEAVE AS PLACEHOLDER — ask the user to fill this in]
<!-- What do you expect to happen and why? -->

## Method

[LEAVE AS PLACEHOLDER — ask the user to fill this in]
<!-- Which paper(s), equations, algorithmic choices? -->

## Domain-Specific Pitfalls

[Fill in what you can infer from the codebase — e.g. if it's JAX, mention broadcasting, PRNG threading, vmap semantics. If PyTorch, mention in-place ops, gradient detach. Then ask the user to add their own.]

## Project Conventions

[Fill in from the scan — directory structure, naming patterns, config system, what NOT to change]

## Known Constraints

[Fill in what you can infer — Python version, key dependency versions, hardware requirements. Ask user to add more.]

## What "Correct" Means Here

[LEAVE AS PLACEHOLDER — ask the user to fill this in]
<!-- How do you verify correctness beyond "tests pass"? -->
```

---

## Part 3: Project Customization (Optional)

After drafting CLAUDE.md, offer automatic project profiling:

### Present the offer

Tell the user:

> **Optional: Automatic Project Profiling**
>
> Propel can analyze your codebase to build a persistent project profile — detecting code conventions, domain context, commit patterns, and development workflows. This takes ~2-3 minutes and creates a `.propel/` directory (gitignored) that Claude references silently on every session start.
>
> The profile means you don't have to re-explain your conventions each session. It captures things like: "this project uses snake_case, Google docstrings, pytest fixtures in conftest.py, and conventional commits."
>
> **Would you like to run the analysis now?**

### Handle response

- **Yes** → Activate the **project-customization** skill. It will run 6 analysis phases and present findings for confirmation before writing anything.
- **No** → Tell the user: "You can run this anytime by saying 'customize Propel' or 'analyze my project'."
- **`.propel/` already exists and is recent** (check `.propel/config.json` timestamp, <7 days old) → Offer: "You have an existing project profile from [date]. Would you like to (A) run a delta check for changes, or (B) do a full re-analysis?"

---

### Step 3: Present and confirm

1. Show the user the drafted CLAUDE.md
2. Clearly mark which sections you filled in vs. which are placeholders for them
3. Tell the user: "The sections I've filled in are based on scanning your codebase. The placeholder sections — Research Question, Hypothesis, Method, and What 'Correct' Means — are where **your domain expertise** matters most. Claude produces the mean of its training data; these sections are what make the output specific to your work."
4. Ask: "Should I write this to `.claude/CLAUDE.md`? And would you like to fill in any of the placeholder sections now?"
5. If they confirm, write the file. If `.claude/CLAUDE.md` already has non-template content, show a diff and ask before overwriting.
