---
name: make-documentations
description: >
  [Propel] Writes and updates a project's versioned documentation (README, hub,
  section index pages, component and method pages, results write-ups, runbooks) in
  one fixed style: present tense, every choice with its reason, every number with its
  baseline, code paths that resolve. Use when the user says "document this", "write
  the docs", "update the docs", "make documentation", "write a results page",
  "document the results", "write a runbook", "docs are stale", "the docs are out of
  date"; an explicit request writes without asking whether. After a component passes
  Gate 3, after validation passes, after a retrospective, and when the [propel:docs]
  hook line names stale pages, it ASKS first: one AskUserQuestion naming the pages
  that would change and what each update would cover, and nothing is written before
  the answer. /disable-make-documentations stops the question. Each page goes
  through concise and doc-check.sh, then a Codex fidelity pass checks the docs
  against what the code does. Writes pages to disk; never commits.
---

# Make Documentations — Docs That Describe the Code as It Is

The docs say what the project is now, and every sentence in them can be checked
against the code. This skill writes pages in one style, checks them mechanically,
and has a second model compare them with the code before the human sees them.

## The Contract

1. **Two layers, never mixed.** The versioned docs hold the present: the current
   design, the current results, the current status. History lives in `scratch/`
   (decision logs, hand-offs, sessions). A page may say that history exists
   outside version control. It never links into `scratch/` and never copies text
   from it.
2. **Layered entry points.** README (what this is, in a paragraph) → hub page →
   section index pages (a paragraph plus a `Page | Question` table) → leaf pages,
   one per component, method, dataset, metric, results write-up or runbook.
3. **One anatomy for every leaf.** H1 `Name: essence`. A 3-6 sentence overview:
   what it is, its role (with a link up), what its output lets a reader conclude,
   what it is not. 3-8 H2s named by a noun or a question, each with prose first,
   a table where facts compress, then the reason. Optional `Known limits` or
   `What it is not`. `References`. At the bottom, a dated **Status** and a 2-3
   sentence **Why this design**.
4. **A choice carries its reason as a consequence:** "<choice>, so that
   <inference it licenses>; a failure would mean <x>, not <y>."
5. **A number never stands alone.** Put its baseline, floor or ceiling next to it,
   with n, seeds and whether an interval was computed.
