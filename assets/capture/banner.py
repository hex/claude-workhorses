#!/usr/bin/env python3
# ABOUTME: Builds assets/banner.svg: the wh-run capture animating under the horse, with a fade around the horse.
# ABOUTME: Usage: python3 -B assets/capture/banner.py (renders from wh-run.json; no host and no model call).

import base64
import re
import tempfile
from pathlib import Path

from render import THEMES, render

ROOT = Path(__file__).resolve().parents[2]
CAPTURE = ROOT / "assets/capture"
HORSE = CAPTURE / "horse.webp"
BANNER = ROOT / "assets/banner.svg"
TITLE = "claude-workhorses: wh runs a repository's tests on a workhorse, under the plugin's horse"


def build(terminal):
    """The banner's SVG text: the terminal's frames unchanged, then the fade and the horse on top."""
    size = re.search(r'viewBox="0 0 ([0-9.]+) ([0-9.]+)"', terminal)
    if size is None:
        raise ValueError("the terminal SVG has no viewBox to size the banner from")
    if not terminal.rstrip().endswith("</svg>"):
        raise ValueError("the terminal SVG does not end with </svg>")
    width, height = float(size.group(1)), float(size.group(2))
    horse = height * 0.86
    centre_x, centre_y = width / 2, height - horse / 2
    picture = base64.b64encode(HORSE.read_bytes()).decode()
    overlay = (
        f"<style>.fade{{stop-color:{THEMES['light'][1]}}}"
        f"@media(prefers-color-scheme:dark){{.fade{{stop-color:{THEMES['dark'][1]}}}}}</style>"
        '<radialGradient id="horse-fade" cx="0.5" cy="0.5" r="0.5">'
        '<stop offset="0.5" class="fade" stop-opacity="1"/><stop offset="1" class="fade" stop-opacity="0"/>'
        "</radialGradient>"
        f'<ellipse cx="{centre_x:g}" cy="{centre_y:g}" rx="{horse * 0.8:g}" ry="{horse * 0.72:g}" fill="url(#horse-fade)"/>'
        f'<image href="data:image/webp;base64,{picture}" x="{(width - horse) / 2:g}" y="{height - horse:g}"'
        f' width="{horse:g}" height="{horse:g}"/>'
    )
    banner = terminal.rstrip()[: -len("</svg>")] + overlay + "</svg>\n"
    return re.sub(r'<title id="title">[^<]*</title>', lambda _: f'<title id="title">{TITLE}</title>', banner, count=1)


def main():
    with tempfile.TemporaryDirectory() as work:
        terminal = Path(work) / "wh-run.svg"
        render(CAPTURE / "wh-run.json", terminal)
        BANNER.write_text(build(terminal.read_text()))


if __name__ == "__main__":
    main()
