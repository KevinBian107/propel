[Propel] Turn off the automatic dual-model layer for this project.

By default, Propel consults OpenAI Codex automatically at every major decision
point — Gate 0 scope, Gate 1 findings, Gate 2 design, Gate 3 audit, Gate 4
diagnosis, bug classification, 3-strike breaks, and retrospective conclusions.
This command turns that off.

## Process

1. **Ensure `.propel/` exists** at the project root.

2. **Write `.propel/codex.json`:**

```json
{
  "enabled": false,
  "disabled_at": "<ISO 8601 timestamp>",
  "reason": "<what the user said, or 'user request'>"
}
```

Preserve any other keys already in the file (e.g. `available`).

3. **Confirm, briefly:**

> Codex is off for this project. Propel now runs single-model — gates, questioners,
> and auditors all still fire, you just won't get the second opinion at them.
>
> Turn it back on with `/enable-codex`.

4. **From now on in this session:** do not consult Codex, and do not mention
   Codex again. A disabled feature that keeps advertising itself is worse than
   one that stays on. The single exception is one `◇ Codex disabled —
   single-model gate.` line at the first gate of each session, so the user
   always knows which regime they are working in.

## Why someone turns this off

Take the reason seriously if they give one — it is usually diagnostic:

- **"It's too slow"** — each consult adds a round-trip, and Gate 3 is the one
  that fires most often. Offer the middle ground before the off switch: keep it
  on, but raise the Gate 3 threshold so only substantial diffs pay for it.
- **"It's noisy / it always agrees"** — that is a real failure of the layer. Two
  models agreeing is weak evidence and should be reported as one line, not as a
  section. If it is producing agreement theatre, turning it off is correct.
- **"Privacy / this code can't leave the machine"** — completely legitimate, and
  the right call. Briefs sent to Codex leave the local machine. Don't argue.
- **"Not installed"** — this is a *different* problem. Don't disable; point them
  at `propel launch`, which installs and links Codex in a couple of clicks.
