---
name: investigation
description: >
  [Propel] Scaffolds a structured investigation in scratch/ for empirical research and documentation.
  Use when the user says "start an investigation" or wants to: trace code paths or data flow
  ("trace from X to Y", "what touches X", "follow the wiring"), document system architecture
  comprehensively ("document how the system works", "archeology"), investigate bugs
  ("figure out why X happens"), explore technical feasibility ("can we do X?"), or explore
  design options ("explore the API", "gather context", "design alternatives").
  Creates dated folder with README. NOT for simple code questions or single-file searches.
---

# Set up an investigation

## IMPORTANT: Gate 0 Must Fire First

Before starting ANY investigation, Gate 0 (Intake) MUST have been completed. If the user has not been asked scoping questions and approved a scope statement, do NOT proceed. Go back to the using-propel skill and run the intake gate.

If the user insists on skipping Gate 0, note the unanswered questions in the README under "## Unanswered Intake Questions".

## Instructions

1. **Check for past experiments**: Before creating a new investigation, check `scratch/registry/` for past entries with matching keywords. If found, inject them as context:
   > "Previous experiment learnings found — reviewing before starting: [list entries]"

2. Create a folder in `{REPO_ROOT}/scratch/` with the format `{YYYY-MM-DD}-{descriptive-name}`.

3. Create a `README.md` in this folder using the template below.

4. Create scripts and data files as needed for empirical work.

5. For complex investigations, split into sub-documents as patterns emerge.

6. **Fan out `investigator` subagents — don't read forty files yourself.**
   Decompose the investigation into specific, independent questions and dispatch
   one `investigator` per question, all in a single message so they run in
   parallel. Then say what you dispatched:

   > Dispatching four investigators in parallel: (1) where the reward is
   > computed, (2) how configs override defaults, (3) what calls `env.step`,
   > (4) what the tests assume about observation ordering.

   **One question per agent.** A single agent with a broad brief ("understand
   the codebase") returns a shallow summary of everything and an answer to
   nothing, and it burns the context that the specific questions needed. Four
   narrow agents return four answers with `file:line` evidence.

   Read their reports, resolve contradictions between them by opening the file
   yourself, and write the synthesis into the README. The subagents produce
   evidence; the synthesis is yours.

## README Template

```markdown
# Investigation: {descriptive-name}

## Scope (Human-Approved)
{One paragraph scope statement from Gate 0. This is what the user confirmed they want.}

## Paper References
{Links to any extracted paper notes in scratch/paper-notes/ that are relevant to this investigation.}
- [paper-name](../paper-notes/paper-name.md) — relevance note

## Task Checklist
- [ ] {task 1}
- [ ] {task 2}

## Findings
{Updated as investigation progresses}

## Surprises / Risks
{Things that were unexpected or will complicate the implementation}

## Design Decisions (Human-Approved)
{Filled in after Gate 1 — documents the user's answers to design-direction questions}

## Previous Experiment Learnings
{Entries from scratch/registry/ that matched this investigation's keywords, if any}
```

## Investigation Patterns

These are common patterns, not rigid categories. Most investigations blend multiple patterns.

**Tracing** - "trace from X to Y", "what touches X", "follow the wiring"
- Follow call stack or data flow from a focal component to its connections
- Can trace forward (X → where does it go?) or backward (what leads to X?)
- Useful for: assessing impact of changes, understanding coupling

**System Architecture Archeology** - "document how the system works", "archeology"
- Comprehensive documentation of an entire system or flow for reusable reference
- Start from entry points, trace through all layers, document relationships exhaustively
- For complex systems, consider numbered sub-documents (01-cli.md, 02-data.md, etc.)

**Bug Investigation** - "figure out why X happens", "this is broken"
- Reproduce → trace root cause → propose fix
- For cross-repo bugs, consider per-repo task breakdowns

**Technical Exploration** - "can we do X?", "is this possible?", "figure out how to"
- Feasibility testing with proof-of-concept scripts
- Document what works AND what doesn't

**Design Research** - "explore the API", "gather context", "design alternatives"
- Understand systems and constraints before building
- Compare alternatives, document trade-offs
- Include visual artifacts (mockups, screenshots) when relevant
- For iterative decisions, use numbered "Design Questions" (DQ1, DQ2...) to structure review

## Codex Consult Before Gate 1 (automatic)

Once findings are assembled and before Gate 1 is presented, dispatch
**`codex-bridge`** with the findings summary and this question:

> "Given these findings, what should this investigation have checked and didn't?
> Name one thing."

Announce it:

```
◆ Consulting Codex — Gate 1 (findings): "What should this investigation have checked and didn't?"
```

An investigation's blind spots are structurally invisible from inside it — the
same reasoning that decided what to trace decided what not to. A second model
reading only the findings is well placed to notice a missing branch, an untested
assumption, or a config path nobody followed. Fold verified additions into the
"Open Questions" section of the Gate 1 card with `[codex]` attribution; if Codex
names something worth checking, say whether you're going to go check it.

## Gate 1: Post-Investigation Checkpoint

After the investigation is complete, you MUST present findings to the user before any design work begins. Follow this format:

```markdown
## Investigation Summary

### What I Found
- [3-5 bullet summary of key findings: architecture, code paths, dependencies]

### Surprises / Risks
- [Things that were unexpected or will complicate the implementation]
- [Existing behavior that might conflict with the proposed change]

### Open Questions — I Need Your Input
1. [Trade-off question surfaced by investigation]
2. [Architecture choice that requires human judgment]
3. [Priority question about which findings to act on]
```

**Rules for Gate 1**:
- Present the investigation README to the user. They MUST read it.
- If the investigation revealed a fundamental problem with the user's idea, say so directly (think-deeply activates here).
- Ask at most 3 questions. More than that means the investigation wasn't thorough enough.
- Document the user's answers in the README under "## Design Decisions (Human-Approved)".
- User confirms design direction → proceed to design phase.

## Best Practices

- Use `uv` with inline dependencies for standalone scripts; for scripts importing local project code, use `python` directly (or `uv run python` if env not activated)
- Use subagents for parallel exploration to save context
- Write small scripts to explore APIs interactively
- Generate figures/diagrams and reference inline in markdown
- For web servers: `npx serve -p 8080 --cors --no-clipboard &`
- For screenshots: use Playwright MCP for web, Qt's grab() for GUI
- For external package API review: clone to `scratch/repos/` for direct source access

## Important: Scratch is Gitignored

The `scratch/` directory is in `.gitignore` and will NOT be committed.

- NEVER delete anything from scratch - it doesn't need cleanup
- When distilling findings into PRs, include all relevant info inline
- Copy key findings, code, and data directly into PR descriptions
- PRs must be self-contained; don't reference scratch files
