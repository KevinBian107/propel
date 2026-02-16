---
name: research-validation
description: >
  Validates research code implementations through four domain-specific gates: shape, gradient,
  overfit, and regression. Use when the user says "validate this", "test the implementation",
  "check if this works", or auto-triggers after implementation tasks complete. Does NOT enforce
  test-first (research code often can't be TDD'd meaningfully). Instead enforces validation
  gates specific to ML/robotics code. Gate 3 fires after each validation to present results.
---

# Research Validation — Four Gates

## When This Activates

- After implementation tasks complete (auto-triggered by subagent-driven-research)
- When the user explicitly asks to validate ("validate this", "test the implementation", "check if this works")
- As part of the Gate 3 mid-implementation checkpoint

## The Four Validation Gates

Run these in order. If an earlier gate fails, don't proceed to later gates — fix the failure first.

### Gate 1: Shape Validation
**Purpose**: Verify that a forward pass with known input produces expected output shape and dtype.

**What to check:**
- Create a test input with known shape and dtype matching the expected data format
- Run the forward pass end-to-end
- Verify output shape matches the design doc specification
- Verify dtype is correct (especially float32 vs float64 mismatches)
- Check intermediate shapes at key points in the pipeline

**Write to**: `scratch/{investigation}/tests/test_shapes.py`

```python
# Template
def test_forward_shapes():
    """Verify forward pass produces expected output shapes."""
    # Create synthetic input matching expected data format
    key = jax.random.PRNGKey(0)
    x = jax.random.normal(key, shape=(B, T, F))  # (batch, time, features)

    # Run forward pass
    output = model.apply(params, x)

    # Verify shapes
    assert output.shape == (B, T, D), f"Expected (B, T, D), got {output.shape}"
    assert output.dtype == jnp.float32
```

### Gate 2: Gradient Validation
**Purpose**: Verify that loss.backward() produces non-zero gradients for all trainable parameters and that stop_gradient boundaries are correct.

**What to check:**
- Compute the loss on a synthetic input
- Compute gradients via `jax.grad` (or equivalent)
- Verify every trainable parameter has non-zero gradient
- Verify parameters that SHOULD be frozen have zero gradient
- Check gradient magnitudes are in a reasonable range (not exploding, not vanishing)

**Write to**: `scratch/{investigation}/tests/test_gradients.py`

```python
# Template
def test_gradient_flow():
    """Verify gradients flow to all trainable parameters."""
    key = jax.random.PRNGKey(0)
    x = jax.random.normal(key, shape=(B, T, F))

    def loss_fn(params):
        output = model.apply(params, x)
        return jnp.mean(output ** 2)  # Simple loss for gradient testing

    grads = jax.grad(loss_fn)(params)

    # Check every parameter has non-zero gradient
    for name, grad in jax.tree_util.tree_leaves_with_path(grads):
        assert jnp.any(grad != 0), f"Zero gradient for {name}"
        assert jnp.all(jnp.isfinite(grad)), f"Non-finite gradient for {name}"
```

### Gate 3: Overfit Validation
**Purpose**: If the model can't overfit 5 samples in 100 steps, nothing else matters. This is the most informative single test for research code.

**What to check:**
- Take 5 samples from the dataset (or generate 5 synthetic samples)
- Train for 100 steps on just these samples
- Loss MUST decrease significantly (not just fluctuate)
- If loss doesn't decrease: the model/loss/optimizer combination is fundamentally broken

**Write to**: `scratch/{investigation}/tests/test_overfit.py`

```python
# Template
def test_overfit_small_batch():
    """Model must be able to overfit 5 samples — if this fails, nothing else matters."""
    # Take 5 samples
    batch = get_small_batch(n=5)

    # Train for 100 steps
    initial_loss = compute_loss(params, batch)
    final_params = train_n_steps(params, batch, n_steps=100)
    final_loss = compute_loss(final_params, batch)

    # Loss must decrease significantly
    assert final_loss < initial_loss * 0.1, (
        f"Failed to overfit: initial={initial_loss:.4f}, final={final_loss:.4f}"
    )
```

### Gate 4: Regression Validation
**Purpose**: Verify that existing configs produce identical output before and after the change.

**What to check:**
- Dispatch the regression-guard agent on the modified files
- For each existing config: run inference with fixed seed, compare output to baseline
- Any difference in output for existing configs is a regression

**Implementation**: Delegate to the regression-guard subagent with the list of changed files and existing configs.

## Gate 3 Presentation Format

After running validation gates, present results to the user:

**If all gates pass:**
> "All 4 validation gates passed for [component]. Shape ✓, Gradient ✓, Overfit ✓, Regression ✓. Moving to next component?"

**If any gate fails:**
```markdown
## Validation Results: [Component]

### Passed
- ✓ Shape validation: output (B, T, D) as expected
- ✓ Gradient flow: all parameters receive non-zero gradients

### Failed
- ✗ Overfit test: loss decreased from 2.3 to 1.8 (only 22% reduction in 100 steps)
  - Expected: >90% reduction
  - Possible causes: learning rate too low, loss term dominating, gradient blocked

### My Assessment
[Interpretation of results and suggested next step]

### Question
[Ask user how to proceed — fix the failure or investigate further?]
```

## Important

- **Overfit test is the most informative single test.** If a model can't memorize 5 samples, there's a fundamental bug. Don't waste time on downstream validation.
- **These are validation scripts, not a test suite.** They live in scratch/ (gitignored). They're for verifying this specific implementation, not permanent tests.
- **For researchers who want TDD**: Use Superpowers' TDD skill for infrastructure code. Research-validation handles the ML-specific validation that TDD can't.
- **Don't skip regression testing.** "I only changed one file" — but that file is imported by 15 others. Always run regression-guard.
