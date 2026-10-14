"""premium-motion: single source of timing + generated score and SFX.
Edit only the blocks marked EDIT. Run: python3 scripts/sound.py
Writes assets/cues.js (window.CUES, read by index.html) and assets/score.m4a. Deterministic (seeded)."""
import json, wave, pathlib, subprocess
import numpy as np

# ===== EDIT: tempo, length, harmony =====
BPM, DUR = 120, 36.0
B = 60 / BPM
# warm, unhurried: Fmaj9 - Dm9 - Bbmaj9 - C6/9
CHORDS = [[53, 60, 64, 67, 69], [50, 57, 60, 64, 65], [46, 53, 57, 60, 62], [48, 55, 60, 62, 67]]
RESOLVE = [53, 60, 65, 69, 72]
rng = np.random.default_rng(7)

def typing(text, start, end):            # seeded, human-ish keystroke times that finish exactly at `end`
    g = rng.uniform(.55, 1.45, len(text)); g[[i for i, c in enumerate(text) if c == " "]] *= 1.35
    t = start + np.cumsum(g) / g.sum() * (end - start)
    return {"text": text, "times": [round(float(x), 3) for x in t]}

# ===== EDIT: every cue the picture uses (seconds, on the beat grid) =====
CUES = dict(
    B=B, DUR=DUR,
    scene=dict(dial=0, drag=3.5, start=6.0, phone=8.0, widget=13.0, mac=17.0, watch=23.5, sync=27.0, logo=31.0),
    type=dict(label=typing("Thesis draft", 20.1, 21.0), code=typing("7U6RMN", 27.6, 28.3)),
    enter=[21.25],
    click=[6.4, 14.6, 18.2],
    pops=[6.6, 9.3, 15.0, 19.75, 21.7, 28.6],
    dragNotes=[3.9 + i * .25 for i in range(7)],
    macNotes=[18.5 + i * .25 for i in range(5)],
)
S = CUES["scene"]
# ===== EDIT: arrangement =====
SECTIONS = [
    (0.0, S["drag"], {"pad", "sparse"}),
    (S["drag"], S["phone"], {"pad", "arp", "hats"}),
    (S["phone"], S["sync"], {"pad", "arp", "hats", "drums"}),
    (S["sync"], S["logo"], {"pad", "arp", "breakdown"}),
    (S["logo"], DUR, {"pad", "breakdown"}),
]
RISER_TO = S["logo"]
LOGO = S["logo"]
# ===== EDIT: SFX events =====
SFX = dict(
    keys=[t for v in CUES["type"].values() for t in v["times"]],
    enter=CUES["enter"],
    click=CUES["click"],
    pop=CUES["pops"],
    notes=CUES["dragNotes"] + CUES["macNotes"],
    whoosh=[S["phone"], S["widget"], S["mac"], S["watch"], S["sync"]],
)

SR = 48000; N = int(DUR * SR); L, R = np.zeros(N), np.zeros(N)
OUT = pathlib.Path(__file__).resolve().parent.parent / "assets"; OUT.mkdir(exist_ok=True)
(OUT / "cues.js").write_text("window.CUES=" + json.dumps(CUES, separators=(",", ":")) + ";\n")

def add(sig, t, gain=1.0, pan=0.0):
    i = int(t * SR); j = min(N, i + len(sig))
    if j <= i or i < 0: return
    s = sig[: j - i] * gain; L[i:j] += s * (1 - max(0, pan)); R[i:j] += s * (1 + min(0, pan))
def env(n, a, d): t = np.arange(n) / SR; return np.minimum(t / a, 1) * np.exp(-t / d)
def hz(m): return 440 * 2 ** ((m - 69) / 12)
def lp(x, cut):
    a = np.exp(-2 * np.pi * cut / SR); y = np.empty_like(x); acc = 0.0
    for k in range(len(x)): acc = (1 - a) * x[k] + a * acc; y[k] = acc
    return y
def noise(n): return rng.standard_normal(n)
def pluck(m, dur=1.2, bright=1.0):
    n = int(dur * SR); t = np.arange(n) / SR; f = hz(m)
    return sum(w * np.sin(2 * np.pi * f * k * t) * np.exp(-t * (3 + 3 * k / bright)) for k, w in [(1, 1), (2, .4 * bright), (3, .15 * bright), (4, .06 * bright)]) * env(n, .003, 9)
def pad(ms, dur):
    n = int(dur * SR); t = np.arange(n) / SR
    return sum(np.sin(2 * np.pi * hz(m) * t * d) for m in ms for d in (1, 1.004)) * np.minimum(t / .8, 1) * np.clip((dur - t) / .8, 0, 1) / (2 * len(ms))
def kick():
    n = int(.35 * SR); t = np.arange(n) / SR; return np.sin(2 * np.pi * np.cumsum(45 + 75 * np.exp(-t * 30)) / SR) * env(n, .001, .12)
