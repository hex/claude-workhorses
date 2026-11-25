#!/usr/bin/env python3
# ABOUTME: Converts captured terminal rows into accessible, animated SVGs.
# ABOUTME: Preserves ANSI colors, expands tabs, draws Powerline half circles, and records hashes, crops and frame timing.

import argparse
import hashlib
import json
import re
import subprocess
import unicodedata
import xml.etree.ElementTree as ET
from pathlib import Path


NS = "http://www.w3.org/2000/svg"
ET.register_namespace("", NS)
SGR = re.compile(r"\x1b\[([0-9;]*)m")
HYPERLINK = re.compile(r"\x1b\]8;[^\x07\x1b]*(?:\x07|\x1b\\)")
PALETTE = (
    "#000000", "#800000", "#008000", "#808000",
    "#000080", "#800080", "#008080", "#c0c0c0",
    "#808080", "#ff0000", "#00ff00", "#ffff00",
    "#0000ff", "#ff00ff", "#00ffff", "#ffffff",
)
# Powerline half circles (Nerd Fonts), which the SVG's fonts lack: drawn as shapes in their cell instead.
HALF_CIRCLES = {"\ue0b6": "left", "\ue0b4": "right"}
HALF_CIRCLE_SPLIT = re.compile("([\ue0b6\ue0b4])")
THEMES = {"light": ("#302a24", "#fbf6e9"), "dark": ("#eeeeee", "#191919")}


def element(parent, tag, text=None, **attrs):
    node = ET.SubElement(parent, f"{{{NS}}}{tag}", {k: str(v) for k, v in attrs.items()})
    node.text = text
    return node


