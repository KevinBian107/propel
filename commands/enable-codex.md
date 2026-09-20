[Propel] Turn the automatic dual-model layer back on for this project.

## Process

1. **Ensure `.propel/` exists** at the project root.

2. **Write `.propel/codex.json`**, preserving other keys:

```json
{
  "enabled": true,
  "available": null,
  "enabled_at": "<ISO 8601 timestamp>"
}
```

Reset `available` to `null` so the next consult re-checks rather than trusting a
stale "not installed" verdict from an earlier session.

3. **Check that Codex can actually run:**

```bash
command -v codex && codex --version
```

- **Found** → confirm:
  > Codex is back on. From here, every major decision point gets a second model
  > before it reaches you: scope, findings, design, audits, diagnosis. I'll
  > announce each consult with a `◆ Consulting Codex` line and label every
  > finding with which model raised it.

- **Not found** → say so plainly and give the two routes:
  > Codex is enabled in config, but the `codex` CLI isn't on your PATH, so gates
  > will run single-model until it is. Fix it with `propel launch` (detects,
  > installs, and links your account), or manually:
  >
  > ```
  > npm install -g @openai/codex   # needs Node 18.18+
  > codex login
  > ```

Do not pretend the layer is active when the CLI is missing. An enabled flag over
a missing binary is exactly the kind of quiet gap Propel exists to surface.

## Related

- `/disable-codex` — turn it off again
- `propel launch` — install and link Codex from the setup console
- `codex-consult` skill — what actually runs at each gate
