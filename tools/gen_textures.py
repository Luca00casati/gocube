#!/usr/bin/env python3
"""Generates the core mod's 16x16 block textures (original, procedural pixel art).

Usage: python3 tools/gen_textures.py   (writes mods/core/textures/*.png)
Deterministic: same output every run. All textures tile seamlessly.
"""
import random
from pathlib import Path

from PIL import Image

S = 16
OUT = Path(__file__).resolve().parent.parent / "mods" / "core" / "textures"


def clamp(c):
    return tuple(max(0, min(255, int(v))) for v in c)


def shade(rgb, d):
    return clamp(v + d for v in rgb)


def noisy(base, amount, seed, speck=None):
    """Per-pixel value noise around `base`; optional (chance, delta) specks."""
    rnd = random.Random(seed)
    img = Image.new("RGB", (S, S))
    for y in range(S):
        for x in range(S):
            d = rnd.randint(-amount, amount)
            if speck and rnd.random() < speck[0]:
                d += speck[1] * rnd.choice((-1, 1))
            img.putpixel((x, y), shade(base, d))
    return img


def stone():
    img = noisy((128, 128, 130), 10, 1)
    rnd = random.Random(11)
    for _ in range(3):  # short dark cracks
        x, y = rnd.randrange(S), rnd.randrange(S)
        for _ in range(rnd.randint(3, 5)):
            img.putpixel((x % S, y % S), (92, 92, 95))
            x += rnd.choice((0, 1))
            y += rnd.choice((0, 1, 1))
    return img


def cobblestone():
    rnd = random.Random(2)
    seeds = [(rnd.uniform(0, S), rnd.uniform(0, S), rnd.randint(-22, 18)) for _ in range(7)]

    def dist(ax, ay, bx, by):  # wrap-around so the texture tiles
        dx = min(abs(ax - bx), S - abs(ax - bx))
        dy = min(abs(ay - by), S - abs(ay - by))
        return (dx * dx + dy * dy) ** 0.5

    img = Image.new("RGB", (S, S))
    for y in range(S):
        for x in range(S):
            ds = sorted((dist(x + 0.5, y + 0.5, sx, sy), tone) for sx, sy, tone in seeds)
            if ds[1][0] - ds[0][0] < 1.1:
                c = shade((70, 70, 72), rnd.randint(-6, 6))  # mortar
            else:
                c = shade((122, 122, 124), ds[0][1] + rnd.randint(-8, 8))
                if ds[1][0] - ds[0][0] < 2.0:
                    c = shade(c, -14)  # darker stone edges for depth
            img.putpixel((x, y), c)
    return img


DIRT = (134, 96, 67)


def dirt(seed=3):
    return noisy(DIRT, 12, seed, speck=(0.12, 22))


GRASS = (98, 160, 58)


def grass_top():
    img = noisy(GRASS, 14, 4)
    rnd = random.Random(44)
    for _ in range(14):  # brighter blade tips
        img.putpixel((rnd.randrange(S), rnd.randrange(S)), shade(GRASS, 30))
    return img


def grass_side():
    img = dirt(seed=5)
    top = grass_top()
    rnd = random.Random(55)
    for x in range(S):
        depth = rnd.choice((2, 3, 3, 4))
        for y in range(depth):
            img.putpixel((x, y), top.getpixel((x, y)))
        img.putpixel((x, depth), shade(top.getpixel((x, depth)), -28))  # shadowed fringe
    return img


def planks():
    rnd = random.Random(6)
    base = (176, 138, 86)
    img = Image.new("RGB", (S, S))
    board_h = 4
    for b in range(S // board_h):
        tone = rnd.randint(-10, 10)
        seam_x = rnd.randrange(S)
        grain = [rnd.randint(-8, 8) for _ in range(S)]
        for dy in range(board_h):
            y = b * board_h + dy
            for x in range(S):
                c = shade(base, tone + grain[(x + dy * 5) % S] // 2 + rnd.randint(-4, 4))
                if dy == board_h - 1:
                    c = shade(base, -48)  # gap between boards
                elif x == seam_x:
                    c = shade(base, -36)  # board end
                elif dy == 0:
                    c = shade(c, 10)  # lit top edge
                img.putpixel((x, y), c)
    return img


TEXTURES = {
    "stone": stone,
    "cobblestone": cobblestone,
    "dirt": dirt,
    "grass_top": grass_top,
    "grass_side": grass_side,
    "planks": planks,
}

if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    for name, fn in TEXTURES.items():
        fn().save(OUT / f"{name}.png")
        print("wrote", OUT / f"{name}.png")
