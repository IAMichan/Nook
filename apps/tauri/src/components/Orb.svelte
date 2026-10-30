<script lang="ts" module>
  // Momenten die alle bollen delen (NookPresence op de Mac): een klik, iets verstuurd, iets klaar.
  export type Mood = "idle" | "working" | "waiting" | "done" | "error" | "listen" | "seen";
  export interface RingPiece {
    id: string;
    label: string;
    state: "working" | "waiting" | "error" | "done";
  }

  const listeners = new Set<(moment: "heard" | "nod") => void>();
  /// Je stuurde Nook iets: een sprongetje met grote ogen.
  export function heard() {
    listeners.forEach((l) => l("heard"));
  }
  /// Iets is klaar: een tevreden knik.
  export function nod() {
    listeners.forEach((l) => l("nod"));
  }
</script>

<script lang="ts">
  // Nook zelf: een bol met licht en schaduw waarvan de ogen je muis volgen. Hij knippert, ademt, knikt als iets klaar
  // is, springt op als je iets verstuurt, krijgt blosjes als je muis even op hem rust en giechelt na drie snelle klikken.
  // In het open paneel draagt hij een ring met alles waar hij mee bezig is (NookOrb en NookTaskRing op de Mac).
  let {
    size = 22,
    mood = "idle",
    level = 0,
    ring = [],
    onpiece,
    movable = false,
  }: { size?: number; mood?: Mood; level?: number; ring?: RingPiece[]; onpiece?: (id: string) => void; movable?: boolean } = $props();

  let el: HTMLDivElement;
  let look = $state({ x: 0, y: 0 });
  let blinking = $state(false);
  let moment = $state<"" | "poke" | "giggle" | "heard" | "nod" | "hello" | "wake">("");
  let blush = $state(false);
  let drowsy = $state(false);
  let hovered = $state<string | null>(null);
  // The hovered piece's name stays a moment after the pointer leaves the ring, so you can move onto it and click it.
  let unhoverTimer: ReturnType<typeof setTimeout> | undefined;
  function hover(id: string) {
    clearTimeout(unhoverTimer);
    hovered = id;
  }
  function unhover() {
    clearTimeout(unhoverTimer);
    unhoverTimer = setTimeout(() => (hovered = null), 250);
  }
  let pokes: number[] = [];
  let restTimer: ReturnType<typeof setTimeout> | undefined;
  let momentTimer: ReturnType<typeof setTimeout> | undefined;
  let lastActivity = Date.now();
  let greeted = 0;

  // Na tien minuten zonder iets dommelt Nook in; de muis maakt hem wakker.
  const DROWSY_AFTER = 600_000;
  const GREETING_GAP = 180_000;

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

  function follow(e: MouseEvent) {
    if (!el) return;
    const r = el.getBoundingClientRect();
    const dx = e.clientX - (r.left + r.width / 2);
    const dy = e.clientY - (r.top + r.height / 2);
    const d = Math.max(1, Math.hypot(dx, dy));
    const reach = size * 0.09;
    look = { x: (dx / d) * Math.min(reach, d / 20), y: (dy / d) * Math.min(reach, d / 20) };
  }

  function enter() {
    const now = Date.now();
    if (drowsy || now - lastActivity > DROWSY_AFTER) play("wake", 700);
    else if (now - greeted > GREETING_GAP) {
      greeted = now;
      play("hello", 600);
    }
    activity();
    clearTimeout(restTimer);
    // De muis rust op Nook: blosjes.
    restTimer = setTimeout(() => (blush = true), 1200);
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
    if (pokes.length >= 3) {
      pokes = [];
      play("giggle", 1100);
    } else {
      play("poke", 350);
    }
  }

  // Knipperen op onregelmatige momenten, soms twee keer; niet als hij tevreden is of denkt.
  const gaps = [3.2, 4.8, 2.6, 6.1, 3.9, 5.4, 2.9, 7.2, 4.1, 3.5];
  $effect(() => {
    let i = 0;
    let timer: ReturnType<typeof setTimeout>;
    const next = () => {
      timer = setTimeout(() => {
        if (mood !== "done" && mood !== "working") {
          blinking = true;
          setTimeout(() => (blinking = false), 130);
          if (i % 4 === 1) setTimeout(() => { blinking = true; setTimeout(() => (blinking = false), 120); }, 260);
        }
        i++;
        next();
      }, gaps[i % gaps.length] * 1000);
    };
    next();
    const drowse = setInterval(() => (drowsy = Date.now() - lastActivity > DROWSY_AFTER), 30_000);
    const listener = (m: "heard" | "nod") => {
      activity();
      play(m, m === "heard" ? 600 : 700);
    };
    listeners.add(listener);
    return () => {
      clearTimeout(timer);
      clearInterval(drowse);
      listeners.delete(listener);
    };
  });

  // Klaar of mislukt: knikken of schudden.
  let lastMood: Mood = "idle";
  $effect(() => {
    if (mood !== lastMood) {
      if (mood === "done") play("nod", 700);
      lastMood = mood;
      activity();
    }
  });

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
  // Hold the left button on a movable Nook and pull: he follows on an elastic tether, stretches along the way he moves,
  // and springs home with a wobble when you let go. A spring runs per frame only while he is held or still settling.
  let held = $state(false);
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
    // Stiff while held so he keeps up with the pointer, loose on release so he overshoots home and wobbles.
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
    // Stretch along the motion, plus a little along the tether while he is pulled away from home.
    const sx = vel.x / 2400 + (held ? (pos.x / tether) * 0.14 : 0);
    const sy = vel.y / 2400 + (held ? (pos.y / tether) * 0.14 : 0);
    const s = calm ? 0 : Math.min(0.24, Math.hypot(sx, sy));
    const look = speed > 40 ? size * 0.09 : 0;
    pull = { x: pos.x, y: pos.y, s, a: Math.atan2(sy, sx), lx: (vel.x / (speed || 1)) * look, ly: (vel.y / (speed || 1)) * look };
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
    // Free close to home, ever stiffer the further you pull, never past the end of the tether.
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

  // Wijst de muis een stuk van de ring aan, dan kijkt Nook ernaar.
  const gaze = $derived.by(() => {
    if (pull.lx || pull.ly) return { x: pull.lx, y: pull.ly };
    const i = ring.findIndex((p) => p.id === hovered);
    if (i < 0) return look;
    const a = middle(i, ring.length);
    return { x: Math.cos(a) * size * 0.09, y: Math.sin(a) * size * 0.09 };
  });
