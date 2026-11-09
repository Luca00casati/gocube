#!/usr/bin/env python3
"""Generates the core mod's 32x32 block textures (original, procedural pixel art).

Usage: python3 tools/gen_textures.py   (writes mods/core/textures/*.png)

Deterministic, and every texture tiles seamlessly (the atlas relies on that for
mipmaps). Technique, roughly how a pixel artist works:
  - each material has a small hand-picked colour ramp (dark -> light),
  - shapes come from periodic value noise / Voronoi cells, not per-pixel random,
  - values are quantized onto the ramp, with light from the top-left.
"""
import math
import random
from pathlib import Path

from PIL import Image

S = 32
OUT = Path(__file__).resolve().parent.parent / "mods" / "core" / "textures"


# --- helpers ---------------------------------------------------------------------

def hexc(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def ramp(*hexes):
    return [hexc(h) for h in hexes]


def pick(r, t):
    """Quantize t in [0,1] onto ramp r."""
    i = int(t * len(r))
    return r[max(0, min(len(r) - 1, i))]


class Noise:
    """Periodic value noise on an S x S torus, so textures tile."""

    def __init__(self, seed, cells):
        rnd = random.Random(seed)
        self.c = cells
        self.v = [[rnd.random() for _ in range(cells)] for _ in range(cells)]

    def at(self, x, y):
        fx, fy = x * self.c / S, y * self.c / S
        x0, y0 = int(math.floor(fx)), int(math.floor(fy))
        tx, ty = fx - x0, fy - y0
        tx, ty = tx * tx * (3 - 2 * tx), ty * ty * (3 - 2 * ty)
        c = self.c
        a = self.v[y0 % c][x0 % c]
        b = self.v[y0 % c][(x0 + 1) % c]
        d = self.v[(y0 + 1) % c][x0 % c]
        e = self.v[(y0 + 1) % c][(x0 + 1) % c]
        return (a * (1 - tx) + b * tx) * (1 - ty) + (d * (1 - tx) + e * tx) * ty


def fbm(seed, x, y, octaves=((4, 0.6), (8, 0.3), (16, 0.1)), _cache={}):
    total = 0.0
    for i, (cells, w) in enumerate(octaves):
        key = (seed, i, cells)
        if key not in _cache:
            _cache[key] = Noise(seed * 31 + i, cells)
        total += _cache[key].at(x, y) * w
    return total


def wrap_d(a, b):
    d = abs(a - b)
    return min(d, S - d)


def voronoi(points, x, y):
    """Returns (nearest index, d1, d2) with wrap-around distances."""
    best = []
    for i, (px, py) in enumerate(points):
        best.append((math.hypot(wrap_d(x, px), wrap_d(y, py)), i))
    best.sort()
    return best[0][1], best[0][0], best[1][0]


def jittered_points(seed, grid):
    rnd = random.Random(seed)
    step = S / grid
    return [((gx + rnd.uniform(0.15, 0.85)) * step, (gy + rnd.uniform(0.15, 0.85)) * step)
            for gy in range(grid) for gx in range(grid)]


def image(fn):
    img = Image.new("RGB", (S, S))
    for y in range(S):
        for x in range(S):
            img.putpixel((x, y), fn(x, y))
    return img


# --- materials ---------------------------------------------------------------------

STONE = ramp("#55585e", "#686b71", "#7a7d83", "#8b8e93", "#9da0a4")
DIRT = ramp("#4f3524", "#64432c", "#785237", "#8b6142", "#9c7150")
GRASS = ramp("#2f5a24", "#3c7029", "#4b8530", "#5c9a38", "#70ae44", "#86c052")
SAND = ramp("#b8a46d", "#c9b57c", "#d6c38a", "#e1cf98", "#eadba8")
WOOD = ramp("#6b4a2b", "#7f5833", "#93683d", "#a67748", "#b88653")
BARK = ramp("#3b2b1d", "#4a3624", "#59422c", "#6a5035")
LEAF = ramp("#1f4219", "#2a5420", "#356828", "#417c30", "#4f8f39")


def stone():
    def px(x, y):
        t = fbm(1, x, y, ((4, 0.4), (8, 0.35), (16, 0.25)))
        # sparse darker veins where a ridged noise is near its middle
        ridge = abs(fbm(2, x, y, ((4, 0.7), (8, 0.3))) - 0.5)
        if ridge < 0.025:
            return STONE[0]
        return pick(STONE[1:], (t - 0.3) / 0.4)
    return image(px)


def cobblestone():
    pts = jittered_points(3, 3)
    rnd = random.Random(33)
    tones = [rnd.uniform(-0.15, 0.15) for _ in pts]

    def px(x, y):
        i, d1, d2 = voronoi(pts, x + 0.5, y + 0.5)
        edge = d2 - d1
        if edge < 1.4:
            return STONE[0]  # mortar
        cx, cy = pts[i]
        # bevel: lit from top-left, shadow bottom-right, strongest near the edge
        dx = ((x + 0.5 - cx + S / 2) % S) - S / 2
        dy = ((y + 0.5 - cy + S / 2) % S) - S / 2
        light = -(dx + dy) / (abs(dx) + abs(dy) + 1e-6)
        rim = max(0.0, 1.0 - (edge - 1.4) / 3.0)
        t = 0.5 + tones[i] + 0.35 * light * rim + (fbm(4, x, y, ((16, 1.0),)) - 0.5) * 0.25
        return pick(STONE, t)
    return image(px)


def dirt(seed=5):
    rnd = random.Random(seed * 7)
    pebbles = {(rnd.randrange(S), rnd.randrange(S)) for _ in range(14)}

    def px(x, y):
        if (x, y) in pebbles:
            return DIRT[4]
        if ((x - 1) % S, y) in pebbles:
            return DIRT[1]  # pebble shadow
        t = fbm(seed, x, y, ((4, 0.3), (8, 0.4), (32, 0.3)))
        return pick(DIRT[1:], (t - 0.28) / 0.44)
    return image(px)


def grass_top():
    """Distinct small blades in many directions over a softly varied base, so it
    reads as a lawn rather than blotches; wraps at the edges to tile."""
    rnd = random.Random(6)
    v = [[0.0] * S for _ in range(S)]  # position on the GRASS ramp, 0..1
    for y in range(S):
        for x in range(S):
            tuft = fbm(6, x, y, ((8, 0.7), (16, 0.3))) - 0.5
            v[y][x] = 0.46 + 0.28 * tuft + rnd.uniform(-0.04, 0.04)
    dirs = [(0, -1), (1, -1), (-1, -1), (1, 0), (-1, 0), (0, 1), (1, 1), (-1, 1)]
    for _ in range(150):  # blades: shadowed root, bright tip
        x, y = rnd.randrange(S), rnd.randrange(S)
        dx, dy = rnd.choice(dirs)
        length = rnd.choice((2, 3, 3, 4))
        tip = rnd.uniform(0.78, 1.0)
        for k in range(length):
            px, py = (x + dx * k) % S, (y + dy * k) % S
            if k == 0:
                v[py][px] = min(v[py][px], 0.22)
            else:
                v[py][px] = max(v[py][px], 0.5 + (tip - 0.5) * k / (length - 1))
    return image(lambda x, y: pick(GRASS, v[y][x]))


def grass_side():
    d = dirt(seed=7)
    top = grass_top()
    rnd = random.Random(8)
    depth = []
    for x in range(S):  # jagged overhang, smoothed so it reads as tufts
        depth.append(rnd.choice((4, 5, 5, 6, 7, 9)))
    depth = [max(4, round((depth[x - 1] + 2 * depth[x] + depth[(x + 1) % S]) / 4)) for x in range(S)]
    for x in range(0, S, 7):
        depth[(x + rnd.randrange(7)) % S] += 3  # occasional drip
    img = d.copy()
    for x in range(S):
        for y in range(depth[x]):
            img.putpixel((x, y), top.getpixel((x, y)))
        img.putpixel((x, depth[x]), GRASS[0])          # shadow line under the grass
        img.putpixel((x, depth[x] + 1), DIRT[0] if x % 3 else DIRT[1])
    return img


def planks():
    rnd = random.Random(9)
    board_h = 8
    seams = [rnd.randrange(S) for _ in range(S // board_h)]
    tones = [rnd.uniform(-0.12, 0.12) for _ in range(S // board_h)]

    def px(x, y):
        b, dy = divmod(y, board_h)
        if dy == board_h - 1:
            return WOOD[0]              # gap between boards
        if x == seams[b]:
            return WOOD[1]              # board end
        if dy == 0:
            return WOOD[4]              # lit top edge
        # grain: noise stretched along x
        g = fbm(10 + b, x, y * 6, ((2, 0.6), (4, 0.4)))
        t = 0.45 + tones[b] + (g - 0.5) * 0.9
        if (x - seams[b]) % S in (2, S - 3) and dy in (2, 5):
            return WOOD[0]              # nail
        return pick(WOOD[1:4], t)
    return image(px)


def sand():
    def px(x, y):
        t = fbm(11, x, y, ((4, 0.4), (8, 0.25), (32, 0.35)))
        # faint wind ripples
        t += 0.08 * math.sin((x * 0.5 + y * 2 * math.pi / S * 3) + fbm(12, x, y) * 3)
        return pick(SAND, (t - 0.2) / 0.6)
    return image(px)


def gravel():
    pts = jittered_points(13, 6)
    rnd = random.Random(14)
    kinds = [rnd.choice((STONE, STONE, DIRT, SAND)) for _ in pts]
    tones = [rnd.uniform(0.25, 0.85) for _ in pts]

    def px(x, y):
        i, d1, d2 = voronoi(pts, x + 0.5, y + 0.5)
        if d2 - d1 < 1.0:
            return DIRT[0]
        cx, cy = pts[i]
        dx = ((x + 0.5 - cx + S / 2) % S) - S / 2
        dy = ((y + 0.5 - cy + S / 2) % S) - S / 2
        lit = 0.18 if dx + dy < -1.5 else (-0.18 if dx + dy > 1.5 else 0)
        return pick(kinds[i], tones[i] + lit)
    return image(px)


def log_side():
    def px(x, y):
        # vertical bark: noise stretched along y, with dark furrows
        n = fbm(15, x * 3, y, ((2, 0.5), (4, 0.3), (8, 0.2)))
        furrow = abs(((x + fbm(16, x, y, ((4, 1.0),)) * 6) % 8) - 4) < 0.8
        if furrow:
            return BARK[0]
        return pick(BARK[1:], (n - 0.25) / 0.5)
    return image(px)


def log_top():
    def px(x, y):
        dx, dy = x - S / 2 + 0.5, y - S / 2 + 0.5
        r = math.hypot(dx, dy)
        if r > S / 2 - 2.5:
            return pick(BARK, 0.3 + fbm(17, x, y) * 0.5)   # bark ring
        wobble = fbm(18, x, y, ((4, 1.0),)) * 2.5
        ring = (r + wobble) % 4
        if ring < 1:
            return WOOD[1]
        return pick(WOOD[2:], 0.3 + (r / S) * 0.8)
    return image(px)


def leaves():
    pts = jittered_points(19, 5)

    def px(x, y):
        i, d1, d2 = voronoi(pts, x + 0.5, y + 0.5)
        n = fbm(20, x, y, ((8, 0.6), (32, 0.4)))
        if d1 > 4.2 and n < 0.45:
            return LEAF[0]  # gaps between clusters
        t = 0.75 - d1 / 7 + (n - 0.5) * 0.5
        return pick(LEAF, t)
    return image(px)


def ore(name, colors, seed, blobs=5):
    """Stone with clustered mineral pieces: each piece shaded from the ramp."""
    base = stone()
    mineral = ramp(*colors)
    rnd = random.Random(seed)
    img = base.copy()
    for _ in range(blobs):
        cx, cy = rnd.randrange(S), rnd.randrange(S)
        r = rnd.uniform(1.6, 2.6)
        cells = set()
        for y in range(-3, 4):  # a rounded nugget, roughly 3-5 px across
            for x in range(-3, 4):
                if math.hypot(x, y * 1.15) <= r + rnd.uniform(-0.4, 0.4):
                    cells.add(((cx + x) % S, (cy + y) % S))
        for x, y in cells:
            lit_up = ((x - 1) % S, y) not in cells or (x, (y - 1) % S) not in cells
            dark_dn = ((x + 1) % S, y) not in cells or (x, (y + 1) % S) not in cells
            c = mineral[-1] if lit_up and not dark_dn else (mineral[0] if dark_dn and not lit_up else mineral[1])
            img.putpixel((x, y), c)
        for x, y in cells:  # dark outline where a chunk meets stone (bottom/right)
            for nx, ny in (((x + 1) % S, y), (x, (y + 1) % S)):
                if (nx, ny) not in cells:
                    img.putpixel((nx, ny), STONE[0])
    return img


LAMP = ramp("#7a4a12", "#c27a1c", "#eba83a", "#fbd36a", "#fff3b8")


def lamp():
    """A glowing block: warm, brightest in the middle, inside a dark iron frame."""
    def px(x, y):
        if x in (0, S - 1) or y in (0, S - 1):
            return (40, 34, 30)                      # outer frame
        if x in (1, S - 2) or y in (1, S - 2):
            return (78, 66, 56)                      # frame highlight
        if x in (S // 2 - 1, S // 2) or y in (S // 2 - 1, S // 2):
            return (52, 44, 38)                      # cross bars
        cx, cy = x - (S - 1) / 2, y - (S - 1) / 2
        glow = 1.0 - min(1.0, math.hypot(cx, cy) / (S * 0.62))
        t = glow * 0.85 + (fbm(30, x, y, ((8, 0.6), (16, 0.4))) - 0.5) * 0.3
        return pick(LAMP, t)
    return image(px)


def stick():
    """Item icon (transparent background): a short diagonal wooden stick."""
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    for i in range(6, S - 6):
        x, y = i, S - 1 - i
        for w in (-1, 0, 1):
            c = WOOD[3] if w < 0 else (WOOD[1] if w > 0 else WOOD[2])
            img.putpixel((x, y + w), c + (255,))
    for x, y in ((6, S - 7), (S - 7, 6)):  # darker cut ends
        img.putpixel((x, y), WOOD[0] + (255,))
    return img


# --- items (transparent background) and the furnace / chest blocks ---------------

IRON = ramp("#6e6a66", "#9a948e", "#c6c0b8", "#ece6dc")
GOLD = ramp("#8a5a08", "#c48a16", "#ecc03a", "#fff0a0")
COAL = ramp("#121214", "#24242a", "#3a3a44", "#5a5a66")


def blank():
    return Image.new("RGBA", (S, S), (0, 0, 0, 0))


def _px(img, x, y, c):
    if 0 <= x < S and 0 <= y < S:
        img.putpixel((x, y), tuple(c) + (255,))


def coal_lump():
    img = blank()
    rnd = random.Random(40)
    cx, cy = S / 2, S / 2 + 1
    for y in range(S):
        for x in range(S):
            d = math.hypot((x - cx) / 10.5, (y - cy) / 8.5) + 0.12 * fbm(41, x, y, ((8, 1.0),))
            if d < 1.0:
                lit = (cx - x + cy - y) / 20.0
                _px(img, x, y, pick(COAL, 0.45 + lit - d * 0.3 + rnd.uniform(-0.08, 0.08)))
    return img


def ingot(palette):
    def make():
        img = blank()
        for y in range(11, 22):
            inset = (y - 11) // 3  # slanted ends: a trapezoid seen from the side
            for x in range(5 + 3 - inset, 27 - 3 + inset):
                t = 0.9 if y == 11 else (0.15 if y == 21 else 0.55 + (x - 16) / 40)
                _px(img, x, y, pick(palette, t))
        return img
    return make


def tool(head_palette, kind):
    """A handle from bottom-left to top-right with a pickaxe or axe head."""
    def make():
        img = blank()
        for i in range(5, 27):  # handle
            _px(img, i, S - 1 - i, WOOD[2])
            _px(img, i + 1, S - 1 - i, WOOD[1])
        if kind == "pickaxe":
            # A thick curved head across the handle's top end. The handle runs
            # along d = (1, -1); the head runs along p = (1, 1) and curves back.
            cx, cy = 21.5, 10.5
            for k10 in range(-110, 111):
                k = k10 / 10.0
                x = cx + k * 0.75 - k * k * 0.045
                y = cy + k * 0.75 + k * k * 0.045
                for w in (-1, 0, 1):
                    shade = 0.85 if w < 0 else (0.25 if w > 0 else 0.55)
                    _px(img, int(round(x + w * 0.7)), int(round(y - w * 0.7)), pick(head_palette, shade))
        elif kind == "hoe":
            # a flat head sticking out to one side at the top of the handle
            for x in range(13, 25):
                for y in (5, 6, 7):
                    shade = 0.85 if y == 5 else (0.3 if y == 7 else 0.55)
                    _px(img, x, y, pick(head_palette, shade))
            for y in range(8, 11):
                _px(img, 13, y, pick(head_palette, 0.4))
                _px(img, 14, y, pick(head_palette, 0.6))
        elif kind == "sword":
            img = blank()  # its own handle: short grip, guard, long blade
            for i in range(4, 10):
                _px(img, i, S - 1 - i, WOOD[2])
                _px(img, i + 1, S - 1 - i, WOOD[1])
            for k in range(-4, 5):  # guard across the grip
                _px(img, 10 + k, S - 1 - 10 + k, pick(head_palette, 0.3))
                _px(img, 11 + k, S - 1 - 10 + k, pick(head_palette, 0.5))
            for i in range(11, 28):  # blade
                for w in (-1, 0, 1):
                    shade = 0.95 if w < 0 else (0.35 if w > 0 else 0.65)
                    _px(img, i + w, S - 1 - i, pick(head_palette, shade))
                _px(img, i, S - 1 - i - 1, pick(head_palette, 0.8))
        else:
            # an axe blade on one side of the handle's top
            for y in range(3, 15):
                for x in range(14, 23):
                    if (x - 14) + (14 - y) * 0.6 < 9 and (x - 18) ** 2 + (y - 9) ** 2 < 42:
                        _px(img, x, y, pick(head_palette, 0.25 + (22 - x) / 12))
        return img
    return make


def furnace_side():
    base = cobblestone().convert("RGB")
    img = base.copy()
    for y in range(17, 28):  # the opening, with embers inside
        for x in range(9, 23):
            edge = y == 17 or x in (9, 22)
            if edge:
                img.putpixel((x, y), (40, 40, 44))
            else:
                glow = max(0.0, 1.0 - (27 - y) / 10) * (0.6 + 0.4 * fbm(43, x, y, ((8, 1.0),)))
                img.putpixel((x, y), tuple(int(max(0, min(255, v))) for v in (30 + 210 * glow, 18 + 110 * glow * glow, 10 + 30 * glow)))
    return img


def furnace_top():
    return stone()


def chest_side():
    img = planks()
    for x in range(S):  # iron band and a latch
        for y in (10, 11):
            img.putpixel((x, y), (60, 58, 56) if y == 11 else (110, 106, 100))
    for y in range(9, 16):
        for x in range(14, 18):
            img.putpixel((x, y), (190, 184, 170) if y in (9, 10) else (130, 124, 116))
    return img


def chest_top():
    img = planks()
    for x in range(S):
        img.putpixel((x, 0), (60, 58, 56))
        img.putpixel((x, S - 1), (60, 58, 56))
    return img


# --- building blocks: torch, ladder, door, glass ------------------------------------

def torch():
    """Drawn for a 2/16-wide box at the tile's centre (columns 14..17): a stick
    from row 18 down, a flame in rows 12..17 (the box's top face samples the
    middle of the flame)."""
    img = blank()
    for y in range(18, 32):
        for x in range(14, 18):
            _px(img, x, y, WOOD[3] if x == 14 else (WOOD[1] if x == 17 else WOOD[2]))
    flame = [(255, 246, 190), (255, 214, 92), (246, 150, 40), (200, 90, 24)]
    for y in range(12, 18):
        for x in range(14, 18):
            t = (y - 12) / 6 + (0.25 if x in (14, 17) else 0.0)
            _px(img, x, y, flame[min(3, int(t * 3.2))])
    return img


def ladder():
    img = blank()
    for y in range(S):
        for x in (3, 4, 5, 26, 27, 28):  # rails
            _px(img, x, y, WOOD[3] if x in (3, 26) else (WOOD[1] if x in (5, 28) else WOOD[2]))
    for r in range(2, S, 8):  # rungs
        for x in range(6, 26):
            for y in (r, r + 1, r + 2):
                _px(img, x, y, WOOD[3] if y == r else (WOOD[1] if y == r + 2 else WOOD[2]))
    return img


def _door(upper):
    def make():
        base = planks().convert("RGBA")
        img = base.copy()
        for y in range(S):
            for x in range(S):
                frame = x < 3 or x > 28 or (y < 3 and upper) or (y > 28 and not upper)
                if frame:
                    c = WOOD[0]
                    img.putpixel((x, y), c + (255,))
        if upper:
            for y in range(7, 21):  # a small window (see-through) with a cross bar
                for x in range(8, 24):
                    if x in (15, 16) or y in (13, 14):
                        img.putpixel((x, y), WOOD[1] + (255,))
                    else:
                        img.putpixel((x, y), (0, 0, 0, 0))
        else:
            for y in range(12, 15):  # handle
                img.putpixel((25, y), (60, 58, 56, 255))
                img.putpixel((26, y), (130, 124, 116, 255))
        return img
    return make


def glass():
    img = blank()
    edge = (205, 225, 235)
    for i in range(S):
        for e in (0, S - 1):
            _px(img, i, e, edge)
            _px(img, e, i, edge)
    for k in range(5):  # a couple of glints
        _px(img, 6 + k, 10 - k, (235, 245, 250))
        _px(img, 9 + k, 11 - k, (225, 238, 245))
        _px(img, 20 + k, 26 - k, (225, 238, 245))
    return img


# --- armour, farming, plants -----------------------------------------------------

def _shape_icon(rows, palette):
    """Icon from an ASCII mask: '#' body, '+' highlight, '-' shadow."""
    def make():
        img = blank()
        oy = (S - len(rows)) // 2
        for y, row in enumerate(rows):
            ox = (S - len(row)) // 2
            for x, ch in enumerate(row):
                if ch in "#+-":
                    t = {"#": 0.55, "+": 0.9, "-": 0.2}[ch]
                    _px(img, ox + x, oy + y, pick(palette, t + 0.06 * ((x * 7 + y * 3) % 3 - 1)))
        return img
    return make


HELMET = [
    "    ++++++++++++    ",
    "  ++############++  ",
    " +################- ",
    " +################- ",
    " +######----######- ",
    " +####-      -####- ",
    " +###-        -###- ",
    " +###          ###- ",
    "  ##-          -##  ",
]
CHESTPLATE = [
    " +++++      +++++ ",
    "+######----######-",
    "+################-",
    "+################-",
    " -##############- ",
    "   +##########-   ",
    "   +##########-   ",
    "   +##########-   ",
    "   +##########-   ",
    "   +##########-   ",
    "   +##########-   ",
    "   +##########-   ",
    "    ----------    ",
]
LEGGINGS = [
    "++++++++++++++",
    "+############-",
    "+############-",
    "+#####--#####-",
    "+####-  +####-",
    "+####-  +####-",
    "+####-  +####-",
    "+####-  +####-",
    "+####-  +####-",
    "+####-  +####-",
    "+####-  +####-",
    " ----    ---- ",
]
BOOTS = [
    "+###-    +###-  ",
    "+###-    +###-  ",
    "+###-    +###-  ",
    "+###-    +###-  ",
    "+#####-  +#####-",
    "+#####-  +#####-",
    " -----    ----- ",
]
SEEDS = None
WHEAT = ramp("#6e5a1c", "#a0842c", "#c8a83c", "#e6cc6a")
GREEN = ramp("#2c4e1c", "#3c6a26", "#4f8a30", "#68a63e")


def seeds():
    img = blank()
    rnd = random.Random(50)
    for _ in range(9):
        x, y = rnd.randrange(9, 23), rnd.randrange(9, 23)
        for dx, dy in ((0, 0), (1, 0), (0, 1)):
            _px(img, x + dx, y + dy, WHEAT[1] if dy else WHEAT[2])
    return img


def wheat_item():
    img = blank()
    for k, x0 in enumerate((11, 15, 19)):
        for y in range(10, 29):  # stalks
            _px(img, x0 + (y - 10) // 9 - 1, y, GREEN[2] if y > 18 else WHEAT[1])
        for y in range(4, 14):  # ears
            _px(img, x0 - 1, y, WHEAT[2 + (y % 2)])
            _px(img, x0, y, WHEAT[3 - (y % 2)])
    return img


def bread():
    img = blank()
    cx, cy = 16, 17
    for y in range(S):
        for x in range(S):
            d = ((x - cx) / 12) ** 2 + ((y - cy) / 7) ** 2
            if d < 1:
                top = y < cy - 2
                c = (196, 136, 64) if top else (168, 108, 46)
                if top and (x - 6) % 6 in (0, 1) and y < cy - 3:
                    c = (226, 186, 120)  # scored top
                _px(img, x, y, c)
    return img


def farmland_top():
    base = dirt(seed=60)
    img = base.copy()
    for y in range(S):
        for x in range(S):
            r, g, b = img.getpixel((x, y))[:3]
            k = 0.62 if y % 8 in (0, 1) else 0.85  # furrows
            img.putpixel((x, y), (int(r * k), int(g * k), int(b * k)))
    return img


def crop(stage):
    """Wheat at stage 0..7: taller and yellower as it grows (drawn for a cross)."""
    def make():
        img = blank()
        rnd = random.Random(70 + stage)
        height = 6 + stage * 3.4
        ripe = stage / 7
        for x0 in range(2, 31, 4):
            h = int(height * rnd.uniform(0.8, 1.0))
            for y in range(S - h, S):
                t = (S - y) / max(1, h)
                if stage == 7 or (stage == 6 and y < S - h / 2):
                    col = WHEAT[1 + int(t * 2)]  # ripening from the top
                else:
                    col = GREEN[1 + int(t * 2)] if ripe < 0.6 or y > S - h + 6 else WHEAT[1 + int(t * 2)]
                _px(img, x0 + (1 if y < S - h / 2 and x0 % 8 == 2 else 0), y, col)
            if stage >= 5:  # ears at the top
                for y in range(S - h, S - h + 5):
                    _px(img, x0 + 1, y, WHEAT[2 if stage == 7 else 1])
        return img
    return make


def tall_grass():
    img = blank()
    rnd = random.Random(80)
    for _ in range(14):
        x = rnd.randrange(3, 29)
        h = rnd.randrange(12, 28)
        lean = rnd.choice((-1, 0, 1))
        for k in range(h):
            y = S - 1 - k
            xx = x + (lean * k) // 9
            _px(img, xx, y, GREEN[1 + min(2, (k * 3) // h)] if k < h - 2 else GREEN[3])
    return img


def flower(petal, centre):
    def make():
        img = blank()
        for y in range(16, 32):  # stem and a leaf
            _px(img, 16, y, GREEN[2])
        for x in range(17, 21):
            _px(img, x, 24 - (x - 17) // 2, GREEN[1])
        for dx, dy in ((0, -3), (3, 0), (0, 3), (-3, 0), (2, -2), (2, 2), (-2, 2), (-2, -2)):
            for ex in (0, 1):
                for ey in (0, 1):
                    _px(img, 15 + dx + ex, 11 + dy + ey, petal)
        for ex in (0, 1):
            for ey in (0, 1):
                _px(img, 15 + ex, 11 + ey, centre)
        return img
    return make


# --- biomes: desert, snow, birch, spruce, lava ----------------------------------------

def remap(img, palette):
    """Recolours an image onto another ramp by brightness (keeps its pattern)."""
    img = img.convert("RGBA")
    lum = [[sum(img.getpixel((x, y))[:3]) for x in range(S)] for y in range(S)]
    lo = min(min(r) for r in lum)
    hi = max(max(r) for r in lum)
    out = img.copy()
    for y in range(S):
        for x in range(S):
            a = img.getpixel((x, y))[3]
            if a:
                out.putpixel((x, y), pick(palette, (lum[y][x] - lo) / max(1, hi - lo)) + (a,))
    return out


SANDSTONE = ramp("#a88f58", "#bba368", "#cdb57a", "#dcc68c")
SNOW = ramp("#d8e2ec", "#e6eef5", "#f2f7fb", "#ffffff")
ICE = ramp("#7fa8d8", "#93b9e2", "#a9caeb", "#c3dcf3")
BIRCH_BARK = ramp("#cfcac0", "#ddd8cf", "#e9e5dd", "#f4f1ea")
BIRCH_LEAF = ramp("#3a6a24", "#4a7e2c", "#5a9236", "#6ea442", "#82b450")
SPRUCE_BARK = ramp("#2a1d13", "#36261a", "#432f20", "#513a28")
SPRUCE_LEAF = ramp("#16301f", "#1d3c27", "#25492f", "#2e5737", "#386540")
CACTUS = ramp("#2c5a1e", "#367026", "#43832e", "#529638")
LAVA = ramp("#8a1c06", "#c8380c", "#ec6418", "#fb9a2a", "#ffd25a")


def sandstone():
    def px(x, y):
        band = (y // 6) % 2
        n = fbm(90, x, y * 3, ((4, 0.6), (8, 0.4)))
        return pick(SANDSTONE, 0.25 + n * 0.5 + band * 0.18 - (0.25 if y % 6 == 0 else 0))
    return image(px)


def snow_top():
    return image(lambda x, y: pick(SNOW, 0.3 + fbm(91, x, y, ((4, 0.5), (16, 0.5))) * 0.7))


def snow_side():
    d = dirt(seed=92)
    img = d.convert("RGB").copy()
    rnd = random.Random(93)
    depth = [max(3, round(4 + rnd.uniform(-1.5, 2.5))) for _ in range(S)]
    for x in range(S):
        for y in range(depth[x]):
            img.putpixel((x, y), pick(SNOW, 0.4 + fbm(94, x, y) * 0.6))
    return img


def ice():
    def px(x, y):
        n = fbm(95, x, y, ((4, 0.7), (8, 0.3)))
        crack = abs(((x * 0.9 + y * 0.4 + fbm(96, x, y, ((4, 1.0),)) * 9) % 13) - 6.5) < 0.5
        return pick(ICE, 0.95 if crack else 0.2 + n * 0.6)
    return image(px)


def birch_side():
    rnd = random.Random(97)
    marks = [(rnd.randrange(S), rnd.randrange(S), rnd.randrange(2, 6)) for _ in range(9)]

    def px(x, y):
        for mx, my, w in marks:
            if 0 <= (x - mx) % S < w and y == my:
                return (40, 36, 32)
        return pick(BIRCH_BARK, 0.3 + fbm(98, x * 2, y, ((4, 1.0),)) * 0.6)
    return image(px)


def lava():
    def px(x, y):
        n = fbm(99, x, y, ((4, 0.55), (8, 0.3), (16, 0.15)))
        return pick(LAVA, n * 1.15)
    return image(px)


def cactus_side():
    def px(x, y):
        rib = x % 6 in (0, 1)
        spine = (x % 6 == 3) and (y % 7 == 2)
        if spine:
            return (230, 222, 180)
        return pick(CACTUS, (0.15 if rib else 0.55) + fbm(100, x, y) * 0.3)
    return image(px)


def cactus_top():
    def px(x, y):
        d = math.hypot(x - S / 2 + 0.5, y - S / 2 + 0.5)
        return pick(CACTUS, 0.85 - d / S + fbm(101, x, y) * 0.2)
    return image(px)


def dead_bush():
    img = blank()
    twig = (110, 80, 44)
    rnd = random.Random(102)
    def branch(x, y, angle, length, depth):
        for i in range(length):
            xx = int(round(x + math.cos(angle) * i))
            yy = int(round(y - math.sin(angle) * i))
            _px(img, xx, yy, twig)
        ex, ey = x + math.cos(angle) * length, y - math.sin(angle) * length
        if depth > 0:
            for da in (-0.5, 0.45):
                branch(ex, ey, angle + da + rnd.uniform(-0.2, 0.2), int(length * 0.7), depth - 1)
    branch(16, 31, math.pi / 2, 9, 3)
    return img


TEXTURES = {
    "stone": stone,
    "cobblestone": cobblestone,
    "dirt": dirt,
    "grass_top": grass_top,
    "grass_side": grass_side,
    "planks": planks,
    "sand": sand,
    "gravel": gravel,
    "log_side": log_side,
    "log_top": log_top,
    "leaves": leaves,
    "coal_ore": lambda: ore("coal", ("#1a1a1d", "#2a2a2f", "#4a4a52"), 21, blobs=6),
    "iron_ore": lambda: ore("iron", ("#7d5c48", "#b48a6c", "#e2c2a2"), 22, blobs=5),
    "gold_ore": lambda: ore("gold", ("#9c7210", "#dcae26", "#fde877"), 23, blobs=5),
    "crystal_ore": lambda: ore("crystal", ("#18707c", "#38bcc6", "#b2f6f3"), 24, blobs=4),
    "lamp": lamp,
    "stick": stick,
    "coal": coal_lump,
    "iron_ingot": ingot(IRON),
    "gold_ingot": ingot(GOLD),
    "wood_pickaxe": tool(WOOD, "pickaxe"),
    "stone_pickaxe": tool(STONE, "pickaxe"),
    "wood_axe": tool(WOOD, "axe"),
    "stone_axe": tool(STONE, "axe"),
    "furnace_side": furnace_side,
    "furnace_top": furnace_top,
    "chest_side": chest_side,
    "chest_top": chest_top,
    "torch": torch,
    "ladder": ladder,
    "door_lower": _door(False),
    "door_upper": _door(True),
    "glass": glass,
    "iron_pickaxe": tool(IRON, "pickaxe"),
    "iron_axe": tool(IRON, "axe"),
    "wood_hoe": tool(WOOD, "hoe"),
    "stone_hoe": tool(STONE, "hoe"),
    "iron_hoe": tool(IRON, "hoe"),
    "wood_sword": tool(WOOD, "sword"),
    "stone_sword": tool(STONE, "sword"),
    "iron_sword": tool(IRON, "sword"),
    "iron_helmet": _shape_icon(HELMET, IRON),
    "iron_chestplate": _shape_icon(CHESTPLATE, IRON),
    "iron_leggings": _shape_icon(LEGGINGS, IRON),
    "iron_boots": _shape_icon(BOOTS, IRON),
    "seeds": seeds,
    "wheat": wheat_item,
    "bread": bread,
    "farmland_top": farmland_top,
    "tall_grass": tall_grass,
    "bluebell": flower((96, 128, 226), (240, 230, 140)),
    "sunpetal": flower((246, 206, 60), (150, 90, 30)),
    **{"wheat_%d" % i: crop(i) for i in range(8)},
    "sandstone": sandstone,
    "snow_grass_top": snow_top,
    "snow_grass_side": snow_side,
    "ice": ice,
    "birch_log_side": birch_side,
    "birch_log_top": lambda: remap(log_top(), ramp("#a68a62", "#b99c72", "#cbb085", "#dcc49a")),
    "birch_leaves": lambda: remap(leaves(), BIRCH_LEAF),
    "spruce_log_side": lambda: remap(log_side(), SPRUCE_BARK),
    "spruce_log_top": lambda: remap(log_top(), ramp("#5a3e24", "#6b4b2c", "#7c5834", "#8d663e")),
    "spruce_leaves": lambda: remap(leaves(), SPRUCE_LEAF),
    "cactus_side": cactus_side,
    "cactus_top": cactus_top,
    "dead_bush": dead_bush,
    "lava": lava,
}

if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    for name, fn in TEXTURES.items():
        fn().save(OUT / f"{name}.png")
    print("wrote %d textures to %s" % (len(TEXTURES), OUT))
