---
name: project-customization
description: >
  [Propel] Builds a persistent project profile in .propel/ by analyzing code conventions,
  domain context, and development patterns. Use when the user says "customize Propel",
  "analyze my project", "detect conventions", "update profile", or during /propel:intro
  Part 3 (opt-in). Creates config.json, profile.md, conventions.md, and domain-context.md
  that Claude references silently on every session start.
---

# Project Customization — Automatic Project Profiling

Build a persistent, machine-readable project profile that Claude references on every session. The profile lives in `.propel/` (gitignored) and captures conventions, domain context, and development patterns that would otherwise need to be re-explained each session.

## When This Skill Activates

- During `/propel:intro` Part 3 (opt-in offer)
- User says "customize Propel", "analyze my project", "detect conventions", "update profile"
- User says "refresh profile", "re-analyze project", "update conventions"

## Decision: First Run vs. Update

Check if `.propel/config.json` exists:

- **Does not exist** → Full analysis (Phase 1-6 below)
- **Exists** → Fast path (see "Subsequent Runs" section below)

---

## First Run — Full Analysis

Run all 6 phases sequentially. Present results after Phase 6 for user confirmation before writing.

### Phase 1: Project Structure Scan

Use Glob and Read to gather:

- **Language**: Check for `pyproject.toml`, `setup.py`, `Cargo.toml`, `package.json`, `go.mod`, `CMakeLists.txt`
- **Framework**: Identify from imports/deps (JAX, PyTorch, TensorFlow, React, FastAPI, etc.)
- **Dependencies**: Read the dependency file, extract key packages
- **Directory layout**: Run `tree -L 3 -d` (via Bash) to get structure
- **Build tools**: Check for `Makefile`, `justfile`, `tox.ini`, `nox`, CI configs
- **Package manager**: pip, uv, conda, poetry, cargo, npm, pnpm

Record findings as structured notes for Phase 6.

### Phase 2: Code Style Analysis

Scan 5-10 representative source files (prioritize recently modified, non-test files):

- **Naming conventions**: snake_case vs camelCase for functions, classes, variables, constants
- **Import style**: absolute vs relative, grouping pattern, star imports
- **Formatting**: indentation (tabs/spaces, width), line length, trailing commas
- **Type hints**: present/absent, style (built-in generics vs typing module), return type coverage
- **Error handling**: exceptions vs Result types, custom exception hierarchy
- **Docstring style**: Google, NumPy, reST, or none
- **String style**: single vs double quotes, f-strings vs format()

Record specific examples (file:line) for each finding.

### Phase 3: Domain Detection

Classify the project's domain from imports and structure:

| Signal | Domain |
|--------|--------|
| `jax`, `flax`, `optax`, `equinox` | JAX/ML |
| `torch`, `lightning`, `transformers` | PyTorch/ML |
| `mujoco`, `gymnasium`, `dm_control`, `robosuite` | Robotics/RL |
| `react`, `next`, `vue`, `angular` | Frontend |
| `fastapi`, `django`, `flask`, `express` | Backend/API |
| `numpy`, `scipy`, `pandas`, `matplotlib` | Scientific computing |
| `ros`, `rclpy` | ROS/Robotics |

**Agent delegation** (selective, only when warranted):

- If simulation/RL environment detected → delegate to **env-researcher** agent to fetch environment documentation, write findings to `.propel/domain-context.md`
- If a specific framework has complex patterns (JAX transforms, PyTorch Lightning) → delegate to **deep-research** agent to fetch best practices, append to `.propel/domain-context.md`

Only delegate if the domain is clearly identified. Do not delegate for generic Python/JS projects.

### Phase 4: Git History Analysis

Use `git log` and `git shortlog` to gather:

- **Commit style**: conventional commits? imperative mood? prefixes (feat:, fix:)?
- **Branch naming**: feature/, bugfix/, experiment/, or flat?
- **Active areas**: which directories/files change most in last 50 commits?
- **Team size**: number of unique authors in last 100 commits
- **Commit frequency**: rough cadence (multiple daily, daily, weekly)

```bash
# Commit style sample
git log --oneline -20

# Active areas
git log --pretty=format: --name-only -50 | sort | uniq -c | sort -rn | head -20

# Team size
git shortlog -sn --no-merges -100
```

### Phase 5: Existing Conventions

Read these files if they exist (silently skip missing ones):

- `.claude/CLAUDE.md` — existing project instructions
- `CONTRIBUTING.md` — contribution guidelines
- `.github/workflows/` — CI configuration
- `.editorconfig` — editor settings
- `ruff.toml` / `pyproject.toml [tool.ruff]` — linter config
- `.prettierrc` / `.eslintrc` — JS/TS formatter/linter
- `rustfmt.toml` — Rust formatter
- `.pre-commit-config.yaml` — pre-commit hooks

Extract concrete rules (line length, banned imports, required checks).

### Phase 6: Write Profile + Present to User

