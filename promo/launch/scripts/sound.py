"""Pomly launch film: single source of timing + generated score and SFX.
Run: python3 scripts/sound.py  -> assets/cues.js (window.CUES) + assets/score.m4a. Deterministic (seeded)."""
import json, wave, pathlib, subprocess
import numpy as np

BPM, DUR = 120, 56.0
B = 60 / BPM
# Dmaj9 - Bm9 - Gmaj9 - A6/9, warm and optimistic
CHORDS = [[50, 57, 61, 64, 66], [47, 54, 57, 61, 62], [43, 50, 54, 57, 59], [45, 52, 57, 59, 64]]
RESOLVE = [62, 66, 69, 73, 76]
rng = np.random.default_rng(7)

# ---- scenes (seconds, on the beat grid) ----
S = dict(title=0.0, meet=5.0, set=9.0, full=17.5, live=21.0, mac=26.0, family=32.0, progress=36.0,
         themes=42.0, values=46.5, end=50.5)
# drag clip (real screen recording) placed inside the hero phone; offsets measured from the recording
CLIP = dict(at=10.6, src0=40.15, dur=6.9, drag=(0.0, 1.9), tap=5.15, steps=8)
DRAG = (CLIP["at"] + CLIP["drag"][0], CLIP["at"] + CLIP["drag"][1])
TAP = CLIP["at"] + CLIP["tap"]

CUES = dict(
    B=B, DUR=DUR, scene=S, clip=CLIP, drag=list(DRAG), tap=TAP,
    title=dict(l1=0.5, l2=2.0),
    meet=dict(icon=S["meet"], word=S["meet"] + .5, sub=S["meet"] + 1.5),
    mac=dict(win=S["mac"], press=S["mac"] + 3.0, release=S["mac"] + 4.5),
    stats=S["progress"] + 1.0, month=S["progress"] + 3.5,
    themes=[S["themes"] + i * .75 for i in range(6)],
    values=[S["values"] + i * 1.0 for i in range(4)],
)
# ---- arrangement ----
SECTIONS = [
    (0.0, S["meet"], {"pad", "sparse"}),
    (S["meet"], S["set"], {"pad", "sparse", "hats"}),
    (S["set"], S["full"], {"pad", "arp", "hats"}),
    (S["full"], S["live"], {"pad", "breakdown"}),
    (S["live"], S["values"], {"pad", "arp", "hats", "drums"}),
    (S["values"], S["end"], {"pad", "arp", "hats", "drums"}),
    (S["end"], DUR, {"pad"}),
]
RISER_TO = S["end"]
LOGO = S["end"]
dsteps = np.linspace(DRAG[0] + .1, DRAG[1] - .1, CLIP["steps"])
SFX = dict(
    clock=[S["title"] + i * B * 2 for i in range(5)] + [S["full"] + .5 + i * B * 2 for i in range(3)],
    detent=list(dsteps),
    tap=[TAP, CUES["mac"]["press"] + .5, CUES["mac"]["release"]],
    glass=[TAP + .05],
    pop=[CUES["meet"]["sub"], S["live"] + .5, S["live"] + 1.0, CUES["stats"], CUES["month"], CUES["mac"]["release"]],
    notes=CUES["themes"] + CUES["values"],
    whoosh=[S["meet"], S["set"], S["full"], S["live"], S["mac"], S["family"], S["progress"], S["themes"], S["values"]],
)