6. **Claims are calibrated.** Observation first, then the reading ("our reading
   is …"). Study-wide limits go in the README and the hub, not only on a deep page.
7. **Code fidelity is checkable.** Relative links that resolve; backticked
   repo paths and function names in a `Code:` paragraph; the tests that enforce a
   claim, named. Docstrings that link back to their page are good practice, but this
   skill edits docs pages only: suggest such docstring links in the presented card,
   never edit source files during a docs run. No line numbers: they rot.
8. **Config pages** show an annotated tree, one config in full, a table of keys,
   what raises an error instead of defaulting, where code defaults and recorded runs
   drift, and a precedence rule ("where this page lags, the config wins").
9. **Shapes inline** as `[B, T, D]` where a tensor is transformed, and a
   `Shape (dtype)` column in artifact tables. A silent pitfall is named together
   with the assertion that guards it.
10. **Results pages read like short papers:** numbered questions, a heading that
    states the claim, a bold **Question.**, one figure per claim with a complete
    italic caption, one shared "How to read the figures" block, and a numbered
    discussion.
11. **Tone:** plain, declarative, first person plural. No emoji, marketing,
    taglines, or TODO/TBD/FIXME. Unbuilt work is written "To build: …". Diagrams
    are ASCII. A superseded design gets one sentence and a pointer to version
    history. Prose uses plain-English names; code identifiers appear only in
    paths, links and commands.

The style has three known ways to fail, and the procedure checks each one: the
Status box drifts from the body (step 3 rewrites both together, step 6 compares
the page with the code), pages keep the anatomy but blow the length budget (step 4: before running
`concise`, count each leaf page's overview sentences (3-6) and H2s (3-8) and cut
or merge to fit),
and the style guide lives somewhere contributors never see (it is this file, and
the hub links the conventions page if the project has one).

## Page Types and Templates

Placeholders are in `<angle brackets>`. Every template is a floor: drop a
section only when it would be empty, and say so in the Status box if that matters.

### (a) Project README

```markdown
# <Project>: <one-line essence>

<2-4 sentences: what the project does, for whom, and the one result or capability
that matters most, with its baseline.>

**Study-wide limits.** <The limits every reader must know, e.g. one dataset, n
seeds, no confidence intervals yet.>

## Where to start

| If you want to… | Read |
|---|---|
| understand the design | [Hub](docs/README.md) |
| reproduce a result | [Runbook](docs/runbooks/<page>.md) |
| see the current results | [Results](docs/results/README.md) |

## Quick start

    <the 2-4 commands that install and run the smallest end-to-end example>

## Status

**Status** (<YYYY-MM-DD>): <what is built, what is validated, what is "To build: …">.
```

### (b) Hub page (`docs/README.md`)

```markdown
# <Project> documentation

<One paragraph: how the docs are organized and the order to read them in.
History of decisions is kept outside version control; these pages state the
present.>

**Study-wide limits.** <Same limits as the README, one line each.>

## Sections

| Section | Question it answers |
|---|---|
| [Design](design/README.md) | How is the system built, and why? |
| [Methods](methods/README.md) | What does each component compute? |
| [Results](results/README.md) | What do the experiments show? |
| [Runbooks](runbooks/README.md) | How do I run and configure it? |

## Conventions

<Where the style rules live; how pages link to code; what "Status" means.>
```

### (c) Section index page (`docs/<section>/README.md`)

```markdown
# <Section>

<One paragraph: what this section covers, what it does not, and how its pages
relate. Up: [Hub](../README.md).>

| Page | Question |
|---|---|
| [<Component A>](<component-a>.md) | <the question that page answers> |
| [<Component B>](<component-b>.md) | <the question that page answers> |
```

### (d) Component or method page

```markdown
# <Component>: <essence in a few words>

<3-6 sentences. What it is. Its role in [<parent>](README.md). What its output
lets a reader conclude. What it is not.>

## Inputs and outputs

<Prose first.> The input `[B, T, D]` (float32) becomes `[B, K]` (int64) after
<transformation>.

| Artifact | Shape (dtype) | Produced by | Consumed by |
|---|---|---|---|
| <name> | `[B, T, D]` (float32) | <step> | <step> |

## How it works

<Prose. Each choice with its consequence: "<choice>, so that <inference>; a
failure would mean <x>, not <y>." Name silent pitfalls with the assertion that
guards them.>

## <A question the reader asks, e.g. "Why not <alternative>?">

<Observation first, then "our reading is …".>

## Known limits

<What this component does not handle, and what would break.>

## References

<Papers, other pages.>

Code: `<path/to/module.py>` (`<function_name>`), `<path/to/other.py>`.
Tests: `<tests/test_name.py>` (`<test_function>`) enforces <the claim it enforces>.

---
**Status** (<YYYY-MM-DD>): <built / validated / To build: …>.
**Why this design.** <2-3 sentences: the reason this shape was chosen over the
obvious alternative, and what would make us revisit it.>
```

### (e) Results write-up

```markdown
# <Study>: <the main claim in one line>

<3-6 sentence overview: what was asked, on what data, with what n and seeds, and
the headline result next to its baseline.>

## How to read the figures

<Axes, units, what a point and an error bar are, what n is, whether intervals were
computed. Written once, for every figure below.>

## Q1. <A heading that states the claim>

**Question.** <The question, in one sentence.>

<Observation, with the number beside its baseline: "<metric> is <value> against a
baseline of <value> (n = <n>, <k> seeds, no interval yet)." Then the reading:
"our reading is …".>

![<alt text>](figures/<q1>.png)

*Figure 1. <A complete caption: what is plotted, against what, n, seeds, and the
one thing to see.>*

## Q2. <A heading that states the claim>

…

## Discussion

1. <What the results license, and what they do not.>
2. <The strongest alternative explanation, and what would rule it out.>
3. <To build: the experiment that would settle the open question.>

## Known limits

<Study-specific limits; study-wide ones also go in the README and hub.>

Code: `<path/to/eval_script.py>`, config `<configs/run.yaml>`.

---
**Status** (<YYYY-MM-DD>): <which runs these numbers come from, and whether they
are final>.
**Why this design.** <2-3 sentences: why these questions and this protocol.>
```

### (f) Runbook or config page

```markdown
# <Task>: <what running it produces>

<3-6 sentences: what this runs, its inputs and outputs, how long it takes on what
hardware, and what it is not for.>

## Config tree

    configs/
      base.yaml        <what it holds>
      <variant>.yaml   <what it overrides>

## One config in full

    <the complete contents of one representative config, annotated>

## Keys

| Key | Type | Default in code | Meaning |
|---|---|---|---|
| <key> | <type> | <value or "required: raises"> | <meaning and consequence> |

## What raises instead of defaulting

<Keys that must be set, and the error a missing one gives.>

## Drift

<Where the code's defaults differ from what recorded runs used. Precedence: where
this page lags, the config wins.>

## Run it

    <commands, copy-paste ready>

Code: `<path/to/entrypoint.py>` (`<main_function>`).

---
**Status** (<YYYY-MM-DD>): <verified against which config, when>.
**Why this design.** <2-3 sentences.>
```

## Step 0: Ask (automatic triggers)

Four points start this skill without the user asking for docs: a component passes
its audits (Gate 3), validation passes, a retrospective is written, and the
`[propel:docs]` hook line names pages that mention a file just edited. At each of
them the skill asks one question first, and writes nothing until the user answers.

1. **Check the switch.** Read `.propel/docs.json`. Docs prompts are off when
   `"enabled"` is `false`, `null`, `0`, or a string that, trimmed and lowercased,
   is `"false"`, `"0"`, `"off"`, `"no"` or empty. A missing file or key means on:
   the same rule as `.propel/codex.json`. While they are off, ask nothing and
   write nothing. At the first trigger of the session print this one line, then
   stay silent:

       ◇ Docs prompts off — /enable-make-documentations to turn them back on.

   While the switch is off, the routing card carries a `docs prompts: off` line
   every turn and the hook adds no `[propel:docs]` line.
2. **Find the pages; edit none.** Run Procedure steps 1 and 2 to pick the pages
   that would be created or updated, without the step 1 question: with no docs
   root, or no page that covers the change, ask nothing. Read each page and the
   code it describes far enough to say what its update would cover: which
   sections, and which change or result.
3. **Ask one question with the AskUserQuestion tool.** When a gate question is
   asked at the same moment (Gate 3, the validation pass), put the docs question
   in that same AskUserQuestion call as a second question, not as a separate
   interruption. The retrospective does the same next to its fold-in question.
   The template:

   - **header:** `Docs`
   - **question:** "Update the docs for <the change or result, in a few words>?
     <N> pages cover it: `<page 1>` (<update or new>; <sections>: <what it would
     say, about which change or result>); `<page 2>` (<update or new>;
     <sections>: <what it would say>)."
   - **options**, each label with a description of what it covers and costs:
     - (a) **Update all <N> pages**: <what the N updates cover together>. Each
       page then goes through concise, doc-check.sh and the Codex fidelity pass.
     - (b) **Update only `<the most important page>`**: <what that one update
       covers>. The other pages keep describing the code as it was.
     - (c) **Skip this time**: no docs change now. The pages keep describing the
       code as it was.
     - (d) **Stop asking (same as /disable-make-documentations)**: no docs
       question in this project until `/enable-make-documentations`. An explicit
       request still works.

   With one page, (a) and (b) are the same option: offer (a), (c) and (d). Name
   every page by path and say what its update would cover; "update the docs"
   alone is not an option the user can weigh.
4. **Act on the answer.** Only (a) or (b) runs the Procedure below, on the pages
   that option names.
   - (c): change nothing.
   - (d): write `.propel/docs.json` exactly as `/disable-make-documentations`
     does (`"enabled": false`, `"disabled_at"`, `"reason"`; keep any other
     keys), confirm in one line, and change no page.
   - Any other answer, or none: change nothing.

**An explicit request skips the whether question.** When the user asks for docs
("document this", "write the docs", "update the docs"), run the Procedure
directly, also while docs prompts are off. If the scope is unclear, with several
plausible page sets, first ask which pages in the same style: one
AskUserQuestion call, each option a page set with what its update would cover.

## Procedure

Run the script as `bash .claude/scripts/doc-check.sh` in a project that uses
Propel, or as `bash scripts/doc-check.sh` in Propel's own source tree. Run it from
the repo root.

1. **Find the docs root.** An existing `docs/` or `documentation/`; otherwise the
   README. If there is none, ask one question: "Create `docs/` with a hub page
   (more pages to maintain; each component gets its own page), or keep this to a
   section of the README (one file; it stops scaling past a few components)?"
2. **Pick the pages.** The page the user asked for, the pages a Step 0 answer
   chose, or, to build the Step 0 question, the pages that cover the changed
   files (search the docs root for each changed path; the `[propel:docs]` hook
   line names them after an edit).
3. **Write or update the pages** from the templates above. Present tense only. No
   links or paths into `scratch/`. Code paths go in the `Code:` paragraph.
   Rewrite the dated **Status** and **Why this design** together with the body,
   never the body alone. Read the code each claim describes before writing it.
4. **Run `concise`** on each page, its written-artifact procedure: save the draft
   with `claim-check.sh --save-draft`, rewrite, run `claim-check.sh` and restore
   every missing token.
5. **Run `bash .claude/scripts/doc-check.sh <pages…>`** and fix every line it
   prints until it exits 0. It checks links and anchors, backticked paths,
   `scratch/` paths, TODO/TBD/FIXME, emoji, and the dated Status line.
6. **Docs fidelity consult** (Codex, per `codex-consult`), when a page changed by
   more than a trivial edit (about 10 or more lines, or any changed claim about
   behavior). Never for `scratch/`. Announce it, then send the paths of the pages
   and of the code they describe, with two questions in one call:
   > "Here are the doc pages at <paths> and the code they describe. Name every
   > claim the code contradicts or does not support, by page and heading, or say
   > 'no additional findings'."
   >
   > "Compare the draft and the rewrite at <draft path> and <page path>: is any
   > claim, caveat or evidence item lost or changed, and where does a reader meet
   > evidence before the claim it supports? Name passages by heading, or say 'no
   > additional findings'."

   This call counts as the writeup review for these pages; no standalone one
   follows. Pass `--question "<docs fidelity question> + writeup review"`. Omit
   `CLAUDE'S POSITION`: Claude wrote the pages. If a page or the code holds
   secrets, credentials or unpublished data, skip the consult and say so. If
   Codex is disabled or unavailable, follow `codex-consult` (one `◇` line, at
   most once per session) and present the pages without a fidelity card.
7. **Present** the pages with the fidelity card (`codex-consult` card format,
   every finding attributed). The human accepts the pages or edits them; that
   answer is the `concise` acceptance, and the drafts are deleted then. When the
   pages follow a Step 0 answer, the gate that triggered them was answered in the
   same AskUserQuestion call (for a retrospective, next to its fold-in question):
   present the pages and the fidelity card once they are written, without asking
   again whether to write them. Pages are written to disk; this skill never
   commits.

## Rules

- **Never write a page at an automatic trigger without an answer.** Only Step 0
  options (a) or (b), or an explicit request from the user, start the Procedure.
- **Never document unbuilt work** except as "To build: …".
- **Never copy text from `scratch/`** into the docs. Restate the present in the
  page's own words, from the code.
- **A superseded design gets one sentence** and a pointer to version history, not
  a section.
- **Fix the page, not the check.** A doc-check line is fixed in the page; a Codex
  finding is verified against the code before the page changes.
- **Never present a page whose doc-check run did not exit 0.**