Synthesize all findings into 4 files. **Present the profile.md content to the user BEFORE writing** and ask for confirmation.

#### `.propel/config.json`

```json
{
  "enabled": true,
  "created": "2026-02-17T10:30:00Z",
  "updated": "2026-02-17T10:30:00Z",
  "analysis_hash": "<sha256 of key file contents>",
  "detected": {
    "language": "python",
    "framework": "jax",
    "domain": "robotics-rl",
    "package_manager": "uv",
    "test_framework": "pytest"
  }
}
```

#### `.propel/profile.md`

~100 lines. The main reference file that the session-start hook injects. Structure:

```markdown
# Project Profile

## Identity
- **Name**: {project name from pyproject.toml or directory}
- **Language**: {language} | **Framework**: {framework}
- **Domain**: {domain classification}
- **Package manager**: {tool}

## Code Style
- Naming: {snake_case/camelCase with examples}
- Imports: {absolute/relative, grouping}
- Type hints: {yes/no, style}
- Docstrings: {Google/NumPy/none}
- Formatter: {ruff/black/prettier/none} with config: {key settings}

## Development Patterns
- Commit style: {description with examples}
- Branch naming: {pattern}
- CI: {what runs, what must pass}
- Test framework: {framework}, tests in {directory}

## Active Areas
{top 5 most-changed directories from git analysis}

## Domain Notes
{1-3 sentences of domain-specific context}

## Conventions from CLAUDE.md
{summary of existing CLAUDE.md rules, if any}
```

#### `.propel/conventions.md`

Detailed conventions with specific examples:

```markdown
# Coding Conventions

## Naming
- Functions: snake_case (e.g., `compute_reward` in src/envs/reward.py:45)
- Classes: PascalCase (e.g., `PolicyNetwork` in src/models/policy.py:12)
- Constants: UPPER_SNAKE (e.g., `MAX_EPISODE_LENGTH` in src/config.py:8)

## Imports
{detailed import ordering with examples}

## Formatting
- Line length: {N} (from {ruff.toml / pyproject.toml})
- Indentation: {spaces/tabs, width}
- Trailing commas: {yes/no}

## Type Hints
{detailed patterns with examples}

## Error Handling
{patterns with examples}

## Testing
- Framework: {pytest/jest/cargo test}
- Fixture patterns: {description}
- Naming: {test_function_name pattern}
- Mocking: {approach}
```

#### `.propel/domain-context.md`

Only created if agent delegation occurred in Phase 3. Contains:

```markdown
# Domain Context

## Environment: {name}
{Content written by env-researcher agent}

## Framework Best Practices: {name}
{Content written by deep-research agent}
```

If no delegation occurred, skip this file.

### Presenting to User

After assembling the profile, present it:

1. Show the `profile.md` content
2. Highlight anything surprising or uncertain: "I detected X — is that correct?"
3. Ask: "Should I write this profile to `.propel/`? You can edit these files anytime."
4. If confirmed → write all files, report what was created
5. If corrections needed → apply corrections, re-present

---

## Subsequent Runs — Fast Path

When `.propel/config.json` already exists:

### Step 1: Hash Key Files

Compute a hash over the contents of these files (skip missing ones):

- `pyproject.toml` / `package.json` / `Cargo.toml`
- Linter configs (`ruff.toml`, `.eslintrc`, etc.)
- CI configs (`.github/workflows/*.yml`)
- `.claude/CLAUDE.md`
- 5 most recently modified source files

### Step 2: Compare Hash

- **Hash matches** `analysis_hash` in config.json → "Profile is current, no changes detected." Done.
- **Hash differs** → continue to Step 3.

### Step 3: Delta Analysis

Identify which categories changed:

- Dependency file changed → re-run Phase 1 (structure scan)
- Linter config changed → re-run Phase 2 (code style)
- Source files changed significantly → re-run Phase 2 (code style)
- CI config changed → re-run Phase 5 (existing conventions)
- CLAUDE.md changed → re-run Phase 5

### Step 4: Present Diff

Show the user what changed:

```
Profile update detected:
- Dependencies: added `wandb`, removed `tensorboard`
- Code style: line length changed from 88 to 120 (ruff.toml updated)
- No changes to: domain, git patterns, conventions
```

Ask: "Apply these updates to your profile?"

### Step 5: Update

If confirmed → update only the changed sections in profile.md and conventions.md, update the hash and timestamp in config.json.

---

## Toggle and Removal

- **Disable**: Set `"enabled": false` in `.propel/config.json`. The session-start hook will skip profile injection.
- **Remove entirely**: Delete the `.propel/` directory. `propel init` will recreate the gitignore entry but won't recreate the profile.
- **Re-enable**: Say "customize Propel" or "analyze my project" to run the full analysis again.

## Integration Points

- **Session-start hook** reads `.propel/profile.md` and injects it as `project_profile` in the JSON context
- **using-propel skill** routes customization triggers to this skill
- **/propel:intro** offers this as Part 3 (optional)