# ---------- engine ----------
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
def pluck(m, dur=1.2, bright=1.0):   # felt-piano-ish
    n = int(dur * SR); t = np.arange(n) / SR; f = hz(m)
    return sum(w * np.sin(2 * np.pi * f * k * t) * np.exp(-t * (3 + 3 * k / bright)) for k, w in [(1, 1), (2, .4 * bright), (3, .15 * bright), (4, .06 * bright)]) * env(n, .004, 9)
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
while bar * 4 * B < LOGO:
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
n = int(2.4 * SR); x = noise(n); add((x - lp(x, 2500)) * np.linspace(0, 1, n) ** 3, RISER_TO - 2.4, .05)
# logo: downbeat, resolving chord, then Pomly's own chime (the real app sound)
add(kick(), LOGO, .45); add(pad(RESOLVE + [RESOLVE[2] + 12], DUR - LOGO + 1), LOGO, .11); add(pluck(RESOLVE[0] - 24, 4, .6), LOGO, .3)
for i, m in enumerate(RESOLVE[:4]): add(pluck(m, 3), LOGO + i * .07, .08)
with wave.open(str(pathlib.Path(__file__).parent / "chime.wav")) as w:
    ch = np.frombuffer(w.readframes(w.getnframes()), "<i2").astype(float) / 32768
add(ch, LOGO + .5, .55)

def tick(): n = int(.03 * SR); return lp(noise(n), rng.uniform(2500, 4200)) * env(n, .0005, .005)
def thock(): n = int(.09 * SR); t = np.arange(n) / SR; return lp(noise(n), 1800) * env(n, .0005, .012) + np.sin(2 * np.pi * 150 * t) * env(n, .001, .02) * .6
def clock(): n = int(.12 * SR); t = np.arange(n) / SR; return (np.sin(2 * np.pi * 2300 * t) * .5 + np.sin(2 * np.pi * 1150 * t) + lp(noise(n), 3000) * .6) * env(n, .0005, .014)
def pop(): n = int(.22 * SR); t = np.arange(n) / SR; return np.sin(2 * np.pi * np.cumsum(700 + 280 * np.exp(-t * 45)) / SR) * env(n, .002, .045)
def glass(): n = int(.9 * SR); t = np.arange(n) / SR; return sum(w * np.sin(2 * np.pi * f * t) * np.exp(-t * d) for f, w, d in [(1318, 1, 5), (1975, .5, 7), (3637, .2, 11)]) * env(n, .003, 9)
def whoosh(d=.6): n = int(d * SR); x = noise(n); t = np.arange(n) / SR; return ((lp(x, 1100) - lp(x, 250)) + lp(x, 3500) * .2) * np.sin(np.pi * t / d) ** 2
def note(m): n = int(.6 * SR); t = np.arange(n) / SR; return (np.sin(2 * np.pi * hz(m) * t) + .3 * np.sin(4 * np.pi * hz(m) * t)) * env(n, .002, .12)
for x in SFX["clock"]: add(clock(), x, .16, .1)
for x in SFX["detent"]: add(tick(), x, .22, rng.uniform(-.15, .15))
for x in SFX["tap"]: add(np.concatenate([thock()[: int(.035 * SR)] * .6, tick() * 1.4]), x, .55)
for x in SFX["glass"]: add(glass(), x, .05)
for x in SFX["pop"]: add(pop(), x, .09, -.1)
for i, x in enumerate(SFX["notes"]): add(note(RESOLVE[2] + 12 + [0, 2, 4, 7, 9, 12][i % 6]), x, .07, .15)
for x in SFX["whoosh"]: add(whoosh(), x - .3, .2)

fade = np.ones(N); k = int((DUR - 2.5) * SR); fade[k:] = np.linspace(1, 0, N - k) ** 1.5
mix = np.stack([L * fade, R * fade], 1); mix *= 10 ** (-18 / 20) / max(1e-9, np.sqrt((mix ** 2).mean())); mix = np.tanh(mix * 1.2) * .9
wav = OUT / "score.wav"
with wave.open(str(wav), "wb") as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR); w.writeframes((mix * 32767).astype("<i2").tobytes())
subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(wav), "-c:a", "aac", "-b:a", "192k", str(OUT / "score.m4a")], check=True)
wav.unlink(); print("ok", DUR, "s · peak", round(float(np.abs(mix).max()), 3))
