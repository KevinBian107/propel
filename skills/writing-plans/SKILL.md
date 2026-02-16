---
name: writing-plans
description: >
  Breaks a design proposal into micro-tasks with exact file paths, verification steps, and
  auditor assignments. Use after research-design has produced an approved design (Gate 2 passed).
  Each task is 2-5 minutes of work with clear verification criteria. Tasks specify which
  auditors run after completion. Output saved to investigation scratch directory.
---

# Writing Plans — Micro-Task Breakdown

## Purpose

Convert an approved design proposal into a sequence of small, precise implementation tasks. Each task should be completable in 2-5 minutes and should have clear verification criteria.

## Task Format

For each task, specify:

```markdown
### Task {N}: {Title}

**What**: {Exactly what to implement — specific functions, classes, or changes}
**Where**: {Exact file paths and approximate line numbers}
**Maps to**: {Paper equation/section or design component}
**Dependencies**: {Which tasks must be done first}

**Steps**:
1. {Step 1 — specific enough to implement without ambiguity}
2. {Step 2}
3. ...

**Verification**:
- [ ] {Specific check — e.g., "forward pass with shape (B, T, F) produces output (B, T, D)"}
- [ ] {e.g., "loss_commitment is non-zero for a random input"}

**Auditors to run after**:
- [ ] paper-alignment-auditor (if implementing paper-derived component)
- [ ] jax-logic-auditor (if modifying JAX transforms)
- [ ] silent-bug-detector (if modifying model/loss/data)
- [ ] regression-guard (always)
```

## Plan Structure

```markdown
# Implementation Plan: {investigation-name}

## Overview
- Design doc: scratch/{investigation-name}/design.md
- Total tasks: {N}
- Estimated components: {M}
- Files to modify: {list}
- Files to create: {list}
- Files NOT touched: {list — explicit}

## Task Order Rationale
{Why tasks are ordered this way — typically: new code paths first, modifications to existing code second, integration last}

## Tasks

### Task 1: ...
### Task 2: ...
...

## Pause Points
- After Task {N}: Good stopping point for /clear (context checkpoint)
- After Task {M}: Natural pause — offer to save session
```

## Key Principles

1. **2-5 minutes per task**: If a task takes longer to describe than to implement, it's the right size. If it takes longer to implement than to describe, break it down further.

2. **Exact file paths**: Never "update the model" — always "add `compute_residual_codes()` to `model/vq.py` after line 145".

3. **Verification steps are mandatory**: Every task must have at least one concrete verification step. For research code, these include:
   - Shape checks: "forward pass produces expected output shape"
   - Paper alignment: "run paper-alignment-auditor on this component"
   - Gradient flow: "verify gradients are non-zero for parameters X"
   - Regression: "existing config Y produces identical output"

4. **Auditor assignments**: Each task specifies which auditors should run after completion. This is not optional — auditors are how Gate 3 fires.

5. **Order minimizes regression risk**: New code paths before modifications to existing paths. Infrastructure before features. Core before periphery.

6. **Pause points every 3 tasks**: Offer natural stopping points for `/clear` and session archival. Long implementation sessions degrade context quality.

## Output

Save to `scratch/{investigation-name}/plan.md`.
