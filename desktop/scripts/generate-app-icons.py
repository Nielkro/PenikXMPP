#!/usr/bin/env python3
"""Regenerate checked-in app icons from the canonical SVG.

Maintainer tool only; requires Python GI (Rsvg 2.0), Cairo and Pillow.
Package builds use the checked-in results and do not need these dependencies.
"""

from io import BytesIO
from pathlib import Path

import cairo
import gi
from PIL import Image

gi.require_version("Rsvg", "2.0")
from gi.repository import Rsvg  # noqa: E402


def main():
    data = Path(__file__).resolve().parents[1] / "main/data"
    icons = data / "icons/hicolor"
    handle = Rsvg.Handle.new_from_file(str(icons / "scalable/apps/im.dinox.dinox.svg"))
    sizes = (16, 24, 32, 48, 64, 128, 256, 512)
    images = {}
    for size in sizes:
        surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, size, size)
        viewport = Rsvg.Rectangle()
        viewport.x = viewport.y = 0
        viewport.width = viewport.height = size
        handle.render_document(cairo.Context(surface), viewport)
        output = BytesIO()
        surface.write_to_png(output)
        output.seek(0)
        images[size] = Image.open(output).convert("RGBA")
        if size in (16, 32, 48, 128, 256, 512):
            images[size].save(icons / f"{size}x{size}/apps/im.dinox.dinox.png")
    # Render each size from vectors; do not upscale the small tray icons.
    images[256].save(data / "dinox.ico", format="ICO",
                     sizes=[(s, s) for s in sizes if s <= 256],
                     append_images=[images[s] for s in sizes if s < 256])


if __name__ == "__main__":
    main()
