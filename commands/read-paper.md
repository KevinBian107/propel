Extract a structured implementation reference from the paper provided in $ARGUMENTS.

The paper may be provided as PNG screenshots, a PDF path, or a URL. If PNGs, read all of them in order.

## Extraction Steps

1. **Read the full paper** — scan all provided pages/images before extracting anything. Build a complete picture first.

2. **Extract the following into a structured markdown document** saved to `scratch/paper-notes/{paper-short-name}.md`:

### Summary
- One paragraph: what the paper proposes and why it matters
- Key contribution (what's new vs prior work)

### Architecture
- Full model architecture description with component names matching the paper's terminology
- Diagram description (or reproduce as ASCII if possible) showing how components connect
- Input/output specification for the full model and each major component: shapes, dtypes, value ranges
- Any architectural variants described (ablations, alternative configs)

### Key Equations
For each important equation:
- Equation number and the equation itself (in LaTeX or clear notation)
- Definition of every variable (what it represents, its shape, where it comes from)
- What this equation computes and where it fits in the pipeline
- Any implicit assumptions (e.g., "expectation is approximated with a single sample")

### Algorithm / Training Procedure
- Step-by-step pseudocode for the training loop as described in the paper
- Order of operations: what gets computed first, what depends on what
- Gradient flow: what gets gradients, what is detached/stopped
- Any alternating optimization or multi-phase training

### Loss Function
- Each loss term separately: name, equation, what it encourages
- How terms are weighted (coefficients, schedules)
- Any tricks (loss clipping, normalization, warmup)

### Hyperparameters
- Table of all reported hyperparameters: name, value, what it controls
- Training details: optimizer, learning rate, schedule, batch size, total steps/epochs
- Architecture details: hidden dims, number of layers/heads, bottleneck size

### Implementation Notes
- Anything that's easy to get wrong: specific normalization, non-obvious activation choices, initialization schemes
- Footnotes or appendix details that matter for implementation
- Differences from "standard" approaches that could be missed

### What's Unclear
- Ambiguities in the paper that will need experimentation or author clarification
- Details that are mentioned but not fully specified

## Important

- Use the paper's own terminology and notation consistently — this document will be the reference for implementation and for the Paper Alignment Auditor later.
- Reference section numbers, figure numbers, and table numbers from the paper.
- Do NOT interpret or simplify equations — reproduce them as written. Simplification is an implementation decision to make later.
- If figures contain architecture diagrams, describe them in detail since you'll lose access to the images after `/clear`.
