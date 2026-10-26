<script lang="ts">
  import { tr } from "../../lib/i18n.svelte";
  // De Muziek-tab: wat er nu speelt, met hoes, doorspoelen, shuffle, herhalen en volume (MusicTab op de Mac).
  import { services, clock, estimatedPosition, type NowPlaying } from "../../lib/services";

  let { info, since }: { info: NowPlaying | null; since: number } = $props();
  let now = $state(Date.now());
  let drag = $state<number | null>(null);
  let volumeDrag = $state<number | null>(null);
  let beforeMute = 50;
  let error = $state<string | null>(null);

  $effect(() => {
    const timer = setInterval(() => (now = Date.now()), 500);
    return () => clearInterval(timer);
  });

  const duration = $derived(info?.duration ?? 0);
  const position = $derived(info ? (drag !== null ? drag * duration : estimatedPosition(info, since, now)) : 0);
  const fraction = $derived(duration > 0 ? Math.min(1, Math.max(0, position / duration)) : 0);
  const volume = $derived(volumeDrag ?? info?.volume ?? null);

  async function run(f: () => Promise<void>) {
    error = null;
    try {
      await f();
    } catch (e) {
      error = String(e);
    }
  }

  function scrub(e: PointerEvent, bar: HTMLElement, done = false) {
    if (!info?.canSeek || !duration) return;
    const r = bar.getBoundingClientRect();
    const f = Math.min(1, Math.max(0, (e.clientX - r.left) / r.width));
    if (done) {
      drag = null;
      run(() => services.seek(f * duration));
    } else {
      drag = f;
    }
  }

  function seekKey(e: KeyboardEvent) {
    if (!info?.canSeek || !duration) return;
    const step = e.key === "ArrowRight" ? 5 : e.key === "ArrowLeft" ? -5 : 0;
    if (!step) return;
    e.preventDefault();
    run(() => services.seek(Math.min(duration, Math.max(0, position + step))));
  }

  function setVolume(e: Event) {
    volumeDrag = Number((e.currentTarget as HTMLInputElement).value);
  }

  function commitVolume() {
    if (volumeDrag === null) return;
    const v = volumeDrag;
    run(() => services.volume(v));
    setTimeout(() => (volumeDrag = null), 2500);
  }

  function mute() {
    if (volume === null) return;
    const target = volume > 0 ? 0 : beforeMute || 50;
    if (volume > 0) beforeMute = volume;
    volumeDrag = target;
    run(() => services.volume(target));
    setTimeout(() => (volumeDrag = null), 2500);
  }
</script>

