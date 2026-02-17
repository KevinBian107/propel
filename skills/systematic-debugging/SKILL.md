---
name: systematic-debugging
description: >
  [Propel] Root-cause-first debugging with a 3-strike limit and ML-specific diagnostics.
  Use when the user reports a bug, training failure, unexpected behavior, or when
  /debug-training identifies an issue that needs deeper investigation. Combines
  Superpowers' root-cause-first discipline with research-specific diagnostic patterns
  (loss magnitudes, gradient norms, codebook metrics). Gate 4 fires after diagnosis —
  Claude MUST present the root cause and proposed fix before changing any code.
---

# Systematic Debugging — Root Cause Before Fix

## Core Rule: Diagnose Before You Fix

**NEVER apply a fix without first presenting the diagnosis to the user.** This is Gate 4 — it is mandatory. The user may have domain knowledge that changes the interpretation of the root cause.

## 3-Strike Limit

If the same approach fails 3 times:
1. **Stop.** Don't try a fourth variation of the same idea.
2. **Step back.** Re-examine your assumptions about the root cause.
3. **Ask the user.** "I've tried [approach] three times without success. My assumption about the root cause may be wrong. Here's what I've learned from the failures: [summary]. Should I try a fundamentally different approach, or do you have insight into what might be happening?"

This prevents the loop of: try fix → doesn't work → try slight variation → doesn't work → try another variation → wasted 30 minutes.

## Debugging Process

### Step 1: Characterize the Symptom
Before investigating, write down exactly what's happening:
- What is the observed behavior?
- What is the expected behavior?
- When did this start? What changed?
- Is it reproducible? Always or intermittent?

### Step 2: Form Hypotheses (Ranked)
Generate 3-5 hypotheses for the root cause, ranked by likelihood:
1. [Most likely — explain why]
2. [Second most likely]
3. [...]

For each hypothesis, state what evidence would confirm or rule it out.

### Step 3: Gather Evidence
For each hypothesis (in order of likelihood):
- Write targeted diagnostic checks — don't search broadly without direction
- Gather concrete evidence: specific values, shapes, line numbers
- Confirm or rule out the hypothesis before moving to the next

### ML-Specific Diagnostics

When debugging training issues, check these systematically:

**Loss Component Magnitudes:**
- Log each loss component individually
- Is one term dominating? (commitment loss >> reconstruction loss = codebook never learns)
- Are any terms exactly zero? (missing term, incorrect masking)
- Are magnitudes reasonable? (loss of 1e6 suggests numerical issue, loss of 0.0 suggests dead path)

**Gradient Norms Per Module:**
- Log gradient norms for each module separately
- Vanishing gradients: norm < 1e-8 (dead path, too many layers without residuals, stop_gradient in wrong place)
- Exploding gradients: norm > 1e3 (missing clipping, bad initialization, numerical instability)
- Imbalanced gradients: one module's gradients 100x another's (loss weighting issue)

**Codebook/Discrete Metrics (VQ-VAE, FSQ, etc.):**
- Codebook utilization: what fraction of codes are being used? (<10% = collapse)
- Perplexity: effective number of codes used per batch (should be close to codebook size)
- Commitment loss: is the encoder being pushed toward codebook entries?
- Code frequency histogram: are some codes monopolizing? (mode collapse in discrete space)

**Write diagnostic scripts to `scratch/debug/`**

### Step 4: Gate 4 — Present Diagnosis

After identifying the root cause, present in this format:

```markdown
## Diagnosis

### Symptom
[What the user reported]

### Root Cause
[What's actually happening, with evidence — specific line numbers, values, shapes]

### Why This Happens
[Explanation of the mechanism, not just the symptom]

### Proposed Fix
[Exact changes, with file paths and line numbers]

### What This Fix Will Change
[Side effects, if any — other behavior that will be affected]

### What This Fix Will NOT Fix
[Other issues that might look related but have different causes]
```

**Then ask the user:**
- "I believe the root cause is [X] because [evidence]. Does this match what you're seeing?"
- "I can fix this by [A: targeted fix] or [B: broader refactor]. A is faster but doesn't address the underlying fragility. Which do you prefer?"
- If applicable: "This fix will also change the behavior of [Y]. Is that acceptable?"

**Wait for user approval before changing any code.**

### Step 5: Apply Fix and Verify
After user approves:
1. Apply the fix
2. Run the relevant validation (research-validation gates if applicable)
3. Present evidence that the fix works: "Loss decreased from X to Y", "gradient norms are now in [range]"
4. Ask: "Should I capture this in a retrospective entry? This failure mode is worth documenting."

## Anti-Patterns to Avoid

1. **Symptom patching**: Fixing the symptom without understanding the cause. "Loss is NaN → add gradient clipping" is a band-aid if the real issue is a log(0) in the loss.
2. **Shotgun debugging**: Changing 5 things at once to see if something works. This makes it impossible to know which change actually fixed the issue.
3. **Displaced fixes**: Fixing in module B what's actually broken in module A. The regression-guard catches these, but you should avoid creating them in the first place.
4. **Ignoring the 3-strike limit**: If your approach isn't working, more of the same approach won't either. Change direction.

## When to Delegate

- **If the failure might be a known issue**: Delegate to failure-mode-researcher for internet search
- **If the failure involves subtle data flow**: Delegate to data-flow-tracer
- **If the failure is JAX-specific**: Delegate to jax-logic-auditor
- **If the failure might be a paper misalignment**: Delegate to paper-alignment-auditor
