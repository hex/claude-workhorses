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
# The horse's moving parts, in the pixels of horse.webp (ART wide). Each part is a copy of the
# picture clipped to the part; the still picture leaves those areas out, so a part that moves
# leaves no second copy behind it.
ART = 560
# A part's clip runs lower than the area cut from the still picture: the band between them stays
# put, like a joint, so a part that turns opens no gap where it meets the head.
EAR_LEFT = ("172,0 216,0 236,50 234,96 178,96 170,60", "172,0 216,0 236,50 233,84 180,84 170,60")
EAR_RIGHT = ("388,0 344,0 324,50 326,96 382,96 390,60", "388,0 344,0 324,50 327,84 380,84 390,60")
TUFT = ("237,10 323,10 323,80 237,80", "237,10 323,10 323,66 237,66")
BROW = (296, 160, 66, 20)
EYES = ((230, 198), (330, 198))
LID = "#20a040"
SKIN = "#25ad45"
ANIMATION = (
    "<style>"
    ".horse-part{transform-box:fill-box}"
    ".ear-left{transform-origin:206px 90px;animation:ear-left 9s infinite}"
    ".ear-right{transform-origin:354px 90px;animation:ear-right 9s infinite}"
    ".tuft{transform-origin:280px 76px;animation:tuft 9s infinite}"
    ".brow{animation:brow 9s infinite}.brow-gap{opacity:0;animation:brow-gap 9s infinite}"
    ".lid{transform-box:fill-box;transform-origin:top;transform:scaleY(0);animation:blink 9s infinite}"
    "@keyframes blink{0%,10%,12.4%,80%,82.4%,100%{transform:scaleY(0)}11.2%,81.2%{transform:scaleY(1)}}"
    "@keyframes ear-left{0%,25%,32%,48%,58%,100%{transform:rotate(0)}26.5%,29.5%{transform:rotate(-9deg)}"
    "28%,31%{transform:rotate(3deg)}51%,55%{transform:rotate(-10deg)}}"
    "@keyframes ear-right{0%,48%,58%,100%{transform:rotate(0)}51%,55%{transform:rotate(-7deg)}}"
    "@keyframes tuft{0%,48%,60%,100%{transform:skewX(0)}50%{transform:skewX(-12deg)}"
    "53%{transform:skewX(-8deg)}55%{transform:skewX(-13deg)}57%{transform:skewX(3deg)}}"
    "@keyframes brow{0%,64%,74%,100%{transform:translateY(0)}66%,72%{transform:translateY(-7px)}}"
    "@keyframes brow-gap{0%,64%,74%,100%{opacity:0}64.5%,73.5%{opacity:1}}"
    "@media(prefers-reduced-motion:reduce){.horse-part,.brow-gap,.lid{animation:none}}"
    "</style>"
    '<defs><mask id="horse-cut" maskUnits="userSpaceOnUse" x="0" y="0" width="560" height="560">'
    '<rect width="560" height="560" fill="#fff"/>'
    f'<polygon points="{EAR_LEFT[1]}"/><polygon points="{EAR_RIGHT[1]}"/><polygon points="{TUFT[1]}"/>'
    "</mask>"
    f'<clipPath id="ear-left"><polygon points="{EAR_LEFT[0]}"/></clipPath>'
    f'<clipPath id="ear-right"><polygon points="{EAR_RIGHT[0]}"/></clipPath>'
    f'<clipPath id="tuft"><polygon points="{TUFT[0]}"/></clipPath>'
    f'<clipPath id="brow"><rect x="{BROW[0]}" y="{BROW[1]}" width="{BROW[2]}" height="{BROW[3]}"/></clipPath>'
    + "".join(f'<clipPath id="eye-{i}"><ellipse cx="{x}" cy="{y}" rx="29" ry="15"/></clipPath>' for i, (x, y) in enumerate(EYES))
    + "</defs>"
    '<g class="horse-part ear-left"><use href="#horse-art" clip-path="url(#ear-left)"/></g>'
    '<g class="horse-part ear-right"><use href="#horse-art" clip-path="url(#ear-right)"/></g>'
    '<g class="horse-part tuft"><use href="#horse-art" clip-path="url(#tuft)"/></g>'
    f'<rect class="brow-gap" x="{BROW[0]}" y="{BROW[1]}" width="{BROW[2]}" height="{BROW[3]}" fill="{SKIN}"/>'
    '<g class="horse-part brow"><use href="#horse-art" clip-path="url(#brow)"/></g>'
    + "".join(
        f'<g clip-path="url(#eye-{i})"><g class="lid"><rect x="{x - 30}" y="{y - 16}" width="60" height="32" fill="{LID}"/>'
        f'<rect x="{x - 30}" y="{y + 13}" width="60" height="3" fill="#111"/></g></g>'
        for i, (x, y) in enumerate(EYES)
    )
)
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
        f'<g transform="translate({(width - horse) / 2:g} {height - horse:g}) scale({horse / ART:g})">'
        f'<defs><image id="horse-art" href="data:image/webp;base64,{picture}" width="{ART}" height="{ART}"/></defs>'
        '<use href="#horse-art" mask="url(#horse-cut)"/>'
        f"{ANIMATION}</g>"
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
