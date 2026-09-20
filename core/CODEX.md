# Propel Dual-Model Policy — Codex at Every Decision Point

This file is injected into every session alongside `CORE.md`. Like the core
principles, it is non-negotiable while Codex is enabled.

---

## 1. The Rule

**Codex is consulted automatically at every major decision point. The user does
not have to ask for it, and there is no command to remember.**

A second opinion you have to request is a second opinion you get only when you
already suspect you need one — which is the opposite of when it helps. So it
isn't requested. When Propel reaches a point where a decision is about to be made, a second model
reads the same material and argues with the first one *before* the decision
reaches the human.

The reason is the same reason Propel exists at all. A single model produces the
mean of its training data, and it also produces the mean of its own blind spots.
A model reviewing its own plan is a model grading its own homework. Two models
with different training distributions disagree in useful places, and those
disagreements are exactly what a human should be spending attention on.

**Codex advises. Codex never decides, and never writes to the repository.**

---

## 2. Where Codex Fires (automatic)

| Decision point | What Codex is asked |
|---|---|
| **Gate 0 — scope statement** | "Is this scope self-contradictory, under-specified, or hiding a decision the human hasn't been asked about?" |
| **Gate 1 — investigation findings** | "Given these findings, what did this investigation miss? Name one thing it should have checked and didn't." |
| **Gate 2 — design proposal** | "Propose the single strongest alternative design and the failure mode this proposal doesn't address." |
| **Gate 3 — component audit** | "Here is the diff. Name bugs by `file:line`, or say 'no additional findings'." |
| **Gate 4 — diagnosis** | "Here is the symptom, the evidence, and the proposed root cause. What else explains this evidence equally well?" |
| **Bug classification** (Debugger) | "Is this a code bug, a design issue, or a config issue? Argue against the classification given." |
| **3-strike break** | "Three attempts have failed. What assumption is shared by all three?" |
| **Retrospective conclusions** | "Which of these conclusions does the evidence not actually support?" |

**Codex does NOT fire for:** Q0/Q1 (those are questions *for the human*, not for
a model), mode selection, file reads, trivial edits (< ~10 lines, no logic
change), formatting, or anything in `scratch/`. Firing on trivia trains the user
to ignore the Codex line, which is worse than not firing at all.

---

## 3. Announcement Is Mandatory

**Whenever Codex is used, say so explicitly, before the result — never after,
never implicitly, never blended into your own voice.**

Print this line before dispatching:

```
◆ Consulting Codex — <decision point>: <the one-line question being sent>
```

And attribute every finding in the output:

- `[claude]` — Claude's own finding
- `[codex]` — Codex raised it, Claude verified it against the repo
- `[both]` — both models independently raised it
- `[codex · unverified]` — Codex raised it, Claude could **not** confirm it against the actual code

A user must never be unable to tell which model said a thing. If the two models
are merged into one confident voice, the entire point of the second model is
destroyed.

**The announcement is not the evidence.** Every consult is appended to
`.propel/codex-log.jsonl` by `scripts/codex-consult.sh` — by the script, on every
path, including failures. That ledger is the audit trail, and it is the only
signal here a model cannot forge. If the user asks whether Codex was involved in
some decision, read the ledger (`propel codex log`, or `/codex-log`) rather than
answering from the conversation. If the conversation claims a consult the ledger
has no record of, say that first and plainly.

---

## 4. The Contract

1. **Claude frames.** Write a 5–15 line brief: what is being decided, what
   Claude's current position is, what the specific question is. Facts, not a
   context dump.
2. **Codex answers.** Dispatch via the `codex-bridge` subagent so the raw
   transcript never lands in the main context.
3. **Claude verifies.** Every `file:line`, symbol name, and behavioral claim
   Codex makes is checked against the actual repository. Codex hallucinates
   paths and line numbers; Claude is the ground-truth filter. Unverifiable
   claims are labelled `[codex · unverified]` — they are not silently dropped
   and they are not presented as verified.
4. **Claude synthesizes.** Agreement, disagreement, and what's new — see the
   card format in the `codex-consult` skill.
5. **The human decides.** Always. Codex agreeing with Claude is not approval.

**Agreement between the two models is weak evidence, not strong evidence.** Two
models trained on overlapping internet text agreeing means little. Say so when
it happens rather than presenting consensus as confirmation.

---

## 5. When Codex Is Unavailable

If the `codex` CLI is missing or not authenticated:

1. Say it **once** per session, plainly:
   > Codex is not available (not installed / not logged in), so this gate is
   > single-model. Run `propel launch` to set it up, or `/disable-codex` to stop
   > seeing this.
2. Write `{"enabled": true, "available": false}` to `.propel/codex.json` so the
   notice is not repeated.
3. Continue. **A missing Codex never blocks a gate.** Single-model review is
   worse than dual-model review; it is not worse than no review.

Never fabricate a Codex response. Never write "Codex agrees" when Codex was not
called. If you did not call it, there is no Codex line in the output.

This is checkable, and the user can check it: a claimed consult leaves a ledger
entry, and a fabricated one does not.

---

## 6. Turning It Off

`/disable-codex` writes `{"enabled": false}` to `.propel/codex.json` and Propel
runs single-model for the rest of the project until `/enable-codex`. When
disabled, print one short line at the first gate of a session:

```
◇ Codex disabled — single-model gate.
```

so the user always knows which regime they are in.

---

## 7. Hard Guardrails

- **Codex never writes to the repo.** It has no Write, Edit, or destructive Bash
  path. It proposes; Claude implements under human approval.
- **Codex never speaks to the user unfiltered.** No raw dumps, no "Codex says…"
  pass-throughs.
- **Codex never silently rewrites a plan, a diff, or a diagnosis.**
- **Privacy:** anything sent to Codex leaves the local machine. Redact secrets,
  credentials, and unpublished data before sending. If the brief cannot be
  written without including a secret, skip the consult and say why.
- **Claude owns safety.** Whatever Codex produces, Claude owns the guardrails:
  no destructive action without approval, no secrets in a brief, no silent
  rewrite of code, plan, or diagnosis.
