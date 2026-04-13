---
name: monitor
description: >
  [Propel] Self-monitoring loop for long-running training runs or multi-step command chains.
  Use when the user says "/monitor", "watch this run", "keep an eye on", "monitor training",
  "run this and make sure it finishes", or hands off a chain of commands and wants Claude
  to supervise until a goal is met. Clarifies the success criteria first, prints them as
  a reference checklist for the user, then iterates: inspect progress, debug issues,
  check against the checklist, and loop until requirements are satisfied or a hard
  blocker is hit. TOKEN-COSTY — requires explicit user go-ahead before entering the loop.
---

# Monitor — Supervised Self-Monitoring Loop

This skill turns Claude into a patient supervisor for work that takes time:
training runs, sweeps, deploy pipelines, multi-step command chains. It does
**not** just poll mindlessly — it clarifies what "done" means, shows the user
that understanding, and then loops with explicit exit criteria.

## Cost Warning (MANDATORY — do this before anything else)

Before entering the monitoring loop, **always** surface the cost tradeoff:

> Heads up — /monitor runs an iterative check-debug-verify loop. Each iteration
> reads progress (logs, metrics, command output), evaluates against the checklist,
> and may dispatch debuggers. This can consume substantial tokens, especially on
> long training runs. Continue? (reply "go" to proceed, or adjust the plan.)

Do not enter the loop until the user explicitly confirms. If they decline, offer
a lighter alternative: a one-shot inspection, or a scheduled check via
`ScheduleWakeup` / the native `loop` skill.

## Phase 1 — Clarify Requirements (before any loop)

1. Parse what the user asked for. If ambiguous, ask up to 3 focused questions.
2. Extract a **success checklist**: each item must be concrete and observable.
   - Bad: "training goes well"
   - Good: "loss < 0.4 after 10k steps, no NaN in last 500 steps, eval accuracy ≥ baseline 0.72"
3. Extract **hard blockers** (non-recoverable failures that terminate the loop):
   OOM, process killed, corrupted checkpoint, auth expired, etc.
4. Extract **soft failures** (debuggable): loss plateau, exploding grads, stuck stage.
5. Set a **max-iterations** budget (default 10) and a **per-iteration delay**
   (default: self-pace via ScheduleWakeup, 5–20 min between checks depending on
   run duration).

Print the reference card to the user:

```
┌─ /monitor plan ─────────────────────────────────────────┐
│ Goal:        <one line>                                 │
│ Success criteria:                                       │
│   [ ] <item 1>                                          │
│   [ ] <item 2>                                          │
│ Hard blockers (terminate loop):                         │
│   • <item>                                              │
│ Debuggable failures (try to fix):                       │
│   • <item>                                              │
│ Budget: up to N iterations, ~M min between checks       │
└─────────────────────────────────────────────────────────┘
```

Wait for user confirmation or edits before starting the loop.

## Phase 2 — The Loop

Each iteration performs these steps in order. Record progress in
`scratch/monitor/{YYYY-MM-DD}-{short-name}/log.md` so the user has an audit trail.

1. **Inspect**: read the authoritative progress source (log file, metric endpoint,
   `nvidia-smi`, `squeue`, process status, last N lines of stdout). Prefer
   cheap reads (tail, head, grep) over full re-reads.
2. **Evaluate against the checklist**: for each success criterion, mark met /
   not-yet / regressed.
3. **Decide**:
   - All criteria met → **exit with success**, summarize outcome for user.
   - Hard blocker hit → **exit with failure**, explain what went wrong and
     propose next action. Do not attempt auto-recovery of hard blockers.
   - Soft failure detected → dispatch a debugger (silent-bug-detector,
     systematic-debugging skill, failure-mode-researcher) with the specific
     symptom. Apply the fix or surface the fix to the user for approval if
     it touches state the user cares about (code, configs, live infra).
   - Still in progress, no issue → schedule next check with ScheduleWakeup at
     the chosen interval.
4. **Check budget**: if iterations ≥ max, stop and report status; do not silently
   keep going.

## Phase 3 — Exit Protocol

On exit (success, failure, or budget exhaustion), always produce:

- **Outcome**: one line (met / partial / failed / timeout)
- **Checklist with final marks**
- **What I did**: iterations, debug actions taken, what changed
- **What's left** (if partial)
- **Suggested next step**

If the run produced learnings, recommend `/retrospective` to capture them.

## Guardrails

- Do not modify production infrastructure, push to remotes, or run destructive
  commands inside the loop without explicit per-action user approval. The loop
  has authority to *read* and *diagnose*; destructive *write* requires a human.
- Do not claim success just because nothing crashed. Always evaluate against the
  checklist the user confirmed — silence is not victory.
- If the user's success criteria turn out to be ill-formed once real progress
  data arrives, pause and renegotiate. Don't keep marching toward the wrong goal.
- Every iteration log must be short (2–5 lines). The point of the log is audit,
  not narrative.

## Related

- `/retrospective` — capture learnings after the loop ends.
- `think-deeply` — if the user's success criteria seem to assume a conclusion,
  push back before starting the loop.
- `systematic-debugging`, `silent-bug-detector` — dispatched on soft failures.
