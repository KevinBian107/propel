---
name: codex-consult
description: >
  [Propel] The automatic dual-model layer. Fires on its own at every major Propel
  decision point — Gate 0 scope, Gate 1 findings, Gate 2 design, Gate 3 audit,
  Gate 4 diagnosis, bug classification, 3-strike breaks — with no user action
  required. Sends a short brief to OpenAI Codex via the codex-bridge subagent,
  verifies every claim Codex makes against the actual repository, and presents an
  attributed comparison card. There is no command to invoke — if the user asks for
  "a second opinion" or "what another model thinks", it is already happening.
  Codex advises; the human decides. Governed by core/CODEX.md and .propel/codex.json.
---

# Codex Consult — The Automatic Second Model

`core/CODEX.md` says *that* Codex fires at every major decision point. This skill
is *how*.

A command would put the burden on the user at exactly the moments they are least
able to carry it — mid-design, mid-diagnosis, head down in the problem. A second
opinion you have to request is a second opinion you get when you already suspect
you need one, which is the opposite of when it helps. So there is no command. The
consult is scheduled.

---

## Step 0 — Should this consult happen at all?

Fire automatically at these points and nowhere else:

| Point | Fires when |
|---|---|
| **Gate 0** | The scope statement is written, before it is shown to the user |
| **Gate 1** | Investigation findings are assembled, before Gate 1 is presented |
| **Gate 2** | The design proposal is complete, before Gate 2 is presented |
| **Gate 3** | A component's diff is non-trivial (≥ ~30 lines, or touching model / loss / data / training-loop code) |
| **Gate 4** | A root cause has been identified, before the fix is proposed |
| **Classification** | A bug is about to be classified as code / design / config |
| **3-strike** | The third attempt at the same approach has failed |
| **Retrospective** | Conclusions are written, before they enter the registry |

**Do not fire** for: Q0 / Q1 (those are questions for the human), mode selection,
reads, renames, formatting, comment edits, trivial diffs, or anything confined to
`scratch/`. Over-firing is a real failure mode — it makes the `◆ Consulting
Codex` line into noise the user scrolls past, and at that point the second model
has stopped working even though it is still running.

Check `.propel/codex.json` first. If `enabled` is `false`, skip silently except
for one `◇ Codex disabled — single-model gate.` line at the session's first gate.

---

## Step 1 — Announce, before you dispatch

```
◆ Consulting Codex — Gate 2 (design): "Propose the strongest alternative to the
  two-stage encoder and name the failure mode this design doesn't address."
```

One line. The decision point, and the actual question being sent. The user should
be able to tell, from this line alone, whether the question was a good one.

This is not optional and it is not retroactive. If the user only learns Codex was
involved when the findings appear, the announcement has failed.

---

## Step 2 — Write the brief

5–15 lines. Facts first, position second, question last.

```
CONTEXT
  Project: <one line — what this codebase is>
  Decision: <what is being decided right now>
  Material: <the design / diff / diagnosis, inlined or summarized>

CLAUDE'S POSITION
  <2-4 lines: what Claude currently thinks and why>

QUESTION
  <one sharp, falsifiable question — see the table below>

CONSTRAINTS
  Answer in under 400 words. Cite file:line for every code claim. If you have no
  additional finding, say "no additional findings" rather than restating mine.
```

**Brief-writing rules**

- **Do not bias the question.** "Does this look right?" gets you agreement.
  "Name the strongest counter-approach" gets you a second opinion. Ask Codex to
  find problems, never to confirm.
- **Omit `CLAUDE'S POSITION` when Claude wrote the thing being reviewed** — a
  Gate 3 diff, or a Gate 2 design Claude proposed. Anchoring Codex to the author's
  reading of their own work throws away most of the value of asking. Keep the
  position line for material Claude did not author, where it saves a round-trip.
- **Redact.** Keys, tokens, credentials, unpublished data. If the brief cannot be
  written without a secret, skip the consult and tell the user why.
- **Inline the material.** Codex does not share Claude's context, working memory,
  registry, or CLAUDE.md. A brief that references "the design we discussed"
  produces a hallucinated review of a design Codex has never seen.

### Question templates by decision point

| Point | Question to send |
|---|---|
| Gate 0 | "Is this scope self-contradictory, under-specified, or hiding a decision the human has not been asked about? Name the single biggest gap." |
| Gate 1 | "Given these findings, what should this investigation have checked and didn't? Name one thing." |
| Gate 2 | "Propose the single strongest alternative design, and name one failure mode this proposal does not address." |
| Gate 3 | "Here is the diff. Name bugs by `file:line`. If there are none beyond those listed, say 'no additional findings'." |
| Gate 4 | "Here is the symptom, the evidence, and the proposed root cause. What else explains this evidence equally well?" |
| Classification | "This was classified as a `<code bug / design issue / config issue>`. Argue against that classification." |
| 3-strike | "Three attempts have failed: `<list>`. What assumption do all three share?" |
| Retrospective | "Which of these conclusions does the evidence presented not actually support?" |

---

## Step 3 — Dispatch through `codex-bridge`

