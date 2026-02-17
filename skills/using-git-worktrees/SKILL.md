---
name: using-git-worktrees
description: >
  [Propel] Guides the use of git worktrees for experiment branch isolation.
  Use when the user says "create a worktree", "experiment branch", "isolate this experiment",
  "work on a separate branch", or when starting a new implementation that could break
  existing functionality. Ensures worktrees are properly set up with dependencies installed
  and baselines verified before making changes.
---

# Using Git Worktrees — Experiment Branch Isolation

## When to Use Worktrees

- Starting a new experiment that modifies core model/training code
- Implementing a paper-derived feature that might break existing configs
- Any change where you want to easily compare "before" and "after" side by side
- Working on multiple experiment variants in parallel

## Setup Process

### 1. Create the Worktree

```bash
# Naming convention: include experiment identifier
git worktree add ../worktrees/{experiment-name} -b experiment/{experiment-name}

# Example:
git worktree add ../worktrees/rvq-depth2-rotation -b experiment/rvq-depth2-rotation
```

**Naming convention**: `experiment/{descriptive-name}` — include the key variables being tested (e.g., `rvq-depth2-rotation`, `fsq-8bit-no-commitment`, `ppo-gae-lambda-sweep`).

### 2. Verify Gitignore

Ensure the worktree directory is gitignored:
```bash
# Check that worktrees/ is in .gitignore
grep -q "worktrees/" .gitignore || echo "worktrees/" >> .gitignore
```

### 3. Install Dependencies

```bash
cd ../worktrees/{experiment-name}
# Use the same dependency manager as the main repo
pip install -e .  # or uv sync, or conda env create, etc.
```

### 4. Run Baseline

Before making any changes in the worktree, verify that the baseline works:
```bash
# Run existing tests
pytest

# Run a short training to verify baseline metrics
python train.py --config configs/baseline.yaml --max_steps 100
```

Record baseline metrics — you'll compare against these after your changes.

## Working in a Worktree

- Make all experimental changes in the worktree, not the main checkout
- The main checkout remains clean for comparison and as a fallback
- You can switch between worktrees instantly (they're separate directories)
- Each worktree has its own `scratch/` directory for investigation artifacts

## Comparing Results

```bash
# Compare file differences between main and experiment
diff ../main-checkout/model/encoder.py ../worktrees/{experiment}/model/encoder.py

# Compare training metrics
# (use your project's specific metric comparison tooling)
```

## Cleanup

After the experiment is complete (merged or abandoned):

```bash
# Remove the worktree
git worktree remove ../worktrees/{experiment-name}

# Delete the branch if abandoned
git branch -d experiment/{experiment-name}
```

## Important

- **Always verify baseline before changing anything.** If the baseline fails in the worktree, your experimental results are meaningless.
- **Keep the main checkout clean.** Don't make experimental changes there — it's your known-good reference.
- **One experiment per worktree.** Don't mix unrelated changes — it makes it impossible to attribute results to specific changes.
- **Document what you changed.** The investigation README should note which worktree/branch contains the experimental code.
