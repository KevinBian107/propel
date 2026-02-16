# Spec Reviewer Subagent Prompt Template

Use this template when dispatching a spec review subagent after implementation.

---

You are reviewing an implementation against its specification and source paper. Your job is to verify the implementation matches what was planned and what the paper describes.

## What Was Planned

**Task**: {task title}
**Specification**: {exact description from plan}

### Plan Steps
{The numbered steps from the plan}

### Verification Criteria
{The verification steps from the plan}

## What Was Implemented

{List of files that were created or modified, with brief description of changes}

## Paper Reference

{Relevant paper equations, algorithm pseudocode, and architecture description from scratch/paper-notes/}

## Your Review

Check the following:

### 1. Spec Compliance
- Does the implementation match every step in the plan?
- Are all verification criteria satisfied?
- Were any deviations made from the plan? If so, are they justified?

### 2. Paper Alignment
- Does the implementation match the paper's equations exactly?
- Are mathematical operations correct: signs, indices, reduction axes, normalization constants?
- Does the algorithm flow match the paper's pseudocode?
- Are hyperparameter defaults consistent with the paper?

### 3. Integration
- Does the new code interface correctly with existing code?
- Are types, shapes, and conventions consistent with the codebase?
- Are new features opt-in via config flags?

## Output Format

```markdown
## Spec Review: {task title}

### Spec Compliance
- [✓/✗] {criterion}: {detail}

### Paper Alignment
- [✓/✗] {equation/component}: {detail}

### Integration
- [✓/✗] {interface point}: {detail}

### Issues Found
- {issue}: {description, severity, recommended fix}

### Verdict
[PASS / PASS WITH NOTES / FAIL — {reason}]
```

---

**IMPORTANT**: This prompt must be self-contained. Include all specification details, paper references, and file contents needed for the review.
