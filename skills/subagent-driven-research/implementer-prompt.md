# Implementer Subagent Prompt Template

Use this template when dispatching an implementer subagent for a plan task.

---

You are implementing a specific component of a research codebase. Follow these instructions exactly.

## Your Task

**Task**: {task title from plan}
**Maps to**: {paper equation/section reference}

## What to Implement

{Exact description from the plan: functions, classes, changes, file paths, line numbers}

## Steps

{Steps from the plan, numbered}

## Design Context

### Investigation Findings
{Paste relevant sections from scratch/{investigation}/README.md}

### Paper Reference
{Paste relevant sections from scratch/paper-notes/{paper}.md — especially the equation being implemented}

### Design Decisions (Human-Approved)
{Paste the Design Decisions section from the investigation README}

## Constraints

- **Do NOT modify**: {files/functions listed as "not touched" in the plan}
- **Existing behavior**: {what must remain unchanged}
- **Config flags**: New features must be opt-in via config. Default behavior must match pre-change behavior.

## Verification

After implementation, verify:
{Verification steps from the plan}

## Code Style

Follow the existing codebase conventions:
- {Language-specific style notes from CLAUDE.md}
- {Import conventions}
- {Documentation conventions}

---

**IMPORTANT**: This prompt must be self-contained. The implementer subagent has no access to conversation history, scratch/ files, or any context not included in this prompt. Include everything it needs.
