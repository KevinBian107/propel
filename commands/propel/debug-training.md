Diagnose the training issue described in $ARGUMENTS.

$ARGUMENTS should describe the symptom, e.g.:
- "NaN loss after 500 steps"
- "loss plateaus at 0.45 and won't decrease"
- "exploding gradients in the policy network"
- "mode collapse — all outputs are identical"
- "reward not increasing after 1M steps"
- "loss spikes every ~1000 steps"

## Diagnostic Process

### Step 1: Understand the Setup
Read the training script, config, and model definition to understand:
- What model architecture is being trained
- What loss function is used (all terms and weights)
- Optimizer settings (type, lr, schedule, gradient clipping)
- Data pipeline (what goes in, any normalization/augmentation)
- Logging setup (wandb, tensorboard — what's being tracked)

### Step 2: Run Symptom-Specific Diagnostics

**For NaN / Inf loss:**
- Write a script to check: which loss component goes NaN first?
- Check for: log(0), division by zero, exp() overflow, large logits into softmax
- Check if inputs contain NaN (corrupted data, bad normalization stats)
- Check gradient norms — are they exploding before the NaN?
- Check learning rate — is it too high for this architecture?

**For loss plateau / not converging:**
- Check gradient norms — are they vanishing? (near zero = dead gradients)
- Check if the learning rate is too low or has decayed too far
- Verify the loss function is correct (wrong reduction, wrong sign, missing term)
- Check if the model has enough capacity (too small for the task)
- Test on a tiny overfit batch — if it can't overfit 5 samples, the problem is the model/loss, not the data
- Check for stop_gradient / detach in the wrong place (blocking learning signal)

**For exploding gradients:**
- Write a script to log per-parameter gradient norms — which layer explodes first?
- Check if gradient clipping is enabled and at what threshold
- Check for: missing normalization layers, skip connections amplifying gradients, high learning rate
- Check initialization scheme — are weights initialized too large?

**For mode collapse:**
- Check if there's a diversity/entropy term in the loss (and if its weight is sufficient)
- Check the bottleneck — is it too small? Is the KL term too strong (posterior collapse)?
- For VQ-VAE: check codebook utilization — are all codes being used?
- For RL: check if entropy bonus is present and correctly scaled

**For reward not increasing (RL-specific):**
- Check advantage estimation — is GAE computed correctly (right axis, right discount)?
- Verify reward normalization/clipping isn't removing the learning signal
- Check if the value function is learning (value loss should decrease)
- Verify environment reset logic — are episode boundaries handled correctly?
- Check action distribution — is it collapsing to deterministic too early?

**For periodic spikes:**
- Check learning rate schedule — do spikes align with warmup/decay transitions?
- Check data — is there a problematic batch that cycles? (bad sample, outlier)
- Check epoch boundaries — does the dataloader reshuffle break something?
- Check checkpoint saving — does I/O stall cause timing issues?

### Step 3: Write Diagnostic Scripts

For each check that requires runtime information, write small targeted scripts in `scratch/debug/` that:
- Load one batch from the dataset and inspect shapes, dtypes, ranges, NaN count
- Run one forward pass and print per-component loss values
- Run one backward pass and print per-layer gradient norms
- Check model parameter statistics (mean, std, min, max, any NaN/Inf)
- Check if the tiny overfit test passes

### Step 4: Report

Output a structured diagnosis:

```markdown
## Training Diagnosis: [symptom]

### Setup Summary
- Model: [architecture]
- Loss: [terms and weights]
- Optimizer: [type, lr, schedule]
- Data: [description]

### Root Cause (most likely)
[What's going wrong and why]

### Evidence
- [Finding 1]: [what the diagnostic showed]
- [Finding 2]: ...

### Recommended Fix
1. [Most likely fix — specific code change with file and line]
2. [Alternative if #1 doesn't work]

### Diagnostic Scripts Created
- `scratch/debug/check_gradients.py` — [what it checks]
- `scratch/debug/overfit_test.py` — [what it checks]
- ...

### What to Monitor After Fix
- [Metric to watch and expected behavior]
```

## Important

- Don't guess — write scripts and check. A wrong diagnosis wastes more compute than the diagnostic time.
- Check the simplest explanations first (wrong learning rate, bug in loss) before complex ones (architecture mismatch).
- If you can't determine the root cause from static analysis alone, say so and provide the diagnostic scripts for the user to run.
