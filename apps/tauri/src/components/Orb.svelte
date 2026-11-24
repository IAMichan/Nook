<script lang="ts" module>
  // Shared moments across every Nook orb (`NookPresence` on macOS): heard, nod, typing along, celebrate, speaking.
  export const NOOK_MOODS = [
    "rest",
    "seen",
    "listen",
    "think",
    "waiting",
    "remind",
    "worry",
    "done",
    "proud",
    "curious",
    "cozy",
    "focus",
    "surprised",
    "caring",
    "sleepy",
    "celebrate",
    "breathe",
  ] as const;

  export type NookMood = (typeof NOOK_MOODS)[number];
  /** All 17 macOS moods plus backwards-compatible aliases ("idle", "working", "error"). */
  export type Mood = NookMood | "idle" | "working" | "error";

  export interface RingPiece {
    id: string;
    label: string;
    state: "working" | "waiting" | "error" | "done";
  }

  type SharedEvent =
    | { kind: "heard" }
    | { kind: "nod" }
    | { kind: "celebrate" }
    | { kind: "typed"; count: number }
    | { kind: "speaking"; level: number };

  const listeners = new Set<(event: SharedEvent) => void>();
  let typedSeq = 0;

  /** You sent Nook something: a small hop with wide eyes. */
  export function heard() {
    listeners.forEach((l) => l({ kind: "heard" }));
  }
  /** Something finished: a content nod. */
  export function nod() {
    listeners.forEach((l) => l({ kind: "nod" }));
  }
  /** Something worth celebrating: a hop with sparks. */
  export function celebrate() {
    listeners.forEach((l) => l({ kind: "celebrate" }));
  }
  /** You typed a character: Nook reads along with his eyes and nods when you pause. */
  export function typed(count?: number) {
    typedSeq = count !== undefined ? count : typedSeq + 1;
    const seq = typedSeq;
    listeners.forEach((l) => l({ kind: "typed", count: seq }));
  }
  /** Broadcasts current read-aloud audio level (0..1) to orbs that do not pass `speakingLevel` directly. */
  export function speaking(level: number) {
    const clamped = Math.max(0, Math.min(1, Number.isFinite(level) ? level : 0));
    listeners.forEach((l) => l({ kind: "speaking", level: clamped }));
  }

  /** Maps legacy aliases ("idle", "working", "error") to their canonical macOS `NookMood`. */
  export function canonicalMood(mood: Mood): NookMood {
    if (mood === "idle") return "rest";
    if (mood === "working") return "think";
    if (mood === "error") return "worry";
    return mood;
  }
</script>

