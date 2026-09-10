#!/usr/bin/env python3
"""Derive the shipped logo SVGs from the supplied autotrace.

The trace is a full-canvas black plate with the logo knocked out of it. The
paths are reused untouched: wrapping them in a <mask> and painting a <rect>
through it inverts the polarity while preserving both the nonzero winding and
the antialiasing. Editing the geometry, or switching to fill-rule="evenodd",
drops shapes.

Colour therefore lives in the single fill on that rect, so one file serves any
tint and no light/dark variants are needed.
"""
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "assets/logo/aerovolt_traced.svg"
OUT_FULL = ROOT / "assets/logo/aerovolt.svg"
OUT_MARK = ROOT / "assets/logo/aerovolt_mark.svg"

# The trace's own canvas, and the transform its <g> carries.
CANVAS_W, CANVAS_H = 1408, 768
TRANSFORM = "translate(0,768) scale(0.1,-0.1)"

# Measured ink boxes, in canvas units.
FULL_BOX = (251.9, 136.6, 905.1, 469.3)
MARK_BOX = (527.5, 136.6, 350.5, 357.8)

PLATE = "M0 3840 l0 -3840 7040 0 7040 0 0 3840 0 3840 -7040 0 -7040 0 0\n-3840z"


def load_paths() -> list[str]:
    svg = SRC.read_text()
    body = svg[svg.index("</metadata>") + len("</metadata>"):]
    paths = re.findall(r'<path d="(.*?)"', body, re.S)
    if len(paths) != 8:
        raise SystemExit(f"expected 8 paths in the trace, found {len(paths)}")
    if not paths[0].startswith(PLATE):
        raise SystemExit("the plate rectangle is not where it was measured")
    return paths


def build(paths: list[str], box: tuple[float, float, float, float]) -> str:
    x, y, w, h = box
    drawn = "\n".join(f'<path d="{d}"/>' for d in paths)
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{x} {y} {w} {h}">\n'
        f'<mask id="a" maskUnits="userSpaceOnUse" '
        f'x="0" y="0" width="{CANVAS_W}" height="{CANVAS_H}">\n'
        f'<rect x="0" y="0" width="{CANVAS_W}" height="{CANVAS_H}" fill="#fff"/>\n'
        f'<g transform="{TRANSFORM}" fill="#000" stroke="none">\n{drawn}\n</g>\n'
        f'</mask>\n'
        f'<rect x="0" y="0" width="{CANVAS_W}" height="{CANVAS_H}" '
        f'fill="#FFFFFF" mask="url(#a)"/>\n'
        f'</svg>\n'
    )


def main() -> None:
    paths = load_paths()
    OUT_FULL.write_text(build(paths, FULL_BOX))
    OUT_MARK.write_text(build(paths, MARK_BOX))
    for p in (OUT_FULL, OUT_MARK):
        print(f"{p.relative_to(ROOT)}  {p.stat().st_size} bytes")


if __name__ == "__main__":
    main()
