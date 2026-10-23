/* Nook video kit: timing, calm motion, the orb and state chips.
   A video page draws one frame from a time: it defines render(t) and calls NV.boot({ duration, cues, render }).
   scripts/render.mjs then steps t frame by frame, so every frame is exact and the sound lines up with the picture. */
(function () {
  const NV = {};

  NV.clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));
  /** 0…1 progress of an animation that starts at `at` and lasts `dur` seconds. */
  NV.prog = (t, at, dur) => NV.clamp((t - at) / dur);
  NV.lerp = (a, b, p) => a + (b - a) * p;
  /** Calm curve for fades and drifts: sine in-out, no edge. */
  NV.ease = p => 0.5 - 0.5 * Math.cos(Math.PI * NV.clamp(p));
  /** A spring without bounce (NookTheme.close/swap/reveal: bounce 0); settles in its duration and never overshoots. */
  NV.settle = p => { p = NV.clamp(p); const w = 9; return p >= 1 ? 1 : 1 - (1 + w * p) * Math.exp(-w * p); };

  /** Fades an element in while it rises a little, and out again. Calm defaults: 1 s in, .8 s out, 24 px. */
  NV.fade = (el, t, inAt, outAt = null, o = {}) => {
    const { rise = 24, dur = 1.0, outDur = 0.8, x = 0 } = o;
    const a = NV.settle(NV.prog(t, inAt, dur));
    const b = outAt == null ? 0 : NV.ease(NV.prog(t, outAt, outDur));
    const v = a * (1 - b);
    el.style.opacity = v;
    el.style.transform = `translate(${(1 - a) * x}px, ${(1 - a) * rise - b * rise * 0.5}px)`;
    return v;
  };

  /** Fades a list of elements in one after another. */
  NV.stagger = (els, t, inAt, gap, outAt = null, o = {}) =>
    Array.from(els).forEach((el, i) => NV.fade(el, t, inAt + i * gap, outAt, o));

  /** Types `text` into `el` at `cps` characters per second; returns how many are shown. */
  NV.type = (el, text, t, at, cps = 14) => {
    const n = Math.floor(NV.clamp((t - at) * cps, 0, text.length));
    el.textContent = t < at ? '' : text.slice(0, n);
    return n;
  };

  /** Crossfades a text change (a chip's word, a row's subtitle) over `dur` seconds at `at`. */
  NV.swapText = (el, t, at, before, after, dur = 0.6) => {
    const p = NV.prog(t, at - dur / 2, dur);
    el.textContent = p < 0.5 ? before : after;
    el.style.opacity = Math.abs(1 - 2 * NV.ease(p)) * 0.85 + 0.15;
  };

  /** The slow breathing light behind the stage: one breath every `period` seconds. */
  NV.breathe = (t, period = 9, depth = 0.35) => {
    const g = document.getElementById('glow');
    if (g) g.style.opacity = 1 - depth / 2 + (depth / 2) * Math.sin((t / period) * 2 * Math.PI);
  };

  // The orb's blink pattern from NookOrb.swift: irregular, like a living thing.
  const GAPS = [3.2, 5.8, 2.6, 6.6, 4.1, 3.5, 7.0, 2.9, 5.2, 4.4, 3.8, 6.1];
  const STARTS = GAPS.reduce((s, g) => (s.push(s[s.length - 1] + g), s), [0]);
  const DOUBLE = new Set([3, 8]);
  const closed = d => (d >= 0 && d < 0.24 ? 1 - 0.92 * Math.sin((d / 0.24) * Math.PI) : 1);
  NV.blink = (t, offset = 0) => {
    const cycle = STARTS[STARTS.length - 1], p = (((t + offset) % cycle) + cycle) % cycle;
    let i = 0; while (i + 1 < GAPS.length && STARTS[i + 1] <= p) i++;
    const phase = p - STARTS[i];
    return Math.min(closed(phase), DOUBLE.has(i) ? closed(phase - 0.32) : 1);
  };

  /** Draws Nook: breathing (scale ±5 % every 3.4 s, as in the app) and blinking. Moods: rest, done, waiting, worry,
      listen, think, proud, celebrate, cozy, caring, breathe, sleepy… (NookMood.swift). */
  NV.orb = (el, t, o = {}) => {
    const { mood = el.dataset.mood || 'rest', scale = 1, breath = true, blinkOffset = 1.1 } = o;
    el.dataset.mood = mood;
    const smiles = ['done', 'proud', 'celebrate', 'cozy'].includes(mood);
    const shut = ['breathe', 'sleepy'].includes(mood);
    el.classList.toggle('happy', smiles); el.classList.toggle('shut', shut);
    const rate = mood === 'think' ? 1.4 : mood === 'sleepy' ? 6.0 : mood === 'breathe' ? 14 : 3.4;
    const amp = mood === 'think' ? 0.025 : mood === 'breathe' ? 0.1 : 0.05;
    const s = breath ? 1 + amp * Math.sin((t * 2 * Math.PI) / rate) : 1;
    el.style.transform = `${el.dataset.base || ''} scale(${s * scale})`;
    const k = smiles || shut || mood === 'think' ? 1 : NV.blink(t, blinkOffset);
    el.querySelectorAll('i').forEach(i => (i.style.transform = `scaleY(${k})`));
  };

  /** Every state the app colors, with the color it uses. One meaning per color, as in the app. */
  NV.STATES = {
    // mint: good, done, going
    done: 'mint', open: 'mint', passing: 'mint', approved: 'mint', connected: 'mint', working: 'mint',
    success: 'mint', listening: 'mint', added: 'mint', allowed: 'mint', found: 'mint',
    // amber: waits on you
    waiting: 'amber', needsYou: 'amber', changesRequested: 'amber', expired: 'amber', warning: 'amber',
    caution: 'amber', blocked: 'amber', behind: 'amber', stack: 'amber', remind: 'amber', pending: 'amber',
    // coral: broken
    error: 'coral', failed: 'coral', failing: 'coral', conflict: 'coral', unreachable: 'coral', denied: 'coral',
    deleted: 'coral', danger: 'coral',
    // soft coral: closed, quietly failed
    closed: 'coral-soft', caring: 'coral-soft',
    // violet: merged
    merged: 'violet',
    // iris: Nook itself, busy, thinking, info
    running: 'iris', busy: 'iris', thinking: 'iris', connecting: 'iris', info: 'iris', note: 'iris', nook: 'iris',
    // blue: links, read receipts, modified files
    link: 'blue', read: 'blue', modified: 'blue', renamed: 'blue',
    // grey: nothing to do yet
    draft: 'secondary', checksRunning: 'secondary', commented: 'secondary', reviewRequired: 'secondary',
    skipped: 'tertiary', noReviews: 'tertiary', dismissed: 'tertiary',
    // music tab
    music: 'music',
  };
  NV.color = state => `var(--${NV.STATES[state] || state})`;
  /** Sets a chip, dot or row to a state; pass the word to show for chips. */
  NV.state = (el, state, word) => {
    el.style.setProperty('--state', NV.color(state));
    if (word != null) el.textContent = word;
  };

  /** Starts the page. `?t=4.2` shows one frame (for stills); otherwise it plays in a loop for previewing. */
  NV.boot = ({ duration, cues = [], render }) => {
    const draw = t => { NV.breathe(t); render(t); };
    window.DURATION = duration; window.CUES = cues; window.render = draw;
    const q = new URLSearchParams(location.search);
    if (q.has('safe')) document.body.classList.add('safe-debug');
    if (q.has('t')) return draw(parseFloat(q.get('t')));
    if (q.has('still')) return;
    const t0 = performance.now();
    (function loop() { draw(((performance.now() - t0) / 1000) % duration); requestAnimationFrame(loop); })();
  };

  window.NV = NV;
})();
