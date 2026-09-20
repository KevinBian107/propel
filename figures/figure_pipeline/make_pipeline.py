"""Figure 1 — the Propel pipeline.

Seven stages, five human gates, two questioners, and the automatic Codex consult
that now runs at each gate. The bars underneath show which stages each mode runs.

    python figures/figure_pipeline/make_pipeline.py
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from matplotlib.pyplot import Circle, Polygon  # noqa: E402

from propel_style import (  # noqa: E402
    PALETTE,
    apply_publication_style,
    arrow,
    box,
    canvas_px,
    elbow,
    finalize_figure,
)

OUT = Path(__file__).resolve().parent / "figures" / "propel_pipeline"

W, H = 1152, 600
BOX_Y, BOX_W, BOX_H = 124, 120, 54
MID = BOX_Y + BOX_H / 2  # 151 — the flow line

STAGES = [
    (30, "Intake", "scoping questions", ""),
    (214, "Investigate", "trace code, read docs", "scratch/ README"),
    (398, "Design & plan", "paper to code map", "regression risk"),
    (558, "Implement", "per component", "auditors"),
    (704, "Debug", "root cause first", "3-strike limit"),
    (864, "Train", "launch, watch", "/monitor"),
    (1010, "Retrospective", "what failed, why", "registry"),
]

GATES = [(169.5, "G0"), (353.5, "G1"), (536, "G2"), (842, "G4")]
QUESTIONERS = [(191, "Q0"), (375, "Q1")]

# (label, palette key, solid spans, hollow spans)
MODE_ROWS = [
    ("Researcher", "researcher", [(30, 304)], []),
    ("Engineer", "engineer", [(30, 1100)], []),
    ("Debugger", "debugger", [(30, 304), (704, 120), (1010, 120)], []),
    ("Trainer", "trainer", [(704, 426)], [(704, 120)]),
]


def marker(ax, x, y, *, filled, color, r=7.0):
    ax.add_patch(Polygon(
        [(x, y - r), (x + r, y), (x, y + r), (x - r, y)], closed=True,
        facecolor=color if filled else PALETTE["paper"],
        edgecolor=color, linewidth=1.4, zorder=5))


def codex_dot(ax, x, y, r=5.0):
    ax.add_patch(Circle((x, y), r, facecolor=PALETTE["codex_soft"],
                        edgecolor=PALETTE["codex"], linewidth=1.3, zorder=5))


def main() -> None:
    apply_publication_style(font_size=10)
    fig, ax = canvas_px(W, H)

    box(ax, 1, 1, W - 2, H - 2, "", face="none",
        edge=PALETTE["rule"], radius=10, lw=1.0)

    ax.text(30, 36, "Propel pipeline", ha="left", va="center",
            fontsize=12, color=PALETTE["ink"], fontweight="bold")

    # ── legend ──
    marker(ax, 400, 36, filled=True, color=PALETTE["human"], r=6)
    ax.text(412, 36, "gate — Claude stops, you decide",
            ha="left", va="center", fontsize=8.6, color=PALETTE["muted"])
    marker(ax, 610, 36, filled=False, color=PALETTE["human"], r=6)
    ax.text(622, 36, "questioner — you supply references",
            ha="left", va="center", fontsize=8.6, color=PALETTE["muted"])
    codex_dot(ax, 842, 36, r=5.5)
    ax.text(854, 36, "Codex consult (automatic)",
            ha="left", va="center", fontsize=8.6, color=PALETTE["muted"])

    # ── G3 sits above Implement: it fires after every component, not once ──
    codex_dot(ax, 600, 80)
    marker(ax, 622, 80, filled=True, color=PALETTE["human"])
    ax.text(586, 80, "G3 · after each component", ha="right", va="center",
            fontsize=8.4, color=PALETTE["muted"])
    arrow(ax, (622, 90), (622, BOX_Y - 6), color=PALETTE["dim"], lw=1.0)

    # ── Debug loops back into Implement on a runtime error ──
    elbow(ax, [(744, BOX_Y - 4), (744, 100), (648, 100), (648, BOX_Y - 4)],
          color=PALETTE["dim"], lw=1.0)
    ax.text(696, 90, "runtime error", ha="center", va="center",
            fontsize=7.8, color=PALETTE["dim"])

    # ── stages ──
    for x, name, sub1, sub2 in STAGES:
        box(ax, x, BOX_Y, BOX_W, BOX_H, "", face=PALETTE["paper"],
            edge=PALETTE["line"], radius=6, lw=1.0)
        ax.text(x + BOX_W / 2, MID, name, ha="center", va="center",
                fontsize=10, color=PALETTE["ink"], fontweight="bold")
        ax.text(x + BOX_W / 2, 198, sub1, ha="center", va="center",
                fontsize=8, color=PALETTE["muted"])
        if sub2:
            ax.text(x + BOX_W / 2, 214, sub2, ha="center", va="center",
                    fontsize=7.8, color=PALETTE["dim"])

    # ── flow arrows, threaded around the gate markers ──
    for i in range(len(STAGES) - 1):
        x0 = STAGES[i][0] + BOX_W
        x1 = STAGES[i + 1][0]
        markers = sorted(m for m, _ in GATES + QUESTIONERS if x0 < m < x1)
        points = [x0 + 3] + [m for m in markers] + [x1 - 3]
        for a, b in zip(points, points[1:]):
            start = a + (8 if a in markers else 0)
            end = b - (8 if b in markers else 0)
            if end - start > 3:
                arrow(ax, (start, MID), (end, MID), color=PALETTE["dim"], lw=1.0)

    # ── gates, questioners, and the Codex dot that now sits under each gate ──
    for gx, label in GATES:
        marker(ax, gx, MID, filled=True, color=PALETTE["human"])
        ax.text(gx, 110, label, ha="center", va="center", fontsize=7.8,
                color=PALETTE["human"], fontweight="bold")
        codex_dot(ax, gx, 176)
    for qx, label in QUESTIONERS:
        marker(ax, qx, MID, filled=False, color=PALETTE["human"])
        ax.text(qx, 110, label, ha="center", va="center", fontsize=7.8,
                color=PALETTE["human"], fontweight="bold")

    # ── working memory loop into the next session ──
    elbow(ax, [(1070, 226), (1070, 250), (90, 250), (90, 224)],
          color=PALETTE["dim"], lw=1.0)
    ax.text(576, 276,
            "next session: hooks re-inject past experiments and designs, "
            "so Claude checks what was already tried",
            ha="center", va="center", fontsize=8.2, color=PALETTE["muted"])

    # ── mode coverage ──
    ax.text(30, 322, "Stages each mode runs", ha="left", va="center",
            fontsize=9.6, color=PALETTE["ink"], fontweight="bold")

    for i, (name, key, solid, hollow) in enumerate(MODE_ROWS):
        y = 362 + i * 40
        box(ax, 30, y, 1100, 8, "", face=PALETTE["machine_soft"],
            edge="none", radius=4, lw=0)
        for sx, sw in solid:
            box(ax, sx, y, sw, 8, "", face=PALETTE[key], edge="none",
                radius=4, lw=0)
        for hx, hw in hollow:  # partial coverage — runtime only
            box(ax, hx + 1, y + 1, hw - 2, 6, "", face=PALETTE["paper"],
                edge="none", radius=3, lw=0)
        ax.text(30, y - 11, name, ha="left", va="center", fontsize=8.4,
                color=PALETTE[key], fontweight="bold")

    ax.text(1130, 471, "hollow = partial coverage (runtime bugs only)",
            ha="right", va="center", fontsize=7.6, color=PALETTE["dim"])

    # ── footnotes ──
    for i, (txt, col) in enumerate([
        ("Auditors (paper alignment, silent bugs, JAX logic, regressions) check every change as "
         "read-only subagents and report at G3.", PALETTE["muted"]),
        ("Codex is consulted automatically at every gate, announced each time, and every claim it "
         "makes is verified against your code first.", PALETTE["muted"]),
        ("Everything here is machine work — except the filled diamonds. Those are decisions only "
         "you can make, and nothing moves past them without you.", PALETTE["human"]),
    ]):
        ax.text(30, 532 + i * 20, txt, ha="left", va="center", fontsize=8.2, color=col)

    finalize_figure(fig, OUT)


if __name__ == "__main__":
    main()
