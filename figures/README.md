# Propel figures

Every figure in this repository is produced by a script that lives next to its
output. Nothing here is hand-drawn, nothing is touched up in a vector editor,
and no figure exists without the code that made it.

The structure follows [ChenLiu-1996/figures4papers](https://github.com/ChenLiu-1996/figures4papers):
one folder per figure, the script beside its outputs, a single shared style
module, and `png` + `pdf` + `svg` written on every run.

## Why scripts and not SVGs

A figure you cannot regenerate is a claim you cannot re-check. When the pipeline
gains a stage, or a mode changes which gates it runs, a hand-drawn SVG goes stale
*silently* — it keeps rendering, it keeps getting cited, and it is now wrong. A
script goes stale *loudly*: you edit one line in `STAGES` and re-run. The figure
and the thing it describes stay in sync because keeping them in sync is cheaper
than letting them drift.

The same logic runs through the rest of Propel. Mechanical work that a machine
does identically every time should be done by a machine; the parts that need
judgment — what the figure is trying to say — stay with a person.

## Layout

```
figures/
├── README.md
├── propel_style.py                 palette, rcParams, diagram primitives, export
├── make_all.py                     regenerate everything, then sync into assets/
├── figure_pipeline/
│   ├── make_pipeline.py
│   └── figures/propel_pipeline.{svg,png,pdf}
├── figure_decision_split/
│   ├── make_decision_split.py
│   └── figures/decision_split.{svg,png,pdf}
├── figure_codex_loop/
│   ├── make_codex_loop.py
│   └── figures/codex_loop.{svg,png,pdf}
└── figure_modes/
    ├── make_modes.py
    └── figures/mode_selection.{svg,png,pdf}
```

## The figures

| Folder | Figure | What it asserts |
|---|---|---|
| `figure_pipeline` | Propel pipeline | Seven stages, five gates, two questioners, the Codex consult at each gate, and which stages each mode runs |
| `figure_decision_split` | Who decides what | The machine column and the human column, and why the line between them is the product |
| `figure_codex_loop` | What happens at every gate | The five-step dual-model consult, and the four things Codex never does |
| `figure_modes` | Automatic mode selection | First message to inferred mode to active gates |

## Regenerating

```bash
pip install matplotlib
python figures/make_all.py
```

`make_all.py` runs every script and then copies the SVGs into `assets/` and
`website/assets/`, which is where the README and the documentation site load them
from. **Do not edit those copies** — they are build output. Edit the script.

## Adding a figure

1. `mkdir -p figures/figure_<name>/figures`
2. Write `figures/figure_<name>/make_<name>.py`, importing from `propel_style`:

```python
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from propel_style import PALETTE, apply_publication_style, canvas_px, finalize_figure

OUT = Path(__file__).resolve().parent / "figures" / "<name>"

def main():
    apply_publication_style(font_size=10)
    fig, ax = canvas_px(1000, 500)
    ...
    finalize_figure(fig, OUT)          # writes .svg, .png and .pdf

if __name__ == "__main__":
    main()
```

3. Add the script to `SCRIPTS` in `make_all.py`, and its SVG to `SYNC` if the
   website needs it.

## Conventions

- **Colors come from `PALETTE`.** Never a literal hex in a figure script. The
  palette matches the website's CSS variables, so figures and page read as one
  system, and re-theming is one file.
- **Blue means the human decides. Purple means Codex. Grey means machine work.**
  That mapping is consistent across every figure and it carries meaning — don't
  use blue for decoration.
- **Text stays text.** `svg.fonttype="none"` and `pdf.fonttype=42` keep labels
  selectable and searchable instead of baking them into outlines.
- **Stick to Latin-1 glyphs in labels.** The sans-serif stack this repo targets
  is missing a lot of the geometric-shape block, and a missing glyph renders as
  a blank box in the PNG while looking fine in the SVG.
- **Every script is runnable on its own** and writes only into its own
  `figures/` folder. `make_all.py` is a convenience, not a dependency.
