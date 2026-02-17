# Customization

How to add project-specific agents, skills, and commands to Propel.

## Automatic Project Profiling

Propel can auto-detect your project's coding conventions, domain context, and development patterns, creating a persistent profile that Claude references on every session start.

### How it works

Run `/propel:intro` and accept the Part 3 offer, or say "customize Propel" at any time. Propel will:

1. **Scan project structure** — language, framework, dependencies, directory layout, build tools
2. **Analyze code style** — naming conventions, import patterns, formatting, type hints, docstrings (from 5-10 source files)
3. **Detect domain** — classify from imports; optionally delegate to env-researcher or deep-research agents for detailed context
4. **Analyze git history** — commit style, branch naming, active areas, team size
5. **Read existing conventions** — CLAUDE.md, CONTRIBUTING.md, CI configs, linter configs, editor configs
6. **Present profile for confirmation** — you review and approve before anything is written

### Output files (in `.propel/`, gitignored)

| File | Purpose |
|------|---------|
| `config.json` | Enabled/disabled flag, timestamps, analysis hash, detected domain/framework |
| `profile.md` | Main reference (~100 lines) — project identity, style, patterns, active areas |
| `conventions.md` | Detailed naming, import, formatting, type hint, and testing conventions with examples |
| `domain-context.md` | Domain-specific context from agent delegation (only if applicable) |

### Keeping it current

On subsequent runs, Propel hashes key project files and compares against the stored hash. If nothing changed, it confirms the profile is current. If files changed, it re-analyzes only the affected categories and shows you a diff before updating.

### Toggle or remove

- **Disable**: Set `"enabled": false` in `.propel/config.json`
- **Remove**: Delete the `.propel/` directory entirely
- **Re-enable**: Say "customize Propel" to run a fresh analysis

## Adding Project-Specific Agents

Propel's agents are defaults. You can add project-specific agents in your own `.claude/agents/` directory — they take precedence over Propel's.

### Example: PyTorch Logic Auditor

If your project uses PyTorch instead of JAX, create `.claude/agents/torch-logic-auditor.md`:

```markdown
---
name: torch-logic-auditor
description: "PyTorch-specific logic auditor. Replaces jax-logic-auditor for PyTorch projects."
tools: Read, Grep, Glob
---

You are a PyTorch logic auditor...
[Your PyTorch-specific checks here]
```

### Example: Domain-Specific Auditor

For robotics projects, you might add `.claude/agents/sim-real-gap-auditor.md`:

```markdown
---
name: sim-real-gap-auditor
description: "Checks for sim-to-real transfer issues..."
tools: Read, Grep, Glob
---

[Auditor content]
```

### Agent Design Principles

1. **One-shot context**: Agents have no conversation history. Their prompt must be self-contained.
2. **Read-only by default**: Auditors should only read code, not modify it.
3. **Structured output**: Use the output format template from existing agents.
4. **Specific trigger conditions**: The description field determines when the agent gets dispatched.

## Adding Project-Specific Skills

Add skills to `.claude/skills/` in your project. They integrate with Propel's existing workflow.

### Example: Hardware Deployment Skill

`.claude/skills/hardware-deployment/SKILL.md`:

```markdown
---
name: hardware-deployment
description: >
  Guides the deployment of trained policies to physical hardware.
  Use when the user says "deploy to robot", "run on hardware", "sim to real".
---

# Hardware Deployment

## Pre-Deployment Checklist
- [ ] Policy verified in simulation (research-validation passed)
- [ ] Action scaling verified (sim units → hardware units)
- [ ] Safety limits configured
- [ ] Fallback behavior defined
...
```

## Adding Project-Specific Commands

Add slash commands to `.claude/commands/` in your project.

### Example: Run Training

`.claude/commands/train.md`:

```markdown
Run a training experiment with the configuration in $ARGUMENTS.

## Process
1. Verify the config exists and is valid
2. Run a 100-step smoke test first
3. If smoke test passes, launch full training
4. Monitor the first 1000 steps for NaN/explosion
...
```

## Modifying Propel's Gate Behavior

You can adjust gate behavior by adding instructions to your project's `CLAUDE.md`:

```markdown
## Propel Overrides

### Gate 0 (Intake)
- For routine experiments (hyperparameter sweeps), Gate 0 can be abbreviated to a single scope confirmation.
- For novel implementations, full Gate 0 is mandatory.

### Gate 3 (Mid-Implementation)
- For this project, always include the sim-real-gap-auditor in the audit dispatch.
```

## Adjusting Auditor Dispatch

The `subagent-driven-research/auditor-dispatch.md` file contains the dispatch rules. To add your project-specific auditor to the dispatch:

1. Add the agent file to your `.claude/agents/` directory
2. Add a dispatch rule in your CLAUDE.md:

```markdown
## Auditor Dispatch Override
After modifying any file in `envs/` or `controllers/`, also dispatch sim-real-gap-auditor.
```

## Project CLAUDE.md Integration

Reference Propel in your project's `CLAUDE.md`:

```markdown
## Workflow
This project uses the Propel research workflow.
Skills, agents, and commands are in .claude/ (installed via `propel init`).
See propel documentation for the investigation → design → implement → validate pipeline.

## Project-Specific Notes
- Our configs are in `configs/` — existing configs must not change behavior (regression-guard)
- Paper references are in `docs/papers/` — use /read-paper to extract them
- Training scripts expect wandb to be configured
```
