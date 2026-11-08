#!/usr/bin/env python3
"""Synthesizes Shothook's two UI sounds into Support/Sounds/ (run once; outputs are committed).

whoosh.wav  lift-off: band-passed noise sweeping upward, swelling toward impact.
whomp.wav   landing: a pitch-dropping thump (saturated so laptop speakers, which can't
            reproduce <100 Hz, still convey the low end) plus a short bright "pop".
"""
import math
import pathlib
import wave

import numpy as np

SR = 44_100
OUT = pathlib.Path(__file__).resolve().parent.parent / "Support" / "Sounds"


def fade_out(x: np.ndarray, seconds: float) -> np.ndarray:
    n = int(SR * seconds)
    x[-n:] *= np.linspace(1, 0, n) ** 2
    return x


def write(name: str, x: np.ndarray, peak: float) -> None:
    x = x - x.mean()
    x = x / np.max(np.abs(x)) * peak
    OUT.mkdir(parents=True, exist_ok=True)
    with wave.open(str(OUT / name), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes((x * 32767).astype("<i2").tobytes())
    print(f"{name}: {len(x) / SR * 1000:.0f} ms, peak {20 * math.log10(peak):.1f} dBFS")


def whomp() -> np.ndarray:
    t = np.arange(int(SR * 0.38)) / SR
    # Body: 165 Hz falling to 52 Hz, fast attack, ~110 ms decay; tanh adds audible harmonics.
    f = 52 + 113 * np.exp(-t / 0.035)
    phase = 2 * np.pi * np.cumsum(f) / SR
    env = (1 - np.exp(-t / 0.002)) * np.exp(-t / 0.11)
    body = np.tanh(1.8 * (np.sin(phase) + 0.45 * np.sin(2 * phase))) * env
    # Pop: a quick upward chirp (600 → 960 Hz) that makes it read as "done", not "error".
    tp = np.clip(t - 0.008, 0, None)
    fp = 600 + 360 * (1 - np.exp(-tp / 0.025))
    pop = np.sin(2 * np.pi * np.cumsum(fp) / SR) * (1 - np.exp(-tp / 0.001)) * np.exp(-tp / 0.032) * (t > 0.008)
    # Transient: a few ms of noise for a soft "thwack" edge.
    rng = np.random.default_rng(7)
    click = rng.standard_normal(len(t)) * np.exp(-t / 0.004)
    return fade_out(body + 0.28 * pop + 0.12 * click, 0.03)


def whoosh() -> np.ndarray:
    n = int(SR * 0.32)
    t = np.arange(n) / SR
    x = t / t[-1]
    rng = np.random.default_rng(11)
    noise = rng.standard_normal(n)
    # Time-varying band-pass (RBJ biquad), centre sweeping 380 → 2600 Hz.
    out = np.zeros(n)
    x1 = x2 = y1 = y2 = 0.0
    q = 0.9
    for i in range(n):
        fc = 380 * (2600 / 380) ** x[i]
        w0 = 2 * math.pi * fc / SR
        alpha = math.sin(w0) / (2 * q)
        a0 = 1 + alpha
        b0, b2 = alpha / a0, -alpha / a0
        a1, a2 = -2 * math.cos(w0) / a0, (1 - alpha) / a0
        y = b0 * noise[i] + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1 = x1, noise[i]
        y2, y1 = y1, y
        out[i] = y
    # Swell to a peak at 75%, then fall away fast into the impact.
    env = np.where(x < 0.75, (x / 0.75) ** 2, ((1 - x) / 0.25) ** 1.5)
    return fade_out(out * env, 0.01)


if __name__ == "__main__":
    write("whomp.wav", whomp(), peak=0.56)   # ≈ -5 dBFS
    write("whoosh.wav", whoosh(), peak=0.2)  # ≈ -14 dBFS: felt more than heard
