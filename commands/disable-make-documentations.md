[Propel] Stop Propel from asking about docs updates in this project, until `/enable-make-documentations`.

By default, Propel asks one question at four points: after a component passes its
audits (Gate 3), after validation passes, after a retrospective, and when an edit
touches a file that docs pages mention. The question names the docs pages that
would change and what each update would cover, and nothing is written until the
user answers. This command turns that question off.

## Process

1. **Ensure `.propel/` exists** at the project root.

2. **Write `.propel/docs.json`:**

```json
{
  "enabled": false,
  "disabled_at": "<ISO 8601 timestamp>",
  "reason": "<what the user said, or 'user request'>"
}
```

Preserve any other keys already in the file.

3. **Confirm, briefly:**

> Docs prompts are off for this project. I won't ask about updating the docs, and
> I won't update them on my own. Say "document this" or "update the docs" any
> time and I'll still write them.
>
> Turn the prompts back on with `/enable-make-documentations`.

4. **From now on, in this session and later ones, until
   `/enable-make-documentations`:** never ask the docs question, and never write
   or update a docs page on your own. An explicit request ("document this",
   "write the docs", "update the docs") still runs the `make-documentations`
   skill. The single exception is one
   `◇ Docs prompts off — /enable-make-documentations to turn them back on.` line
   at the first docs trigger of each session, then silence.

The hooks enforce the same switch: while it is off, the auditor-dispatch hook
no longer adds its `[propel:docs]` line after an edit, and the per-turn routing
card carries a `docs prompts: off` line.

## Related

- `/enable-make-documentations` — turn the prompts back on
- `make-documentations` skill — what runs when you ask for docs
