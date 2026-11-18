---
name: concise
description: >
  [Propel] Makes responses and write-ups shorter without losing a fact or a piece of
  evidence, ordered claim first, evidence second. Use when the user says "make this
  concise", "tighten this", "too long", "cut this down", "shorter", "trim this",
  "write this up", "clean up the README", "clean up the write-up". Also runs
  automatically before any finished written artifact is presented: the Gate 1
  investigation write-up, the Gate 2 design doc, a retrospective entry, a docs page.
  For written artifacts it saves the draft, rewrites, and checks with claim-check.sh
  that no evidence token was dropped. Concise means fewer words per fact, not fewer facts.
---

# Concise — Fewer Words per Fact, Not Fewer Facts

A shorter text that has lost a `file:line`, a number or a caveat is a worse text.
This skill cuts words. Every claim and every piece of evidence stays.

## The Rules

1. **Lead with the claim.** Put the evidence after the claim it supports, never before.
2. **Keep every piece of evidence.** `file:line`, numbers, test results, command
   output, decisions, attributions (`[claude]`, `[codex]`, `[both]`,
   `[codex · unverified]`), commit hashes, links.
3. **Cut what carries no information:** restatement, narration of process ("I then
   looked at…"), hedges, preamble, recaps, adjectives that do no work.
4. **One idea per sentence.** Use a table for parallel facts. Never nest bullets
   more than 2 levels deep.
5. **Keep uncertainty that carries information**, e.g. "unverified" or "not tested
   on tmux". Drop only the hedges that say nothing.

## Chat Replies

Apply the rules yourself. That is all: no draft file, no script, no Codex. The
per-turn routing card restates the short version (rule 7) so it holds in long
sessions.

## Written Artifacts

This applies to finished write-ups: Gate 1 investigation findings, Gate 2 design
docs, retrospective entries, docs pages, and long write-ups outside a gate.

Run the script as `bash .claude/scripts/claim-check.sh` in a project that uses
Propel, or as `bash scripts/claim-check.sh` in Propel's own source tree. Run it
from the repo root.

1. **Save the draft** with `claim-check.sh --save-draft <artifact>`. It copies the
   artifact to `.propel/concise/<path>.draft.md`, where `<path>` is the artifact's
   repo-relative path with every `/` replaced by `__`, and prints the draft path:
   `scratch/2026-11-18-x/README.md` becomes
   `.propel/concise/scratch__2026-11-18-x__README.md.draft.md`.
   **If it exits 1, a draft for this artifact is already pending.** Do not
   overwrite or delete it. Finish that rewrite first: present it and get the user
   to accept it, then do step 8.
2. **Rewrite** the artifact in place, following the 5 rules.
3. **Run the check:**
   ```bash
   bash .claude/scripts/claim-check.sh <draft path> <artifact>
   ```
   Each `missing` line names a token the rewrite dropped, with its class and its
   first line in the draft. A `fewer` line is a token kept with a lower count,
   e.g. after a restatement was cut. An `unquoted` line is a backtick span whose
   text is still there without its backticks. `fewer` and `unquoted` lines do not
   change the exit status; check that each one is intended.
4. **Restore every missing token.** Put it back in the rewrite. Never write "removed
   X" instead of restoring it: rule 2 has no exceptions. Re-run until exit 0.
5. **Read for meaning yourself.** Exit 0 means "no extracted token missing". It
   never means "no evidence lost". The script cannot see a dropped "not" or "only",
   a lost caveat, a swap of which result passed and which failed, bare integers
   ("exit 2", "Gate 1"), counts in table cells without a unit, or units it doesn't
   know. Compare draft and rewrite claim by claim for these.
6. **Codex** (if enabled — see `.propel/codex.json`):
   - **If the artifact belongs to a gate** (Gate 1, Gate 2, retrospective), add
     this question to **that gate's existing consult**. It is one call, and it
     counts as the writeup review:
     > "Compare the draft and the rewrite at <draft path> and <artifact path>: is
     > any claim, caveat or evidence item lost or changed, and where does a reader
     > meet evidence before the claim it supports? Name passages by heading, or say
     > 'no additional findings'."
   - **Otherwise**, a standalone **Writeup review** consult (same question, through
     `codex-consult`) runs only when both are true: the artifact is a finished docs
     page or long write-up, and the rewrite changed its prose substantively
     (about 30 or more changed lines, the same threshold as Gate 3).
   - Never for `scratch/` working notes, trivial edits, chat replies, or a
     formatting-only change. Never review the same rewrite twice.
   - Pass both **paths**, never pasted content. Codex reads the files in the repo.
   - Verify each Codex finding against the two files before acting on it.
7. **Present** the rewrite. **Keep the draft until the user accepts the rewrite.**
8. **Clean up.** Once the user accepts the rewrite, delete the draft
   (`rm <draft path>`). A draft left behind blocks the next `--save-draft` of
   that artifact, which is how an unaccepted rewrite stays visible.

## Example

Before (66 words):

> I started by looking into why the evaluation numbers seemed off. After reading
> through a number of files, I eventually found that the loader in
> `src/data/loader.py:118` drops the last batch, which I think might possibly be
> the reason. When I set `drop_last=False` the accuracy went from 91.2% to 92.0%,
> which is a pretty significant change. Codex also agreed with this [codex]. Not
> tested on multi-GPU yet.

After (30 words):

> The loader drops the last batch (`src/data/loader.py:118`), probably the cause
> of the low evaluation numbers. Setting `drop_last=False` raises accuracy from
> 91.2% to 92.0%; Codex agreed [codex]. Not tested on multi-GPU.

The rewrite cuts narration ("I started by…", "After reading…") and an adjective
("pretty significant"). "I think might possibly be the reason" becomes
"probably": the uncertainty carries information, so it stays, in one word
(rule 5). It keeps the path, the flag, both numbers, the tag and the caveat.
`claim-check.sh` exits 0 on this pair. Whether "probably the cause" is as weak as
the draft's claim is a meaning question, and you check it by reading (step 5).

## Important

- **Fewer facts is a failure, not a style.** If the rewrite cannot keep a fact,
  keep the longer sentence.
- **The draft is the evidence of what was there.** Never delete it before the user
  accepts the rewrite.
- **Exit 0 is a floor, not a verdict.** Token survival is checked by the script.
  Meaning survival is checked by you, and at a gate, by Codex.
- **Don't run this on code, quoted output or logs.** Rewrite prose. Copy evidence verbatim.
