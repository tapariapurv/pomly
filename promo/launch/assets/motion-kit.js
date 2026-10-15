/* premium-motion kit: seek-safe GSAP helpers for HyperFrames.
   Usage (inside document.fonts.ready):
     const tl = gsap.timeline({ paused: true }), K = MotionKit(tl);
     // 1) measure everything first (K.box / K.withShown), 2) then build tweens, 3) register tl last.
   All times are seconds on the main timeline; take them from window.CUES. */
window.MotionKit = function (tl) {
  const $ = (q) => (typeof q === "string" ? document.querySelector(q) : q);
  const R0 = document.querySelector("[data-composition-id]").getBoundingClientRect();

  // ---- measurement (root coordinates, pre-transform) ----
  const box = (q) => { const r = $(q).getBoundingClientRect(); const x = r.left - R0.left, y = r.top - R0.top;
    return { x, y, w: r.width, h: r.height, cx: x + r.width / 2, cy: y + r.height / 2, r: x + r.width, b: y + r.height }; };
  // temporarily reveal display:none elements (data-show="flex" for non-block) to measure a future layout
  const withShown = (qs, fn) => { const els = qs.map($); els.forEach((e) => (e.style.display = e.dataset.show || "block"));
    const out = fn(); els.forEach((e) => (e.style.display = "")); return out; };
  // place a label beside a measured box: x/y may be numbers or fns of the label's own (w|h)
  const placeLabel = (q, x, y) => { const el = $(q), w = el.offsetWidth, h = el.offsetHeight;
    el.style.left = (typeof x === "function" ? x(w) : x) + "px"; el.style.top = (typeof y === "function" ? y(h) : y) + "px"; };

  // ---- entries / exits ----
  const fadeIn = (q, t, d = .35) => tl.fromTo(q, { opacity: 0 }, { opacity: 1, duration: d, ease: "power2.out" }, t);
  const fadeOut = (q, t, d = .3) => tl.to(q, { opacity: 0, duration: d, ease: "power2.in" }, t);
  const rise = (q, t, y = 28, d = .6, o = 1) => tl.fromTo(q, { opacity: 0, y }, { opacity: o, y: 0, duration: d, ease: "power3.out" }, t);
  const stagger = (q, t, y = 24, each = .06, d = .5) => tl.fromTo(q, { opacity: 0, y }, { opacity: 1, y: 0, duration: d, stagger: each, ease: "power3.out" }, t);
  const maskIn = (q, t, d = .9) => tl.fromTo(q, { yPercent: 105 }, { yPercent: 0, duration: d, ease: "expo.out" }, t);   // q inside .mask
  const maskOut = (q, t, d = .45) => tl.to(q, { yPercent: -105, duration: d, ease: "power3.in" }, t - d);
  const sceneIn = (q, t) => tl.fromTo(q, { opacity: 0, y: 24 }, { opacity: 1, y: 0, duration: .45, ease: "power3.out" }, t);
  const sceneOut = (q, t) => tl.to(q, { opacity: 0, y: -24, duration: .28, ease: "power2.in" }, t - .28);   // ends exactly at t
  const drift = (q, t0, t1, to = 1.03) => tl.fromTo(q, { scale: 1 }, { scale: to, duration: t1 - t0, ease: "none" }, t0);
  // display:none until t, then a small rise (appends like real UI)
  const show = (q, t) => { tl.set(q, { display: $(q).dataset.show || "block" }, t);
    tl.fromTo(q, { opacity: 0, y: 6 }, { opacity: 1, y: 0, duration: .28, ease: "power2.out" }, t); };
  const hide = (q, t) => tl.set(q, { display: "none" }, t);

  // ---- typing ----
  const type = (q, spec) => spec.times.forEach((t, i) => tl.set(q, { textContent: spec.text.slice(0, i + 1) }, t));
  const blink = (q, a, b) => { for (let t = a; t + .5 <= b; t += 1) tl.set(q, { opacity: 0 }, t + .5).set(q, { opacity: 1 }, Math.min(t + 1, b)); };
  // submit: clear the input, put the text at its destination, reveal it
  const submit = (spec, input, dest, t, prefix = "") => { tl.set(input, { textContent: "" }, t).set(dest, { textContent: prefix + spec.text }, t); show(dest, t); };

  // ---- camera (wrapper .cam, inset 0, origin = frame centre) ----
  const W = 1920 / 2, H = 1080 / 2;   // change if the composition isn't 1920x1080
  const camV = (px, py, Z, tx = W, ty = H) => ({ scale: Z, x: tx - W - (px - W) * Z, y: ty - H - (py - H) * Z });
  const cam = (q, px, py, Z, t, d = .55, ease = "expo.inOut", tx, ty) => tl.to(q, { ...camV(px, py, Z, tx, ty), duration: d, ease }, t);
  const wide = (q, t, d = .75, ease = "expo.inOut") => tl.to(q, { scale: 1, x: 0, y: 0, duration: d, ease }, t);
  // where a content point appears on screen at zoom z (for cursor targets during drift)
  const onScreen = (px, py, z = 1) => [W + (px - W) * z, H + (py - H) * z];

  // ---- cursor (an absolutely positioned svg at left/top 0) ----
  const cursorTo = (x, y, t, d = .8, q = "#cursor") => tl.to(q, { x, duration: d, ease: "power2.inOut" }, t).to(q, { y, duration: d, ease: "power3.inOut" }, t);
  const cursorEnter = (x, y, t, q = "#cursor") => tl.set(q, { x, y, scale: 1 }, t).to(q, { opacity: 1, duration: .2 }, t + .05);
  const press = (target, t, q = "#cursor") => tl.to(target, { scale: .94, duration: .08, yoyo: true, repeat: 1, ease: "power1.inOut" }, t)
    .to(q, { scale: .82, duration: .08, yoyo: true, repeat: 1 }, t);

  // ---- numbers ----
  const count = (q, from, to, t, d = 1.2, fmt = (v) => Math.round(v).toLocaleString("en-US")) => {
    const o = { v: from }; tl.set(q, { textContent: fmt(from) }, 0);
    tl.to(o, { v: to, duration: d, ease: "expo.out", onUpdate: () => ($(q).textContent = fmt(o.v)) }, t); };

  // ---- logo (inline SVG paths + clipPaths, see references/brand.md) ----
  // radial mark: circle clip #clipCircle grows from the mark's centre while it turns in; wordmark wipes via rect #clipRect
  const logoBloom = (mark, circle, t, hold = 3) => { const b = $(mark).getBBox(), cx = b.x + b.width / 2, cy = b.y + b.height / 2;
    gsap.set(circle, { attr: { cx, cy, r: 0 } });
    tl.to(circle, { attr: { r: Math.hypot(b.width, b.height) / 2 + 4 }, duration: 1, ease: "expo.out" }, t);
    tl.fromTo(mark, { rotation: -110, scale: .55, svgOrigin: `${cx} ${cy}` }, { rotation: 0, scale: 1, duration: 1.3, ease: "expo.out" }, t);
    tl.to(mark, { rotation: 14, duration: Math.max(.5, hold - 1.3), ease: "sine.inOut" }, t + 1.3); };
  const logoWipe = (word, rect, t, d = .9) => { const b = $(word).getBBox();
    gsap.set(rect, { attr: { x: b.x - 12, y: b.y - 30, height: b.height + 60, width: 0 } });
    tl.to(rect, { attr: { width: b.width + 24 }, duration: d, ease: "power3.inOut" }, t);
    tl.fromTo(word, { x: -26 }, { x: 0, duration: d + .2, ease: "expo.out" }, t); };

  return { $, box, withShown, placeLabel, fadeIn, fadeOut, rise, stagger, maskIn, maskOut, sceneIn, sceneOut, drift, show, hide,
    type, blink, submit, camV, cam, wide, onScreen, cursorTo, cursorEnter, press, count, logoBloom, logoWipe };
};
