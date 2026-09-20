"""Figure 3 — what happens at a gate.

Every major decision point runs the same five steps. Two models produce the
material; exactly one of them is a human, and that one decides.

    python figures/figure_codex_loop/make_codex_loop.py
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

OUT = Path(__file__).resolve().parent / "figures" / "codex_loop"

W, H = 1060, 520

STEPS = [
    (30, "1 · Claude drafts", "the design, the diff,\nthe diagnosis",
     PALETTE["machine"], PALETTE["machine_soft"]),
    (238, "2 · Codex critiques", "a second model reads\nthe same material",
     PALETTE["codex"], PALETTE["codex_soft"]),
    (446, "3 · Claude verifies", "every file:line checked\nagainst your repo",
     PALETTE["machine"], PALETTE["machine_soft"]),
    (654, "4 · Attributed card", "[claude] [codex] [both]\n[codex · unverified]",
     PALETTE["machine"], PALETTE["machine_soft"]),
    (862, "5 · You decide", "nothing proceeds\nuntil you answer",
     PALETTE["human"], PALETTE["human_soft"]),
]

BOX_W, BOX_H, BOX_Y = 168, 108, 132


def main() -> None:
    apply_publication_style(font_size=10)
    fig, ax = canvas_px(W, H)

    ax.text(30, 34, "What happens at every gate", ha="left", va="center",
            fontsize=12, color=PALETTE["ink"], fontweight="bold")
    ax.text(30, 56,
            'Automatic. Announced every time with a "Consulting Codex" line. No command to '
            "remember, and no way to forget it.",
            ha="left", va="center", fontsize=8.8, color=PALETTE["muted"])

    for i, (x, head, sub, accent, fill) in enumerate(STEPS):
        is_human = i == len(STEPS) - 1
        box(ax, x, BOX_Y, BOX_W, BOX_H, "", face=fill,
            edge=accent if is_human or i == 1 else PALETTE["line"],
            radius=9, lw=1.4 if is_human else 1.0)
        ax.text(x + BOX_W / 2, BOX_Y + 30, head, ha="center", va="center",
                fontsize=9.8, color=accent, fontweight="bold")
        for j, line in enumerate(sub.split("\n")):
            ax.text(x + BOX_W / 2, BOX_Y + 58 + j * 16, line, ha="center",
                    va="center", fontsize=8.2, color=PALETTE["muted"])
        if i < len(STEPS) - 1:
            arrow(ax, (x + BOX_W + 6, BOX_Y + BOX_H / 2),
                  (x + BOX_W + 34, BOX_Y + BOX_H / 2),
                  color=PALETTE["dim"], lw=1.1)

    # ── what never happens ──
    ax.text(30, 300, "What Codex never does", ha="left", va="center",
            fontsize=9.6, color=PALETTE["ink"], fontweight="bold")

    NEVER = [
        "write to your repository — it has no write path, only a read-only sandbox",
        "speak to you unfiltered — the raw reply is discarded after verification",
        "decide anything — agreement between two models is weak evidence, and Propel says so",
        "get invented — if the CLI didn't run, there is no Codex line in the card",
    ]
    for i, line in enumerate(NEVER):
        y = 328 + i * 24
        ax.text(38, y, "×", ha="center", va="center", fontsize=11,
                color=PALETTE["bad"])
        ax.text(54, y, line, ha="left", va="center", fontsize=8.6,
                color=PALETTE["muted"])

    # ── the off switch ──
    box(ax, 640, 296, 390, 112, "", face=PALETTE["panel"],
        edge=PALETTE["line"], radius=9, lw=1.0)
    ax.text(662, 322, "Don't want it?", ha="left", va="center", fontsize=9.4,
            color=PALETTE["ink"], fontweight="bold")
    ax.text(662, 346, "/disable-codex", ha="left", va="center", fontsize=9,
            color=PALETTE["human"], family="monospace")
    ax.text(662, 370, "Gates, questioners and auditors all still fire.",
            ha="left", va="center", fontsize=8.2, color=PALETTE["muted"])
    ax.text(662, 388, "Only the second opinion goes away.",
            ha="left", va="center", fontsize=8.2, color=PALETTE["muted"])

    ax.text(30, 448,
            "Two models disagreeing is the useful signal. Two models agreeing is cheap — "
            "they share most of their training data,",
            ha="left", va="center", fontsize=8.4, color=PALETTE["muted"])
    ax.text(30, 466,
            "so Propel reports consensus as weak evidence rather than as confirmation.",
            ha="left", va="center", fontsize=8.4, color=PALETTE["muted"])

    finalize_figure(fig, OUT)


if __name__ == "__main__":
    main()
