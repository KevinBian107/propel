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

## Phase 1.5: Delegate to `trainer-operator`

Once the human has approved the exact command, **dispatch the `trainer-operator`
subagent** rather than launching and tailing the log yourself.

This is not ceremony. Monitoring is context-toxic: a training log is thousands of
near-identical lines, and pulling them into the main conversation pushes out the
design decisions and investigation findings that the session actually needs to
keep. The operator absorbs the log in its own context and returns a status card.

Give it, explicitly:

- the **exact approved command**, verbatim
- the **discretion range** — what it may adjust without asking (e.g. "batch size
  may go down to 32, nothing else"). If you give it no range, it has none.
- the run name and output directory (the console log always goes to
  `.propel/runs/<NAME>.log`, see Phase 2)
- what "healthy" looks like: expected first-loss magnitude, expected throughput
- the **ledger session**: the value `echo "$PROPEL_SESSION"` prints, so the
  operator can record the run with `start --session <value>` (a subagent may not
  inherit the variable). If it prints nothing, say so: the run is then not
  tracked in the task ledger.

It will escalate anything that would change what the experiment measures. When it
does, that comes back to the human as an Engineer-Mode question, not as a patch.

The phases below are what the operator executes — and what you do yourself if the
run is short enough that delegation costs more than it saves.

## Phase 2: Screen Session Management

### Launch training

1. **Detect OS and terminal multiplexer**:
   - Check for `screen` availability: `which screen`
   - If not found and on macOS: suggest `brew install screen` or fall back to `tmux`
   - If not found and on Linux: suggest `apt install screen` or `yum install screen`

2. **Record and launch, in one Bash call.** `<NAME>` is
   `propel-train-<YYYYmmdd-HHMMSS>` (`date +%Y%m%d-%H%M%S`; letters, digits, `-`
   and `_` only, since tmux rewrites `.` and `:`). Write it out literally in every
   command, because shell variables do not survive between Bash calls. `<CMD>` is
   the exact confirmed command. When you delegate, the operator runs this itself.
```bash
O=$PWD; R=$PWD; while [ "$R" != / ] && [ ! -f "$R/.claude/scripts/task-queue.sh" ]; do R=$(dirname "$R"); done; [ -f "$R/.claude/scripts/task-queue.sh" ] && cd "$R"
[ ! -e .propel/runs/<NAME>.sh ] || { echo "<NAME> is taken, pick a new name"; exit 1; }
mkdir -p .propel/runs && printf 'cd %q || exit 1\n' "$O" > .propel/runs/<NAME>.sh && cat >> .propel/runs/<NAME>.sh <<'PROPEL_CMD'
<CMD>
PROPEL_CMD
ID=$(bash .claude/scripts/task-queue.sh start --kind train --title "<short title>" --screen <NAME> --log .propel/runs/<NAME>.log --exit-file .propel/runs/<NAME>.exit --cmd '<CMD>') || ID="not tracked in the task ledger"
screen -dmS <NAME> bash -c 'set -o pipefail; bash .propel/runs/<NAME>.sh 2>&1 | tee .propel/runs/<NAME>.log; echo $? > .propel/runs/<NAME>.exit' || echo "launch failed"
echo "task: $ID"
```
   - **The command always goes in `.propel/runs/<NAME>.sh`**, verbatim, through
     the quoted heredoc, so no quoting rule depends on what it contains. The
     closing `PROPEL_CMD` must start at column 0. The file is the record of the
     approved command. Its first line `cd`s back to the directory the Bash
     call started in, so the command runs where it would have run by hand. The
     ledger and the run files live at the project root.
   - **`--cmd` rule:** pass `--cmd '<CMD>'` only when the command is one line
     with no single quote. Otherwise replace it with
     `--note "command: .propel/runs/<NAME>.sh"`.
   - **`start` runs first**, while the exit file cannot exist yet, because a run
     that dies within milliseconds would otherwise write its `.exit` before
     `start` checks for one. `start` never gates the launch. The ledger is
     advisory: if it fails (no session, ledger busy, anything), the block prints
     "not tracked in the task ledger" and launches anyway.
   - `pipefail` applies only to the outer `| tee`, so the recorded exit code is
     the command's own instead of `tee`'s. Pipelines inside the user's command
     behave exactly as written, because Propel never changes the approved
     command.
   - Output goes through a pipe to `tee`, so Python may block-buffer it and the
     log can lag behind the run. Do not edit the command to fix that. Tell the
     user that `PYTHONUNBUFFERED=1` or `python -u` would make the log live, and
     let them decide.
   - The session closes when the command ends. After that, the log is the post-mortem record
     and `<NAME>.exit` holds the exit code. Status comes from that evidence:
     `<NAME>.exit` exists → done (exit 0) or failed. Session alive → running.
     Session gone and no exit file → lost.
   - If the block prints "launch failed", the task derives to lost. Close it:
     `bash .claude/scripts/task-queue.sh done <ID> --status failed --note "launch failed"`.
     Run this and every other ledger command from the project root, with the
     same walk-up line that starts the block.

3. **Critical rules**:
   - Execute the EXACT command the user confirmed — no modifications
   - Do NOT create temporary folders (`.propel/runs/` for the command file, log
     and exit file is the only directory you create)
   - Do NOT disable wandb or any logging
   - Do NOT add wrapper scripts (the only exception: `.propel/runs/<NAME>.sh`,
     which holds the confirmed command verbatim)
   - Do NOT modify environment variables unless the user explicitly requests it

4. **Report to user**:
   ```
   Training launched in screen session: <NAME>
   Task:    <task id> (the check-progress skill lists it) | not tracked in the task ledger

   Attach:  screen -r <NAME>
   Detach:  Ctrl+A, then D
   List:    screen -ls
   Command: .propel/runs/<NAME>.sh
   Log:     tail -n 50 .propel/runs/<NAME>.log
   Result:  .propel/runs/<NAME>.exit (exit code; appears when the command ends)
   Kill:    screen -X -S <NAME> quit   (writes no exit file, so the task shows as lost)
   ```

### If using tmux (fallback)

Use the same block, with the `screen -dmS` line replaced by:

```bash
tmux new-session -d -s <NAME> "bash -c 'set -o pipefail; bash .propel/runs/<NAME>.sh 2>&1 | tee .propel/runs/<NAME>.log; echo \$? > .propel/runs/<NAME>.exit'" || echo "launch failed"
```

Your shell expands the outer double quotes before tmux sees them, which is why
`$?` is written `\$?`. The command itself is in the `.sh` file, so nothing else
needs escaping. Report `tmux attach -t <NAME>`, detach with Ctrl+B then D,
`tmux ls`, and `tmux kill-session -t <NAME>` (no exit file, so the task shows as
lost), plus the Task, Command, Log and Result lines.

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

1. **Read the traceback** from the log, `tail -n 100 .propel/runs/<NAME>.log`. The
   screen session closes when the command ends, and `<NAME>.exit` holds the exit
   code.
2. **Classify**: Is this a runtime bug or a logic change?
   - Runtime → proceed to fix
   - Logic → deliver redirect message
3. **If runtime bug**:
   - Present the fix (Gate 4 lite): "The error is [X] because [Y]. I'll fix it by [Z]. This changes [file:line]. Okay?"
   - Wait for user confirmation
   - Apply the minimal fix — smallest change that resolves the error
   - Relaunch as a **new** run: a fresh `<NAME>` (new timestamp) and the Phase 2
     block, with `--ref <OLD_ID>` added to `start`. Then close the old task with
     `bash .claude/scripts/task-queue.sh done <OLD_ID> --status failed --note "<error signature>; relaunched as <NEW_ID>"`.
     Never reuse a name, because its old `.exit` would be read as the new run's
     result.
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
