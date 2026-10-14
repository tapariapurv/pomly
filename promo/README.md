# Pomly promo

A 36-second film, 1920×1080, with a generated score and sound effects. Watch it on the [website](https://tapariapurv.github.io/pomly/#promo) or download it from the [release](https://github.com/tapariapurv/pomly/releases/latest).

Every frame is code ([HyperFrames](https://github.com/heygen-com/hyperframes) + GSAP). All timing lives in `scripts/sound.py`, which writes `assets/cues.js` and `assets/score.m4a`.

```bash
python3 scripts/sound.py                                   # cues + score
npx hyperframes check                                      # layout, contrast
npx hyperframes render --quality delivery --output renders/pomly-promo.mp4
```
