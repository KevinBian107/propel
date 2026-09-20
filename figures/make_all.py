"""Regenerate every Propel figure, then sync the SVGs the docs actually load.

    python figures/make_all.py

Run this after changing anything a figure asserts — a new pipeline stage, a
different gate, a mode that gains or loses coverage. A figure nobody can
regenerate goes stale silently; one that is a script goes stale loudly.
"""

from __future__ import annotations

import runpy
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent

SCRIPTS = [
    ROOT / "figure_pipeline" / "make_pipeline.py",
    ROOT / "figure_decision_split" / "make_decision_split.py",
    ROOT / "figure_codex_loop" / "make_codex_loop.py",
    ROOT / "figure_modes" / "make_modes.py",
]

# Generated SVG -> the paths the README and the website load it from.
SYNC = {
    ROOT / "figure_pipeline/figures/propel_pipeline.svg": [
        REPO / "assets/propel_pipeline.svg",
        REPO / "website/assets/propel_pipeline.svg",
    ],
    ROOT / "figure_decision_split/figures/decision_split.svg": [
        REPO / "assets/decision_split.svg",
        REPO / "website/assets/decision_split.svg",
    ],
    ROOT / "figure_codex_loop/figures/codex_loop.svg": [
        REPO / "assets/codex_loop.svg",
        REPO / "website/assets/codex_loop.svg",
    ],
    ROOT / "figure_modes/figures/mode_selection.svg": [
        REPO / "assets/mode_selection.svg",
        REPO / "website/assets/mode_selection.svg",
    ],
}


def main() -> int:
    failed = []
    for script in SCRIPTS:
        print(f"\n== {script.relative_to(REPO)}")
        try:
            runpy.run_path(str(script), run_name="__main__")
        except Exception as exc:  # keep going; report everything at the end
            print(f"  FAILED: {exc}")
            failed.append(script)

    print("\n== sync")
    for src, destinations in SYNC.items():
        if not src.exists():
            print(f"  missing {src.relative_to(REPO)} - skipped")
            continue
        for dest in destinations:
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dest)
            print(f"  {src.name} -> {dest.relative_to(REPO)}")

    if failed:
        print(f"\n{len(failed)} figure(s) failed.")
        return 1
    print(f"\nAll {len(SCRIPTS)} figures regenerated and synced.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
