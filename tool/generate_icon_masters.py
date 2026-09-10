#!/usr/bin/env python3
"""Rasterise the Aerovolt mark into the two app-icon masters.

Headless Chrome is the rasteriser: it renders SVG at an exact pixel size with
real transparency, and it is already on the machine. There is no cairosvg or
rsvg-convert here.

Two masters, not one file used twice. iOS rejects alpha and applies its own
corner mask, so it gets an opaque plate. Android's adaptive foreground is
transparent and must keep its content inside the 66/108 safe zone, because the
launcher crops and animates that layer.
"""
import pathlib
import subprocess
import sys

from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent
MARK = ROOT / "assets/logo/aerovolt_mark.svg"
OUT = ROOT / "tool/icons"

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
SIZE = 1024
SURFACE = (13, 17, 23, 255)  # #0D1117, the app's own surface

IOS_FRACTION = 0.64      # ~18 % breathing room each side
ANDROID_FRACTION = 0.59  # inside the 66/108 adaptive safe zone (0.611)


def render_mark(px: int) -> Image.Image:
    """The mark, white on transparent, at px by px."""
    if not pathlib.Path(CHROME).exists():
        sys.exit(f"Chrome not found at {CHROME}; it is the only rasteriser here")
    OUT.mkdir(parents=True, exist_ok=True)
    html = OUT / "_render.html"
    png = OUT / "_render.png"
    # Inlined, not <img src="...">: Chrome blocks a file:// page from loading
    # a file:// subresource, and the failure mode is a blank screenshot rather
    # than an error.
    svg = MARK.read_text().replace(
        "<svg ", f'<svg width="{px}" height="{px}" ', 1
    )
    html.write_text(
        "<style>html,body{margin:0;padding:0}svg{display:block}</style>" + svg
    )
    subprocess.run(
        [
            CHROME, "--headless", "--disable-gpu", "--no-sandbox",
            "--hide-scrollbars", "--default-background-color=00000000",
            "--force-device-scale-factor=1",
            f"--window-size={px},{px}", f"--screenshot={png}",
            html.as_uri(),
        ],
        check=True,
        capture_output=True,
    )
    im = Image.open(png).convert("RGBA")
    html.unlink()
    png.unlink()
    if im.split()[3].getbbox() is None:
        sys.exit("the render came out empty — check the mark's viewBox")
    return im


def centred(mark: Image.Image, background: tuple[int, int, int, int]) -> Image.Image:
    canvas = Image.new("RGBA", (SIZE, SIZE), background)
    x = (SIZE - mark.width) // 2
    y = (SIZE - mark.height) // 2
    canvas.alpha_composite(mark, (x, y))
    return canvas


def main() -> None:
    ios = centred(render_mark(round(SIZE * IOS_FRACTION)), SURFACE)
    # iOS rejects an alpha channel outright.
    ios.convert("RGB").save(OUT / "icon_ios.png")

    android = centred(render_mark(round(SIZE * ANDROID_FRACTION)), (0, 0, 0, 0))
    android.save(OUT / "icon_android_foreground.png")

    for name in ("icon_ios.png", "icon_android_foreground.png"):
        im = Image.open(OUT / name)
        print(f"{name}  {im.size}  {im.mode}")


if __name__ == "__main__":
    main()