def color(index):
    if not 0 <= index <= 255:
        raise ValueError(f"ANSI palette index outside 0..255: {index}")
    if index < 16:
        return PALETTE[index]
    if index >= 232:
        return "#{0:02x}{0:02x}{0:02x}".format(8 + (index - 232) * 10)
    levels = (0, 95, 135, 175, 215, 255)
    index -= 16
    return "#{:02x}{:02x}{:02x}".format(
        levels[index // 36], levels[index // 6 % 6], levels[index % 6]
    )


def cells(text):
    return sum(0 if unicodedata.combining(c) else
               2 if unicodedata.east_asian_width(c) in ("W", "F") else 1 for c in text)


def spans(ansi, foreground, background):
    defaults = [foreground, background, False, False, False, False, False]
    state = defaults.copy()
    offset = 0
    for match in SGR.finditer(ansi):
        if match.start() > offset:
            yield ansi[offset:match.start()], tuple(state)
        values = [int(value or 0) for value in match[1].split(";")]
        i = 0
        while i < len(values):
            value = values[i]
            if value == 0:
                state = defaults.copy()
            elif value in (1, 2, 3, 4, 7):
                state[{1: 2, 2: 3, 3: 4, 4: 5, 7: 6}[value]] = True
            elif value == 22:
                state[2:4] = [False, False]
            elif value in (23, 24, 27):
                state[{23: 4, 24: 5, 27: 6}[value]] = False
            elif value in (39, 49):
                state[0 if value == 39 else 1] = defaults[0 if value == 39 else 1]
            elif 30 <= value <= 37 or 90 <= value <= 97:
                state[0] = color(value - 30 if value < 90 else value - 90 + 8)
            elif 40 <= value <= 47 or 100 <= value <= 107:
                state[1] = color(value - 40 if value < 100 else value - 100 + 8)
            elif value in (38, 48):
                slot = 0 if value == 38 else 1
                mode = values[i + 1]
                if mode == 5:
                    state[slot] = color(values[i + 2])
                    i += 2
                elif mode == 2:
                    rgb = values[i + 2:i + 5]
                    if len(rgb) != 3 or any(not 0 <= c <= 255 for c in rgb):
                        raise ValueError(f"Invalid ANSI RGB: {rgb}")
                    state[slot] = "#{:02x}{:02x}{:02x}".format(*rgb)
                    i += 4
                else:
                    raise ValueError(f"Unsupported ANSI color mode: {mode}")
            else:
                raise ValueError(f"Unsupported ANSI style: {value}")
            i += 1
        offset = match.end()
    if offset < len(ansi):
        yield ansi[offset:], tuple(state)


def expand_tabs(row):
    """A tab moves to the next multiple of 8 columns, as in the terminal the row came from."""
    expanded, column = [], 0
    for word, style in row:
        text = ""
        for character in word:
            if character == "\t":
                text += " " * (8 - column % 8)
                column += 8 - column % 8
            else:
                text += character
                column += cells(character)
        expanded.append((text, style))
    return expanded


def half_circle(side, column):
    """A half ellipse filling one cell, from the row's baseline frame: the cell runs from -16.72 to 5.28."""
    left, right = column * 7.8, (column + 1) * 7.8
    if side == "left":
        return f"M{right:g} -16.72A7.8 11 0 0 0 {right:g} 5.28Z"
    return f"M{left:g} -16.72A7.8 11 0 0 1 {left:g} 5.28Z"


def draw(group, ansi, theme, start, stop):
    foreground, background = THEMES[theme]
    rows = [[]]
    ansi = HYPERLINK.sub("", ansi)
    for text, style in spans(ansi, foreground, background):
        if "\x1b" in text:
            raise ValueError("Capture contains a control sequence other than SGR")
        for part in text.splitlines(keepends=True):
            word = part.rstrip("\r\n")
            if word:
                if rows[-1] and rows[-1][-1][1] == style:
                    previous, _ = rows[-1].pop()
                    word = previous + word
                rows[-1].append((word, style))
            if part.endswith("\n"):
                rows.append([])
    for number, row in enumerate(rows[start:stop]):
        row = expand_tabs(row)
        y, column = 24 + number * 22, 0
        for word, style in row:
            fg, bg, bold, dim, italic, underline, inverse = style
            if inverse:
                fg, bg = bg, fg
            width = cells(word)
            if bg != background:
                element(group, "rect", x=f"{24 + column * 7.8:g}", y=y,
                        width=f"{width * 7.8:g}", height=22, fill=bg)
            column += width
        if not any(word.strip() for word, _ in row):
            continue
        line = element(group, "g", transform=f"translate(24 {y + 16.72:g})")
        column = 0
        for word, style in row:
            fg, bg, bold, dim, italic, underline, inverse = style
            if inverse:
                fg, bg = bg, fg
            for piece in HALF_CIRCLE_SPLIT.split(word):
                width = cells(piece)
                if piece in HALF_CIRCLES:
                    attrs = {"d": half_circle(HALF_CIRCLES[piece], column)}
                    if fg != foreground:
                        attrs["fill"] = fg
                    element(line, "path", **attrs)
                    column += 1
                    continue
                attrs = {"x": f"{column * 7.8:g}", "y": "0", "textLength": f"{width * 7.8:g}"}
                column += width
                if not piece.strip():
                    continue
                if fg != foreground:
                    attrs["fill"] = fg
                classes = [name for name, enabled in
                           (("b", bold), ("d", dim), ("i", italic), ("u", underline)) if enabled]
                if classes:
                    attrs["class"] = " ".join(classes)
                element(line, "text", piece, **attrs)


def render(manifest, output):
    data = json.loads(manifest.read_text())
    frames = data["frames"]
    if not frames:
        raise ValueError("A capture must have at least one frame")
    rows = max(c["crop"][1] - c["crop"][0] for f in frames for c in f["captures"].values())
    width, height = 110 * 7.8 + 48, rows * 22 + 48
    root = ET.Element(f"{{{NS}}}svg", {
        "viewBox": f"0 0 {width:g} {height:g}", "width": f"{width:g}", "height": f"{height:g}",
        "role": "img", "aria-labelledby": "title desc", "xml:space": "preserve",
    })
    element(root, "title", data["title"], id="title")
    element(root, "desc", data["description"], id="desc")
    metadata = {**data, "columns": 110, "seconds_per_frame": 2.5,
                "layout": {"font": 13, "cell": 7.8, "line": 22, "padding": 24}}
    for frame in frames:
        for capture in frame["captures"].values():
            source = manifest.parent / capture["file"]
            capture["sha256"] = hashlib.sha256(source.read_bytes()).hexdigest()
    manifest.write_text(json.dumps(data, indent=2) + "\n")
    element(root, "metadata", json.dumps(metadata, separators=(",", ":")))
    element(root, "style", (
        'text{font-family:Menlo,Consolas,"DejaVu Sans Mono",monospace;'
        'font-size:13px;white-space:pre;font-variant-numeric:tabular-nums;font-variant-ligatures:none}'
        '.b{font-weight:700}.d{opacity:.5}.i{font-style:italic}.u{text-decoration:underline}'
        '.theme-dark{display:none}@media(prefers-color-scheme:dark){'
        '.theme-light{display:none}.theme-dark{display:inline}}'
        '@media(prefers-reduced-motion:reduce){.frame{display:none}'
        '.frame.first{display:inline;opacity:1!important}.frame animate{display:none}}'
    ))
    count = len(frames)
    for index, frame in enumerate(frames):
        group = element(root, "g", **{"class": "frame first" if index == 0 else "frame",
                                     "opacity": 1 if index == 0 else 0, "data-frame": index})
        if count > 1:
            element(group, "animate", attributeName="opacity",
                    values=";".join("1" if i % count == index else "0" for i in range(count + 1)),
                    keyTimes=";".join(f"{i / count:.6f}" for i in range(count + 1)),
                    calcMode="discrete", dur=f"{count * 2.5:g}s", repeatCount="indefinite")
        for theme, capture in frame["captures"].items():
            themed = element(group, "g", fill=THEMES[theme][0], **{"class": f"theme-{theme}"})
            element(themed, "rect", width=f"{width:g}", height=f"{height:g}", rx=8, fill=THEMES[theme][1])
            draw(themed, (manifest.parent / capture["file"]).read_text(), theme, *capture["crop"])
    paints = {}
    for node in root.iter():
        if "fill" in node.attrib:
            paints.setdefault(node.attrib["fill"], []).append(node)
    style = root.find(f"{{{NS}}}style")
    for index, (paint, nodes) in enumerate(paints.items()):
        if len(nodes) < 5:
            continue
        name = f"p{index}"
        style.text += f".{name}{{fill:{paint}}}"
        for node in nodes:
            del node.attrib["fill"]
            node.set("class", " ".join(filter(None, (node.get("class"), name))))
    repeated = {}
    for parent in root.iter(f"{{{NS}}}g"):
        for node in parent:
            if node.tag == f"{{{NS}}}text":
                repeated.setdefault(ET.tostring(node), []).append((parent, node))
    definitions = element(root, "defs")
    for markup, occurrences in repeated.items():
        if len(occurrences) < 2 or len(markup) < 80:
            continue
        name = f"t{len(definitions)}"
        for parent, node in occurrences:
            position = list(parent).index(node)
            parent.remove(node)
            parent.insert(position, ET.Element(f"{{{NS}}}use", {"href": f"#{name}"}))
        node.set("id", name)
        definitions.append(node)
    content = ET.tostring(root, encoding="utf-8", xml_declaration=True)
    if len(content) >= 80_000:
        raise ValueError(f"{output.name} is {len(content)} bytes; limit is 80,000")
    output.write_bytes(content)
    print(f"{output}: {count} frames, {len(content)} bytes")



if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    render(args.manifest, args.output)
