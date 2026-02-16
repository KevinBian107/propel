Trace tensor shapes through the code path specified in $ARGUMENTS.

$ARGUMENTS should be an entry point (function name, file path, or description like "training forward pass" or "env.step through policy").

## Process

1. **Find the entry point** — locate the function or code path described in the arguments. If ambiguous, list candidates and ask.

2. **Trace forward from input to output**, documenting every intermediate tensor:

```
[function/operation] @ file:line
  input:  (axis1=N, axis2=M, ...) dtype  — semantic meaning
  output: (axis1=N, axis3=K, ...) dtype  — semantic meaning
  notes:  [what changed and why]
```

3. **At every step, record:**
   - Shape with **semantic axis labels** (batch, time, envs, joints, xyz, hidden, heads, etc.) — never just numbers
   - dtype (float32, int64, bool, etc.)
   - What the operation does to the shape (which axes are consumed, created, reshaped, transposed)
   - Any broadcasting that happens implicitly

4. **At branches**, trace both paths:
   - Where does the tensor fan out to multiple consumers?
   - Where do tensors merge back (concat, add, multiply)?
   - What axes are used for concatenation/stacking?

5. **Flag any concerns:**
   - Reshapes that could silently swap axis semantics
   - Implicit broadcasting between tensors of different ranks
   - Squeeze/unsqueeze that assumes a specific axis position
   - Hardcoded dimension indices that would break if batch/time ordering changes

## Output

Print the full shape trace as a readable chain. Example:

```
## Shape Trace: training forward pass

obs = env.step(action) @ envs/vectorized.py:45
  output: (envs=16, obs_dim=24) float32 — joint angles + velocities

encoded = encoder(obs) @ models/encoder.py:12
  input:  (envs=16, obs_dim=24) float32
  output: (envs=16, hidden=128) float32
  notes:  Linear(24→128) + ReLU

...

⚠ WARNING @ models/decoder.py:38
  reshape (envs=16, hidden=128) → (16, 8, 16) — hardcoded dims, unclear axis semantics
```

Keep it concise — this is a quick reference, not a full audit. If a deeper audit is needed, suggest using the Data Flow Tracer or JAX Logic Auditor subagents.
