"""Figure 4 - automatic mode selection.

Propel reads the first message and picks the mode itself, then says which and
why. The user is not asked to classify their own problem before they have
started working on it.

    python figures/figure_modes/make_modes.py
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from propel_style import (  # noqa: E402
    PALETTE,
    apply_publication_style,
    arrow,
    box,
    canvas_px,
    finalize_figure,
)

OUT = Path(__file__).resolve().parent / "figures" / "mode_selection"

W, H = 1020, 560

# (example message, mode, palette key, active gates, what the mode is for)
ROWS = [
    ('"how does the reward actually get computed here?"',
     "Researcher", "researcher", "G0  G1",
     "understand before building"),
    ('"port the diffusion head from section 3.2"',
     "Engineer", "engineer", "G0  G1  G2  G3  G4",
     "the full pipeline"),
    ('"loss goes NaN around step 500, here’s the trace"',
     "Debugger", "debugger", "G0  G1  G4",
     "explain a specific wrong behavior"),
    ('"kick off the sweep on the cluster"',
     "Trainer", "trainer", "G4",
     "code is settled, execution isn’t"),
]

ROW_H = 74
TOP = 128
MSG_X, MSG_W = 30, 430
MODE_X, MODE_W = 520, 190
GATE_X = 748


def main() -> None:
    apply_publication_style(font_size=10)
    fig, ax = canvas_px(W, H)

    ax.text(30, 34, "You describe the problem. Propel picks the mode.",
            ha="left", va="center", fontsize=12, color=PALETTE["ink"],
            fontweight="bold")
    ax.text(30, 56,
            "No menu, no interruption. The choice is announced in one line with its "
            "reason, and it switches again on its own",
            ha="left", va="center", fontsize=8.8, color=PALETTE["muted"])
    ax.text(30, 74,
            "when the work crosses into another mode. /switch overrides it whenever "
            "you disagree.",
            ha="left", va="center", fontsize=8.8, color=PALETTE["muted"])

    for label, x in (("YOUR FIRST MESSAGE", MSG_X), ("MODE SELECTED", MODE_X),
                     ("GATES THAT FIRE", GATE_X)):
        ax.text(x, 108, label, ha="left", va="center", fontsize=7.8,
                color=PALETTE["dim"], fontweight="bold")

    for i, (msg, mode, key, gates, why) in enumerate(ROWS):
        y = TOP + i * ROW_H
        cy = y + 24

        box(ax, MSG_X, y, MSG_W, 48, "", face=PALETTE["panel"],
            edge=PALETTE["line"], radius=8, lw=1.0)
        ax.text(MSG_X + 16, cy, msg, ha="left", va="center", fontsize=9,
                color=PALETTE["ink"])

        arrow(ax, (MSG_X + MSG_W + 8, cy), (MODE_X - 8, cy),
              color=PALETTE["dim"], lw=1.1)

        box(ax, MODE_X, y, MODE_W, 48, "", face=PALETTE["paper"],
            edge=PALETTE[key], radius=8, lw=1.5)
        ax.text(MODE_X + MODE_W / 2, cy - 7, mode, ha="center", va="center",
                fontsize=9.6, color=PALETTE[key], fontweight="bold")
        ax.text(MODE_X + MODE_W / 2, cy + 10, why, ha="center", va="center",
                fontsize=7.6, color=PALETTE["muted"])

        ax.text(GATE_X, cy, gates, ha="left", va="center", fontsize=9,
                color=PALETTE[key], family="monospace")

    # ── the part that does not change with the mode ──
    y0 = TOP + len(ROWS) * ROW_H + 18
    box(ax, 30, y0, W - 60, 92, "", face=PALETTE["human_soft"],
        edge=PALETTE["human"], radius=9, lw=1.2)
    ax.text(52, y0 + 26, "What the mode never changes",
            ha="left", va="center", fontsize=9.4, color=PALETTE["human"],
            fontweight="bold")
    ax.text(52, y0 + 50,
            "Every mode stops at its gates and hands the decision back to you. A "
            "narrower mode runs fewer gates — it does not",
            ha="left", va="center", fontsize=8.5, color=PALETTE["ink"])
    ax.text(52, y0 + 68,
            "lower the bar at the ones it runs, and it never decides in your place "
            "to save you a question.",
            ha="left", va="center", fontsize=8.5, color=PALETTE["ink"])

    finalize_figure(fig, OUT)


if __name__ == "__main__":
    main()
