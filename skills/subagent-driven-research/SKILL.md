---
name: subagent-driven-research
description: >
  Orchestrates the implementation of approved plans using subagents for implementation,
  spec review, paper alignment review, and domain auditing. Use when the user has approved
  a plan (Gate 2 passed) and says "go", "implement this", "start building", or when the
  writing-plans skill has produced a task list. Executes one component at a time with
  three-stage review after each. Gate 3 fires after every component.
  REQUIRES an approved plan — refuses to proceed without one.
---

# Subagent-Driven Research Implementation

## Prerequisite Check

**Before proceeding, verify:**
1. A plan exists in `scratch/{investigation}/plan.md`
2. Gate 2 (Post-Design) was completed — the user approved the plan
3. The user explicitly said "go" or equivalent

**If no plan exists**: Stop. Direct the user to research-design → writing-plans first.

## Implementation Pipeline

For each task in the plan:

### Stage 1: Implementation
Dispatch the implementer subagent with:
- The specific task from the plan (exact file paths, what to implement, paper reference)
- The full design context (investigation README, paper notes, design doc)
- The implementation constraints (what NOT to change, existing behavior to preserve)

See `implementer-prompt.md` for the full implementer subagent prompt.

### Stage 2: Spec + Paper Review
After implementation, run two reviews:

**a) Spec compliance review:**
- Does the implementation match the plan's specification?
- Are all verification steps from the plan satisfied?
- Were any deviations from the plan made? (If so, they must be justified)

See `spec-reviewer-prompt.md` for the full spec review subagent prompt.

**b) Paper alignment review:**
- Dispatch paper-alignment-auditor on the implemented component
- Provide it with the relevant paper notes from `scratch/paper-notes/`
- This catches equation/algorithm mismatches before they become training bugs

### Stage 3: Domain Audit
Dispatch auditors in parallel based on what was changed:

See `auditor-dispatch.md` for the dispatch logic.

| What Changed | Auditors |
|-------------|----------|
| Paper-derived component | paper-alignment-auditor |
| JAX code | jax-logic-auditor |
| Model/loss/data | silent-bug-detector |
| Any code | regression-guard |

### Gate 3: Present Results

After all three stages complete, present audit results to the user.

**If all auditors pass:**
> "All auditors passed for [component name]. Spec ✓, Paper alignment ✓, Domain audit ✓. Moving to next component?"

**If any auditor flags an issue:**

```markdown
## Component [N] Audit Results

### Passed
- ✓ Spec compliance: matches plan specification
- ✓ Regression guard: existing configs unchanged

### Issues Found
- ✗ [Auditor]: [specific finding]
  - Evidence: [what the auditor found]
  - Severity: [Critical/Medium/Minor]

### My Assessment
[Whether the issues are real bugs or false positives, with reasoning]

### Question
[Specific question about how to handle the finding — disjunctive, not yes/no]
```

**Rules:**
- Don't silently fix auditor findings. Present them first.
- For clean passes: keep it brief.
- Every 3 components: offer a natural pause point:
  > "We've completed 3 of [N] components. Good stopping point if you want to /clear and resume later."

## Key Constraints

1. **One component at a time.** Never implement multiple components in parallel — each component's review must complete before the next starts.
2. **Never skip reviews.** Even if the implementation seems trivial, run all three stages.
3. **Complete the review loop.** If a review finds an issue and the user requests a fix, implement the fix and re-run the review before moving on.
4. **Full context to subagents.** Subagents have no conversation history — their prompts must be self-contained. Include all relevant files, design context, and paper references in every dispatch.
5. **Track progress.** Update the plan with completion status after each component.
