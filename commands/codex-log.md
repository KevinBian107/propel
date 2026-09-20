[Propel] Show the Codex consult audit trail for this project.

This answers one question: **did Codex actually get consulted, and when?**

## Why this exists

The `◆ Consulting Codex` announcement and the `[codex]` attribution tags are
written by a model. They are good for reading a conversation, and they are not
evidence. A model that forgets to announce, or that writes "Codex agrees"
without calling anything, produces a transcript indistinguishable from the
honest one.

`.propel/codex-log.jsonl` is written by `scripts/codex-consult.sh` — a shell
script, on every invocation, including the ones that fail. It is the only signal
in the system that a model cannot forge, because no model writes it.

**A gate that claimed a Codex consult with no matching ledger entry did not
consult Codex.** Say that plainly if the user asks you to check.

## Process

1. **Run the CLI** if it's installed:

```bash
propel codex log          # last 20
propel codex log -q       # also show the question sent each time
propel codex log --all    # everything
propel codex status       # is it on, reachable, and being used?
```

2. **If `propel` isn't on PATH**, read the ledger directly — do not skip the
   step, and do not summarize from memory of the conversation:

```bash
cat .propel/codex-log.jsonl
```

Each line is one consult: `ts`, `label` (the decision point), `outcome`
(`reply` / `no-findings` / `unavailable` / `disabled`), `detail`, `question`,
`duration_s`.

3. **Present it as a table**, then answer the question the user actually has:

- **"Was Codex involved in decision X?"** → find the entry whose `label` matches
  that gate. If there isn't one, say so directly. Do not reconstruct it from the
  conversation and present that as confirmation.
- **"Why do I keep seeing single-model gates?"** → look for repeated
  `unavailable` entries and read their `detail`. Usually the CLI is missing or
  auth expired.
- **"Is it even running?"** → `propel codex status`.

4. **If the ledger contradicts the transcript, say so first.** A conversation
   that announced a consult the ledger has no record of is the single most
   important thing this command can surface. Lead with it; don't bury it under a
   table.

## The live view

The ledger is the after-the-fact record. For an at-a-glance signal while working,
there is a status-line segment:

```bash
propel codex statusline --install
```

It renders `codex ● 3 · 7s` (enabled, three consults today, last one seven
seconds ago) next to the model and git segments. If the user asks "how do I see
this without running a command", that is the answer.

## What the ledger does not contain

The question sent, never the material. Briefs carry source code, diffs and
diagnoses; the ledger records only the `QUESTION` block, the outcome and the
timings. If the user wants to know what was *sent*, that was in the conversation
— it is deliberately not on disk.

The file lives under `.propel/`, which `propel init` gitignores. It is one short
line per consult.
