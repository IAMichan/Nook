<script lang="ts">
  import { tr } from "../../lib/i18n.svelte";
  import { services, clock, estimatedPosition, type NowPlaying } from "../../lib/services";
  import { invoke } from "@tauri-apps/api/core";
  import { listen } from "@tauri-apps/api/event";
  import MusicLyrics from "./MusicLyrics.svelte";

  let { info, since }: { info: NowPlaying | null; since: number } = $props();

  type LoadState =
    | { kind: "idle" }
    | { kind: "done" }
    | { kind: "connectSpotify" }
    | { kind: "reconnectSpotify" }
    | { kind: "failed"; message: string };

  type MusicTrack = {
    id: string;
    title: string;
    artist: string;
    duration: number;
    artworkUrl: string | null;
    album: string;
  };

  type MusicAlbum = {
    id: string;
    name: string;
    artist: string;
    artworkUrl: string | null;
    releaseYear: string;
    totalTracks: number;
  };

  type MusicPlaylist = {
    id: string;
    name: string;
    trackCount: number;
    artworkUrl: string | null;
    editable: boolean;
    owner: string;
  };

  type MusicArtist = {
    name: string;
    plays: number | null;
    artworkUrl: string | null;
  };

  type QueueEntry = {
    id: string;
    track: MusicTrack;
  };

  type OutputKind =
    | "speaker"
    | "headphones"
    | "bluetooth"
    | "display"
    | "phone"
    | "computer"
    | "tv"
    | "car"
    | "other";

  type MusicOutput = {
    id: string;
    name: string;
    kind: OutputKind;
    active: boolean;
    volume: number | null;
  };

  type MusicOverviewView = {
    spotifyConnected: boolean;
    spotifyClientId: string;
    spotifyRedirectUri: string;
    spotifyUser: string | null;
    spotifyPendingUrl: string | null;
    nowPlaying: NowPlaying | null;
    recent: MusicTrack[];
    searches: string[];
    nookQueue: QueueEntry[];
    spotifyQueue: MusicTrack[];
    playlists: MusicPlaylist[];
    outputs: MusicOutput[];
    streak: number;
    weekSeconds: number;
    weekPlays: number;
  };

  type SpotifySearchCatalog = {
    query: string;
    state: LoadState;
    tracks: MusicTrack[];
    albums: MusicAlbum[];
    playlists: MusicPlaylist[];
  };

  type MusicQueueView = {
    state: LoadState;
    nookQueue: QueueEntry[];
    spotifyQueue: MusicTrack[];
  };

  type MusicPlaylistsView = {
    state: LoadState;
    playlists: MusicPlaylist[];
    selectedId: string | null;
    tracks: MusicTrack[];
  };

  type TrackRank = {
    track: MusicTrack;
    plays: number;
    seconds: number;
  };

  type ArtistRank = {
    name: string;
    plays: number;
    seconds: number;
    artworkUrl: string | null;
  };

  type MusicLibraryView = {
    state: LoadState;
    timeRange: string;
    playerStats: {
      app: string;
      tracks: MusicTrack[];
      artists: MusicArtist[];
    };
    recent: MusicTrack[];
    localTopTracks: TrackRank[];
    localTopArtists: ArtistRank[];
  };

  type Bucket = {
    start: string;
    seconds: number;
  };

  type StatsPeriod = "week" | "month" | "year" | "all";
  type ListenerType = "morning" | "afternoon" | "evening" | "night";

  type MusicStats = {
    period: StatsPeriod;
    seconds: number;
    plays: number;
    uniqueTracks: number;
    uniqueArtists: number;
    previousSeconds: number | null;
    buckets: Bucket[];
    hours: number[];
    weekHours: number[][];
    newArtists: number | null;
    topTracks: TrackRank[];
    topArtists: ArtistRank[];
    streak: number;
    bestDay: Bucket | null;
    peakHour: number | null;
    listenerType: ListenerType | null;
  };

  type MusicHistoryStatsView = {
    stats: MusicStats;
    changePercent: number | null;
    totalPlays: number;
    recent: MusicTrack[];
    searches: string[];
  };

  type SpotifyConnectStatus = {
    connected: boolean;
    clientId: string;
    redirectUri: string;
    authorizeUrl: string | null;
    userId: string | null;
    displayName: string | null;
  };

  type Section = "now" | "search" | "playlists" | "library" | "stats";

  let section = $state<Section>("now");
  let now = $state(Date.now());
  let drag = $state<number | null>(null);
  let volumeDrag = $state<number | null>(null);
  let beforeMute = 50;
  let error = $state<string | null>(null);

  let overview = $state<MusicOverviewView | null>(null);
  let searchQuery = $state("");
  let searchCatalog = $state<SpotifySearchCatalog | null>(null);
  let searching = $state(false);

  let playlistsView = $state<MusicPlaylistsView | null>(null);
  let newPlaylistName = $state("");
  let renamePlaylistName = $state("");
  let renamingPlaylistId = $state<string | null>(null);
  let playlistTargetTrack = $state<MusicTrack | null>(null);

  let libraryView = $state<MusicLibraryView | null>(null);
  let libraryRange = $state<"short_term" | "medium_term" | "long_term">("medium_term");

  let historyView = $state<MusicHistoryStatsView | null>(null);
  let statsPeriod = $state<StatsPeriod>("week");

  let showOutputs = $state(false);
  let showSpotifySetup = $state(false);
  let clientIdInput = $state("");
  let redirectUriInput = $state("http://127.0.0.1:43821/spotify/callback");
  let callbackCodeInput = $state("");
  let pendingAuthorizeUrl = $state<string | null>(null);

  const activeInfo = $derived(info ?? overview?.nowPlaying ?? null);
  const duration = $derived(activeInfo?.duration ?? 0);
  const position = $derived(activeInfo ? (drag !== null ? drag * duration : estimatedPosition(activeInfo, since, now)) : 0);
  const fraction = $derived(duration > 0 ? Math.min(1, Math.max(0, position / duration)) : 0);
  const volume = $derived(volumeDrag ?? activeInfo?.volume ?? null);
  const activeOutput = $derived(overview?.outputs.find((o) => o.active) ?? overview?.outputs[0] ?? null);

  async function refreshOverview() {
    try {
      const ov = await invoke<MusicOverviewView>("music_overview");
      overview = ov;
      if (!clientIdInput && ov.spotifyClientId) clientIdInput = ov.spotifyClientId;
      if (ov.spotifyRedirectUri) redirectUriInput = ov.spotifyRedirectUri;
      if (ov.spotifyPendingUrl) pendingAuthorizeUrl = ov.spotifyPendingUrl;
    } catch (e) {
      error = String(e);
    }
  }

  $effect(() => {
    refreshOverview();
    const tick = setInterval(() => (now = Date.now()), 500);
    const poll = setInterval(() => refreshOverview(), 6000);
    let unlisten: (() => void) | null = null;
    listen("music-spotify-connected", () => {
      showSpotifySetup = false;
      pendingAuthorizeUrl = null;
      callbackCodeInput = "";
      refreshOverview();
    })
      .then((fn) => (unlisten = fn))
      .catch(() => {});
    return () => {
      clearInterval(tick);
      clearInterval(poll);
      unlisten?.();
    };
  });

  async function run(f: () => Promise<void>) {
    error = null;
    try {
      await f();
    } catch (e) {
      error = String(e);
    }
  }

  async function openSection(next: Section) {
    section = next;
    if (next === "playlists") {
      await loadPlaylists(playlistsView?.selectedId ?? null);
    } else if (next === "library") {
      await loadLibrary(libraryRange);
    } else if (next === "stats") {
      await loadStats(statsPeriod);
    } else if (next === "now") {
      await refreshOverview();
    }
  }

  async function submitSearch(q = searchQuery) {
    const clean = q.trim();
    searchQuery = clean;
    if (!clean) return;
    section = "search";
    searching = true;
    try {
      searchCatalog = await invoke<SpotifySearchCatalog>("music_search", { query: clean, remember: true });
      await refreshOverview();
    } catch (e) {
      error = String(e);
    } finally {
      searching = false;
    }
  }

  async function forgetSearch(q: string) {
    try {
      await invoke<SpotifySearchCatalog>("music_search", { query: "", remember: false, forget: q });
      await refreshOverview();
    } catch (e) {
      error = String(e);
    }
  }

  async function playTrack(track: MusicTrack, contextUri?: string) {
    await run(async () => {
      const qv = await invoke<MusicQueueView>("music_queue_add", {
        track,
        playNow: true,
        contextUri: contextUri ?? null,
      });
      if (overview) {
        overview.nookQueue = qv.nookQueue;
        overview.spotifyQueue = qv.spotifyQueue;
      }
      await refreshOverview();
    });
  }

  async function playContextUri(uri: string) {
    const dummy: MusicTrack = { id: uri, title: "", artist: "", duration: 0, artworkUrl: null, album: "" };
    await playTrack(dummy, uri);
  }

  async function queueTrack(track: MusicTrack) {
    await run(async () => {
      const qv = await invoke<MusicQueueView>("music_queue_add", {
        track,
        playNow: false,
      });
      if (overview) {
        overview.nookQueue = qv.nookQueue;
        overview.spotifyQueue = qv.spotifyQueue;
      }
    });
  }

  async function removeQueueEntry(id: string) {
    await run(async () => {
      const qv = await invoke<MusicQueueView>("music_queue", { removeId: id });
      if (overview) {
        overview.nookQueue = qv.nookQueue;
        overview.spotifyQueue = qv.spotifyQueue;
      }
    });
  }

  async function playQueueEntry(id: string) {
    await run(async () => {
      const qv = await invoke<MusicQueueView>("music_queue", { playEntryId: id });
      if (overview) {
        overview.nookQueue = qv.nookQueue;
        overview.spotifyQueue = qv.spotifyQueue;
      }
      await refreshOverview();
    });
  }

  async function clearNookQueue() {
    await run(async () => {
      const qv = await invoke<MusicQueueView>("music_queue", { clear: true });
      if (overview) {
        overview.nookQueue = qv.nookQueue;
        overview.spotifyQueue = qv.spotifyQueue;
      }
    });
  }

  async function loadPlaylists(playlistId: string | null = null) {
    await run(async () => {
      playlistsView = await invoke<MusicPlaylistsView>("music_playlists", { playlistId });
    });
  }

  async function createPlaylist() {
    const name = newPlaylistName.trim();
    if (!name) return;
    await run(async () => {
      const created = await invoke<MusicPlaylist>("music_playlist_create", { name, public: false });
      newPlaylistName = "";
      await loadPlaylists(created.id);
      await refreshOverview();
    });
  }

  async function modifyPlaylist(playlistId: string, action: "rename" | "delete" | "add_track" | "remove_track" | "play", extra?: { name?: string; trackUri?: string }) {
    await run(async () => {
      playlistsView = await invoke<MusicPlaylistsView>("music_playlist_modify", {
        playlistId,
        action,
        name: extra?.name ?? null,
        trackUri: extra?.trackUri ?? null,
      });
      renamingPlaylistId = null;
      playlistTargetTrack = null;
      await refreshOverview();
    });
  }

  async function loadLibrary(range: "short_term" | "medium_term" | "long_term") {
    libraryRange = range;
    await run(async () => {
      libraryView = await invoke<MusicLibraryView>("music_library", { timeRange: range });
    });
  }

  async function loadStats(period: StatsPeriod, clear = false) {
    statsPeriod = period;
    await run(async () => {
      historyView = await invoke<MusicHistoryStatsView>("music_history_stats", { period, clear });
      if (clear) await refreshOverview();
    });
  }

  async function selectOutput(deviceId: string) {
    await run(async () => {
      const outs = await invoke<MusicOutput[]>("music_select_output", { deviceId, play: true });
      if (overview) overview.outputs = outs;
      showOutputs = false;
    });
  }

  async function startSpotifyConnect() {
    await run(async () => {
      const res = await invoke<SpotifyConnectStatus>("music_spotify_connect", {
        clientId: clientIdInput.trim() || null,
        redirectUri: redirectUriInput.trim() || null,
        callbackCode: null,
      });
      pendingAuthorizeUrl = res.authorizeUrl;
      await refreshOverview();
    });
  }

  async function finishSpotifyConnectWithCode() {
    if (!callbackCodeInput.trim()) return;
    await run(async () => {
      await invoke<SpotifyConnectStatus>("music_spotify_connect", {
        clientId: clientIdInput.trim() || null,
        redirectUri: redirectUriInput.trim() || null,
        callbackCode: callbackCodeInput.trim(),
      });
      callbackCodeInput = "";
      pendingAuthorizeUrl = null;
      showSpotifySetup = false;
      await refreshOverview();
    });
  }

  async function disconnectSpotify() {
    await run(async () => {
      await invoke<SpotifyConnectStatus>("music_spotify_disconnect");
      pendingAuthorizeUrl = null;
      showSpotifySetup = false;
      await refreshOverview();
    });
  }

  function scrub(e: PointerEvent, bar: HTMLElement, done = false) {
    if (!activeInfo?.canSeek || !duration) return;
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
    if (!activeInfo?.canSeek || !duration) return;
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

  function formatHoursMinutes(seconds: number): string {
    const mins = Math.round(seconds / 60);
    if (mins < 60) return tr("{n} min", "{n} min", { n: mins });
    const h = Math.floor(mins / 60);
    const m = mins % 60;
    return m > 0 ? tr("{h} u {m} min", "{h}h {m}m", { h, m }) : tr("{h} uur", "{h}h", { h });
  }

  function listenerTypeLabel(kind: ListenerType | null): string {
    switch (kind) {
      case "morning":
        return tr("Ochtendluisteraar", "Morning listener");
      case "afternoon":
        return tr("Middagluisteraar", "Afternoon listener");
      case "evening":
        return tr("Avondluisteraar", "Evening listener");
      case "night":
        return tr("Nachtluisteraar", "Night listener");
      default:
        return tr("Muziekliefhebber", "Music listener");
    }
  }

  function outputIcon(kind: OutputKind): string {
    switch (kind) {
      case "headphones":
        return "🎧";
      case "phone":
        return "📱";
      case "tv":
      case "display":
        return "🖥";
      case "car":
        return "🚗";
      case "speaker":
      case "bluetooth":
        return "🔊";
      default:
        return "💻";
    }
  }
</script>

<div class="stage">
  <!-- Top navigation, search bar, output picker & Spotify PKCE badge (SV-30..SV-38) -->
  <header class="topbar">
    <nav class="tabs" aria-label={tr("Muziekonderdelen", "Music sections")}>
      <button class="tab" class:active={section === "now"} onclick={() => openSection("now")}>
        {tr("Nu & wachtrij", "Now & Queue")}
      </button>
      <button class="tab" class:active={section === "search"} onclick={() => openSection("search")}>
        {tr("Zoeken", "Search")}
      </button>
      <button class="tab" class:active={section === "playlists"} onclick={() => openSection("playlists")}>
        {tr("Afspeellijsten", "Playlists")}
      </button>
      <button class="tab" class:active={section === "library"} onclick={() => openSection("library")}>
        {tr("Bibliotheek", "Library")}
      </button>
      <button class="tab" class:active={section === "stats"} onclick={() => openSection("stats")}>
        {tr("Statistieken", "Stats")}
        {#if (overview?.streak ?? 0) > 0}
          <span class="streak-pill">{overview?.streak}d</span>
        {/if}
      </button>
    </nav>

    <form
      class="searchbox"
      onsubmit={(e) => {
        e.preventDefault();
        submitSearch();
      }}
    >
      <input
        type="search"
        placeholder={tr("Zoek nummers, albums, afspeellijsten…", "Search tracks, albums, playlists…")}
        bind:value={searchQuery}
      />
      {#if searchQuery}
        <button type="button" class="ghost small" onclick={() => (searchQuery = "")}>×</button>
      {/if}
    </form>

    <div class="top-actions">
      <div class="popover-anchor">
        <button
          class="capsule"
          title={tr("Kies waar de muziek klinkt", "Choose where music plays")}
          onclick={() => (showOutputs = !showOutputs)}
        >
          <span>{activeOutput ? outputIcon(activeOutput.kind) : "🔊"}</span>
          <span>{activeOutput?.name ?? tr("Speelt op", "Plays on")}</span>
        </button>
        {#if showOutputs}
          <div class="popover">
            <div class="popover-head">
              <strong>{tr("Speelt op", "Plays on")}</strong>
              <button class="ghost small" onclick={() => invoke<MusicOutput[]>("music_outputs").then((o) => { if (overview) overview.outputs = o; })}>
                ↻
              </button>
            </div>
            {#each overview?.outputs ?? [] as out (out.id)}
              <button class="output-row" class:active={out.active} onclick={() => selectOutput(out.id)}>
                <span>{outputIcon(out.kind)}</span>
                <span class="output-name">{out.name}</span>
                {#if out.volume !== null}
                  <small class="faint">{out.volume}%</small>
                {/if}
                {#if out.active}
                  <span class="active-dot">●</span>
                {/if}
              </button>
            {/each}
          </div>
        {/if}
      </div>

      <button
        class="capsule"
        class:connected={overview?.spotifyConnected}
        onclick={() => (showSpotifySetup = !showSpotifySetup)}
      >
        {#if overview?.spotifyConnected}
          <span>●</span>
          <span>{overview.spotifyUser ? `Spotify (${overview.spotifyUser})` : "Spotify"}</span>
        {:else}
          <span>{tr("Koppel Spotify", "Connect Spotify")}</span>
        {/if}
      </button>
    </div>
  </header>

  {#if showSpotifySetup}
    <section class="spotify-card">
      <div class="card-head">
        <div>
          <h4>{tr("Spotify Web API (PKCE)", "Spotify Web API (PKCE)")}</h4>
          <p class="faint">
            {tr(
              "Koppel je eigen Spotify Client ID om te zoeken, je wachtrij en afspeellijsten te beheren en op Spotify Connect-apparaten af te spelen.",
              "Connect your Spotify Client ID to search the catalog, manage your queue and playlists, and switch Spotify Connect outputs."
            )}
          </p>
        </div>
        <button class="ghost small" onclick={() => (showSpotifySetup = false)}>×</button>
      </div>
      {#if overview?.spotifyConnected}
        <div class="spotify-row">
          <span>
            {tr("Verbonden met Spotify", "Connected to Spotify")}
            {#if overview.spotifyUser}· <strong>{overview.spotifyUser}</strong>{/if}
          </span>
          <button class="danger small" onclick={disconnectSpotify}>{tr("Ontkoppelen", "Disconnect")}</button>
        </div>
      {:else}
        <div class="spotify-grid">
          <label class="field-col">
            <span>{tr("Spotify Client ID", "Spotify Client ID")}</span>
            <input placeholder="e.g. 8a9b0c1d2e3f4g5h6i7j8k9l0m1n2o3p" bind:value={clientIdInput} />
          </label>
          <label class="field-col">
            <span>{tr("Redirect URI (zet deze in je Spotify Developer Dashboard)", "Redirect URI (add this in your Spotify Developer Dashboard)")}</span>
            <div class="copy-row">
              <input readonly value={redirectUriInput} />
              <button class="ghost small" onclick={() => navigator.clipboard.writeText(redirectUriInput)}>
                {tr("Kopiëren", "Copy")}
              </button>
            </div>
          </label>
        </div>
        <div class="spotify-row">
          <button class="primary" onclick={startSpotifyConnect}>
            {tr("Inloggen bij Spotify (PKCE)", "Sign in with Spotify (PKCE)")}
          </button>
          {#if pendingAuthorizeUrl}
            <button class="ghost small" onclick={() => navigator.clipboard.writeText(pendingAuthorizeUrl!)}>
              {tr("Kopieer inloglink", "Copy sign-in URL")}
            </button>
          {/if}
        </div>
        {#if pendingAuthorizeUrl}
          <div class="spotify-row">
            <input
              placeholder={tr("Of plak hier de callback-URL / code na het inloggen…", "Or paste the callback URL / code here after signing in…")}
              bind:value={callbackCodeInput}
            />
            <button class="capsule" onclick={finishSpotifyConnectWithCode}>
              {tr("Voltooien", "Complete")}
            </button>
          </div>
        {/if}
      {/if}
    </section>
  {/if}

  {#if playlistTargetTrack}
    <section class="spotify-card">
      <div class="card-head">
        <strong>
          {tr("Voeg \"{title}\" toe aan afspeellijst", "Add \"{title}\" to playlist", { title: playlistTargetTrack.title })}
        </strong>
        <button class="ghost small" onclick={() => (playlistTargetTrack = null)}>×</button>
      </div>
      <div class="chip-row">
        {#each (overview?.playlists ?? []).filter((p) => p.editable) as pl (pl.id)}
          <button
            class="capsule"
            onclick={() => modifyPlaylist(pl.id, "add_track", { trackUri: playlistTargetTrack!.id })}
          >
            + {pl.name}
          </button>
        {:else}
          <span class="faint">{tr("Geen bewerkbare afspeellijsten gevonden.", "No editable playlists found.")}</span>
        {/each}
      </div>
    </section>
  {/if}

  <!-- Hero Transport Player -->
  {#if activeInfo}
    <div class="music">
      {#if activeInfo.artwork}<div class="glow" style="background-image:url({activeInfo.artwork})"></div>{/if}
      <div class="art" class:empty={!activeInfo.artwork} class:playing={activeInfo.playing}>
        {#if activeInfo.artwork}<img src={activeInfo.artwork} alt="" />{:else}<span class="note">♪</span>{/if}
        <div class="eq" class:playing={activeInfo.playing}><span></span><span></span><span></span></div>
      </div>
      <div class="side">
        <div class="title">{activeInfo.title || tr("Onbekend nummer", "Unknown track")}</div>
        <div class="sub muted">{activeInfo.artist ? `${activeInfo.artist} · ${activeInfo.app}` : activeInfo.app}</div>
        <div class="scrub">
          <span class="time">{clock(position)}</span>
          <!-- svelte-ignore a11y_no_static_element_interactions -->
          <div
            class="bar"
            class:seekable={activeInfo.canSeek && duration > 0}
            title={tr("Voortgang", "Progress")}
            role="slider"
            tabindex={activeInfo.canSeek && duration > 0 ? 0 : -1}
            aria-label={tr("Voortgang", "Progress")}
            aria-valuemin="0"
            aria-valuemax={Math.round(duration)}
            aria-valuenow={Math.round(position)}
            onkeydown={seekKey}
            onpointerdown={(e) => {
              (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
              scrub(e, e.currentTarget as HTMLElement);
            }}
            onpointermove={(e) => drag !== null && scrub(e, e.currentTarget as HTMLElement)}
            onpointerup={(e) => drag !== null && scrub(e, e.currentTarget as HTMLElement, true)}
          >
            <div class="fill" style="width:{fraction * 100}%"><span class="knob"></span></div>
          </div>
          <span class="time right">{duration > 0 ? `-${clock(duration - position)}` : "–:––"}</span>
        </div>
        <div class="controls">
          {#if activeInfo.shuffle !== null}
            <button
              class="toggle"
              class:on={activeInfo.shuffle}
              title={tr("Willekeurig", "Shuffle")}
              aria-label={tr("Willekeurig", "Shuffle")}
              onclick={() => run(() => services.shuffle(!activeInfo.shuffle))}
            >
              ⤮
            </button>
          {/if}
          <button
            class="round"
            title={tr("Vorige", "Previous")}
            aria-label={tr("Vorige", "Previous")}
            onclick={() => run(() => services.media("previous"))}
          >
            ⏮
          </button>
          <button
            class="round big"
            title={activeInfo.playing ? tr("Pauze", "Pause") : tr("Afspelen", "Play")}
            aria-label={activeInfo.playing ? tr("Pauze", "Pause") : tr("Afspelen", "Play")}
            onclick={() => run(() => services.media("playPause"))}
          >
            {activeInfo.playing ? "⏸" : "▶"}
          </button>
          <button
            class="round"
            title={tr("Volgende", "Next")}
            aria-label={tr("Volgende", "Next")}
            onclick={() => run(() => services.media("next"))}
          >
            ⏭
          </button>
          {#if activeInfo.repeat !== null}
            <button
              class="toggle"
              class:on={activeInfo.repeat}
              title={tr("Herhalen", "Repeat")}
              aria-label={tr("Herhalen", "Repeat")}
              onclick={() => run(() => services.repeat(!activeInfo.repeat))}
            >
              ⟳
            </button>
          {/if}
          <span class="spacer"></span>
          {#if volume !== null}
            <button
              class="toggle"
              title={volume > 0 ? tr("Dempen", "Mute") : tr("Geluid aan", "Unmute")}
              aria-label={volume > 0 ? tr("Dempen", "Mute") : tr("Geluid aan", "Unmute")}
              onclick={mute}
            >
              {volume === 0 ? "🔇" : volume < 40 ? "🔈" : "🔊"}
            </button>
            <input
              class="volume"
              type="range"
              min="0"
              max="100"
              value={volume}
              aria-label={tr("Volume", "Volume")}
              oninput={setVolume}
              onchange={commitVolume}
            />
          {/if}
        </div>
        {#if error}<div class="err">{error}</div>{/if}
      </div>
    </div>
  {:else if section === "now"}
    <div class="idle">
      <div class="idle-note">♪</div>
      <h3>{tr("Er speelt nu niets", "Nothing is playing")}</h3>
      <p class="muted">
        {tr(
          "Start een nummer in Spotify, je browser of een andere speler, of zoek hierboven in Spotify.",
          "Start a track in Spotify, your browser or another player, or search Spotify above."
        )}
      </p>
      {#if error}<div class="err">{error}</div>{/if}
    </div>
  {/if}

  <!-- Main Content Area per Section -->
  <div class="content-scroll">
    {#if section === "now"}
      {#if activeInfo}
        <MusicLyrics info={activeInfo} {position} />
      {/if}

      <!-- Up Next Queue (SV-33) -->
      <section class="panel">
        <div class="panel-head">
          <h4>{tr("Wachtrij (Hierna)", "Up Next Queue")}</h4>
          {#if (overview?.nookQueue.length ?? 0) > 0}
            <button class="ghost small" onclick={clearNookQueue}>{tr("Wachtrij wissen", "Clear queue")}</button>
          {/if}
        </div>
        {#if (overview?.nookQueue.length ?? 0) === 0 && (overview?.spotifyQueue.length ?? 0) === 0}
          <p class="faint">
            {tr(
              "Geen nummers in de wachtrij. Voeg nummers toe vanuit Zoeken, Afspeellijsten of Bibliotheek.",
              "No tracks queued. Add tracks from Search, Playlists, or Library."
            )}
          </p>
        {:else}
          <div class="track-list">
            {#each overview?.nookQueue ?? [] as entry (entry.id)}
              <div class="track-row">
                {#if entry.track.artworkUrl}
                  <img class="thumb" src={entry.track.artworkUrl} alt="" />
                {:else}
                  <div class="thumb placeholder">♪</div>
                {/if}
                <div class="track-meta">
                  <strong>{entry.track.title}</strong>
                  <small class="faint">{entry.track.artist}{entry.track.album ? ` · ${entry.track.album}` : ""}</small>
                </div>
                <span class="badge">{tr("Nook-wachtrij", "Nook queue")}</span>
                <div class="row-actions">
                  <button class="ghost small" title={tr("Nu afspelen", "Play now")} onclick={() => playQueueEntry(entry.id)}>▶</button>
                  <button class="ghost small" title={tr("Verwijderen", "Remove")} onclick={() => removeQueueEntry(entry.id)}>×</button>
                </div>
              </div>
            {/each}
            {#each overview?.spotifyQueue ?? [] as track, idx (`${track.id}-${idx}`)}
              <div class="track-row">
                {#if track.artworkUrl}
                  <img class="thumb" src={track.artworkUrl} alt="" />
                {:else}
                  <div class="thumb placeholder">♪</div>
                {/if}
                <div class="track-meta">
                  <strong>{track.title}</strong>
                  <small class="faint">{track.artist}{track.album ? ` · ${track.album}` : ""}</small>
                </div>
                <span class="faint">{clock(track.duration)}</span>
                <div class="row-actions">
                  <button class="ghost small" title={tr("Nu afspelen", "Play now")} onclick={() => playTrack(track)}>▶</button>
                </div>
              </div>
            {/each}
          </div>
        {/if}
      </section>

      <!-- Recent Tracks (SV-35 / SV-36) -->
      {#if (overview?.recent.length ?? 0) > 0}
        <section class="panel">
          <div class="panel-head">
            <h4>{tr("Onlangs afgespeeld", "Recently Played")}</h4>
          </div>
          <div class="track-list">
            {#each (overview?.recent ?? []).slice(0, 12) as track, idx (`${track.id || track.title}-${idx}`)}
              <div class="track-row">
                {#if track.artworkUrl}
                  <img class="thumb" src={track.artworkUrl} alt="" />
                {:else}
                  <div class="thumb placeholder">♪</div>
                {/if}
                <div class="track-meta">
                  <strong>{track.title}</strong>
                  <small class="faint">{track.artist}{track.album ? ` · ${track.album}` : ""}</small>
                </div>
                <div class="row-actions">
                  {#if track.id}
                    <button class="ghost small" title={tr("Afspelen", "Play")} onclick={() => playTrack(track)}>▶</button>
                  {/if}
                  <button class="ghost small" title={tr("In wachtrij", "Add to queue")} onclick={() => queueTrack(track)}>+</button>
                </div>
              </div>
            {/each}
          </div>
        </section>
      {/if}
    {:else if section === "search"}
      <!-- Search Everywhere in Music (SV-32) -->
      {#if (overview?.searches.length ?? 0) > 0}
        <section class="panel">
          <div class="panel-head">
            <h4>{tr("Recente zoekopdrachten", "Recent Searches")}</h4>
          </div>
          <div class="chip-row">
            {#each overview?.searches ?? [] as q (q)}
              <span class="search-chip">
                <button class="ghost small" onclick={() => submitSearch(q)}>{q}</button>
                <button class="ghost small" title={tr("Vergeten", "Forget")} onclick={() => forgetSearch(q)}>×</button>
              </span>
            {/each}
          </div>
        </section>
      {/if}

      {#if searching}
        <section class="panel"><p class="faint">{tr("Zoeken in Spotify…", "Searching Spotify…")}</p></section>
      {:else if searchCatalog}
        {#if searchCatalog.state.kind === "connectSpotify" || searchCatalog.state.kind === "reconnectSpotify"}
          <section class="panel">
            <p class="faint">
              {tr(
                "Koppel Spotify om in de hele catalogus van Spotify te zoeken.",
                "Connect Spotify to search the full Spotify catalog."
              )}
            </p>
            <button class="capsule" onclick={() => (showSpotifySetup = true)}>
              {tr("Spotify koppelen", "Connect Spotify")}
            </button>
          </section>
        {/if}

        <section class="panel">
          <div class="panel-head">
            <h4>{tr("Nummers", "Tracks")} ({searchCatalog.tracks.length})</h4>
          </div>
          {#if searchCatalog.tracks.length === 0}
            <p class="faint">{tr("Geen nummers gevonden.", "No tracks found.")}</p>
          {:else}
            <div class="track-list">
              {#each searchCatalog.tracks as track (track.id || track.title)}
                <div class="track-row">
                  {#if track.artworkUrl}
                    <img class="thumb" src={track.artworkUrl} alt="" />
                  {:else}
                    <div class="thumb placeholder">♪</div>
                  {/if}
                  <div class="track-meta">
                    <strong>{track.title}</strong>
                    <small class="faint">{track.artist}{track.album ? ` · ${track.album}` : ""}</small>
                  </div>
                  <span class="faint">{clock(track.duration)}</span>
                  <div class="row-actions">
                    <button class="ghost small" title={tr("Nu afspelen", "Play now")} onclick={() => playTrack(track)}>▶</button>
                    <button class="ghost small" title={tr("In wachtrij", "Add to queue")} onclick={() => queueTrack(track)}>+</button>
                    {#if overview?.spotifyConnected}
                      <button
                        class="ghost small"
                        title={tr("Aan afspeellijst toevoegen", "Add to playlist")}
                        onclick={() => (playlistTargetTrack = track)}
                      >
                        ☰
                      </button>
                    {/if}
                  </div>
                </div>
              {/each}
            </div>
          {/if}
        </section>

        {#if searchCatalog.albums.length > 0}
          <section class="panel">
            <div class="panel-head">
              <h4>{tr("Albums", "Albums")} ({searchCatalog.albums.length})</h4>
            </div>
            <div class="card-grid">
              {#each searchCatalog.albums as album (album.id)}
                <div class="media-card">
                  {#if album.artworkUrl}
                    <img class="card-art" src={album.artworkUrl} alt="" />
                  {:else}
                    <div class="card-art placeholder">💿</div>
                  {/if}
                  <strong>{album.name}</strong>
                  <small class="faint">{album.artist}{album.releaseYear ? ` · ${album.releaseYear}` : ""}</small>
                  <button class="capsule small" onclick={() => playContextUri(album.id)}>
                    ▶ {tr("Afspelen", "Play")}
                  </button>
                </div>
              {/each}
            </div>
          </section>
        {/if}

        {#if searchCatalog.playlists.length > 0}
          <section class="panel">
            <div class="panel-head">
              <h4>{tr("Afspeellijsten", "Playlists")} ({searchCatalog.playlists.length})</h4>
            </div>
            <div class="card-grid">
              {#each searchCatalog.playlists as pl (pl.id)}
                <div class="media-card">
                  {#if pl.artworkUrl}
                    <img class="card-art" src={pl.artworkUrl} alt="" />
                  {:else}
                    <div class="card-art placeholder">♫</div>
                  {/if}
                  <strong>{pl.name}</strong>
                  <small class="faint">{tr("{n} nummers", "{n} tracks", { n: pl.trackCount })}</small>
                  <button class="capsule small" onclick={() => playContextUri(pl.id)}>
                    ▶ {tr("Afspelen", "Play")}
                  </button>
                </div>
              {/each}
            </div>
          </section>
        {/if}
      {/if}
    {:else if section === "playlists"}
      <!-- Playlists Management (SV-34) -->
      <section class="panel">
        <div class="panel-head">
          <h4>{tr("Jouw afspeellijsten", "Your Playlists")}</h4>
          <form
            class="inline-form"
            onsubmit={(e) => {
              e.preventDefault();
              createPlaylist();
            }}
          >
            <input
              placeholder={tr("Nieuwe afspeellijst…", "New playlist…")}
              bind:value={newPlaylistName}
            />
            <button type="submit" class="capsule small">+ {tr("Maken", "Create")}</button>
          </form>
        </div>

        {#if !overview?.spotifyConnected}
          <p class="faint">
            {tr("Koppel Spotify om je afspeellijsten te bekijken en te bewerken.", "Connect Spotify to browse and edit your playlists.")}
          </p>
        {:else if playlistsView}
          <div class="playlists-layout">
            <div class="playlist-sidebar">
              {#each playlistsView.playlists as pl (pl.id)}
                <button
                  class="playlist-nav-item"
                  class:active={playlistsView.selectedId === pl.id}
                  onclick={() => loadPlaylists(pl.id)}
                >
                  <span class="pl-title">{pl.name}</span>
                  <small class="faint">{pl.trackCount}</small>
                </button>
              {/each}
            </div>

            <div class="playlist-detail">
              {#if playlistsView.selectedId}
                {@const currentPl = playlistsView.playlists.find((p) => p.id === playlistsView!.selectedId)}
                {#if currentPl}
                  <div class="panel-head">
                    <div>
                      <h4>{currentPl.name}</h4>
                      <small class="faint">
                        {tr("{n} nummers", "{n} tracks", { n: currentPl.trackCount })}
                        {currentPl.owner ? ` · ${currentPl.owner}` : ""}
                      </small>
                    </div>
                    <div class="row-actions">
                      <button class="primary small" onclick={() => modifyPlaylist(currentPl.id, "play")}>
                        ▶ {tr("Afspelen", "Play")}
                      </button>
                      {#if currentPl.editable}
                        <button
                          class="ghost small"
                          onclick={() => {
                            renamingPlaylistId = currentPl.id;
                            renamePlaylistName = currentPl.name;
                          }}
                        >
                          {tr("Hernoemen", "Rename")}
                        </button>
                        <button
                          class="danger small"
                          onclick={() => modifyPlaylist(currentPl.id, "delete")}
                        >
                          {tr("Verwijderen", "Delete")}
                        </button>
                      {/if}
                    </div>
                  </div>

                  {#if renamingPlaylistId === currentPl.id}
                    <form
                      class="inline-form"
                      onsubmit={(e) => {
                        e.preventDefault();
                        modifyPlaylist(currentPl.id, "rename", { name: renamePlaylistName });
                      }}
                    >
                      <input bind:value={renamePlaylistName} />
                      <button type="submit" class="capsule small">{tr("Opslaan", "Save")}</button>
                      <button type="button" class="ghost small" onclick={() => (renamingPlaylistId = null)}>
                        {tr("Annuleren", "Cancel")}
                      </button>
                    </form>
                  {/if}

                  <div class="track-list">
                    {#each playlistsView.tracks as track, idx (`${track.id}-${idx}`)}
                      <div class="track-row">
                        {#if track.artworkUrl}
                          <img class="thumb" src={track.artworkUrl} alt="" />
                        {:else}
                          <div class="thumb placeholder">♪</div>
                        {/if}
                        <div class="track-meta">
                          <strong>{track.title}</strong>
                          <small class="faint">{track.artist}{track.album ? ` · ${track.album}` : ""}</small>
                        </div>
                        <span class="faint">{clock(track.duration)}</span>
                        <div class="row-actions">
                          <button
                            class="ghost small"
                            title={tr("Nu afspelen", "Play now")}
                            onclick={() => modifyPlaylist(currentPl.id, "play", { trackUri: track.id })}
                          >
                            ▶
                          </button>
                          <button class="ghost small" title={tr("In wachtrij", "Add to queue")} onclick={() => queueTrack(track)}>+</button>
                          {#if currentPl.editable}
                            <button
                              class="ghost small"
                              title={tr("Uit afspeellijst halen", "Remove from playlist")}
                              onclick={() => modifyPlaylist(currentPl.id, "remove_track", { trackUri: track.id })}
                            >
                              ×
                            </button>
                          {/if}
                        </div>
                      </div>
                    {/each}
                  </div>
                {/if}
              {/if}
            </div>
          </div>
        {/if}
      </section>
    {:else if section === "library"}
      <!-- Library: Top Artists, Top Tracks, Recent (SV-35) -->
      <section class="panel">
        <div class="panel-head">
          <h4>{tr("Meest gedraaid", "Top Artists & Tracks")}</h4>
          <div class="chip-row">
            <button
              class="capsule small"
              class:connected={libraryRange === "short_term"}
              onclick={() => loadLibrary("short_term")}
            >
              {tr("Laatste 4 weken", "Last 4 weeks")}
            </button>
            <button
              class="capsule small"
              class:connected={libraryRange === "medium_term"}
              onclick={() => loadLibrary("medium_term")}
            >
              {tr("Laatste 6 maanden", "Last 6 months")}
            </button>
            <button
              class="capsule small"
              class:connected={libraryRange === "long_term"}
              onclick={() => loadLibrary("long_term")}
            >
              {tr("Altijd", "All time")}
            </button>
          </div>
        </div>

        {#if libraryView}
          {#if libraryView.playerStats.artists.length > 0}
            <h5>{tr("Topartiesten", "Top Artists")}</h5>
            <div class="card-grid">
              {#each libraryView.playerStats.artists as artist (artist.name)}
                <div class="media-card">
                  {#if artist.artworkUrl}
                    <img class="card-art round-art" src={artist.artworkUrl} alt="" />
                  {:else}
                    <div class="card-art round-art placeholder">★</div>
                  {/if}
                  <strong>{artist.name}</strong>
                  {#if artist.plays !== null}
                    <small class="faint">{tr("{n}× afgespeeld", "{n} plays", { n: artist.plays })}</small>
                  {/if}
                </div>
              {/each}
            </div>
          {/if}

          {#if libraryView.playerStats.tracks.length > 0}
            <h5>{tr("Topnummers", "Top Tracks")}</h5>
            <div class="track-list">
              {#each libraryView.playerStats.tracks as track, idx (`${track.id || track.title}-${idx}`)}
                <div class="track-row">
                  <span class="rank-num">{idx + 1}</span>
                  {#if track.artworkUrl}
                    <img class="thumb" src={track.artworkUrl} alt="" />
                  {:else}
                    <div class="thumb placeholder">♪</div>
                  {/if}
                  <div class="track-meta">
                    <strong>{track.title}</strong>
                    <small class="faint">{track.artist}{track.album ? ` · ${track.album}` : ""}</small>
                  </div>
                  <div class="row-actions">
                    {#if track.id}
                      <button class="ghost small" onclick={() => playTrack(track)}>▶</button>
                    {/if}
                    <button class="ghost small" onclick={() => queueTrack(track)}>+</button>
                  </div>
                </div>
              {/each}
            </div>
          {:else}
            <p class="faint">
              {tr(
                "Nog geen topnummers beschikbaar. Luister muziek of koppel Spotify om je bibliotheek te vullen.",
                "No top tracks yet. Listen to music or connect Spotify to populate your library."
              )}
            </p>
          {/if}
        {/if}
      </section>
    {:else if section === "stats"}
      <!-- Listening History, Streaks & Statistics (SV-36) -->
      <section class="panel">
        <div class="panel-head">
          <h4>{tr("Luistergeschiedenis & statistieken", "Listening History & Statistics")}</h4>
          <div class="chip-row">
            {#each (["week", "month", "year", "all"] as const) as p (p)}
              <button
                class="capsule small"
                class:connected={statsPeriod === p}
                onclick={() => loadStats(p)}
              >
                {p === "week"
                  ? tr("Week", "Week")
                  : p === "month"
                    ? tr("Maand", "Month")
                    : p === "year"
                      ? tr("Jaar", "Year")
                      : tr("Alles", "All")}
              </button>
            {/each}
          </div>
        </div>

        {#if historyView}
          {@const st = historyView.stats}
          <div class="stats-grid">
            <div class="stat-box">
              <small class="faint">{tr("Luistertijd", "Listening time")}</small>
              <strong>{formatHoursMinutes(st.seconds)}</strong>
              {#if historyView.changePercent !== null}
                <small class="faint">
                  {historyView.changePercent >= 0 ? `+${historyView.changePercent}%` : `${historyView.changePercent}%`}
                  {tr("t.o.v. vorige periode", "vs previous period")}
                </small>
              {/if}
            </div>
            <div class="stat-box">
              <small class="faint">{tr("Afgespeeld", "Plays")}</small>
              <strong>{st.plays}</strong>
              <small class="faint">{tr("{n} unieke nummers", "{n} unique tracks", { n: st.uniqueTracks })}</small>
            </div>
            <div class="stat-box">
              <small class="faint">{tr("Artiesten", "Artists")}</small>
              <strong>{st.uniqueArtists}</strong>
              {#if st.newArtists !== null}
                <small class="faint">{tr("{n} nieuw ontdekt", "{n} newly discovered", { n: st.newArtists })}</small>
              {/if}
            </div>
            <div class="stat-box">
              <small class="faint">{tr("Reeks & ritme", "Streak & rhythm")}</small>
              <strong>{tr("{n} dagen op rij", "{n} day streak", { n: st.streak })}</strong>
              <small class="faint">
                {listenerTypeLabel(st.listenerType)}
                {st.peakHour !== null ? ` · ${st.peakHour}:00` : ""}
              </small>
            </div>
          </div>

          {#if st.buckets.length > 0}
            {@const maxBucket = Math.max(1, ...st.buckets.map((b) => b.seconds))}
            <h5>{tr("Verloop over de periode", "Listening over time")}</h5>
            <div class="bars-chart">
              {#each st.buckets as b (b.start)}
                <div class="bar-col" title={`${b.start}: ${formatHoursMinutes(b.seconds)}`}>
                  <div class="bar-fill" style="height:{Math.max(4, Math.round((b.seconds / maxBucket) * 100))}%"></div>
                  <small class="faint">{b.start.slice(-2)}</small>
                </div>
              {/each}
            </div>
          {/if}

          {#if st.topTracks.length > 0}
            <h5>{tr("Meest geluisterd in deze periode", "Most played in this period")}</h5>
            <div class="track-list">
              {#each st.topTracks as item, idx (item.track.id || item.track.title)}
                <div class="track-row">
                  <span class="rank-num">{idx + 1}</span>
                  <div class="track-meta">
                    <strong>{item.track.title}</strong>
                    <small class="faint">{item.track.artist}</small>
                  </div>
                  <span class="faint">{item.plays}× · {formatHoursMinutes(item.seconds)}</span>
                </div>
              {/each}
            </div>
          {/if}

          <div class="panel-foot">
            <span class="faint">{tr("{n} geregistreerde luisterbeurten op deze computer.", "{n} recorded plays on this computer.", { n: historyView.totalPlays })}</span>
            {#if historyView.totalPlays > 0}
              <button class="danger small" onclick={() => loadStats(statsPeriod, true)}>
                {tr("Luistergeschiedenis wissen", "Clear listening history")}
              </button>
            {/if}
          </div>
        {/if}
      </section>
    {/if}
  </div>
</div>

<style>
  .stage {
    --accent: var(--music);
    height: 100%;
    display: flex;
    flex-direction: column;
    min-height: 0;
  }
  .topbar {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: var(--space-12);
    padding: var(--space-12) var(--space-24);
    border-bottom: 1px solid var(--line);
    flex-wrap: wrap;
  }
  .tabs {
    display: flex;
    align-items: center;
    gap: var(--space-4);
  }
  .tab {
    display: inline-flex;
    align-items: center;
    gap: var(--space-6);
    padding: var(--space-6) var(--space-12);
    border-radius: var(--radius-control);
    border: 1px solid transparent;
    background: transparent;
    color: var(--text2);
    font: var(--text-control);
    cursor: pointer;
  }
  .tab:hover {
    color: var(--paper);
    background: var(--row-hover);
  }
  .tab.active {
    color: var(--paper);
    background: var(--row-selected);
    border-color: var(--line2);
  }
  .streak-pill {
    padding: var(--space-2) var(--space-6);
    border-radius: 999px;
    background: var(--accent);
    color: var(--ink);
    font: var(--text-caption);
  }
  .searchbox {
    display: flex;
    align-items: center;
    gap: var(--space-4);
    flex: 1;
    min-width: 180px;
    max-width: 320px;
  }
  .searchbox input {
    width: 100%;
  }
  .top-actions {
    display: flex;
    align-items: center;
    gap: var(--space-8);
  }
  .capsule.connected {
    border-color: var(--mint);
    color: var(--mint);
  }
  .popover-anchor {
    position: relative;
  }
  .popover {
    position: absolute;
    right: 0;
    top: calc(100% + var(--space-6));
    min-width: 240px;
    padding: var(--space-8);
    border-radius: var(--radius-panel);
    background: var(--surface);
    border: 1px solid var(--line2);
    box-shadow: var(--shadow-popover);
    z-index: 20;
    display: flex;
    flex-direction: column;
    gap: var(--space-4);
  }
  .popover-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: var(--space-4) var(--space-6);
    font: var(--text-label);
  }
  .output-row {
    display: flex;
    align-items: center;
    gap: var(--space-8);
    padding: var(--space-6) var(--space-8);
    border-radius: var(--radius-control);
    border: none;
    background: transparent;
    color: var(--text2);
    font: var(--text-control);
    text-align: left;
    cursor: pointer;
  }
  .output-row:hover {
    background: var(--row-hover);
    color: var(--paper);
  }
  .output-row.active {
    background: var(--row-selected);
    color: var(--paper);
  }
  .output-name {
    flex: 1;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .active-dot {
    color: var(--mint);
  }
  .spotify-card {
    margin: var(--space-12) var(--space-24) 0;
    padding: var(--space-16);
    border-radius: var(--radius-card);
    background: var(--surface);
    border: 1px solid var(--line2);
    display: flex;
    flex-direction: column;
    gap: var(--space-12);
  }
  .card-head {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: var(--space-12);
  }
  .card-head h4 {
    margin: 0 0 var(--space-4);
    font: var(--text-title);
  }
  .card-head p {
    margin: 0;
    font: var(--text-detail);
  }
  .spotify-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
    gap: var(--space-12);
  }
  .field-col {
    display: flex;
    flex-direction: column;
    gap: var(--space-4);
    font: var(--text-detail);
  }
  .copy-row,
  .spotify-row,
  .inline-form {
    display: flex;
    align-items: center;
    gap: var(--space-8);
  }
  .copy-row input,
  .spotify-row input {
    flex: 1;
  }
  .music {
    --accent: var(--music);
    display: flex;
    gap: var(--space-24);
    align-items: center;
    padding: var(--space-16) var(--space-24);
    flex: none;
    position: relative;
    overflow: hidden;
    border-bottom: 1px solid var(--line);
  }
  .glow {
    position: absolute;
    inset: -40px;
    background-size: cover;
    background-position: center;
    filter: blur(48px) saturate(1.4);
    opacity: 0.28;
    pointer-events: none;
  }
  .music > :not(.glow) {
    position: relative;
  }
  .art {
    width: 112px;
    height: 112px;
    border-radius: var(--radius-composer);
    background: var(--accent);
    overflow: hidden;
    flex: none;
    border: 1px solid var(--line);
    box-shadow: var(--shadow-popover);
    transition: transform 240ms ease;
  }
  .art.playing {
    transform: scale(1.02);
  }
  .note {
    position: absolute;
    inset: 0;
    display: grid;
    place-items: center;
    font: var(--text-display);
    color: var(--ink);
    opacity: 0.75;
  }
  .art img {
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
  .eq {
    position: absolute;
    left: 10px;
    bottom: 10px;
    padding: 4px 5px;
    border-radius: var(--radius-control);
    background: color-mix(in srgb, var(--notch) 35%, transparent);
    backdrop-filter: blur(6px);
    display: flex;
    gap: 3px;
    align-items: flex-end;
    height: 14px;
  }
  .eq span {
    width: 3px;
    height: 5px;
    background: var(--paper);
    border-radius: 999px;
  }
  .art.empty .eq span {
    background: var(--ink);
  }
  .eq.playing span {
    animation: eq 0.9s ease-in-out infinite;
  }
  .eq.playing span:nth-child(2) {
    animation-delay: 0.2s;
  }
  .eq.playing span:nth-child(3) {
    animation-delay: 0.4s;
  }
  @keyframes eq {
    50% {
      height: 14px;
    }
  }
  .side {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: var(--space-6);
  }
  .title {
    font: var(--text-heading);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    user-select: text;
  }
  .sub {
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    user-select: text;
  }
  .scrub {
    display: flex;
    align-items: center;
    gap: var(--space-8);
    font: var(--text-label);
    font-family: var(--mono);
    color: var(--text3);
  }
  .time {
    width: 40px;
  }
  .time.right {
    text-align: right;
    width: 44px;
  }
  .bar {
    flex: 1;
    height: 18px;
    outline: none;
    display: flex;
    align-items: center;
    position: relative;
    touch-action: none;
  }
  .bar::before {
    content: "";
    position: absolute;
    left: 0;
    right: 0;
    height: 3px;
    border-radius: 999px;
    background: var(--line2);
  }
  .fill {
    position: relative;
    height: 3px;
    border-radius: 999px;
    background: var(--paper);
  }
  .knob {
    position: absolute;
    right: -6px;
    top: 50%;
    width: 12px;
    height: 12px;
    margin-top: -6px;
    border-radius: 50%;
    background: var(--paper);
    box-shadow: var(--shadow-control);
    opacity: 0;
    transform: scale(0.6);
    transition: opacity 120ms ease, transform 120ms ease;
  }
  .bar.seekable:hover .knob,
  .bar.seekable:focus-visible .knob {
    opacity: 1;
    transform: scale(1);
  }
  .bar:focus-visible::before {
    box-shadow: 0 0 0 2px color-mix(in srgb, var(--accent) 60%, transparent);
  }
  .bar.seekable {
    cursor: pointer;
  }
  .bar.seekable:hover::before,
  .bar.seekable:hover .fill {
    height: 5px;
  }
  .bar.seekable:hover .fill,
  .bar.seekable:focus-visible .fill {
    background: var(--accent);
  }
  .controls {
    display: flex;
    align-items: center;
    gap: var(--space-6);
  }
  .spacer {
    flex: 1;
  }
  .round {
    width: 30px;
    height: 30px;
    padding: 0;
    border-radius: 50%;
    background: transparent;
    border: none;
    font: var(--text-body);
    transition: transform 120ms ease, background 120ms ease;
  }
  .round:hover:not(.big) {
    background: var(--smoke);
  }
  .round:active {
    transform: scale(0.92);
  }
  .round.big {
    width: 38px;
    height: 38px;
    background: var(--paper);
    color: var(--ink);
    font: var(--text-title);
    box-shadow: var(--shadow-popover);
  }
  .round.big:hover {
    background: var(--text-strong);
  }
  .toggle {
    width: 28px;
    height: 28px;
    padding: 0;
    border-radius: 50%;
    background: transparent;
    border: none;
    color: var(--text3);
    font: var(--text-body);
    position: relative;
  }
  .toggle:hover {
    color: var(--paper);
    background: var(--smoke);
  }
  .toggle.on {
    color: var(--accent);
  }
  .toggle.on::after {
    content: "";
    position: absolute;
    bottom: 2px;
    left: 50%;
    width: 4px;
    height: 4px;
    margin-left: -2px;
    border-radius: 50%;
    background: var(--accent);
  }
  .volume {
    width: 92px;
    padding: 0;
    accent-color: var(--accent);
    background: transparent;
    border: none;
    cursor: pointer;
  }
  .content-scroll {
    flex: 1;
    overflow-y: auto;
    padding: var(--space-16) var(--space-24);
    display: flex;
    flex-direction: column;
    gap: var(--space-16);
  }
  .panel {
    padding: var(--space-16);
    border-radius: var(--radius-card);
    background: var(--well);
    border: 1px solid var(--line);
    display: flex;
    flex-direction: column;
    gap: var(--space-12);
  }
  .panel-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: var(--space-12);
    flex-wrap: wrap;
  }
  .panel-head h4,
  .panel h5 {
    margin: 0;
    font: var(--text-title);
  }
  .track-list {
    display: flex;
    flex-direction: column;
    gap: var(--space-4);
  }
  .track-row {
    display: flex;
    align-items: center;
    gap: var(--space-12);
    padding: var(--space-6) var(--space-8);
    border-radius: var(--radius-control);
  }
  .track-row:hover {
    background: var(--row-hover);
  }
  .thumb {
    width: 36px;
    height: 36px;
    border-radius: var(--radius-chip);
    object-fit: cover;
    flex: none;
    background: var(--smoke);
  }
  .placeholder {
    display: grid;
    place-items: center;
    color: var(--text3);
  }
  .track-meta {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
  }
  .track-meta strong {
    font: var(--text-emphasis);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .track-meta small {
    font: var(--text-detail);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .row-actions {
    display: flex;
    align-items: center;
    gap: var(--space-4);
  }
  .badge {
    padding: var(--space-2) var(--space-8);
    border-radius: 999px;
    background: var(--row-selected);
    color: var(--text2);
    font: var(--text-caption);
  }
  .chip-row {
    display: flex;
    flex-wrap: wrap;
    gap: var(--space-6);
  }
  .search-chip {
    display: inline-flex;
    align-items: center;
    gap: var(--space-2);
    padding: var(--space-2) var(--space-6);
    border-radius: var(--radius-chip);
    background: var(--surface);
    border: 1px solid var(--line2);
  }
  .card-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(140px, 1fr));
    gap: var(--space-12);
  }
  .media-card {
    padding: var(--space-12);
    border-radius: var(--radius-card);
    background: var(--surface);
    border: 1px solid var(--line);
    display: flex;
    flex-direction: column;
    gap: var(--space-6);
  }
  .card-art {
    width: 100%;
    aspect-ratio: 1;
    border-radius: var(--radius-control);
    object-fit: cover;
    background: var(--smoke);
  }
  .round-art {
    border-radius: 50%;
  }
  .playlists-layout {
    display: grid;
    grid-template-columns: 200px 1fr;
    gap: var(--space-16);
  }
  .playlist-sidebar {
    display: flex;
    flex-direction: column;
    gap: var(--space-4);
    border-right: 1px solid var(--line);
    padding-right: var(--space-12);
  }
  .playlist-nav-item {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: var(--space-8);
    padding: var(--space-6) var(--space-8);
    border-radius: var(--radius-control);
    border: none;
    background: transparent;
    color: var(--text2);
    font: var(--text-control);
    text-align: left;
    cursor: pointer;
  }
  .playlist-nav-item:hover {
    background: var(--row-hover);
    color: var(--paper);
  }
  .playlist-nav-item.active {
    background: var(--row-selected);
    color: var(--paper);
  }
  .pl-title {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .playlist-detail {
    display: flex;
    flex-direction: column;
    gap: var(--space-12);
    min-width: 0;
  }
  .rank-num {
    width: 22px;
    text-align: right;
    color: var(--text3);
    font: var(--text-label);
  }
  .stats-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
    gap: var(--space-12);
  }
  .stat-box {
    padding: var(--space-12);
    border-radius: var(--radius-card);
    background: var(--surface);
    border: 1px solid var(--line);
    display: flex;
    flex-direction: column;
    gap: var(--space-4);
  }
  .stat-box strong {
    font: var(--text-heading);
    color: var(--paper);
  }
  .bars-chart {
    display: flex;
    align-items: flex-end;
    gap: var(--space-4);
    height: 96px;
    padding: var(--space-8) 0;
  }
  .bar-col {
    flex: 1;
    height: 100%;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: flex-end;
    gap: var(--space-4);
  }
  .bar-fill {
    width: 100%;
    max-width: 18px;
    border-radius: var(--radius-chip);
    background: var(--accent);
  }
  .panel-foot {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding-top: var(--space-8);
    border-top: 1px solid var(--line);
  }
  .idle {
    padding: var(--space-24);
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    gap: var(--space-4);
    user-select: text;
  }
  .idle-note {
    width: 48px;
    height: 48px;
    display: grid;
    place-items: center;
    border-radius: var(--radius-composer);
    background: var(--smoke);
    border: 1px solid var(--line2);
    font: var(--text-heading);
    color: var(--accent);
    margin-bottom: var(--space-8);
    user-select: none;
  }
  .idle h3 {
    margin: 0;
    font: var(--text-heading);
  }
  .idle p {
    margin: 0;
    max-width: 46ch;
    line-height: 1.45;
  }
  .err {
    color: var(--coral);
    font: var(--text-detail);
  }
</style>
