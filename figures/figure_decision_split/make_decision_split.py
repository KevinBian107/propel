"""Figure 2 — who decides what.

The single claim the rest of Propel is built around: the tedious, mechanical,
easily-botched half of research engineering is machine work, and the half that
decides what the experiment means is not. Propel automates the left column
aggressively and refuses to touch the right one.

    python figures/figure_decision_split/make_decision_split.py
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from propel_style import (  # noqa: E402
    PALETTE,
    apply_publication_style,
    box,
    canvas_px,
    finalize_figure,
)

OUT = Path(__file__).resolve().parent / "figures" / "decision_split"

W, H = 1000, 630

MACHINE = [
    ("Reading the codebase", "call graphs, config wiring, what actually calls what"),
    ("Checking code against the paper", "every equation, sign, axis, and constant"),
    ("Hunting silent bugs", "broadcasting, reductions, detached gradients, leakage"),
    ("Guarding against regressions", "existing configs still produce existing numbers"),
    ("Remembering", "what was tried, what failed, and why — across sessions"),
    ("Arguing with itself", "a second model critiques before anything reaches you"),
]

HUMAN = [
    ("What question is worth asking", "no model can tell you what your field needs"),
    ("Which paper, which variant", "\"like the paper\" is not a specification"),
    ("What counts as a result", "the threshold that makes the experiment mean something"),
    ("Which trade-off to accept", "faster vs. faithful, simple vs. exact — a values call"),
    ("When the evidence is enough", "knowing when to stop looking is domain judgment"),
    ("Whether to believe the number", "the last defence against a plausible wrong answer"),
]


def main() -> None:
    apply_publication_style(font_size=10)
    fig, ax = canvas_px(W, H)

    ax.text(30, 36, "Propel automates the left column. It never takes the right one.",
            ha="left", va="center", fontsize=12, color=PALETTE["ink"], fontweight="bold")
    ax.text(30, 58,
            "Not an autonomous agent. An assistant that does the work you shouldn't have to do "
            "by hand, and stops at every decision that is yours.",
            ha="left", va="center", fontsize=8.8, color=PALETTE["muted"])

    col_w, col_h = 455, 440
    left_x, right_x, top_y = 30, 515, 92

    # ── machine column ──
    box(ax, left_x, top_y, col_w, col_h, "", face=PALETTE["machine_soft"],
        edge=PALETTE["line"], radius=10, lw=1.0)
    ax.text(left_x + 22, top_y + 30, "MACHINE EXECUTES", ha="left", va="center",
            fontsize=9.2, color=PALETTE["machine"], fontweight="bold")
    ax.text(left_x + 22, top_y + 50, "automatic · announced · evidence-backed",
            ha="left", va="center", fontsize=8, color=PALETTE["dim"])

    for i, (head, sub) in enumerate(MACHINE):
        y = top_y + 86 + i * 62
        ax.plot([left_x + 22, left_x + 30], [y, y], color=PALETTE["machine"],
                lw=2.2, solid_capstyle="round", zorder=3)
        ax.text(left_x + 42, y, head, ha="left", va="center", fontsize=9.6,
                color=PALETTE["ink"], fontweight="bold")
        ax.text(left_x + 42, y + 17, sub, ha="left", va="center", fontsize=8.2,
                color=PALETTE["muted"])

    # ── human column ──
    box(ax, right_x, top_y, col_w, col_h, "", face=PALETTE["human_soft"],
        edge=PALETTE["human"], radius=10, lw=1.3)
    ax.text(right_x + 22, top_y + 30, "YOU DECIDE", ha="left", va="center",
            fontsize=9.2, color=PALETTE["human"], fontweight="bold")
    ax.text(right_x + 22, top_y + 50, "Propel stops here and does not proceed without you",
            ha="left", va="center", fontsize=8, color=PALETTE["human"])

    for i, (head, sub) in enumerate(HUMAN):
        y = top_y + 86 + i * 62
        ax.add_patch(__import__("matplotlib.pyplot", fromlist=["Polygon"]).Polygon(
            [(right_x + 26, y - 6), (right_x + 32, y), (right_x + 26, y + 6),
             (right_x + 20, y)],
            closed=True, facecolor=PALETTE["human"], edgecolor=PALETTE["human"],
            linewidth=1.0, zorder=3))
        ax.text(right_x + 42, y, head, ha="left", va="center", fontsize=9.6,
                color=PALETTE["ink"], fontweight="bold")
        ax.text(right_x + 42, y + 17, sub, ha="left", va="center", fontsize=8.2,
                color=PALETTE["muted"])

    # ── the line between them ──
    ax.text(W / 2, top_y + col_h + 32,
            "The line between the columns is the product.",
            ha="center", va="center", fontsize=9.6, color=PALETTE["ink"],
            fontweight="bold")
    ax.text(W / 2, top_y + col_h + 52,
            "Automation that crosses it doesn't save you work — it makes decisions "
            "you never saw, in code you'll publish.",
            ha="center", va="center", fontsize=8.4, color=PALETTE["muted"])

    finalize_figure(fig, OUT)


if __name__ == "__main__":
    main()