<script lang="ts">
  import { nook, accentCss } from "../lib/state.svelte";
  import { LOOK_PRESETS, type NookLook } from "../lib/types";

  // Nook's orb (`NookOrb` + `NookOrb+Face` + `NookMood` + `NookTaskRing` on macOS):
  // - All 17 moods with distinct eye shapes, mouth poses, glows, and motions
  // - All 3 eye looks (round with iris glow + catchlights, bars, dots) and 3 mouth modes (expressive, line, none)
  // - Organic blinking (including double-blinks), cursor gaze tracking, hover petting blush, click squish,
  //   triple-click giggle, typing read-along, elastic drag spring, and read-aloud mouth animation (`speakingLevel`).
  let {
    size = 22,
    mood = "idle",
    level = 0,
    speakingLevel,
    curious = false,
    ring = [],
    onpiece,
    movable = false,
    look: lookOverride,
    tint,
  }: {
    size?: number;
    mood?: Mood;
    level?: number;
    /** Read-aloud speech amplitude 0..1 driving animated mouth movement. */
    speakingLevel?: number;
    /** Head tilt and lifted eye as if noticing something interesting. */
    curious?: boolean;
    ring?: RingPiece[];
    onpiece?: (id: string) => void;
    movable?: boolean;
    look?: NookLook;
    tint?: string;
  } = $props();

  const resolvedMood = $derived<NookMood>(canonicalMood(mood));
  const face = $derived<NookLook>(lookOverride ?? nook.settings?.nookLook ?? LOOK_PRESETS[1].look);
  const moments = $derived(nook.settings?.buddyMoments !== false);

  // Mood-aware orb color: explicit `tint` always wins; buddy/status moods use NookMood colors unless neutral.
  const accentColor = $derived(accentCss(nook.settings?.accentHex ?? 0xf4f3f7));
  const faceColor = $derived.by(() => {
    if (tint) return tint;
    switch (resolvedMood) {
      case "proud":
      case "celebrate":
        return "var(--mint)";
      case "breathe":
        return "var(--mint-soft)";
      case "cozy":
      case "remind":
        return "var(--amber)";
      case "caring":
        return "var(--coral-soft)";
      default:
        return accentColor;
    }
  });

  // Subtle iris tint inside round eyes, matching `NookOrb.eyeTint(for:)` on macOS.
  const irisTint = $derived.by(() => {
    switch (resolvedMood) {
      case "listen":
      case "done":
      case "proud":
      case "celebrate":
      case "breathe":
        return "var(--mint)";
      case "waiting":
      case "remind":
      case "cozy":
        return "var(--amber)";
      case "worry":
        return "var(--coral)";
      case "caring":
        return "var(--coral-soft)";
      default:
        return "var(--violet)";
    }
  });

  let el: HTMLDivElement;
  let look = $state({ x: 0, y: 0 });
  let blinking = $state(false);
  let moment = $state<"" | "poke" | "giggle" | "heard" | "nod" | "hello" | "wake" | "wink" | "party">("");
  let blush = $state(false);
  let drowsy = $state(false);
  let hovered = $state<string | null>(null);
  let reading = $state(false);
  let readingStep = $state(0);
  let globalSpeaking = $state(0);
  let speakPhase = $state(0);
  let sparksKey = $state(0);
  let held = $state(false);

  let unhoverTimer: ReturnType<typeof setTimeout> | undefined;
  let pokes: number[] = [];
  let restTimer: ReturnType<typeof setTimeout> | undefined;
  let momentTimer: ReturnType<typeof setTimeout> | undefined;
  let readTimer: ReturnType<typeof setTimeout> | undefined;
  let lastActivity = Date.now();
  let greeted = 0;

  const DROWSY_AFTER = 600_000;
  const GREETING_GAP = 180_000;

  const activeSpeaking = $derived(
    Math.max(0, Math.min(1, speakingLevel !== undefined ? speakingLevel : globalSpeaking)),
  );
  const isSpeaking = $derived(activeSpeaking > 0.02);

  // Mood traits matching `NookMood.swift`.
  const moodSmiles = $derived(
    resolvedMood === "done" || resolvedMood === "proud" || resolvedMood === "celebrate" || resolvedMood === "cozy",
  );
  const moodEyesShut = $derived(resolvedMood === "sleepy" || resolvedMood === "breathe");
  const isDrowsy = $derived(drowsy && (resolvedMood === "rest" || resolvedMood === "seen"));
  const showZ = $derived(isDrowsy || resolvedMood === "sleepy");
  const isCurious = $derived(curious || resolvedMood === "curious");

  // Happy ^ ^ eyes when mood smiles, greeting, nodding, or being petted (unless giggling, winking, or poking).
  const happyEyes = $derived(
    moment !== "giggle" &&
      moment !== "poke" &&
      moment !== "wink" &&
      (moodSmiles || blush || moment === "hello" || moment === "nod"),
  );
  const giggleEyes = $derived(moment === "giggle");
  const eyesClosed = $derived(
    !giggleEyes && !happyEyes && (blinking || moodEyesShut || moment === "poke"),
  );
  const showCheeks = $derived(
    face.cheeks &&
      (blush ||
        held ||
        moment === "giggle" ||
        resolvedMood === "cozy" ||
        resolvedMood === "proud" ||
        resolvedMood === "celebrate" ||
        resolvedMood === "caring"),
  );
  const showSparks = $derived(
    resolvedMood === "celebrate" || moment === "party",
  );

  function hover(id: string) {
    clearTimeout(unhoverTimer);
    hovered = id;
  }
  function unhover() {
    clearTimeout(unhoverTimer);
    unhoverTimer = setTimeout(() => (hovered = null), 250);
  }

  function play(m: typeof moment, ms: number) {
    clearTimeout(momentTimer);
    moment = "";
    queueMicrotask(() => (moment = m));
    momentTimer = setTimeout(() => (moment = ""), ms);
  }

  function activity() {
    lastActivity = Date.now();
    drowsy = false;
  }

  function noteTyping(seq: number) {
    if (!moments) return;
    if (resolvedMood === "think" || resolvedMood === "done" || moodEyesShut || isDrowsy) return;
    activity();
    reading = true;
    readingStep = seq;
    clearTimeout(readTimer);
    readTimer = setTimeout(() => {
      reading = false;
    }, 950);
  }

  function onGlobalKeydown(e: KeyboardEvent) {
    if (!moments || e.metaKey || e.ctrlKey || e.altKey || e.key.length !== 1) return;
    const target = e.target;
    if (target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement || (target instanceof HTMLElement && target.isContentEditable)) {
      noteTyping(readingStep + 1);
    }
  }

  function follow(e: MouseEvent) {
    if (!el || moodEyesShut || isDrowsy) return;
    const r = el.getBoundingClientRect();
    const dx = e.clientX - (r.left + r.width / 2);
    const dy = e.clientY - (r.top + r.height / 2);
    const d = Math.max(1, Math.hypot(dx, dy));
    const reach = size * 0.09;
    look = { x: (dx / d) * Math.min(reach, d / 20), y: (dy / d) * Math.min(reach, d / 20) };
  }

  function enter() {
    if (!moments) return activity();
    const now = Date.now();
    if (isDrowsy || now - lastActivity > DROWSY_AFTER) play("wake", 700);
    else if (now - greeted > GREETING_GAP) {
      greeted = now;
      play("hello", 650);
    }
    activity();
    clearTimeout(restTimer);
    // Pointer rests on Nook: gentle blush + happy petting reaction.
    restTimer = setTimeout(() => (blush = true), 900);
  }

  function leave() {
    clearTimeout(restTimer);
    blush = false;
  }

  function poke() {
    if (tugged) {
      tugged = false;
      return;
    }
    const now = Date.now();
    pokes = [...pokes.filter((t) => now - t < 1000), now];
    activity();
    if (pokes.length >= 3 && moments) {
      pokes = [];
      play("giggle", 1200);
    } else {
      play("poke", 420);
    }
  }

  // Organic irregular blinking with occasional double-blinks (`NookOrb.blinkGaps` + `doubleBlinks`).
  const gaps = [3.2, 5.8, 2.6, 6.6, 4.1, 3.5, 7.0, 2.9, 5.2, 4.4, 3.8, 6.1];
  const doubleBlinks = new Set([2, 7, 10]);
  $effect(() => {
    let i = 0;
    let timer: ReturnType<typeof setTimeout>;
    const next = () => {
      timer = setTimeout(() => {
        if (
          resolvedMood !== "think" &&
          !moodSmiles &&
          !moodEyesShut &&
          !document.body.classList.contains("easy")
        ) {
          blinking = true;
          setTimeout(() => (blinking = false), 130);
          if (doubleBlinks.has(i % gaps.length)) {
            setTimeout(() => {
              blinking = true;
              setTimeout(() => (blinking = false), 120);
            }, 260);
          }
        }
        i++;
        next();
      }, gaps[i % gaps.length] * 1000);
    };
    next();
    const drowse = setInterval(() => (drowsy = Date.now() - lastActivity > DROWSY_AFTER), 30_000);
    const listener = (ev: SharedEvent) => {
      if (ev.kind === "heard") {
        activity();
        play("heard", 650);
      } else if (ev.kind === "nod") {
        activity();
        play("nod", 750);
      } else if (ev.kind === "celebrate") {
        activity();
        sparksKey += 1;
        play("party", 1000);
      } else if (ev.kind === "typed") {
        noteTyping(ev.count);
      } else if (ev.kind === "speaking") {
        globalSpeaking = ev.level;
      }
    };
    listeners.add(listener);
    return () => {
      clearTimeout(timer);
      clearInterval(drowse);
      clearTimeout(readTimer);
      listeners.delete(listener);
    };
  });

  // Read-aloud mouth oscillation while speakingLevel > 0.02.
  $effect(() => {
    if (!isSpeaking) {
      speakPhase = 0;
      return;
    }
    let raf = 0;
    const tick = (now: number) => {
      speakPhase = now / 85;
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  });

  // Mood transitions: wink into done, celebrate sparks on proud/celebrate.
  let lastMood: NookMood | null = null;
  $effect(() => {
    const cur = resolvedMood;
    if (lastMood !== null && cur !== lastMood) {
      if (cur === "done") play("wink", 650);
      else if (cur === "proud" || cur === "celebrate") {
        sparksKey += 1;
        play("party", 1000);
      }
      activity();
    }
    lastMood = cur;
  });

  // Task ring geometry.
  const gap = 0.025;
  const ringSize = $derived(size * 1.75);
  function arc(i: number, n: number) {
    const r = ringSize / 2 - 3;
    const c = ringSize / 2;
    const span = 1 / n;
    const a0 = (i * span + gap) * 2 * Math.PI - Math.PI / 2;
    const a1 = ((i + 1) * span - gap) * 2 * Math.PI - Math.PI / 2;
    const large = a1 - a0 > Math.PI ? 1 : 0;
    return `M ${c + r * Math.cos(a0)} ${c + r * Math.sin(a0)} A ${r} ${r} 0 ${large} 1 ${c + r * Math.cos(a1)} ${c + r * Math.sin(a1)}`;
  }
  function middle(i: number, n: number) {
    return ((i + 0.5) / n) * 2 * Math.PI - Math.PI / 2;
  }

  // Elastic spring tether drag when `movable` is true.
  let pull = $state({ x: 0, y: 0, s: 0, a: 0, lx: 0, ly: 0 });
  let tugged = false;
  let grab: { x: number; y: number } | null = null;
  let pos = { x: 0, y: 0 };
  let vel = { x: 0, y: 0 };
  let aim = { x: 0, y: 0 };
  let frame = 0;
  let lastFrame = 0;
  let calm = false;
  const tether = $derived(size * 1.6);

  function step(now: number) {
    const dt = Math.min(1 / 30, (now - lastFrame) / 1000 || 1 / 60);
    lastFrame = now;
    const k = held ? 900 : 220;
    const c = 2 * Math.sqrt(k) * (held || calm ? 0.85 : 0.3);
    vel.x += (-k * (pos.x - aim.x) - c * vel.x) * dt;
    vel.y += (-k * (pos.y - aim.y) - c * vel.y) * dt;
    pos.x += vel.x * dt;
    pos.y += vel.y * dt;
    const speed = Math.hypot(vel.x, vel.y);
    if (!held && speed < 2 && Math.hypot(pos.x, pos.y) < 0.2) {
      pos = { x: 0, y: 0 };
      vel = { x: 0, y: 0 };
      pull = { x: 0, y: 0, s: 0, a: 0, lx: 0, ly: 0 };
      frame = 0;
      return;
    }
    const sx = vel.x / 2400 + (held ? (pos.x / tether) * 0.14 : 0);
    const sy = vel.y / 2400 + (held ? (pos.y / tether) * 0.14 : 0);
    const s = calm ? 0 : Math.min(0.24, Math.hypot(sx, sy));
    const lookMag = speed > 40 ? size * 0.09 : 0;
    pull = {
      x: pos.x,
      y: pos.y,
      s,
      a: Math.atan2(sy, sx),
      lx: (vel.x / (speed || 1)) * lookMag,
      ly: (vel.y / (speed || 1)) * lookMag,
    };
    frame = requestAnimationFrame(step);
  }

  function wake() {
    if (frame) return;
    lastFrame = performance.now();
    frame = requestAnimationFrame(step);
  }

  function hold(e: PointerEvent) {
    if (!movable || e.button !== 0) return;
    e.preventDefault();
    e.stopPropagation();
    (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
    calm = matchMedia("(prefers-reduced-motion: reduce)").matches || document.body.classList.contains("easy");
    grab = { x: e.clientX - pos.x, y: e.clientY - pos.y };
    tugged = false;
  }

  function drag(e: PointerEvent) {
    if (!grab) return;
    const dx = e.clientX - grab.x;
    const dy = e.clientY - grab.y;
    const d = Math.hypot(dx, dy);
    if (!held) {
      if (d < 4) return;
      held = true;
      tugged = true;
      activity();
    }
    const reach = tether * Math.tanh(d / tether);
    aim = { x: (dx / (d || 1)) * reach, y: (dy / (d || 1)) * reach };
    wake();
  }

  function release() {
    if (!grab) return;
    grab = null;
    if (!held) return;
    held = false;
    aim = { x: 0, y: 0 };
    wake();
  }

  $effect(() => () => cancelAnimationFrame(frame));

  // Gaze: elastic drag direction > hovered ring piece > typing read-along > waiting glance > pointer.
  const gaze = $derived.by(() => {
    if (pull.lx || pull.ly) return { x: pull.lx, y: pull.ly };
    const i = ring.findIndex((p) => p.id === hovered);
    if (i >= 0) {
      const a = middle(i, ring.length);
      return { x: Math.cos(a) * size * 0.09, y: Math.sin(a) * size * 0.09 };
    }
    if (reading) {
      const progress = ((readingStep % 24) / 24) * 2 - 1;
      return { x: progress * size * 0.07, y: size * 0.07 };
    }
    if (resolvedMood === "waiting") {
      return { x: size * 0.07, y: 0 };
    }
    if (resolvedMood === "think" || moodEyesShut || isDrowsy) {
      return { x: 0, y: 0 };
    }
    return look;
  });

  // Normalized mouth pose in 100x100 SVG coordinates (mirrors `NookOrb.moodMouth` + `drawMouth`).
  interface MouthPose {
    w: number;
    open: number;
    curve: number;
    round: number;
    shift: number;
  }

  const mouthPose = $derived.by((): MouthPose => {
    let base: MouthPose;
    if (isDrowsy || resolvedMood === "sleepy") {
      base = { w: 10, open: 4, curve: 0, round: 1, shift: 0 };
    } else {
      switch (resolvedMood) {
        case "seen": base = { w: 11, open: 6.5, curve: 0, round: 1, shift: 0 }; break;
        case "listen": base = { w: 13, open: 4.5 + level * 5, curve: 0.2, round: 0.8, shift: 0 }; break;
        case "think": base = { w: 12, open: 0, curve: -0.15, round: 0, shift: 5 }; break;
        case "waiting": base = { w: 15, open: 0, curve: 0.08, round: 0, shift: 0 }; break;
        case "remind": base = { w: 18, open: 4.5, curve: 0.6, round: 0, shift: 0 }; break;
        case "worry": base = { w: 17, open: 1.5, curve: -0.75, round: 0, shift: 0 }; break;
        case "done": base = { w: 25, open: 10, curve: 1, round: 0, shift: 0 }; break;
        case "proud": base = { w: 24, open: 6, curve: 1, round: 0, shift: 0 }; break;
        case "curious": base = { w: 11, open: 6, curve: 0, round: 1, shift: 0 }; break;
        case "cozy": base = { w: 18, open: 2, curve: 0.85, round: 0, shift: 0 }; break;
        case "focus": base = { w: 12, open: 0, curve: 0.05, round: 0, shift: 0 }; break;
        case "surprised": base = { w: 12, open: 10.5, curve: 0, round: 1, shift: 0 }; break;
        case "caring": base = { w: 16, open: 0, curve: 0.35, round: 0, shift: 0 }; break;
        case "celebrate": base = { w: 26, open: 12, curve: 1, round: 0, shift: 0 }; break;
        case "breathe": base = { w: 11, open: 2.5, curve: 0.3, round: 0.6, shift: 0 }; break;
        default: base = { w: 19, open: 0, curve: 0.55, round: 0, shift: 0 }; break;
      }
    }

    if (moment === "hello" || moment === "nod") base = { w: 22, open: 7, curve: 0.9, round: 0, shift: 0 };
    if (blush) base = { w: 20, open: 4, curve: 0.9, round: 0, shift: 0 };
    if (moment === "poke") base = { w: 10, open: 7, curve: 0, round: 1, shift: 0 };
    if (moment === "giggle") base = { w: 22, open: 10, curve: 1, round: 0, shift: 0 };

    // Read-aloud speech animation driven by `speakingLevel` (0..1).
    if (isSpeaking) {
      const wave = 0.55 + 0.45 * Math.sin(speakPhase * 1.9);
      const vowel = 0.5 + 0.5 * Math.cos(speakPhase * 1.15);
      const amp = activeSpeaking * wave;
      base = {
        w: 13 + amp * 13 - vowel * 3,
        open: Math.max(2.5, amp * 15),
        curve: Math.max(-0.2, base.curve * 0.5 + 0.2),
        round: vowel * 0.65,
        shift: 0,
      };
    }

    if (face.mouth === "line") {
      return { ...base, w: Math.min(base.w, 18), open: isSpeaking ? Math.min(base.open, 3) : 0 };
    }
    return base;
  });

  // Build SVG path for the mouth in 100x100 coordinates.
  const mouthGeometry = $derived.by(() => {
    const m = mouthPose;
    const gx = (gaze.x / Math.max(1, size)) * 100;
    const gy = (gaze.y / Math.max(1, size)) * 100;
    const cx = 50 + gx * 0.8 + m.shift;
    const cy = 67 + gy * 0.6;
    const halfW = m.w / 2;
    const lift = -m.curve * 3.4;
    const open = face.mouth === "expressive" ? m.open : 0;

    if (size < 26 || open < 2.2) {
      const ctrlY = cy + m.curve * 4.2 + (size < 26 ? open * 0.4 : 0);
      return {
        open: false,
        d: `M ${cx - halfW} ${cy + lift} Q ${cx} ${ctrlY} ${cx + halfW} ${cy + lift}`,
        cx,
        cy,
        rx: halfW,
        ry: open / 2,
      };
    }

    if (m.round > 0.65) {
      const rx = Math.max(3.4, halfW * 0.82);
      const ry = Math.max(3.2, open * 0.58);
      return {
        open: true,
        oval: true,
        d: "",
        cx,
        cy: cy + ry * 0.2,
        rx,
        ry,
      };
    }

    const topCtrlY = cy + lift * 0.15 + (m.curve < 0 ? -1.5 : 0.8);
    const botCtrlY = cy + open * 1.15 + m.curve * 2.4;
    const d = `M ${cx - halfW} ${cy + lift} Q ${cx} ${topCtrlY} ${cx + halfW} ${cy + lift} Q ${cx} ${botCtrlY} ${cx - halfW} ${cy + lift} Z`;
    return {
      open: true,
      oval: false,
      d,
      cx,
      cy: cy + open * 0.45,
      rx: halfW * 0.65,
      ry: open * 0.35,
    };
  });

  // Eye geometry in 100x100 SVG coordinates (bars, round, dots), matching `NookOrb.eyeSize(for:)`.
  const eyeMetrics = $derived.by(() => {
    const mode = face.eyes;
    let w = 13;
    let h = 26;
    if (mode === "bars") {
      switch (resolvedMood) {
        case "listen": w = 12; h = 34 + level * 7; break;
        case "waiting":
        case "worry": w = 13; h = 30; break;
        case "think": w = 13; h = 13; break;
        case "focus": w = 13; h = 16; break;
        case "surprised": w = 13.5; h = 36; break;
        default: w = 12; h = 26; break;
      }
    } else if (mode === "round") {
      switch (resolvedMood) {
        case "seen": w = 17; h = 20; break;
        case "listen": w = 16; h = 21 + level * 4; break;
        case "think": w = 13.5; h = 13.5; break;
        case "focus": w = 17; h = 12.5; break;
        case "surprised": w = 19; h = 24; break;
        default: w = 16.8; h = 19; break;
      }
    } else {
      switch (resolvedMood) {
        case "seen": w = 12.5; h = 12.5; break;
        case "listen": w = 10.5; h = 13 + level * 3; break;
        case "think": w = 9; h = 9; break;
        case "focus": w = 11.5; h = 7.5; break;
        case "surprised": w = 14; h = 14; break;
        default: w = 10.5; h = 10.5; break;
      }
    }

    if (held || moment === "heard" || moment === "wake") h *= 1.18;
    if (isDrowsy) h *= 0.42;
    if (reading) h *= 0.84;

    const lift = face.mouth === "none" ? 0 : mode === "bars" ? 4.5 : 5.5;
    const spacing = mode === "dots" ? 16 : mode === "round" ? 14 : 17;
    const gx = (gaze.x / Math.max(1, size)) * 100;
    const gy = (gaze.y / Math.max(1, size)) * 100;
    const baseY = 50 - lift + gy + (resolvedMood === "proud" ? -2.5 : resolvedMood === "focus" ? 1.5 : 0);

    const leftH = isCurious ? h * 0.9 : h;
    const rightH = isCurious ? h * 1.16 : resolvedMood === "seen" ? h * 1.06 : h;
    const leftY = baseY;
    const rightY = baseY + (resolvedMood === "seen" ? -2.5 : 0);

    const leftRot = resolvedMood === "worry" ? 14 : resolvedMood === "caring" ? -10 : 0;
    const rightRot = resolvedMood === "worry" ? -14 : resolvedMood === "caring" ? 10 : 0;

    return {
      w,
      leftH,
      rightH,
      leftX: 50 - spacing / 2 - w / 2 + gx,
      rightX: 50 + spacing / 2 + w / 2 + gx,
      leftY,
      rightY,
      leftRot,
      rightRot,
      gx,
      gy,
    };
  });

  const sparkAngles = [0, 1, 2, 3, 4, 5, 6, 7].map((i) => (i / 8) * Math.PI * 2 + 0.3);
</script>

<svelte:window onmousemove={follow} onkeydown={onGlobalKeydown} />

<div class="wrap" style="--s:{size}px;--r:{ringSize}px;--face:{faceColor};--iris-tint:{irisTint}" class:ringed={ring.length > 0}>
  {#if ring.length}
    <svg class="ring" width={ringSize} height={ringSize} viewBox="0 0 {ringSize} {ringSize}" aria-hidden="true">
      {#each ring as piece, i (piece.id)}
        <!-- svelte-ignore a11y_no_static_element_interactions, a11y_click_events_have_key_events -->
        <path
          d={arc(i, ring.length)}
          class="piece {piece.state}"
          class:hover={hovered === piece.id}
          style="animation-delay:{i * 60}ms"
          onmouseenter={() => hover(piece.id)}
          onmouseleave={unhover}
          onclick={() => onpiece?.(piece.id)}
        />
      {/each}
    </svg>
    {#if hovered}
      {@const id = hovered}
      <button class="label" onmouseenter={() => hover(id)} onmouseleave={unhover} onclick={() => { hovered = null; onpiece?.(id); }}>
        {ring.find((p) => p.id === id)?.label}
      </button>
    {/if}
  {/if}
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div
    class="hold"
    class:movable
    class:held
    onpointerdown={hold}
    onpointermove={drag}
    onpointerup={release}
    onpointercancel={release}
    onmousedown={(e) => movable && e.button === 0 && e.stopPropagation()}
    style="transform: translate({pull.x}px, {pull.y}px) rotate({pull.a}rad) scale({1 + pull.s}, {1 - pull.s * 0.55}) rotate({-pull.a}rad)"
  >
    <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
    <div
      class="orb mood-{resolvedMood} {moment} eyes-{face.eyes} mouth-{face.mouth}"
      class:drowsy={isDrowsy}
      class:curious={isCurious}
      class:petting={blush}
      class:speaking={isSpeaking}
      class:flat={!face.gloss}
      class:noglow={!face.glow}
      bind:this={el}
      onmouseenter={enter}
      onmouseleave={leave}
      onclick={poke}
      style="--lx:{-gaze.x * 1.6}px;--ly:{-gaze.y * 1.6}px;--level:{level};--speak-lift:{isSpeaking ? -mouthPose.open * 0.12 : 0}px"
    >
      <svg class="face-svg" viewBox="0 0 100 100" aria-hidden="true">
        <!-- Left eye -->
        <g
          class="eye-group left"
          class:thinking={resolvedMood === "think"}
          transform="translate({eyeMetrics.leftX}, {eyeMetrics.leftY}) rotate({eyeMetrics.leftRot})"
        >
          {#if giggleEyes}
            <path class="eye-stroke" d="M {-eyeMetrics.w * 0.45} {-eyeMetrics.leftH * 0.28} L {eyeMetrics.w * 0.35} 0 L {-eyeMetrics.w * 0.45} {eyeMetrics.leftH * 0.28}" />
          {:else if moment === "wink"}
            <path class="eye-stroke" d="M {-eyeMetrics.w * 0.55} 1 Q 0 {-eyeMetrics.w * 0.35} {eyeMetrics.w * 0.55} 1" />
          {:else if happyEyes}
            <path class="eye-stroke" d="M {-eyeMetrics.w * 0.58} {eyeMetrics.w * 0.2} Q 0 {-eyeMetrics.w * 0.48} {eyeMetrics.w * 0.58} {eyeMetrics.w * 0.2}" />
          {:else if eyesClosed}
            <path class="eye-stroke" d="M {-eyeMetrics.w * 0.52} 0 Q 0 {eyeMetrics.w * 0.28} {eyeMetrics.w * 0.52} 0" />
          {:else if face.eyes === "bars"}
            <rect class="eye-fill" x={-eyeMetrics.w / 2} y={-eyeMetrics.leftH / 2} width={eyeMetrics.w} height={eyeMetrics.leftH} rx={eyeMetrics.w / 2} />
            {#if face.gloss && size >= 30 && eyeMetrics.leftH > 14}
              <ellipse class="catchlight" cx={-eyeMetrics.w * 0.14} cy={-eyeMetrics.leftH * 0.24} rx={eyeMetrics.w * 0.19} ry={eyeMetrics.leftH * 0.09} />
            {/if}
          {:else}
            <ellipse class="eye-fill" cx="0" cy="0" rx={eyeMetrics.w / 2} ry={eyeMetrics.leftH / 2} />
            {#if face.eyes === "round" && face.gloss && size >= 26}
              <ellipse class="eye-iris" cx="0" cy={eyeMetrics.leftH * 0.2} rx={eyeMetrics.w * 0.34} ry={eyeMetrics.leftH * 0.2} />
              <ellipse class="catchlight" cx={-eyeMetrics.w * 0.16} cy={-eyeMetrics.leftH * 0.16} rx={eyeMetrics.w * 0.17} ry={eyeMetrics.leftH * 0.15} />
              <circle class="catchlight-small" cx={eyeMetrics.w * 0.18} cy={eyeMetrics.leftH * 0.16} r={eyeMetrics.w * 0.075} />
            {/if}
          {/if}
        </g>

        <!-- Right eye -->
        <g
          class="eye-group right"
          class:thinking={resolvedMood === "think"}
          transform="translate({eyeMetrics.rightX}, {eyeMetrics.rightY}) rotate({eyeMetrics.rightRot})"
        >
          {#if giggleEyes}
            <path class="eye-stroke" d="M {eyeMetrics.w * 0.45} {-eyeMetrics.rightH * 0.28} L {-eyeMetrics.w * 0.35} 0 L {eyeMetrics.w * 0.45} {eyeMetrics.rightH * 0.28}" />
          {:else if happyEyes}
            <path class="eye-stroke" d="M {-eyeMetrics.w * 0.58} {eyeMetrics.w * 0.2} Q 0 {-eyeMetrics.w * 0.48} {eyeMetrics.w * 0.58} {eyeMetrics.w * 0.2}" />
          {:else if eyesClosed}
            <path class="eye-stroke" d="M {-eyeMetrics.w * 0.52} 0 Q 0 {eyeMetrics.w * 0.28} {eyeMetrics.w * 0.52} 0" />
          {:else if face.eyes === "bars"}
            <rect class="eye-fill" x={-eyeMetrics.w / 2} y={-eyeMetrics.rightH / 2} width={eyeMetrics.w} height={eyeMetrics.rightH} rx={eyeMetrics.w / 2} />
            {#if face.gloss && size >= 30 && eyeMetrics.rightH > 14}
              <ellipse class="catchlight" cx={-eyeMetrics.w * 0.14} cy={-eyeMetrics.rightH * 0.24} rx={eyeMetrics.w * 0.19} ry={eyeMetrics.rightH * 0.09} />
            {/if}
          {:else}
            <ellipse class="eye-fill" cx="0" cy="0" rx={eyeMetrics.w / 2} ry={eyeMetrics.rightH / 2} />
            {#if face.eyes === "round" && face.gloss && size >= 26}
              <ellipse class="eye-iris" cx="0" cy={eyeMetrics.rightH * 0.2} rx={eyeMetrics.w * 0.34} ry={eyeMetrics.rightH * 0.2} />
              <ellipse class="catchlight" cx={-eyeMetrics.w * 0.16} cy={-eyeMetrics.rightH * 0.16} rx={eyeMetrics.w * 0.17} ry={eyeMetrics.rightH * 0.15} />
              <circle class="catchlight-small" cx={eyeMetrics.w * 0.18} cy={eyeMetrics.rightH * 0.16} r={eyeMetrics.w * 0.075} />
            {/if}
          {/if}
        </g>

        <!-- Mouth -->
        {#if face.mouth !== "none"}
          {#if mouthGeometry.open}
            {#if mouthGeometry.oval}
              <ellipse class="mouth-fill" cx={mouthGeometry.cx} cy={mouthGeometry.cy} rx={mouthGeometry.rx} ry={mouthGeometry.ry} />
              {#if mouthGeometry.ry > 3.8}
                <ellipse class="mouth-tongue" cx={mouthGeometry.cx} cy={mouthGeometry.cy + mouthGeometry.ry * 0.45} rx={mouthGeometry.rx * 0.62} ry={mouthGeometry.ry * 0.42} />
              {/if}
            {:else}
              <path class="mouth-fill" d={mouthGeometry.d} />
              {#if mouthGeometry.ry > 2.2}
                <ellipse class="mouth-tongue" cx={mouthGeometry.cx} cy={mouthGeometry.cy + mouthGeometry.ry * 0.32} rx={mouthGeometry.rx * 0.65} ry={mouthGeometry.ry * 0.55} />
              {/if}
            {/if}
          {:else}
            <path class="mouth-stroke" d={mouthGeometry.d} />
          {/if}
        {/if}
      </svg>

      {#if showCheeks}
        <span class="cheek left"></span><span class="cheek right"></span>
      {/if}
      {#if showSparks}
        {#key sparksKey}
          <span class="sparks" class:repeat={resolvedMood === "celebrate"} aria-hidden="true">
            {#each sparkAngles as angle, idx (idx)}
              <span
                class="spark"
                class:alt={idx % 2 === 1}
                style="--sx:{Math.cos(angle) * size * 0.85}px;--sy:{Math.sin(angle) * size * 0.85}px"
              ></span>
            {/each}
          </span>
        {/key}
      {/if}
      {#if showZ}
        <span class="zzz" aria-hidden="true">z</span>
      {/if}
    </div>
  </div>
</div>

<style>
  .wrap { --eye: var(--ink); position: relative; width: var(--s); height: var(--s); display: inline-flex; align-items: center; justify-content: center; flex: none; }
  .wrap.ringed { width: var(--r); height: var(--r); }
  .orb {
    width: var(--s);
    height: var(--s);
    border-radius: 50%;
    background:
      radial-gradient(circle at calc(34% + var(--lx)) calc(30% + var(--ly)), color-mix(in srgb, var(--face) 20%, var(--paper)) 0%, var(--face) 45%, color-mix(in srgb, var(--face) 86%, var(--ink)) 100%),
      var(--face);
    box-shadow:
      inset 0 calc(var(--s) * -0.08) calc(var(--s) * 0.18) color-mix(in srgb, var(--ink) 14%, transparent),
      0 0 calc(var(--s) * (0.5 + var(--level) * 0.6)) color-mix(in srgb, var(--paper) 14%, transparent);
    display: flex;
    align-items: center;
    justify-content: center;
    position: relative;
    transition: box-shadow 0.3s, background 0.3s;
    cursor: default;
  }
  .orb.speaking { transform: translateY(var(--speak-lift)); }
  .orb.flat { background: var(--face); box-shadow: 0 0 calc(var(--s) * (0.5 + var(--level) * 0.6)) color-mix(in srgb, var(--paper) 12%, transparent); }
  .orb.noglow:not(.mood-waiting):not(.mood-listen):not(.mood-worry):not(.mood-breathe) {
    box-shadow: inset 0 calc(var(--s) * -0.08) calc(var(--s) * 0.18) color-mix(in srgb, var(--ink) 12%, transparent);
  }
  .orb.flat.noglow:not(.mood-waiting):not(.mood-listen):not(.mood-worry):not(.mood-breathe) { box-shadow: none; }

  .face-svg { width: 100%; height: 100%; overflow: visible; pointer-events: none; }
  .eye-group { transition: transform 0.08s linear; }
  .eye-fill { fill: var(--eye); }
  .eye-stroke { fill: none; stroke: var(--eye); stroke-width: 5.5; stroke-linecap: round; stroke-linejoin: round; }
  .eye-iris { fill: var(--iris-tint); opacity: 0.42; }
  .catchlight { fill: var(--paper); opacity: 0.92; }
  .catchlight-small { fill: var(--paper); opacity: 0.72; }
  .mouth-stroke { fill: none; stroke: var(--eye); stroke-width: 4.5; stroke-linecap: round; }
  .mouth-fill { fill: var(--eye); stroke: var(--eye); stroke-width: 1.5; stroke-linejoin: round; }
  .mouth-tongue { fill: var(--coral-soft); opacity: 0.85; }

  .eye-group.thinking.left { animation: think-eye 1.4s ease-in-out infinite; }
  .eye-group.thinking.right { animation: think-eye 1.4s ease-in-out 0.12s infinite; }

  .hold { display: flex; position: relative; z-index: 1; will-change: transform; }
  .hold.movable { cursor: grab; user-select: none; touch-action: none; }
  .hold.movable .orb { cursor: inherit; }
  .hold.held { cursor: grabbing; z-index: 10; }
  .held .orb { box-shadow: 0 calc(var(--s) * 0.18) calc(var(--s) * 0.6) color-mix(in srgb, var(--paper) 25%, transparent); }

  .cheek { position: absolute; top: 58%; width: calc(var(--s) * 0.17); height: calc(var(--s) * 0.085); border-radius: 50%;
    background: color-mix(in srgb, var(--coral-soft) 65%, transparent); filter: blur(1px); pointer-events: none; }
  .cheek.left { left: 15%; }
  .cheek.right { right: 15%; }

  .zzz { position: absolute; right: calc(var(--s) * -0.18); top: calc(var(--s) * -0.18); font: var(--text-caption); font-weight: 700;
    color: var(--text3); pointer-events: none; animation: float-z 2.8s ease-in-out infinite; }

  .sparks { position: absolute; inset: 0; pointer-events: none; }
  .spark { position: absolute; left: 50%; top: 50%; width: max(3px, calc(var(--s) * 0.08)); height: max(3px, calc(var(--s) * 0.08));
    margin: calc(max(3px, calc(var(--s) * 0.08)) * -0.5); border-radius: 999px; background: var(--paper);
    animation: spark-burst 0.9s ease-out 1 both; }
  .spark.alt { background: var(--mint); }
  .sparks.repeat .spark { animation: spark-burst 2.2s ease-out infinite; }

  /* 17 mood animations & glows */
  .mood-rest:not(.drowsy) { animation: rest 4.5s ease-in-out infinite; }
  .mood-think { animation: breathe 1.6s ease-in-out infinite; }
  .mood-waiting { box-shadow: 0 0 calc(var(--s) * 0.6) color-mix(in srgb, var(--amber) 55%, transparent); animation: tap-shoulder 3.6s ease-in-out infinite; }
  .mood-remind { box-shadow: 0 0 calc(var(--s) * 0.55) color-mix(in srgb, var(--amber) 50%, transparent); animation: rest 3.6s ease-in-out infinite; }
  .mood-listen { box-shadow: 0 0 calc(var(--s) * (0.5 + var(--level) * 1.2)) color-mix(in srgb, var(--mint) 60%, transparent); }
  .mood-worry { box-shadow: 0 0 calc(var(--s) * 0.6) color-mix(in srgb, var(--coral) 55%, transparent); animation: shake 0.45s ease-in-out 1; }
  .mood-done { box-shadow: 0 0 calc(var(--s) * 0.55) color-mix(in srgb, var(--mint) 48%, transparent); }
  .mood-proud { box-shadow: 0 0 calc(var(--s) * 0.55) color-mix(in srgb, var(--mint) 55%, transparent); animation: proud-bounce 2.4s ease-in-out infinite; }
  .mood-cozy { box-shadow: 0 0 calc(var(--s) * 0.55) color-mix(in srgb, var(--amber) 48%, transparent); animation: sway 4.2s ease-in-out infinite; }
  .mood-caring { box-shadow: 0 0 calc(var(--s) * 0.52) color-mix(in srgb, var(--coral-soft) 48%, transparent); transform: rotate(6deg); }
  .mood-sleepy, .orb.drowsy { animation: sleep-nod 6s ease-in-out infinite; }
  .mood-celebrate { box-shadow: 0 0 calc(var(--s) * 0.65) color-mix(in srgb, var(--mint) 62%, transparent); animation: celebrate-hop 1.1s ease-in-out infinite; }
  .mood-breathe { box-shadow: 0 0 calc(var(--s) * 0.6) color-mix(in srgb, var(--mint-soft) 55%, transparent); animation: breathe-446 14s ease-in-out infinite; }
  .mood-surprised { animation: surprised-jump 0.55s ease-out 1; }
  .mood-focus { transform: translateY(1px); }
  .orb.curious { animation: curious-tilt 4.4s ease-in-out infinite; }
  .orb.petting { animation: sway 2.8s ease-in-out infinite; }

  /* Energy saver (`body.easy`) & reduced motion */
  :global(body.easy) .mood-rest,
  :global(body.easy) .mood-cozy,
  :global(body.easy) .mood-sleepy,
  :global(body.easy) .orb.drowsy { animation: none; }
  :global(body.easy) .mood-think { animation-duration: 4.8s; }
  :global(body.easy) .piece.waiting { animation-duration: 0.5s, 3.6s; }
  @media (prefers-reduced-motion: reduce) {
    .orb, .eye-group, .spark, .zzz { animation: none !important; }
  }

  /* Moment reactions */
  .nod { animation: nod 0.7s ease-out 1; }
  .poke { animation: squash 0.4s ease-out 1; }
  .heard { animation: hop 0.6s cubic-bezier(0.3, 1.6, 0.5, 1) 1; }
  .hello { animation: hop 0.6s ease-out 1; }
  .wake { animation: hop 0.7s cubic-bezier(0.3, 1.8, 0.5, 1) 1; }
  .giggle { animation: wobble 1.1s ease-in-out 1; }
  .wink { animation: wink-tilt 0.65s ease-out 1; }
  .party { animation: hop 0.75s cubic-bezier(0.3, 1.6, 0.5, 1) 1; }

  @keyframes rest { 50% { transform: translateY(-1px) scale(1.02); } }
  @keyframes breathe { 50% { transform: scale(1.07); } }
  @keyframes think-eye { 50% { transform: translateY(-4px); } }
  @keyframes nod { 30% { transform: translateY(3px) rotate(-4deg); } 60% { transform: translateY(-1px); } }
  @keyframes wink-tilt { 40% { transform: translateY(-2px) rotate(-7deg); } }
  @keyframes squash { 30% { transform: scale(1.16, 0.82); } 65% { transform: scale(0.95, 1.06); } }
  @keyframes hop { 25% { transform: scale(1.1, 0.88); } 55% { transform: translateY(calc(var(--s) * -0.2)); } 80% { transform: translateY(0) scale(1.05, 0.95); } }
  @keyframes wobble { 15%, 45%, 75% { transform: rotate(-9deg) translateY(-1px); } 30%, 60%, 90% { transform: rotate(9deg) translateY(-2px); } }
  @keyframes shake { 25% { transform: translateX(-3px); } 50% { transform: translateX(3px); } 75% { transform: translateX(-2px); } }
  @keyframes sway { 0%, 100% { transform: rotate(-4deg); } 50% { transform: rotate(4deg); } }
  @keyframes proud-bounce { 0%, 75%, 100% { transform: translateY(-1px); } 88% { transform: translateY(calc(var(--s) * -0.09)) scale(0.98, 1.04); } }
  @keyframes celebrate-hop { 12% { transform: scale(1.08, 0.92); } 45% { transform: translateY(calc(var(--s) * -0.15)) scale(0.96, 1.06); } 80% { transform: translateY(0); } }
  @keyframes surprised-jump { 35% { transform: translateY(calc(var(--s) * -0.14)) scale(0.96, 1.07); } 100% { transform: translateY(0); } }
  @keyframes tap-shoulder { 0%, 100% { transform: translate(0, 0); } 14% { transform: translate(2px, -3px); } 22% { transform: translate(2px, 0); } 30% { transform: translate(2px, -3px); } 40% { transform: translate(0, 0); } }
  @keyframes curious-tilt { 15%, 75% { transform: rotate(10deg) translateX(2px); } 0%, 100% { transform: rotate(0deg); } }
  @keyframes sleep-nod { 0%, 100% { transform: scale(1); } 50% { transform: translateY(2px) rotate(-4deg) scale(1.03); } }
  /* 4s in (0-28.5%), 4s hold (28.5-57%), 6s out (57-100%) */
  @keyframes breathe-446 { 0%, 100% { transform: scale(0.94); } 28.5%, 57% { transform: scale(1.12); } }
  @keyframes spark-burst { 0% { opacity: 0; transform: translate(0, 0) scale(0.6); } 15% { opacity: 1; } 70% { opacity: 0; transform: translate(var(--sx), var(--sy)) scale(0.45); } 100% { opacity: 0; transform: translate(var(--sx), var(--sy)) scale(0.4); } }
  @keyframes float-z { 0%, 100% { opacity: 0.45; transform: translateY(0); } 50% { opacity: 0.9; transform: translateY(-3px); } }

  .ring { position: absolute; inset: 0; overflow: visible; }
  .piece { fill: none; stroke-width: 3; stroke-linecap: round; cursor: pointer; animation: draw 0.5s ease-out both; }
  .piece.working { stroke: color-mix(in srgb, var(--paper) 45%, transparent); }
  .piece.waiting { stroke: var(--amber); animation: draw 0.5s ease-out both, pulse 1.2s ease-in-out infinite; }
  .piece.error { stroke: var(--coral); }
  .piece.done { stroke: var(--mint); }
  .piece.hover { stroke-width: 5; }
  @keyframes draw { from { opacity: 0; } }
  @keyframes pulse { 50% { opacity: 0.45; } }
  .label { position: absolute; left: calc(100% + 6px); top: 50%; transform: translateY(-50%); white-space: nowrap; font: var(--text-caption); color: var(--text2); background: var(--notch); padding: var(--space-2) var(--space-6); border: none; border-radius: var(--radius-chip); z-index: 5; }
  .label:hover { color: var(--paper); background: var(--smoke); }
</style>