Dispatch the **`codex-bridge`** subagent with the brief **and the question
separately** — the bridge passes the latter to the wrapper as `--question`, and
it is the only part of the exchange that is written to disk. Do not run
`scripts/codex-consult.sh` from the main context.

The reason is context hygiene, and it is load-bearing. Codex's raw reply is long,
confident, and partly wrong. Dropping it into the main conversation means every
subsequent turn is reasoning next to unverified claims that *look* like findings.
`codex-bridge` runs the CLI, checks each claim against the repo, throws away the
transcript, and returns only a verified findings table. The main context sees the
table, never the raw text.

`codex-bridge` returns:

```
VERIFIED    — claim + the file:line that confirms it
DISPUTED    — claim + what the file actually says
UNVERIFIED  — claim Codex made that names nothing checkable
```

---

## Step 4 — Verify (this is the load-bearing step)

`codex-bridge` does the mechanical verification. Claude does the judgment.

For every `VERIFIED` finding, decide whether it is *real* — a confirmed line
number is not a confirmed bug. Codex will correctly quote a line and draw the
wrong conclusion from it. For every `DISPUTED` finding, decide whether Codex was
wrong or was describing something real in the wrong place.

**Never promote an `UNVERIFIED` claim to a finding.** It goes in the card,
labelled, or it doesn't appear. Silently dropping it is also wrong — a claim
Claude could not check is information about where the repo is hard to reason
about.

---

## Step 5 — The card

```
┌─ ◆ Codex consult — Gate 2 (design) ───────────────────────────┐
│ Asked: Propose the strongest alternative and name a failure    │
│        mode this design doesn't address.                       │
│                                                                │
│ Both models agree:                                             │
│   • [both] The encoder must be frozen before stage 2            │
│            — weak evidence, two models agreeing is cheap        │
│                                                                │
│ They disagree:                                                 │
│   • Codebook init. [claude] k-means on a data sample, per       │
│     §3.2. [codex] uniform, argues k-means leaks val statistics. │
│     Claude's read: codex is right about the leak, wrong that    │
│     §3.2 requires uniform. This is a real decision for you.     │
│                                                                │
│ New from Codex:                                                │
│   • [codex] EMA decay 0.99 is applied per-step, but the paper   │
│     applies it per-epoch — vq.py:88 (verified)   severity: high │
│                                                                │
│ Codex claimed, Claude could not confirm:                       │
│   • [codex · unverified] "loss.py:210 detaches the codebook"    │
│     — loss.py has 140 lines; no detach found anywhere in it.    │
│                                                                │
│ Your decision:                                                 │
│   The codebook init question is the one that changes results.   │
│   Uniform init, or k-means with a train-only sample?            │
└────────────────────────────────────────────────────────────────┘
```

Then the gate proceeds as it normally would. **The card is input to the gate, not
a replacement for it.** Codex is not a fifth reviewer whose approval advances the
pipeline — the human still answers the gate question.

---

## Step 6 — When Codex is unavailable

`codex-bridge` returns `CODEX UNAVAILABLE` with a reason. Then:

1. Say it once per session, plainly, with the remedy.
2. Proceed with the gate, single-model, and say that's what you're doing.
3. Do not re-announce at the next gate. One notice per session.

**Never fabricate a reply.** No Codex call, no Codex line in the card. "Codex
agrees" written without calling Codex is the single worst failure this skill can
produce, because it manufactures exactly the confidence the second model exists
to prevent.

---

## The Only Controls

There is no invoke command, because there is nothing to invoke. The two controls
are both switches, not triggers:

| Command | Effect |
|---|---|
| `/disable-codex` | Single-model for this project until re-enabled |
| `/enable-codex` | Turn the dual-model layer back on |
| `/codex-log` | The audit trail — what was actually consulted, and when |

## The Audit Trail

`scripts/codex-consult.sh` appends one line to `.propel/codex-log.jsonl` on every
invocation: timestamp, decision point, the question, the outcome, the duration.
It logs the failures and the skips too.

This matters more than it looks. Steps 1–5 above are all things *you* produce, so
they are only as reliable as you are on turn forty of a long session. The ledger
is produced by the script as a side effect of actually running Codex, so it
cannot drift from reality. When the user asks whether Codex was involved in a
decision, **read the ledger** — do not answer from the conversation.

The ledger records the question, never the material. Briefs carry source code;
`.propel/codex-log.jsonl` carries only what was passed as `--question`, the
outcome, and the timings — nothing is parsed out of the brief, and Codex's own
stderr never reaches it either.

If a user asks for Codex's opinion on something mid-turn — not at a gate — just
run the consult. It is the same procedure; the schedule is a floor, not a ceiling.
Say `◆ Consulting Codex` as always.

## Related

- `core/CODEX.md` — the policy this skill implements. Non-negotiable.
- `codex-bridge` agent — runs the CLI and verifies claims in an isolated context.
- `think-deeply` — the *internal* anti-sycophancy pass. Codex is the external one:
  a different model rather than a second look from the same one.
- `c-review` — folds the Anthropic review plugin into the same Gate 3 card.
