<script lang="ts">
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
    <div class="art" class:empty={!info.artwork}>
      {#if info.artwork}<img src={info.artwork} alt="" />{/if}
      <div class="eq" class:playing={info.playing}><span></span><span></span><span></span></div>
    </div>
    <div class="side">
      <div class="title">{info.title || "Onbekend nummer"}</div>
      <div class="sub muted">{info.artist ? `${info.artist} · ${info.app}` : info.app}</div>
      <div class="scrub">
        <span class="time">{clock(position)}</span>
        <!-- svelte-ignore a11y_no_static_element_interactions -->
        <div
          class="bar"
          class:seekable={info.canSeek && duration > 0}
          title="Voortgang"
          onpointerdown={(e) => { (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId); scrub(e, e.currentTarget as HTMLElement); }}
          onpointermove={(e) => drag !== null && scrub(e, e.currentTarget as HTMLElement)}
          onpointerup={(e) => drag !== null && scrub(e, e.currentTarget as HTMLElement, true)}
        >
          <div class="fill" style="width:{fraction * 100}%"></div>
        </div>
        <span class="time right">{duration > 0 ? `-${clock(duration - position)}` : "–:––"}</span>
      </div>
      <div class="controls">
        {#if info.shuffle !== null}
          <button class="toggle" class:on={info.shuffle} title="Willekeurig" aria-label="Willekeurig" onclick={() => run(() => services.shuffle(!info.shuffle))}>⤮</button>
        {/if}
        <button class="round" title="Vorige" aria-label="Vorige" onclick={() => run(() => services.media("previous"))}>⏮</button>
        <button class="round big" title={info.playing ? "Pauze" : "Afspelen"} aria-label={info.playing ? "Pauze" : "Afspelen"} onclick={() => run(() => services.media("playPause"))}>{info.playing ? "⏸" : "▶"}</button>
        <button class="round" title="Volgende" aria-label="Volgende" onclick={() => run(() => services.media("next"))}>⏭</button>
        {#if info.repeat !== null}
          <button class="toggle" class:on={info.repeat} title="Herhalen" aria-label="Herhalen" onclick={() => run(() => services.repeat(!info.repeat))}>⟳</button>
        {/if}
        <span class="spacer"></span>
        {#if volume !== null}
          <button class="toggle" title={volume > 0 ? "Dempen" : "Geluid aan"} aria-label={volume > 0 ? "Dempen" : "Geluid aan"} onclick={mute}>{volume === 0 ? "🔇" : volume < 40 ? "🔈" : "🔊"}</button>
          <input class="volume" type="range" min="0" max="100" value={volume} aria-label="Volume" oninput={setVolume} onchange={commitVolume} />
        {/if}
      </div>
      {#if error}<div class="err">{error}</div>{/if}
    </div>
  </div>
{:else}
  <div class="idle">
    <h3>Er speelt nu niets</h3>
    <p class="muted">Start een nummer in Spotify, je browser of een andere speler, dan zie je het hier.</p>
  </div>
{/if}

<style>
  .music { display: flex; gap: 20px; align-items: center; padding: 22px 24px; height: 100%; }
  .art { width: 132px; height: 132px; border-radius: 14px; background: #ff8a5b; position: relative; overflow: hidden; flex: none; border: 1px solid rgba(255, 255, 255, 0.06); }
  .art img { width: 100%; height: 100%; object-fit: cover; }
  .eq { position: absolute; left: 12px; bottom: 12px; display: flex; gap: 3px; align-items: flex-end; height: 16px; }
  .eq span { width: 3px; height: 5px; background: var(--paper); border-radius: 2px; }
  .art.empty .eq span { background: var(--ink); }
  .eq.playing span { animation: eq 0.9s ease-in-out infinite; }
  .eq.playing span:nth-child(2) { animation-delay: 0.2s; }
  .eq.playing span:nth-child(3) { animation-delay: 0.4s; }
  @keyframes eq { 50% { height: 16px; } }
  .side { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 8px; }
  .title { font-size: 17px; font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .sub { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .scrub { display: flex; align-items: center; gap: 10px; font-family: var(--mono); font-size: 11px; color: var(--text3); }
  .time { width: 40px; }
  .time.right { text-align: right; width: 44px; }
  .bar { flex: 1; height: 16px; display: flex; align-items: center; position: relative; touch-action: none; }
  .bar::before { content: ""; position: absolute; left: 0; right: 0; height: 3px; border-radius: 3px; background: var(--line2); }
  .fill { position: relative; height: 3px; border-radius: 3px; background: var(--paper); }
  .bar.seekable { cursor: pointer; }
  .bar.seekable:hover::before, .bar.seekable:hover .fill { height: 5px; }
  .bar.seekable:hover .fill { background: #ff8a5b; }
  .controls { display: flex; align-items: center; gap: 4px; }
  .spacer { flex: 1; }
  .round { width: 32px; height: 32px; padding: 0; border-radius: 50%; background: transparent; border: none; font-size: 14px; }
  .round.big { width: 38px; height: 38px; background: var(--paper); color: var(--ink); font-size: 15px; }
  .round.big:hover { background: #fff; }
  .toggle { width: 30px; height: 30px; padding: 0; border-radius: 50%; background: transparent; border: none; color: var(--text3); font-size: 14px; position: relative; }
  .toggle:hover { color: var(--paper); background: var(--smoke); }
  .toggle.on { color: #ff8a5b; }
  .toggle.on::after { content: ""; position: absolute; bottom: 3px; left: 50%; width: 4px; height: 4px; margin-left: -2px; border-radius: 50%; background: #ff8a5b; }
  .volume { width: 90px; padding: 0; accent-color: var(--paper); background: transparent; border: none; }
  .idle { padding: 24px; }
  .idle h3 { margin: 0 0 6px; font-size: 17px; }
  .err { color: var(--coral); font-size: 12px; }
</style>