def hat(): x = noise(int(.06 * SR)); return (x - lp(x, 6000)) * env(len(x), .0005, .018)
def rim(): n = int(.08 * SR); t = np.arange(n) / SR; return ((noise(n) - lp(noise(n), 1500)) * .5 + np.sin(2 * np.pi * 1700 * t)) * env(n, .0005, .012)
def layers_at(t):
    for a, b, ls in SECTIONS:
        if a <= t < b: return ls
    return set()

ARP = [0, 2, 3, 4, 2, 3, 4, 3]
bar = 0
while bar * 4 * B < (LOGO or DUR):
    t0 = bar * 4 * B; ch = CHORDS[(bar // 2) % len(CHORDS)]; ls = layers_at(t0)
    if "pad" in ls and bar % 2 == 0: add(pad([m + 12 for m in ch[1:]], 8 * B + .8), t0, .09)
    if ("arp" in ls or "drums" in ls) and bar % 2 == 0: add(pluck(ch[0] - 12, 2.5, .6), t0, .26)
    for k in range(8):
        tt = t0 + k * B / 2; lk = layers_at(tt)
        if not ({"sparse", "arp", "breakdown"} & lk): continue
        if ("sparse" in lk or "breakdown" in lk) and "arp" not in lk and k % 2: continue
        if "breakdown" in lk and k % 4: continue
        add(pluck(ch[ARP[k]] + 12 + (12 if k in (2, 6) else 0), 1.0, .5 if "breakdown" in lk else 1), tt, .10 * (1 if k % 2 == 0 else .65), (-.35, .35)[k % 2])
    for k in range(4):
        tb = t0 + k * B; lk = layers_at(tb)
        if "hats" in lk: add(hat(), tb + B / 2, .10, .25)
        if "drums" in lk: add(kick() if k % 2 == 0 else rim(), tb, .55 if k % 2 == 0 else .07)
    bar += 1
if RISER_TO:
    n = int(2.4 * SR); x = noise(n); add((x - lp(x, 2500)) * np.linspace(0, 1, n) ** 3, RISER_TO - 2.4, .05)
if LOGO is not None:
    add(kick(), LOGO, .45); add(pad(RESOLVE + [RESOLVE[2] + 12], DUR - LOGO + 1), LOGO, .11); add(pluck(RESOLVE[0] - 24, 4, .6), LOGO, .3)
    for i, m in enumerate(RESOLVE[:4]): add(pluck(m, 3), LOGO + i * .07, .08)
    n = int(3.5 * SR); t = np.arange(n) / SR; f = hz(RESOLVE[0] + 19)
    add(sum(w * np.sin(2 * np.pi * f * r * t) * np.exp(-t * d) for r, w, d in [(1, 1, 1.1), (2.76, .35, 2.5), (5.4, .12, 4)]), LOGO, .16)

def tick(): n = int(.03 * SR); return lp(noise(n), rng.uniform(2500, 4200)) * env(n, .0005, .005)
def thock(): n = int(.09 * SR); t = np.arange(n) / SR; return lp(noise(n), 1800) * env(n, .0005, .012) + np.sin(2 * np.pi * 150 * t) * env(n, .001, .02) * .6
def pop(): n = int(.22 * SR); t = np.arange(n) / SR; return np.sin(2 * np.pi * np.cumsum(700 + 280 * np.exp(-t * 45)) / SR) * env(n, .002, .045)
def whoosh(d=.6): n = int(d * SR); x = noise(n); t = np.arange(n) / SR; return ((lp(x, 1100) - lp(x, 250)) + lp(x, 3500) * .2) * np.sin(np.pi * t / d) ** 2
def note(m): n = int(.6 * SR); t = np.arange(n) / SR; return (np.sin(2 * np.pi * hz(m) * t) + .3 * np.sin(4 * np.pi * hz(m) * t)) * env(n, .002, .12)
for x in SFX["keys"]: add(tick(), x - .004, .3, rng.uniform(-.2, .2))
for x in SFX["enter"]: add(thock(), x, .5)
for x in SFX["click"]: add(np.concatenate([thock()[: int(.035 * SR)] * .6, tick() * 1.4]), x, .55)
for x in SFX["pop"]: add(pop(), x, .09, -.1)
for i, x in enumerate(SFX["notes"]): add(note(RESOLVE[2] + 12 + [0, 2, 5, 7, 9, 12][i % 6]), x, .07, .15)
for x in SFX["whoosh"]: add(whoosh(), x - .3, .2)

fade = np.ones(N); k = int((DUR - 2.5) * SR); fade[k:] = np.linspace(1, 0, N - k) ** 1.5
mix = np.stack([L * fade, R * fade], 1); mix *= 10 ** (-18 / 20) / max(1e-9, np.sqrt((mix ** 2).mean())); mix = np.tanh(mix * 1.2) * .9
wav = OUT / "score.wav"
with wave.open(str(wav), "wb") as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR); w.writeframes((mix * 32767).astype("<i2").tobytes())
subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(wav), "-c:a", "aac", "-b:a", "192k", str(OUT / "score.m4a")], check=True)
wav.unlink(); print("ok", DUR, "s · peak", round(float(np.abs(mix).max()), 3))
