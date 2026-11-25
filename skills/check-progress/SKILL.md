---
name: check-progress
description: >
  [Propel] Read-only status of the task ledger: training runs, plan tasks and monitor
  loops recorded in .propel/tasks/. Use when the user says "check progress", "what's
  running", "status of my jobs", "status of my runs", "status of my tasks", "what's
  left", "where was I", "is my training done", "did my run finish", "what did we leave
  open". Also auto-use at session start when the hook lists open tasks from earlier
  sessions and the user's first message is about continuing ("let's continue", "pick up
  where we left off"). Cheap: one script call, prints a table. Never changes a task's
  state without the user's answer, never restarts a job, never edits code.
---

# Check Progress — What's In Flight

One read of the task ledger, shown as-is, then the user decides what happens to
anything left open. This skill produces information; every state change is a
human decision.

## Step 1 — Show the table

```bash
R=$PWD; while [ "$R" != / ] && [ ! -f "$R/.claude/scripts/task-queue.sh" ]; do R=$(dirname "$R"); done; [ -f "$R/.claude/scripts/task-queue.sh" ] && cd "$R"
bash .claude/scripts/task-queue.sh list --table --sessions 10
```

Then, as its own command, `printenv PROPEL_SESSION` (no `$` expansion, so it
needs no extra permission): it prints this session's id, or nothing if it is unset.
The Bash tool reports the list command's exit status itself when it is non-zero.

The table lists every open task, plus finished ones from the newest 10 session
files of the last 14 days.

Check the exit status first, then read the output:

- **exit 5**: part of the ledger couldn't be read, so the output is incomplete,
  even if it says `No tasks recorded.`. Show what printed, quote the error line,
  and continue with what's there.
- **exit 0** with `No tasks recorded.` (or nothing): say "Nothing in the task
  ledger." in one line and stop.
- **No `.claude/scripts/task-queue.sh` found**: Propel isn't installed in this
  project. Say so in one line (`propel init` installs it) and stop.

Otherwise print the table unchanged. Don't reorder, summarize or drop rows. In the
Session column, `(this)` is this session, `(carried here)` was carried into it, and
an unmarked row belongs to an earlier session. If `printenv PROPEL_SESSION` printed nothing, say the
session markers are unavailable, so this session's own tasks may look like they
came from an earlier session.

When the script reads a done/failed result from a run's exit file, it records that
result during this read. That's the script settling a result, not this skill
changing state.

## Step 2 — What needs a decision (≤ 3 lines)

Name the ids by status. Skip any status with no rows:

- **lost**: the screen/tmux session is gone and no exit file was written (killed,
  node rebooted). Read its log (see "Finding a task's log").
- **unknown**: no evidence recorded either way (no exit file, no screen/tmux).
- **failed** / **blocked**: the run failed, or the goal wasn't met. Someone has to
  choose the next step.

If nothing is lost, unknown, failed or blocked, say "Nothing needs a decision." and
go to Step 3.

## Step 3 — Earlier-session tasks: ask, don't act

Only if open rows (running, blocked, lost, unknown) belong to an earlier session.
Ask **one** disjunctive question per batch, with AskUserQuestion if available,
otherwise in plain text. Group the tasks with the same likely answer:

> Tasks t…, t… are open from an earlier session. Which?
> - **Carry**: resume them here. They show as `(carried here)` and this session
>   owns the follow-up.
> - **Abandon**: close them. They leave the start-of-session list for good.
>   Nothing is killed, but the record of an unfinished run stops prompting anyone.
> - **Leave open**: no change. They appear at every session start until someone
>   decides.

If `printenv PROPEL_SESSION` printed nothing, offer only abandon or leave open. Carry needs a session.

Act only on the ids the user named. No answer means leave open. Run each command
in the same Bash call as the walk-up line:

```bash
R=$PWD; while [ "$R" != / ] && [ ! -f "$R/.claude/scripts/task-queue.sh" ]; do R=$(dirname "$R"); done; [ -f "$R/.claude/scripts/task-queue.sh" ] && cd "$R"
bash .claude/scripts/task-queue.sh carry <ID>
bash .claude/scripts/task-queue.sh abandon <ID> --note "<user's reason>"
```

If a command fails:
- **exit 2**: no session id, so nothing was recorded. Say carry isn't available
  in this session.
- **exit 3**: the ledger is busy. Say so and offer to retry. Never run `unlock`
  unless the user asks for it.
- **exit 4**: unknown id. Re-run Step 1 and check the id against the table.

Don't restart, relaunch, kill or "fix" anything here. If the user wants a run
restarted, that's trainer-mode's job.

## Finding a task's log

A task's `start` event records its `log`, `screen` and `exit_file`:

```bash
grep -h '"ev":"start","id":"<ID>"' .propel/tasks/*.jsonl
```

Read the `"log"` field (stored as an absolute path). Train tasks launched by trainer-mode log to
`.propel/runs/<NAME>.log`. If the user asks how a running `train` task is doing,
show the last lines with `tail -n 20 <log>` and say what they show (step, loss,
last error). Don't start a monitoring loop. That's `/monitor`, and it asks first.

## In the terminal

`propel tasks` prints the same kind of table outside Claude, but only open tasks by
default. `propel tasks --all` adds finished ones, and with `--all`,
`--sessions N` sets how many recent session files they come from.

## Related

- `trainer-mode`: launches the `train` tasks listed here.
- `monitor`: supervises one run until its goal is met.
