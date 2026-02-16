# Auditor Dispatch Logic

After each implementation task, dispatch the appropriate auditors based on what was changed.

## Dispatch Rules

### Always Run
- **regression-guard**: After every code change, no exceptions. Verify existing configs produce identical results.

### Conditional Dispatch

| Condition | Auditor | What to Provide |
|-----------|---------|-----------------|
| Implemented a paper equation or algorithm | **paper-alignment-auditor** | Paper notes + implemented files |
| Modified JAX transforms (jit, vmap, scan, pmap) | **jax-logic-auditor** | Modified files + calling context |
| Modified model, loss function, or data pipeline | **silent-bug-detector** | Modified files + training config |
| Deep trace requested or shape issues suspected | **data-flow-tracer** | Entry point + pipeline files |
| Stuck on unexplained failure | **failure-mode-researcher** | Symptom + what was tried |

### Parallel Execution

Auditors that don't depend on each other can run in parallel:
- paper-alignment-auditor + jax-logic-auditor + silent-bug-detector can run simultaneously
- regression-guard should run last (needs final state of all changes)
- failure-mode-researcher runs on demand, not automatically

## Context for Each Auditor

Each auditor is a subagent with no conversation history. Include in its prompt:

1. **What changed**: List of files modified, what was added/changed
2. **What it implements**: Paper reference, design intent
3. **What to check**: Specific concerns based on the dispatch rule
4. **Relevant files**: Full content of files to audit (auditors can't read files not provided)

## Collecting Results

After all dispatched auditors return:

1. Merge results into a single audit report
2. Categorize: Passed / Issues Found / Suspicious Patterns
3. For issues: include auditor name, specific finding, severity, location
4. Present to user via Gate 3

## Example Dispatch

For a task implementing a new VQ-VAE loss term from a paper:

```
Dispatch:
1. paper-alignment-auditor — check loss equation matches paper eq. 5
2. silent-bug-detector — check for wrong reduction axis, missing loss term, gradient flow
3. jax-logic-auditor — check shapes through vmap/scan boundaries
4. regression-guard — verify existing VQ-VAE config produces identical output

Provide each with:
- The implemented loss function (full file content)
- The paper notes for eq. 5 (from scratch/paper-notes/)
- The existing loss function (before changes, for regression comparison)
- The training config (for regression guard)
```