</script>

<svelte:window onmousemove={follow} />

<div class="wrap" style="--s:{size}px;--r:{ringSize}px" class:ringed={ring.length > 0}>
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
      class="orb {mood} {moment}"
      class:drowsy
      bind:this={el}
      onmouseenter={enter}
      onmouseleave={leave}
      onclick={poke}
      style="--lx:{-gaze.x * 1.6}px;--ly:{-gaze.y * 1.6}px;--level:{level}"
    >
      <span class="eye" class:blink={blinking || moment === "poke" || moment === "giggle"} style="transform: translate({gaze.x}px, {gaze.y}px)"></span>
      <span class="eye" class:blink={blinking || moment === "poke" || moment === "giggle"} style="transform: translate({gaze.x}px, {gaze.y}px)"></span>
      {#if blush || held || moment === "giggle"}
        <span class="cheek left"></span><span class="cheek right"></span>
      {/if}
    </div>
  </div>
</div>

<style>
  .wrap { position: relative; width: var(--s); height: var(--s); display: inline-flex; align-items: center; justify-content: center; flex: none; }
  .wrap.ringed { width: var(--r); height: var(--r); }
  .orb {
    width: var(--s);
    height: var(--s);
    border-radius: 50%;
    /* Belicht als een bal: hoogtepunt linksboven dat tegen de blik in schuift, schaduw naar de rand, wat teruggekaatst licht onderin. */
    background:
      radial-gradient(circle at calc(34% + var(--lx)) calc(30% + var(--ly)), #fff 0%, var(--iris) 38%, color-mix(in srgb, var(--iris) 55%, #000) 100%),
      var(--iris);
    box-shadow:
      inset 0 calc(var(--s) * -0.08) calc(var(--s) * 0.18) color-mix(in srgb, var(--iris) 40%, #fff 10%),
      0 0 calc(var(--s) * (0.5 + var(--level) * 0.6)) color-mix(in srgb, var(--iris) 25%, transparent);
    display: flex;
    align-items: center;
    justify-content: center;
    gap: calc(var(--s) * 0.16);
    position: relative;
    transition: box-shadow 0.3s;
    cursor: default;
  }
  .eye {
    width: calc(var(--s) * 0.13);
    height: calc(var(--s) * 0.22);
    border-radius: 999px;
    background: #050507;
    transition: transform 0.08s linear, height 0.08s;
  }
  .hold { display: flex; position: relative; z-index: 1; will-change: transform; }
  .hold.movable { cursor: grab; user-select: none; touch-action: none; }
  .hold.movable .orb { cursor: inherit; }
  .hold.held { cursor: grabbing; z-index: 10; }
  /* Held: wide awake, and a soft lift that the glow follows. */
  .held .orb { box-shadow: 0 calc(var(--s) * 0.18) calc(var(--s) * 0.6) color-mix(in srgb, var(--iris) 40%, transparent); }
  .held .eye { height: calc(var(--s) * 0.26); }
  .eye.blink { height: calc(var(--s) * 0.03); }
  .drowsy .eye { height: calc(var(--s) * 0.08); }
  .cheek { position: absolute; top: 58%; width: calc(var(--s) * 0.16); height: calc(var(--s) * 0.08); border-radius: 50%; background: rgba(255, 120, 150, 0.55); filter: blur(1px); }
  .cheek.left { left: 16%; }
  .cheek.right { right: 16%; }
  .working { animation: breathe 1.6s ease-in-out infinite; }
  .idle:not(.drowsy) { animation: rest 4.5s ease-in-out infinite; }
  /* Taking it easy (battery, saver, paused): the idle float rests, so the webview stops drawing frames for it. */
  :global(body.easy) .idle { animation: none; }
  .waiting { box-shadow: 0 0 calc(var(--s) * 0.6) color-mix(in srgb, var(--amber) 55%, transparent); }
  .listen { box-shadow: 0 0 calc(var(--s) * (0.5 + var(--level) * 1.2)) color-mix(in srgb, var(--mint) 60%, transparent); }
  .listen .eye { height: calc(var(--s) * (0.22 + var(--level) * 0.06)); }
  .seen .eye:last-child { transform: translateY(-2px) !important; }
  .error { box-shadow: 0 0 calc(var(--s) * 0.6) color-mix(in srgb, var(--coral) 55%, transparent); animation: shake 0.4s ease-in-out 1; }
  .nod { animation: nod 0.7s ease-out 1; }
  .poke { animation: squash 0.35s ease-out 1; }
  .heard { animation: hop 0.6s cubic-bezier(0.3, 1.6, 0.5, 1) 1; }
  .heard .eye { height: calc(var(--s) * 0.26); }
  .hello { animation: hop 0.6s ease-out 1; }
  .wake { animation: hop 0.7s cubic-bezier(0.3, 1.8, 0.5, 1) 1; }
  .giggle { animation: wobble 1.1s ease-in-out 1; }
  @keyframes rest { 50% { transform: translateY(-1px) scale(1.01); } }
  @keyframes breathe { 50% { transform: scale(1.08); } }
  @keyframes nod { 30% { transform: translateY(3px) rotate(2deg); } 60% { transform: translateY(-1px); } }
  @keyframes squash { 30% { transform: scale(1.15, 0.82); } 65% { transform: scale(0.95, 1.06); } }
  @keyframes hop { 25% { transform: scale(1.1, 0.88); } 55% { transform: translateY(calc(var(--s) * -0.22)); } 80% { transform: translateY(0) scale(1.05, 0.95); } }
  @keyframes wobble { 15%, 45%, 75% { transform: rotate(-9deg); } 30%, 60%, 90% { transform: rotate(9deg); } }
  @keyframes shake { 25% { transform: translateX(-3px); } 50% { transform: translateX(3px); } 75% { transform: translateX(-2px); } }
  .ring { position: absolute; inset: 0; overflow: visible; }
  .piece { fill: none; stroke-width: 3; stroke-linecap: round; cursor: pointer; animation: draw 0.5s ease-out both; }
  .piece.working { stroke: color-mix(in srgb, var(--paper) 45%, transparent); }
  .piece.waiting { stroke: var(--amber); animation: draw 0.5s ease-out both, pulse 1.2s ease-in-out infinite; }
  .piece.error { stroke: var(--coral); }
  .piece.done { stroke: var(--mint); }
  .piece.hover { stroke-width: 5; }
  @keyframes draw { from { opacity: 0; } }
  .label { position: absolute; left: calc(100% + 6px); top: 50%; transform: translateY(-50%); white-space: nowrap; font-size: 11px; color: var(--text2); background: var(--notch); padding: 2px 6px; border: none; border-radius: 6px; z-index: 5; }
  .label:hover { color: var(--paper); background: var(--smoke); }
</style>
