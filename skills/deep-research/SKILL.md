---
name: deep-research
description: >
  Conducts a structured literature review or technical survey with human checkpoints.
  Use when the user says "survey", "literature review", "what's the state of",
  "what approaches exist for", "compare methods for", "find papers on",
  "what has been tried for", or wants to understand the landscape of a technique
  before starting implementation. Creates a structured research document.
  NOT for reading a single specific paper — use /read-paper for that.
---

# Deep Research — Structured Literature Survey

## Instructions

### Phase 1: Scope Definition
Before searching, clarify scope with the user:

1. Create `scratch/research/{YYYY-MM-DD}-{topic}/README.md` with:
   - **Research question**: What specifically are we trying to learn?
   - **Scope boundaries**: What's in scope and out of scope?
   - **Success criteria**: What do we need to know to make a decision?

2. Propose a research outline — the key subtopics to cover. Example:
   ```
   ## Research Outline: VQ-VAE variants for action prediction
   1. Original VQ-VAE and VQ-VAE-2 — baseline understanding
   2. Discrete representations in robotics — who has used this and for what?
   3. Codebook collapse solutions — what works?
   4. Alternatives to VQ (FSQ, LFQ, RVQ) — trade-offs?
   5. Integration with trajectory prediction — any existing work?
   ```

3. **Checkpoint with user**: Get approval on the outline before proceeding. The user may want to narrow or expand scope.

### Phase 2: Systematic Search
For each subtopic in the outline:

1. Search using web search, arxiv, and any available tools
2. For each relevant paper/resource found, extract:
   - **Citation**: Authors, title, year, venue
   - **Key idea**: One paragraph summary
   - **Method**: How it works (architecture, loss, training procedure)
   - **Results**: Main quantitative results and claims
   - **Relevance**: Why this matters for our specific question
   - **Limitations**: What doesn't work or isn't addressed

3. Update the README.md with findings as you go — don't wait until the end

### Phase 3: Synthesis
After covering all subtopics:

1. **Comparison table**: Methods side-by-side on key dimensions

   | Method | Year | Key Idea | Pros | Cons | Relevance |
   |--------|------|----------|------|------|-----------|
   | ... | ... | ... | ... | ... | ... |

2. **Taxonomy**: How do the approaches relate? What are the major families/paradigms?

3. **Gaps**: What hasn't been tried? Where is there opportunity?

4. **Recommendation**: Given our specific use case, which approach(es) should we try first and why?

5. **References**: Full list with links

### Phase 4: User Review
**Checkpoint with user**: Present the synthesis. The user may want to:
- Dig deeper into a specific method
- Challenge your recommendation
- Add additional methods they know about
- Refine the research question based on findings

## Output Structure

```
scratch/research/{YYYY-MM-DD}-{topic}/
├── README.md           # Main synthesis document
├── papers/             # Per-paper detailed notes (if needed)
│   ├── vqvae-original.md
│   └── fsq-2023.md
└── comparison.md       # Detailed comparison table (if too large for README)
```

## Important

- **Breadth first, then depth**: Survey the landscape before diving deep into any single paper. Don't get stuck on the first promising result.
- **Be critical of claims**: Papers overstate results. Look for ablations, failure cases, and what's NOT reported.
- **Track what's reproducible**: A paper with no code and vague hyperparameters is less useful than one with a working repo.
- **Date matters**: A 2020 method may be superseded. Always check for more recent work that builds on it.
- **Our specific context matters**: Rank everything by relevance to the user's actual problem, not by general impressiveness.
- This document lives in scratch/ (gitignored). Distill actionable findings into the investigation README when ready to implement.
