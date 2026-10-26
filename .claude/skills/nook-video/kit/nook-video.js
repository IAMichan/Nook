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

  /** A spring with NookTheme.open's small overshoot (bounce .08): for things that arrive with a little life. */
  NV.pop = p => {
    p = NV.clamp(p); if (p >= 1) return 1;
    const z = 0.63, w = 9, wd = w * Math.sqrt(1 - z * z);
    return 1 - Math.exp(-z * w * p) * (Math.cos(wd * p) + (z * w / wd) * Math.sin(wd * p));
  };

  /** The beat grid: NV.tempo(84) → { beat: seconds per beat, at(n): time of beat n, bar(n): time of bar n, index(t) }. */
  NV.tempo = bpm => {
    const beat = 60 / bpm;
    return { bpm, beat, bar: n => n * 4 * beat, at: n => n * beat, index: t => Math.floor(t / beat + 1e-6) };
  };

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

  /** Kinetic type: reveals the words of `el` one by one, each rising out of a soft blur. `gap` seconds between words
      (use the beat or half of it), `outAt` fades the whole line. Words keep their markup (<br>, spans). */
  NV.words = (el, t, inAt, gap = 0.12, outAt = null, o = {}) => {
    const { rise = 0.35, blur = 14, dur = 0.7 } = o;
    if (!el.dataset.split) {
      const walk = node => Array.from(node.childNodes).forEach(c => {
        if (c.nodeType === 3) {
          const frag = document.createDocumentFragment();
          c.textContent.split(/(\s+)/).forEach(part => {
            if (!part) return;
            if (/^\s+$/.test(part)) frag.appendChild(document.createTextNode(part));
            else { const s = document.createElement('span'); s.className = 'w'; s.textContent = part; frag.appendChild(s); }
          });
          c.replaceWith(frag);
        } else if (c.nodeType === 1 && c.tagName !== 'BR') walk(c);
      });
      walk(el); el.dataset.split = '1';
    }
    const out = outAt == null ? 0 : NV.ease(NV.prog(t, outAt, 0.5));
    el.querySelectorAll('.w').forEach((w, i) => {
      const p = NV.pop(NV.prog(t, inAt + i * gap, dur));
      const f = NV.clamp(NV.prog(t, inAt + i * gap, dur * 0.6));
      w.style.display = 'inline-block';
      w.style.opacity = f * (1 - out);
      w.style.transform = `translateY(${(1 - p) * rise}em)`;
      w.style.filter = `blur(${(1 - f) * blur + out * 8}px)`;
    });
  };

  /** One word that changes on every beat: `items` swap at `times` (seconds), each rising out of a blur. Returns the
      index shown. Put the word in its own element; the element's width follows the word. */
  NV.cycle = (el, t, items, times, o = {}) => {
    const { dur = 0.4, rise = 40, blur = 10 } = o;
    let k = -1; times.forEach((s, i) => { if (t >= s) k = i; });
    if (k < 0) { el.style.opacity = 0; return -1; }
    const item = items[Math.min(k, items.length - 1)];
    if (el.dataset.item !== String(k)) { el.innerHTML = item; el.dataset.item = String(k); }
    const p = NV.pop(NV.prog(t, times[k], dur)), f = NV.clamp(NV.prog(t, times[k], dur * 0.6));
    el.style.opacity = f;
    el.style.transform = `translateY(${(1 - p) * rise}px)`;
    el.style.filter = `blur(${(1 - f) * blur}px)`;
    return k;
  };

  /** Nook's celebration: a small burst of mint and white sparks flying outward and fading (as in NookOrb.swift).
      `host` is an empty absolutely positioned element at the burst's center. */
  NV.sparks = (host, t, at, o = {}) => {
    const { count = 18, reach = 220, life = 1.1, seed = 3 } = o;
    if (!host.childElementCount) {
      for (let i = 0; i < count; i++) {
        const s = document.createElement('i');
        s.style.cssText = 'position:absolute;left:0;top:0;border-radius:50%;';
        host.appendChild(s);
      }
    }
    let r = seed;
    const rand = () => (r = (r * 16807) % 2147483647) / 2147483647;
    Array.from(host.children).forEach((s, i) => {
      const a = (i / count) * 2 * Math.PI + rand() * 0.5, sp = 0.55 + rand() * 0.45, size = 8 + rand() * 10;
      const k = (t - at) / life;
      if (k < 0 || k > 1) { s.style.opacity = 0; return; }
      const d = reach * sp * (1 - Math.exp(-k * 4.5));
      s.style.width = s.style.height = size * (1 - k * 0.6) + 'px';
      s.style.background = i % 3 === 0 ? 'var(--paper)' : 'var(--mint)';
      s.style.opacity = (1 - k) * (k < 0.08 ? k / 0.08 : 1);
      s.style.transform = `translate(${Math.cos(a) * d - size / 2}px, ${Math.sin(a) * d - size / 2 + k * k * 40}px)`;
    });
  };

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
    // look: where the eyes look, {x, y} in -1…1 (the app follows the pointer); wink: 0…1 closes the right eye.
    const { mood = el.dataset.mood || 'rest', scale = 1, breath = true, blinkOffset = 1.1, look = { x: 0, y: 0 }, wink = 0 } = o;
    el.dataset.mood = mood;
    const smiles = ['done', 'proud', 'celebrate', 'cozy'].includes(mood);
    const shut = ['breathe', 'sleepy'].includes(mood);
    el.classList.toggle('happy', smiles); el.classList.toggle('shut', shut);
    const rate = mood === 'think' ? 1.4 : mood === 'sleepy' ? 6.0 : mood === 'breathe' ? 14 : 3.4;
    const amp = mood === 'think' ? 0.025 : mood === 'breathe' ? 0.1 : 0.05;
    const s = breath ? 1 + amp * Math.sin((t * 2 * Math.PI) / rate) : 1;
    el.style.transform = `${el.dataset.base || ''} scale(${s * scale})`;
    const k = smiles || shut || mood === 'think' ? 1 : NV.blink(t, blinkOffset);
    const d = el.offsetWidth || 100;
    el.querySelectorAll('i').forEach((i, n) => {
      const close = n === 1 ? Math.min(k, 1 - 0.9 * NV.clamp(wink)) : k;
      i.style.transform = `translate(${look.x * d * 0.14}px, ${look.y * d * 0.08}px) scaleY(${close})`;
    });
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
  /** `music` is passed to scripts/music.py: { mood, bpm, drumsFrom, drumsUntil, chord, seed }. */
  NV.boot = ({ duration, cues = [], music = {}, render }) => {
    const draw = t => { NV.breathe(t); render(t); };
    window.DURATION = duration; window.CUES = cues; window.MUSIC = music; window.render = draw;
    const q = new URLSearchParams(location.search);
    if (q.has('safe')) document.body.classList.add('safe-debug');
    if (q.has('t')) return draw(parseFloat(q.get('t')));
    if (q.has('still')) return;
    const t0 = performance.now();
    (function loop() { draw(((performance.now() - t0) / 1000) % duration); requestAnimationFrame(loop); })();
  };

  window.NV = NV;
})();
