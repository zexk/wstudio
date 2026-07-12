#!/usr/bin/env python3
"""Render a `tmux capture-pane -e -p` ANSI text dump to a PNG.

Usage: ansi2png.py input.ansi output.png [font_size]

Parses SGR sequences (reset, bold, faint, reverse, 30-37/90-97 fg,
40-47/100-107 bg, 38;5;N / 48;5;N indexed, 38;2;r;g;b / 48;2;r;g;b
truecolor, 39/49 default) and draws one cell per character: a
background rect plus the glyph, using DejaVu Sans Mono. Glyphs the
font lacks (Nerd Font icons, braille spectrum bars) render as tofu
boxes -- expected, not a bug (they're fine on a real terminal).
"""
import re
import sys
import glob

from PIL import Image, ImageDraw, ImageFont

ANSI_16 = [
    (0, 0, 0), (205, 0, 0), (0, 205, 0), (205, 205, 0),
    (0, 0, 238), (205, 0, 205), (0, 205, 205), (229, 229, 229),
    (127, 127, 127), (255, 0, 0), (0, 255, 0), (255, 255, 0),
    (92, 92, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255),
]

DEFAULT_FG = 7
DEFAULT_BG = 0


def resolve_color(c):
    """c is either an int (0-255 palette index) or an (r,g,b) tuple."""
    if isinstance(c, tuple):
        return c
    if c < 16:
        return ANSI_16[c]
    if c < 232:
        n = c - 16
        r, g, b = n // 36, (n % 36) // 6, n % 6
        scale = lambda v: 0 if v == 0 else 55 + v * 40
        return (scale(r), scale(g), scale(b))
    v = 8 + (c - 232) * 10
    return (v, v, v)


def dim_toward(fg, bg):
    return tuple((f + b) // 2 for f, b in zip(fg, bg))


def find_font():
    for pat in (
        "/nix/store/*/share/fonts/truetype/DejaVuSansMono.ttf",
        "/nix/store/*-dejavu-fonts-*/share/fonts/truetype/DejaVuSansMono.ttf",
    ):
        matches = glob.glob(pat)
        if matches:
            return matches[0]
    for p in (
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
        "/run/current-system/sw/share/X11/fonts/DejaVuSansMono.ttf",
    ):
        import os
        if os.path.exists(p):
            return p
    raise RuntimeError(
        "DejaVuSansMono.ttf not found; "
        "nix build --impure --expr '(builtins.getFlake \"flake:nixpkgs\")"
        ".legacyPackages.x86_64-linux.dejavu_fonts'"
    )


SGR_RE = re.compile(r"\x1b\[([0-9;]*)m")
CSI_SKIP_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


class CellStyle:
    __slots__ = ("fg", "bg", "bold", "faint", "reverse")

    def __init__(self):
        self.fg = DEFAULT_FG
        self.bg = DEFAULT_BG
        self.bold = False
        self.faint = False
        self.reverse = False

    def clone(self):
        s = CellStyle()
        s.fg, s.bg, s.bold, s.faint, s.reverse = (
            self.fg, self.bg, self.bold, self.faint, self.reverse,
        )
        return s

    def paint(self):
        fg = resolve_color(self.fg)
        bg = resolve_color(self.bg)
        if self.reverse:
            fg, bg = bg, fg
        if self.faint:
            fg = dim_toward(fg, bg)
        return fg, bg


def apply_sgr(style, codes):
    nums = [int(p) if p else 0 for p in codes.split(";")] if codes else [0]
    i = 0
    while i < len(nums):
        c = nums[i]
        if c == 0:
            style.fg, style.bg = DEFAULT_FG, DEFAULT_BG
            style.bold = style.faint = style.reverse = False
        elif c == 1:
            style.bold = True
        elif c == 2:
            style.faint = True
        elif c == 22:
            style.bold = style.faint = False
        elif c == 7:
            style.reverse = True
        elif c == 27:
            style.reverse = False
        elif 30 <= c <= 37:
            style.fg = c - 30
        elif c == 39:
            style.fg = DEFAULT_FG
        elif 40 <= c <= 47:
            style.bg = c - 40
        elif c == 49:
            style.bg = DEFAULT_BG
        elif 90 <= c <= 97:
            style.fg = c - 90 + 8
        elif 100 <= c <= 107:
            style.bg = c - 100 + 8
        elif c in (38, 48):
            mode = nums[i + 1] if i + 1 < len(nums) else 0
            if mode == 5:
                color = nums[i + 2]
                i += 2
            elif mode == 2:
                color = (nums[i + 2], nums[i + 3], nums[i + 4])
                i += 4
            else:
                color = DEFAULT_FG if c == 38 else DEFAULT_BG
            if c == 38:
                style.fg = color
            else:
                style.bg = color
        i += 1


def parse_grid(text):
    """Returns (rows, cols) where rows is a list of lists of (char, CellStyle)."""
    lines = text.split("\n")
    while lines and lines[-1] == "":
        lines.pop()
    grid = []
    cols = 0
    style = CellStyle()
    for line in lines:
        row = []
        style = style.clone()
        pos = 0
        while pos < len(line):
            m = SGR_RE.match(line, pos)
            if m:
                apply_sgr(style, m.group(1))
                pos = m.end()
                continue
            m = CSI_SKIP_RE.match(line, pos)
            if m:
                pos = m.end()
                continue
            ch = line[pos]
            pos += 1
            if ch == "\r":
                continue
            row.append((ch, style.clone()))
        grid.append(row)
        cols = max(cols, len(row))
    return grid, cols


def render(grid, cols, font_size=16):
    font = ImageFont.truetype(find_font(), font_size)
    bbox = font.getbbox("M")
    cell_w = font.getlength("M")
    cell_h = (bbox[3] - bbox[1]) * 1.35
    cell_w = int(cell_w)
    cell_h = int(cell_h)
    rows = len(grid)
    img = Image.new("RGB", (cols * cell_w, rows * cell_h), resolve_color(DEFAULT_BG))
    draw = ImageDraw.Draw(img)
    for y, row in enumerate(grid):
        for x, (ch, style) in enumerate(row):
            if ch == " ":
                fg, bg = style.paint()
                if bg != resolve_color(DEFAULT_BG):
                    draw.rectangle(
                        [x * cell_w, y * cell_h, (x + 1) * cell_w, (y + 1) * cell_h],
                        fill=bg,
                    )
                continue
            fg, bg = style.paint()
            if bg != resolve_color(DEFAULT_BG):
                draw.rectangle(
                    [x * cell_w, y * cell_h, (x + 1) * cell_w, (y + 1) * cell_h],
                    fill=bg,
                )
            draw.text((x * cell_w, y * cell_h - bbox[1]), ch, font=font, fill=fg)
    return img


def main():
    if len(sys.argv) < 3:
        print(f"usage: {sys.argv[0]} input.ansi output.png [font_size]", file=sys.stderr)
        sys.exit(1)
    in_path, out_path = sys.argv[1], sys.argv[2]
    font_size = int(sys.argv[3]) if len(sys.argv) > 3 else 16
    with open(in_path, encoding="utf-8", errors="replace") as f:
        text = f.read()
    grid, cols = parse_grid(text)
    img = render(grid, cols, font_size)
    img.save(out_path)
    print(f"wrote {out_path} ({img.width}x{img.height}, {len(grid)} rows x {cols} cols)")


if __name__ == "__main__":
    main()
