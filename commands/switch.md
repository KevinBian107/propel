[Propel] Switch between Propel modes (Researcher, Engineer, Debugger, Trainer).

Usage: `/switch $ARGUMENTS`

Where `$ARGUMENTS` is one of: `researcher`, `engineer`, `debugger`, `trainer`

---

## Process

### 1. Validate input

If `$ARGUMENTS` is empty or not one of `researcher`, `engineer`, `debugger`, `trainer` (case-insensitive), show:

```
Available modes:
  researcher — Focus on understanding the problem space. Literature, investigation, and deep research skills only. Gates 0 and 1.
  engineer   — Full pipeline. All skills and gates active. (Default mode.)
  debugger   — Deep root-cause analysis with evidence-backed diagnosis. Gates 0, 1, and 4.
  trainer    — Training execution and runtime debugging. No investigation or design phases.

Usage: /switch researcher | /switch engineer | /switch debugger | /switch trainer
```

Then stop — do not proceed.

### 2. Read current mode

Check if `.propel/mode.json` exists. If it does, read the current mode to record as `previous_mode`.

### 3. Write mode file

Ensure `.propel/` directory exists. Write `.propel/mode.json`:

```json
{
  "mode": "<selected_mode>",
  "switched_at": "<ISO 8601 timestamp>",
  "previous_mode": "<previous mode or null>"
}
```

### 4. Deliver mode-specific welcome

**If switching to Researcher:**

> **Researcher Mode active.**
>
> Active skills: investigation, deep-research, paper-extraction, think-deeply, retrospective, context-hygiene, project-customization.
> Active gates: Gate 0 (Intake), Gate 1 (Post-Investigation).
>
> Implementation and debugging skills are paused. If you need to build or fix code, use `/switch engineer`.
>
> What's the research question driving this session?

**If switching to Engineer:**

> **Engineer Mode active.**
>
> Full pipeline active — all skills, gates, and auditors are available.
> This is the default Propel experience: Intake → Investigation → Design → Implementation → Validation → Debugging → Retrospective.
>
> What are you working on? What outcome would make this session successful?

**If switching to Debugger:**

> **Debugger Mode active.**
>
> Active skills: investigation, systematic-debugging, deep-research, paper-extraction, think-deeply, retrospective, context-hygiene, verification-before-completion, project-customization.
> Active gates: Gate 0 (Scope the Bug), Gate 1 (Investigation Findings), Gate 4 (Before Fix).
> Active agents: All auditors for diagnosis.
>
> I'll classify every issue as a code bug, design issue, or configuration problem — with solid evidence to back up the claim. For design issues, I'll search the literature for similar problems and validated alternatives.
>
> What's going wrong? Describe the symptom — what you see, what you expected, and when it started.

**If switching to Trainer:**

> **Trainer Mode active.**
>
> Active skills: trainer-mode, think-deeply, retrospective, context-hygiene, project-customization.
> Active gate: Gate 4 (runtime bugs only).
>
> I can launch training, fix runtime errors (CUDA, OOM, paths, imports, configs), and monitor runs. For logic changes (architecture, loss, data pipeline), use `/switch engineer`.
>
> Let me scan your project for training commands...

Then immediately activate the **trainer-mode** skill Phase 1 (Training Command Detection) — scan for training scripts, configs, and entry points without waiting for further input.

### 5. No /clear needed

The mode switch takes effect immediately. The using-propel skill will read the updated `.propel/mode.json` and route accordingly. No need to restart the session.
