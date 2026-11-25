[Propel] Turn docs prompts back on for this project.

## Process

1. **Ensure `.propel/` exists** at the project root.

2. **Write `.propel/docs.json`**, preserving other keys:

```json
{
  "enabled": true,
  "enabled_at": "<ISO 8601 timestamp>"
}
```

3. **Confirm, briefly:**

> Docs prompts are back on. After a component passes its audits (Gate 3), after
> validation passes, after a retrospective, and when an edit touches a file that
> docs pages mention, I'll ask one question: whether to update the pages that
> cover the change, and what each update would cover. Nothing in the docs
> changes until you answer.

## Related

- `/disable-make-documentations` — stop the prompts again
- `make-documentations` skill — what runs after you choose to update the docs
