---
name: paper-extraction
description: >
  [Propel] Batch-processes multiple papers to build a structured literature database.
  Use when the user says "process these papers", "build a paper database",
  "extract from these PDFs", "organize these references", or provides multiple
  papers to catalog. Creates structured entries with BibTeX metadata for each paper.
  For a single paper's implementation reference, use /read-paper instead.
  For surveying a topic, use deep-research instead.
---

# Paper Extraction — Batch Literature Database

## Instructions

### 1. Setup
Create a database directory:
```
scratch/paper-db/
├── README.md           # Index of all processed papers
├── entries/            # One file per paper
│   ├── author2024-shortname.md
│   └── ...
└── tags.md             # Tag index for cross-referencing
```

### 2. For Each Paper Provided

Read the paper (PNGs for figures, PDF, or URL) and extract into `entries/{firstauthor}{year}-{shortname}.md`:

```markdown
# {Paper Title}

## Metadata
- **Authors**: {full author list}
- **Year**: {year}
- **Venue**: {conference/journal}
- **URL**: {link to paper}
- **Code**: {link to repo, or "Not available"}

## BibTeX
\`\`\`bibtex
@article{key,
  author = {...},
  title = {...},
  year = {...},
  ...
}
\`\`\`

## Summary
{2-3 paragraph summary: problem, approach, results}

## Key Contributions
1. {contribution 1}
2. {contribution 2}

## Method
- **Architecture**: {high-level description}
- **Input/Output**: {what goes in, what comes out, shapes if specified}
- **Loss Function**: {terms and their purpose}
- **Training**: {optimizer, schedule, key hyperparameters}

## Results
| Benchmark | Metric | Value | Notes |
|-----------|--------|-------|-------|
| ... | ... | ... | ... |

## Tags
{comma-separated tags for cross-referencing: e.g., vq-vae, robotics, action-prediction, discrete-representation}

## Relevance Notes
{Why this paper matters for our work. What we could use from it. What to be cautious about.}
```

### 3. Update Index
After processing each paper, update `README.md`:

```markdown
# Paper Database

## Papers by Topic

### {Tag 1}
- [{Author et al. (Year)} - {Short Title}](entries/author2024-shortname.md) — {one-line summary}

### {Tag 2}
- ...

## Recent Additions
- {date}: Added {paper title}
```

And update `tags.md` with the tag cross-reference.

### 4. Cross-Reference Analysis
After processing a batch of papers, add a section to README.md:

```markdown
## Cross-References
- Papers A and B both address {X} but with different approaches: {comparison}
- Paper C builds on Paper A's method with {modification}
- Gap: No paper addresses {Y} in the context of {Z}
```

## Important

- **Process papers in the order provided** — the user may have organized them deliberately.
- **Preserve exact numbers**: Reproduce reported metrics exactly. Don't round or approximate.
- **Flag missing information**: If a paper doesn't report something important (code, hyperparameters, ablations), note it explicitly.
- **Tags enable discovery**: Good tagging lets you find relevant papers later when starting a new investigation. Use specific tags (not just "machine learning" — use "vq-vae", "codebook-collapse", "commitment-loss").
- **This is a database, not a review**: Stay factual. Save opinions for the "Relevance Notes" section.
- The database lives in scratch/ (gitignored). Reference specific entries in investigation READMEs or PR descriptions as needed.
