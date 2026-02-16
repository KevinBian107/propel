---
name: research-design
description: >
  Proposes an implementation approach based on investigation findings and paper references.
  Use when the user says "propose how to", "design the implementation", "plan the architecture",
  "how should we implement". REQUIRES a completed investigation (Gate 1 passed) — refuses to
  proceed without one. Reads investigation README + paper notes, proposes paper-equation-to-code
  mapping, identifies regression risks, and fires Gate 2 before any implementation begins.
  NOT for brainstorming from scratch — that's what investigation is for.
---

# Research Design — From Investigation to Implementation Plan

## Prerequisite Check

**Before proceeding, verify:**
1. An investigation exists in `scratch/` with a completed README.md
2. The README has a "## Design Decisions (Human-Approved)" section (filled in after Gate 1)
3. Gate 1 (Post-Investigation) was completed — findings were presented and the user approved a direction

**If no investigation exists**: Stop. Tell the user:
> "I need to investigate before I can design. There's no investigation artifact in scratch/. Let's start with an investigation to understand the codebase and the science before designing the implementation."

**If Gate 1 wasn't completed**: Stop. Tell the user:
> "The investigation findings haven't been reviewed yet. Let me present what I found before we design — I may have discovered things that change the approach."

## Design Process

### Step 1: Read Context
- Read the investigation README including "Design Decisions (Human-Approved)"
- Read any referenced paper notes from `scratch/paper-notes/`
- Read any relevant registry entries from `scratch/registry/`

### Step 2: Paper-to-Code Mapping
For each new component, create an explicit mapping:

```markdown
## Paper-to-Code Mapping

| Paper Reference | Code Component | Files Affected | New/Modified |
|----------------|---------------|----------------|-------------|
| Eq. 3 (commitment loss) | `compute_commitment_loss()` | model/losses.py | New |
| Fig. 2 (encoder architecture) | `ResidualEncoder` class | model/encoder.py | Modified |
| Alg. 1, line 5 (codebook update) | `update_codebook()` | model/vq.py | New |
```

### Step 3: Regression Risk Assessment
Identify what existing behavior must remain unchanged:

- Which existing configs must produce identical results?
- Which code paths are shared between old and new functionality?
- Where are the coupling points between new and existing code?
- Propose config flags for each new feature (new features are opt-in, existing configs unchanged)

### Step 4: Design Proposal
Write the design proposal with:
- Component list with implementation order (minimize regression risk: new code paths first, then modifications to existing paths)
- For each component: what it implements, which paper reference it maps to, which files it touches
- Explicit statement of what will NOT be changed
- Estimated scope: number of components, files modified, new files

### Step 5: Gate 2 — Post-Design Checkpoint

**You MUST present the plan and ask questions before proceeding to implementation.**

Present in this format:

```markdown
## Implementation Plan Summary

### Components (in order)
1. [Component] — maps to paper eq. [X] — touches files [Y, Z]
2. ...

### Regression Risk Assessment
- [What existing behavior could break, and how we're protecting against it]

### What I'm Uncertain About
1. [Specific uncertainty + the two options I'm considering + why I can't decide without your input]
2. ...

### Estimated Scope
- [N] components, [M] files modified, [K] new files
- [Which components are independent vs. sequential]
```

**Gate 2 questions must be about:**
- **Implementation order**: "I've ordered to minimize regression risk, but the most interesting part comes third. Do you want to see the core component first instead?"
- **Uncertainty resolution**: "The paper doesn't specify [X]. I see two options: [A] or [B]. [A] is [trade-off]. [B] is [trade-off]. Which do you prefer?"
- **Scope confirmation**: "This plan modifies [N] files. I've kept [these files] untouched. Should any of the modified files also be off-limits?"

**Rules for Gate 2:**
- The plan must be specific enough that the user can reject individual steps
- Claude must explicitly state what it will NOT change
- If the plan is more than ~10 tasks, ask whether to split into multiple sessions

**Exit condition**: User approves the plan (possibly with modifications). User says "go" → proceed to writing-plans for micro-task breakdown, then to implementation.

## Output

Save the design proposal to `scratch/{investigation-name}/design.md`.
