# Pomly films

| File | What |
|---|---|
| `index.html` → `pomly-film.mp4` | 58 s, 1920×1080: promo, then an install guide for Mac, iPhone/iPad, Watch and sync |
| `vertical/index.html` → `pomly-vertical.mp4` | 26 s, 1080×1920 promo for Reels, Shorts and TikTok |

Built from real captures of the app (`assets/cap/`: simulator screen recordings and screenshots, Mac screenshots) with [HyperFrames](https://github.com/heygen-com/hyperframes) + GSAP. Timing, score and SFX come from `scripts/sound.py`.

```bash
python3 scripts/sound.py && npx hyperframes render --quality delivery --output renders/pomly-film.mp4
VERTICAL=1 OUT_DIR=vertical/assets python3 scripts/sound.py && (cd vertical && npx hyperframes render --quality delivery --output renders/pomly-vertical.mp4)
```
