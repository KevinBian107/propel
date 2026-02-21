---
name: trainer-mode
description: >
  [Propel] Training execution and runtime debugging skill. Activates in Trainer Mode.
  Scans for training commands, launches them in screen sessions, and fixes runtime bugs
  (GPU/CUDA errors, OOM, path errors, import errors, config typos). Does NOT fix logic
  changes (model architecture, loss functions, data pipelines) — suggests /switch engineer
  for those. Use when the user says "train", "launch training", "run training", "start
  training", "my training crashed", or when Trainer Mode is active.
---

# Trainer Mode — Training Execution & Runtime Debugging

This skill handles the full training lifecycle: finding training commands, launching them in persistent sessions, and fixing runtime errors that prevent training from running. It does NOT modify training logic.

## Phase 1: Training Command Detection

When Trainer Mode activates, immediately scan the project for training entry points.

### Scan targets

1. **Training scripts**: Glob for `train*.py`, `run*.py`, `main*.py` in the project root and common subdirectories (`scripts/`, `tools/`, `bin/`)
2. **Shell scripts**: Glob for `*.sh` in the project root, `scripts/`, `bin/`
3. **Package entry points**: Read `pyproject.toml` `[project.scripts]` section, `setup.py` `console_scripts`, `Makefile` targets
4. **Config files**: Glob for `configs/`, `conf/`, `config/` directories — list YAML/JSON/TOML files found
5. **README instructions**: Grep for "train", "run", "usage" in README.md for documented commands

### Present findings

Present results as a structured table:

```markdown
## Training Commands Detected

| Source | Command / File | Notes |
|--------|---------------|-------|
| Script | `python train.py --config configs/default.yaml` | Main training entry point |
| Makefile | `make train` | Wraps train.py with default args |
| pyproject.toml | `my-project train` | CLI entry point |

## Configs Found
- `configs/default.yaml`
- `configs/large.yaml`

## Environment
- **Python**: 3.11 (from pyproject.toml)
- **Framework**: PyTorch 2.1 / JAX 0.4 / etc.
- **CUDA**: [detected or unknown]
- **GPUs**: [from nvidia-smi if available]
- **wandb**: [configured / not found]
```

### Confirm with user

Ask: "Which command should I launch? And do you want to modify any arguments (e.g., config file, number of GPUs)?"

Do NOT proceed until the user confirms a specific command.

## Phase 2: Screen Session Management

### Launch training

1. **Detect OS and terminal multiplexer**:
   - Check for `screen` availability: `which screen`
   - If not found and on macOS: suggest `brew install screen` or fall back to `tmux`
   - If not found and on Linux: suggest `apt install screen` or `yum install screen`

2. **Create named screen session**:
   ```bash
   screen -dmS propel-train-{timestamp} bash -c '{EXACT_CONFIRMED_COMMAND}; exec bash'
   ```

3. **Critical rules**:
   - Execute the EXACT command the user confirmed — no modifications
   - Do NOT create temporary folders
   - Do NOT disable wandb or any logging
   - Do NOT add wrapper scripts
   - Do NOT modify environment variables unless the user explicitly requests it

4. **Report to user**:
   ```
   Training launched in screen session: propel-train-{timestamp}

   Attach:  screen -r propel-train-{timestamp}
   Detach:  Ctrl+A, then D
   List:    screen -ls
   Kill:    screen -X -S propel-train-{timestamp} quit
   ```

### If using tmux (fallback)

```bash
tmux new-session -d -s propel-train-{timestamp} '{EXACT_CONFIRMED_COMMAND}; exec bash'
```

Report equivalent tmux commands for attach/detach/list/kill.

## Phase 3: Runtime Bug Fixing

### Scope boundary — this is critical

**CAN fix (runtime bugs)**:
- GPU/CUDA errors (`RuntimeError: CUDA error`, `CudaError`, device mismatch)
- OOM errors (`RuntimeError: CUDA out of memory`, `torch.cuda.OutOfMemoryError`)
- Path errors (`FileNotFoundError`, `NotADirectoryError`, missing checkpoint paths)
- Dependency issues (`ImportError`, `ModuleNotFoundError`, version conflicts)
- Config typos (misspelled keys, wrong types, missing required fields)
- Environment issues (wrong Python version, missing env vars, venv not activated)
- Multi-GPU/DDP setup (`NCCL` timeouts, rank errors, `torch.distributed` init failures)
- Permission errors (`PermissionError` on log dirs, checkpoint dirs)

**CANNOT fix (logic changes)** — respond with the redirect message:
- Model architecture changes ("add a layer", "change the backbone")
- Loss function modifications ("try a different loss", "add a regularization term")
- Feature additions ("add gradient clipping", "add learning rate scheduling")
- Algorithm changes ("switch from Adam to SGD", "add warmup")
- Data pipeline changes ("augment differently", "change the dataloader")
- Hyperparameter tuning ("try a lower learning rate") — suggesting values is okay, but changing code is not

**Redirect message**: "That's a logic change, not a runtime bug. Switch to Engineer Mode with `/switch engineer` to get the full investigation-design-implement workflow for that change."

### Fixing process

1. **Read the traceback** — get the full error output from the screen session
2. **Classify**: Is this a runtime bug or a logic change?
   - Runtime → proceed to fix
   - Logic → deliver redirect message
3. **If runtime bug**:
   - Present the fix (Gate 4 lite): "The error is [X] because [Y]. I'll fix it by [Z]. This changes [file:line]. Okay?"
   - Wait for user confirmation
   - Apply the minimal fix — smallest change that resolves the error
   - Restart training in the same screen session
4. **If the same error recurs after 2 fixes**: Stop and reassess. "This error has come back twice. Let me take a deeper look before trying again."

## Phase 4: Thought-Promoting Prompts

Don't just wait passively for the user to report problems. Proactively prompt useful thinking.

### Before training

Ask these if the user hasn't addressed them:
- "What's your target metric for this run? Having a number in mind helps evaluate early."
- "Have you run a smoke test (a few steps on a small batch) to make sure the pipeline runs end-to-end?"
- "Is wandb/tensorboard configured? You'll want to monitor loss curves from the start."
- "Is this resuming from a checkpoint? If so, which one?"

### During training (when user checks in)

- If loss plateaus early: "Loss hasn't moved in [N] steps. Common causes: learning rate too low, data not shuffled, or a bug in the loss computation. Want me to check the logs?"
- Throughput: "What's your steps/second? If it's lower than expected, check DataLoader num_workers and pin_memory."
- Checkpointing: "Are checkpoints being saved? If training crashes at hour 8 without a checkpoint, you lose everything."

### Common pitfalls to flag

- **fp16/bf16 instability**: "If you're using mixed precision, watch for NaN in the first 100 steps. bf16 is more stable than fp16 for most training."
- **Multi-GPU linear scaling rule**: "With [N] GPUs, effective batch size is [N]x. You may need to scale learning rate by sqrt([N]) or linearly."
- **Missing warmup**: "If loss spikes at the start and never recovers, try adding learning rate warmup (100-1000 steps)."
- **Gradient accumulation math**: "With gradient_accumulation_steps=[N], your effective batch size is batch_size * N * num_gpus. Make sure the learning rate accounts for this."
