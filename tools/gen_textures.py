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
    rnd = random.Random(6)
    blades = set()
    for _ in range(70):
        x, y = rnd.randrange(S), rnd.randrange(S)
        blades.add((x, y, rnd.random() < 0.6))

    bright = {(x, y) for x, y, b in blades if b}
    dark = {(x, y) for x, y, b in blades if not b}

    def px(x, y):
        t = fbm(6, x, y, ((4, 0.55), (8, 0.3), (32, 0.15)))
        base = (t - 0.25) / 0.5
        if (x, y) in bright or (x, (y + 1) % S) in bright:
            base += 0.25  # 1x2 lit blade
        elif (x, y) in dark:
            base -= 0.25
        return pick(GRASS[1:], base)
    return image(px)


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
}

if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    for name, fn in TEXTURES.items():
        fn().save(OUT / f"{name}.png")
    print("wrote %d textures to %s" % (len(TEXTURES), OUT))
