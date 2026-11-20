<script lang="ts">
  // The Music tab's lyrics (the Mac's `MusicLyricsView`): from lrclib.net once you turned that on, synced lines follow
  // the track with the current one bright, plain ones simply list. Off, it says what would be sent and offers to turn it on.
  import Ico from "../../components/ui/Ico.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import { currentLyric, services, type Lyrics, type NowPlaying } from "../../lib/services";

  let { info, position }: { info: NowPlaying; position: number } = $props();

  type Look = { kind: "loading" } | { kind: "off" } | { kind: "none" } | { kind: "found"; lyrics: Lyrics };
  let look = $state<Look>({ kind: "loading" });
  const track = $derived(`${info.title}\u0000${info.artist}\u0000${info.album}`);

  async function load() {
    look = { kind: "loading" };
    try {
      const prefs = await services.prefs();
      if (!prefs.onlineLyrics) return void (look = { kind: "off" });
      const lyrics = await services.lyrics(info);
      look = lyrics ? { kind: "found", lyrics } : { kind: "none" };
    } catch {
      look = { kind: "none" };
    }
  }

  async function turnOn() {
    const prefs = await services.prefs();
    await services.savePrefs({ ...prefs, onlineLyrics: true });
    load();
  }

  $effect(() => {
    void track;
    load();
  });

  const found = $derived(look.kind === "found" ? look.lyrics : null);
  const active = $derived(found?.synced ? currentLyric(found.lines, position + 0.2) : -1);
  let list = $state<HTMLElement | null>(null);
  $effect(() => {
    const row = active >= 0 ? list?.children[active] : null;
    row?.scrollIntoView({ block: "center", behavior: "smooth" });
  });
</script>

<section class="lyrics" aria-label={tr("Songtekst", "Lyrics")}>
  {#if look.kind === "loading"}
    <div class="empty">
      <span class="empty-ico spin"><Ico name="loader-circle" size={20} stroke={1.8} /></span>
      <strong>{tr("Songtekst zoeken…", "Looking for lyrics…")}</strong>
    </div>
  {:else if look.kind === "off"}
    <div class="empty">
      <span class="empty-ico"><Ico name="wifi-off" size={22} stroke={1.7} /></span>
      <strong>{tr("Online songteksten staan uit", "Online lyrics are off")}</strong>
      <p>{tr("Nook kan songteksten opzoeken op lrclib.net. Alleen de titel, artiest, het album en de lengte van het nummer gaan mee.", "Nook can look up lyrics on lrclib.net. Only the title, artist, album and length of the track are sent.")}</p>
      <button class="ghost" onclick={turnOn}>{tr("Songteksten online opzoeken", "Look up lyrics online")}</button>
    </div>
  {:else if look.kind === "none"}
    <div class="empty">
      <span class="empty-ico"><Ico name="message-square-text" size={22} stroke={1.7} /></span>
      <strong>{tr("Geen songtekst gevonden", "No lyrics found")}</strong>
      <p>{tr("Nog niet elk nummer heeft een songtekst.", "Not every track has lyrics yet.")}</p>
      <button class="ghost" onclick={load}>{tr("Opnieuw zoeken", "Search again")}</button>
    </div>
  {:else if found && (found.instrumental || !found.lines.length)}
    <div class="empty">
      <span class="empty-ico"><Ico name="music" size={22} stroke={1.7} /></span>
      <strong>{tr("Instrumentaal, geen tekst", "Instrumental, no lyrics")}</strong>
    </div>
  {:else if found}
    <div class="source">{tr("Songtekst van LRCLIB", "Lyrics from LRCLIB")}{found.synced ? "" : ` · ${tr("niet gesynchroniseerd", "not synced")}`}</div>
    <ol class="lines" class:synced={found.synced} bind:this={list}>
      {#each found.lines as line, i (i)}
        <li class:now={i === active} class:past={found.synced && i < active}>
          {#if found.synced && info.canSeek && line.at !== null}
            <button class="line" onclick={() => services.seek(line.at!)}>{line.text || "♪"}</button>
          {:else}
            <span class="line-text">{line.text || (found.synced ? "♪" : "\u00a0")}</span>
          {/if}
        </li>
      {/each}
    </ol>
  {/if}
</section>

<style>
  .lyrics {
    flex: 1;
    min-height: 0;
    display: flex;
    flex-direction: column;
    padding: 0 var(--space-24) var(--space-16);
  }
  .empty {
    margin: auto;
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: var(--space-8);
    text-align: center;
    color: var(--text3);
    font: var(--text-detail);
    max-width: 46ch;
  }
  .empty-ico {
    display: grid;
    place-items: center;
    color: var(--text3);
    margin-bottom: var(--space-2);
  }
  .empty-ico.spin {
    animation: lyrics-spin 1s linear infinite;
  }
  @keyframes lyrics-spin {
    to { transform: rotate(360deg); }
  }
  .empty strong {
    color: var(--paper);
    font: var(--text-emphasis);
  }
  .empty p {
    margin: 0;
    line-height: 1.45;
  }
  .source {
    font: var(--text-caption);
    color: var(--text3);
    text-align: center;
    margin-bottom: var(--space-4);
  }
  /* Plain lyrics (`PlainLyrics`): centred body text over the stage, up to 560 px wide. */
  .lines {
    list-style: none;
    margin: 0;
    padding: var(--space-16) 0;
    overflow-y: auto;
    flex: 1;
    min-height: 0;
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: var(--space-8);
    font: var(--text-body);
    color: var(--text-strong);
    text-align: center;
    user-select: text;
  }
  .lines li {
    max-width: 560px;
    width: 100%;
    display: flex;
    justify-content: center;
  }
  /* Synced lyrics (`SyncedLyrics` + `LyricRow`): vertical fade mask, heading scale on the active line,
     past lines recessed (24%), upcoming readable (42%), and hover pill on seekable lines. */
  .lines.synced {
    gap: var(--space-12);
    font: var(--text-heading);
    padding: 80px 0 120px;
    scrollbar-width: none;
    -webkit-mask-image: linear-gradient(to bottom, transparent 0%, var(--ink) 22%, var(--ink) 70%, transparent 100%);
    mask-image: linear-gradient(to bottom, transparent 0%, var(--ink) 22%, var(--ink) 70%, transparent 100%);
  }
  .lines.synced::-webkit-scrollbar {
    display: none;
  }
  .lines.synced li {
    max-width: min(540px, 84%);
    color: color-mix(in srgb, var(--paper) 42%, transparent);
    transition: color 220ms ease, transform 220ms ease, padding 220ms ease;
  }
  .lines.synced li.past {
    color: color-mix(in srgb, var(--paper) 24%, transparent);
  }
  .lines.synced li.now {
    color: var(--paper);
    transform: scale(1.14);
    padding: var(--space-4) 0;
  }
  .line, .line-text {
    display: inline-block;
    max-width: 100%;
  }
  .lines.synced .line, .lines.synced .line-text {
    padding: var(--space-4) var(--space-16);
    border-radius: var(--radius-card);
    transition: background var(--motion-hover) ease, color var(--motion-hover) ease;
  }
  .line {
    all: unset;
    cursor: pointer;
    box-sizing: border-box;
    text-align: center;
  }
  .lines.synced li:not(.now) .line:hover {
    color: var(--text-strong);
    background: var(--row-hover);
  }
  .line:focus-visible {
    outline: 2px solid var(--music);
    border-radius: var(--radius-card);
  }
  @media (prefers-reduced-motion: reduce) {
    .lines.synced li, .empty-ico.spin {
      transition: none;
      animation: none;
    }
  }
</style>
