#!/usr/bin/env python3
"""Generates the core mod's sound effects (original, synthesised) as WAV files.

Usage: python3 tools/gen_sounds.py   (writes mods/core/sounds/*.wav)

Everything is built from filtered noise, decaying tones and envelopes, seeded so
the output is the same every run. Several variants per sound so repeats don't
sound identical (the game also varies the pitch a little).
"""
from pathlib import Path

import numpy as np
import wave

RATE = 22050
OUT = Path(__file__).resolve().parent.parent / "mods" / "core" / "sounds"


def save(name, samples):
    samples = np.clip(samples, -1.0, 1.0)
    pcm = (samples * 32767 * 0.9).astype("<i2")
    with wave.open(str(OUT / f"{name}.wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(pcm.tobytes())


def t(seconds):
    return np.arange(int(seconds * RATE)) / RATE


def lowpass(x, cutoff):
    """One-pole low-pass, applied forwards and backwards (no phase shift)."""
    a = np.exp(-2 * np.pi * cutoff / RATE)
    y = np.empty_like(x)
    acc = 0.0
    for i, v in enumerate(x):
        acc = (1 - a) * v + a * acc
        y[i] = acc
    acc = 0.0
    for i in range(len(y) - 1, -1, -1):
        acc = (1 - a) * y[i] + a * acc
        y[i] = acc
    return y


def highpass(x, cutoff):
    return x - lowpass(x, cutoff)


def env(n, attack, decay):
    """Fast attack, exponential decay; attack/decay in seconds."""
    tt = np.arange(n) / RATE
    a = np.minimum(1.0, tt / max(attack, 1e-4))
    return a * np.exp(-tt / decay)


def norm(x, peak=1.0):
    m = np.max(np.abs(x))
    return x * (peak / m) if m > 0 else x


# --- materials ----------------------------------------------------------------------
# Each material: a function (rng, length, strength) -> samples.

def soft(rng, length, strength):           # grass, dirt, leaves
    n = int(length * RATE)
    x = lowpass(rng.normal(size=n), 900 + 400 * rng.random())
    return norm(x * env(n, 0.006, length / 3.5), 0.7 * strength)


def hard(rng, length, strength):           # stone, ores, cobblestone
    n = int(length * RATE)
    noise = highpass(rng.normal(size=n), 1500)
    click = np.sin(2 * np.pi * (900 + 300 * rng.random()) * t(length)) * env(n, 0.001, 0.012)
    x = noise * env(n, 0.002, length / 5) + 0.6 * click
    return norm(x, 0.8 * strength)


def wood(rng, length, strength):           # planks, logs
    n = int(length * RATE)
    f = 140 + 60 * rng.random()
    tone = np.sin(2 * np.pi * f * t(length)) + 0.4 * np.sin(2 * np.pi * f * 2.7 * t(length))
    knock = lowpass(rng.normal(size=n), 2500) * env(n, 0.001, 0.02)
    x = tone * env(n, 0.002, length / 4) + 0.5 * knock
    return norm(x, 0.8 * strength)


def sandy(rng, length, strength):          # sand
    n = int(length * RATE)
    x = highpass(rng.normal(size=n), 2500) * env(n, 0.02, length / 3)
    return norm(x, 0.45 * strength)


def crunchy(rng, length, strength):        # gravel
    n = int(length * RATE)
    x = np.zeros(n)
    for _ in range(int(25 * length / 0.1)):
        start = rng.integers(0, max(1, n - 400))
        m = rng.integers(60, 300)
        burst = highpass(rng.normal(size=m), 1200) * np.exp(-np.arange(m) / (m / 4))
        x[start:start + m] += burst[: n - start] * rng.random()
    return norm(x * env(n, 0.003, length / 2.5), 0.7 * strength)


MATERIALS = {"grass": soft, "stone": hard, "wood": wood, "sand": sandy, "gravel": crunchy}


def splash(rng):
    n = int(0.6 * RATE)
    noise = rng.normal(size=n)
    # sweep the brightness down: bright splash, darker tail
    bright = highpass(noise, 1200) * env(n, 0.005, 0.08)
    body = lowpass(noise, 700) * env(n, 0.02, 0.25)
    return norm(bright * 0.7 + body, 0.8)


def hurt(rng):
    n = int(0.25 * RATE)
    f = 220 * np.exp(-t(0.25) * 3)  # falling pitch
    phase = 2 * np.pi * np.cumsum(f) / RATE
    x = (np.sin(phase) + 0.3 * np.sign(np.sin(phase))) * env(n, 0.004, 0.09)
    return norm(lowpass(x, 3000), 0.7)


def pickup(rng):
    """Two short rising tones."""
    out = []
    for f in (880, 1320):
        n = int(0.07 * RATE)
        out.append(np.sin(2 * np.pi * f * t(0.07)) * env(n, 0.003, 0.025))
    return norm(np.concatenate(out), 0.45)


def loop_crossfade(x, fade):
    """Makes x loop seamlessly: blend its tail into its head."""
    m = int(fade * RATE)
    head, tail = x[:m], x[-m:]
    w = np.linspace(0, 1, m)
    x = x[: len(x) - m].copy()
    x[:m] = head * w + tail * (1 - w)
    return x


def wind(rng, seconds, level):
    n = int(seconds * RATE)
    brown = np.cumsum(rng.normal(size=n))
    brown = highpass(brown, 40)            # remove drift
    gusts = lowpass(rng.normal(size=n), 0.15)
    gusts = (gusts - gusts.min()) / (gusts.max() - gusts.min() + 1e-9)
    x = lowpass(brown, 500) * (0.35 + 0.65 * gusts)
    return norm(x, level)


def ambience_day(rng):
    return loop_crossfade(wind(rng, 21.0, 0.35), 1.0)


def ambience_night(rng):
    seconds = 21.0
    x = wind(rng, seconds, 0.18)
    tt = t(seconds)
    chirps = np.zeros_like(x)
    when = 0.4
    while when < seconds - 1.5:
        f = 4300 + 500 * rng.random()
        for k in range(rng.integers(2, 5)):  # a few pulses per chirp
            s = int((when + k * 0.06) * RATE)
            m = int(0.035 * RATE)
            chirps[s:s + m] += np.sin(2 * np.pi * f * tt[:m]) * np.hanning(m)
        when += 0.6 + 1.6 * rng.random()
    x = x + 0.12 * chirps
    return loop_crossfade(x, 1.0)


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(1234)
    count = 0
    for name, make in MATERIALS.items():
        for i in range(1, 4):
            save(f"{name}_step_{i}", make(rng, 0.11, 0.55)); count += 1
            save(f"{name}_break_{i}", make(rng, 0.28, 1.0)); count += 1
        save(f"{name}_place", make(rng, 0.14, 0.8)); count += 1
    for i in range(1, 3):
        save(f"splash_{i}", splash(rng)); count += 1
    save("hurt", hurt(rng)); count += 1
    save("pickup", pickup(rng)); count += 1
    save("ambience_day", ambience_day(rng)); count += 1
    save("ambience_night", ambience_night(rng)); count += 1
    print("wrote %d sounds to %s" % (count, OUT))