{#if info}
  <div class="music">
    {#if info.artwork}<div class="glow" style="background-image:url({info.artwork})"></div>{/if}
    <div class="art" class:empty={!info.artwork} class:playing={info.playing}>
      {#if info.artwork}<img src={info.artwork} alt="" />{:else}<span class="note">♪</span>{/if}
      <div class="eq" class:playing={info.playing}><span></span><span></span><span></span></div>
    </div>
    <div class="side">
      <div class="title">{info.title || tr("Onbekend nummer", "Unknown track")}</div>
      <div class="sub muted">{info.artist ? `${info.artist} · ${info.app}` : info.app}</div>
      <div class="scrub">
        <span class="time">{clock(position)}</span>
        <!-- svelte-ignore a11y_no_static_element_interactions -->
        <div
          class="bar"
          class:seekable={info.canSeek && duration > 0}
          title={tr("Voortgang", "Progress")}
          role="slider"
          tabindex={info.canSeek && duration > 0 ? 0 : -1}
          aria-label={tr("Voortgang", "Progress")}
          aria-valuemin="0"
          aria-valuemax={Math.round(duration)}
          aria-valuenow={Math.round(position)}
          onkeydown={seekKey}
          onpointerdown={(e) => { (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId); scrub(e, e.currentTarget as HTMLElement); }}
          onpointermove={(e) => drag !== null && scrub(e, e.currentTarget as HTMLElement)}
          onpointerup={(e) => drag !== null && scrub(e, e.currentTarget as HTMLElement, true)}
        >
          <div class="fill" style="width:{fraction * 100}%"><span class="knob"></span></div>
        </div>
        <span class="time right">{duration > 0 ? `-${clock(duration - position)}` : "–:––"}</span>
      </div>
      <div class="controls">
        {#if info.shuffle !== null}
          <button class="toggle" class:on={info.shuffle} title={tr("Willekeurig", "Shuffle")} aria-label={tr("Willekeurig", "Shuffle")} onclick={() => run(() => services.shuffle(!info.shuffle))}>⤮</button>
        {/if}
        <button class="round" title={tr("Vorige", "Previous")} aria-label={tr("Vorige", "Previous")} onclick={() => run(() => services.media("previous"))}>⏮</button>
        <button class="round big" title={info.playing ? tr("Pauze", "Pause") : tr("Afspelen", "Play")} aria-label={info.playing ? tr("Pauze", "Pause") : tr("Afspelen", "Play")} onclick={() => run(() => services.media("playPause"))}>{info.playing ? "⏸" : "▶"}</button>
        <button class="round" title={tr("Volgende", "Next")} aria-label={tr("Volgende", "Next")} onclick={() => run(() => services.media("next"))}>⏭</button>
        {#if info.repeat !== null}
          <button class="toggle" class:on={info.repeat} title={tr("Herhalen", "Repeat")} aria-label={tr("Herhalen", "Repeat")} onclick={() => run(() => services.repeat(!info.repeat))}>⟳</button>
        {/if}
        <span class="spacer"></span>
        {#if volume !== null}
          <button class="toggle" title={volume > 0 ? tr("Dempen", "Mute") : tr("Geluid aan", "Unmute")} aria-label={volume > 0 ? tr("Dempen", "Mute") : tr("Geluid aan", "Unmute")} onclick={mute}>{volume === 0 ? "🔇" : volume < 40 ? "🔈" : "🔊"}</button>
          <input class="volume" type="range" min="0" max="100" value={volume} aria-label="Volume" oninput={setVolume} onchange={commitVolume} />
        {/if}
      </div>
      {#if error}<div class="err">{error}</div>{/if}
    </div>
  </div>
{:else}
  <div class="idle">
    <div class="idle-note">♪</div>
    <h3>{tr("Er speelt nu niets", "Nothing is playing")}</h3>
    <p class="muted">{tr("Start een nummer in Spotify, je browser of een andere speler, dan zie je het hier.", "Start a track in Spotify, your browser or another player and you will see it here.")}</p>
  </div>
{/if}

<style>
  .music { --accent: #ff8a5b; display: flex; gap: 24px; align-items: center; padding: 24px 28px; height: 100%; position: relative; overflow: hidden; }
  .glow { position: absolute; inset: -40px; background-size: cover; background-position: center; filter: blur(48px) saturate(1.4); opacity: 0.28; pointer-events: none; }
  .music > :not(.glow) { position: relative; }
  .art { width: 148px; height: 148px; border-radius: 16px; background: var(--accent); overflow: hidden; flex: none; border: 1px solid rgba(255, 255, 255, 0.08); box-shadow: 0 10px 28px rgba(0, 0, 0, 0.45); transition: transform 240ms ease; }
  .art.playing { transform: scale(1.02); }
  .note { position: absolute; inset: 0; display: grid; place-items: center; font-size: 56px; color: var(--ink); opacity: 0.75; }
  .art img { width: 100%; height: 100%; object-fit: cover; }
  .eq { position: absolute; left: 12px; bottom: 12px; padding: 5px 6px; border-radius: 8px; background: rgba(0, 0, 0, 0.35); backdrop-filter: blur(6px); display: flex; gap: 3px; align-items: flex-end; height: 16px; }
  .eq span { width: 3px; height: 5px; background: #fff; border-radius: 2px; }
  .art.empty .eq span { background: var(--ink); }
  .eq.playing span { animation: eq 0.9s ease-in-out infinite; }
  .eq.playing span:nth-child(2) { animation-delay: 0.2s; }
  .eq.playing span:nth-child(3) { animation-delay: 0.4s; }
  @keyframes eq { 50% { height: 16px; } }
  .side { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 8px; }
  .title { font-size: 20px; font-weight: 650; letter-spacing: -0.01em; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; user-select: text; }
  .sub { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; user-select: text; margin-bottom: 4px; }
  .scrub { display: flex; align-items: center; gap: 10px; font-family: var(--mono); font-size: 11px; color: var(--text3); }
  .time { width: 40px; }
  .time.right { text-align: right; width: 44px; }
  .bar { flex: 1; height: 20px; outline: none; display: flex; align-items: center; position: relative; touch-action: none; }
  .bar::before { content: ""; position: absolute; left: 0; right: 0; height: 3px; border-radius: 3px; background: var(--line2); }
  .fill { position: relative; height: 3px; border-radius: 3px; background: var(--paper); }
  .knob { position: absolute; right: -6px; top: 50%; width: 12px; height: 12px; margin-top: -6px; border-radius: 50%; background: #fff; box-shadow: 0 1px 4px rgba(0, 0, 0, 0.5); opacity: 0; transform: scale(0.6); transition: opacity 120ms ease, transform 120ms ease; }
  .bar.seekable:hover .knob, .bar.seekable:focus-visible .knob { opacity: 1; transform: scale(1); }
  .bar:focus-visible::before { box-shadow: 0 0 0 2px color-mix(in srgb, var(--accent) 60%, transparent); }
  .bar.seekable { cursor: pointer; }
  .bar.seekable:hover::before, .bar.seekable:hover .fill { height: 5px; }
  .bar.seekable:hover .fill, .bar.seekable:focus-visible .fill { background: var(--accent); }
  .controls { display: flex; align-items: center; gap: 6px; }
  .spacer { flex: 1; }
  .round { width: 32px; height: 32px; padding: 0; border-radius: 50%; background: transparent; border: none; font-size: 14px; }
  .round { transition: transform 120ms ease, background 120ms ease; }
  .round:hover:not(.big) { background: var(--smoke); }
  .round:active { transform: scale(0.92); }
  .round.big { width: 42px; height: 42px; background: var(--paper); color: var(--ink); font-size: 16px; box-shadow: 0 4px 14px rgba(0, 0, 0, 0.35); }
  .round.big:hover { background: #fff; }
  .toggle { width: 30px; height: 30px; padding: 0; border-radius: 50%; background: transparent; border: none; color: var(--text3); font-size: 14px; position: relative; }
  .toggle:hover { color: var(--paper); background: var(--smoke); }
  .toggle.on { color: var(--accent); }
  .toggle.on::after { content: ""; position: absolute; bottom: 3px; left: 50%; width: 4px; height: 4px; margin-left: -2px; border-radius: 50%; background: var(--accent); }
  .volume { width: 96px; padding: 0; accent-color: var(--accent); background: transparent; border: none; cursor: pointer; }
  .idle { padding: 32px 28px; display: flex; flex-direction: column; align-items: flex-start; gap: 4px; user-select: text; }
  .idle-note { width: 56px; height: 56px; display: grid; place-items: center; border-radius: 16px; background: var(--smoke); border: 1px solid var(--line2); font-size: 26px; color: var(--accent, #ff8a5b); margin-bottom: 10px; user-select: none; }
  .idle h3 { margin: 0; font-size: 18px; }
  .idle p { margin: 0; max-width: 46ch; line-height: 1.45; }
  .err { color: var(--coral); font-size: 12px; }
</style>
