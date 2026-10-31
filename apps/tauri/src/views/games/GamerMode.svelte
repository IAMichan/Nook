<script lang="ts">
  // Gamer Mode: the games Nook can coach, each switched on or off (off by default: no screenshots, no requests to the
  // brain), and the coach of the one you open. A new game is an entry in `games::supported` (Rust) and a coach in
  // `coaches` below.
  import type { Component } from "svelte";
  import { games, type GameInfo } from "../../lib/games";
  import { gamer } from "../../lib/gamer.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import { onBack } from "../../lib/mobile";
  import OnOffSwitch from "../../components/OnOffSwitch.svelte";
  import ValorantCoach from "./ValorantCoach.svelte";

  interface Coach {
    component: Component<{ onback: () => void }>;
    tagline: () => string;
    /// `undefined` while loading.
    enabled: () => boolean | undefined;
    setEnabled: (on: boolean) => void;
  }

  const coaches: Record<string, Coach> = {
    valorant: {
      component: ValorantCoach,
      tagline: () => tr("Analyse en coaching van je potjes met AI", "AI-powered gameplay analysis and coaching"),
      enabled: () => gamer.view?.prefs.enabled,
      setEnabled: (on) => {
        const prefs = gamer.view?.prefs;
        if (prefs) gamer.run(() => games.savePrefs({ ...prefs, enabled: on }), tr("Kon Valorant niet aan- of uitzetten", "Could not switch Valorant on or off"));
      },
    },
  };

  $effect(() => gamer.start());

  let list = $state<GameInfo[] | null>(null);
  let open = $state<string | null>(read());

  function read(): string | null {
    try { return localStorage.getItem("games.open"); } catch { return null; }
  }

  $effect(() => {
    try {
      if (open) localStorage.setItem("games.open", open);
      else localStorage.removeItem("games.open");
    } catch {
      // No storage: the choice holds for now only.
    }
  });

  $effect(() => {
    games.list().then((l) => (list = l)).catch(() => (list = []));
  });

  $effect(() => onBack(() => (open ? ((open = null), true) : false)));

  const Coach = $derived(open ? coaches[open]?.component : undefined);
</script>

{#if Coach}
  <Coach onback={() => (open = null)} />
{:else}
  <div class="gamer">
    <p class="muted intro">
      {tr(
        "Nook kijkt mee naar je eigen scherm terwijl je speelt, onthoudt wat er eerder in het potje gebeurde en vertelt je wat de tegenstander steeds herhaalt.",
        "Nook watches your own screen while you play, remembers what happened earlier in the match, and tells you what the other team keeps repeating.",
      )}
    </p>
    <div class="games">
      {#each list ?? [] as game (game.id)}
        {@const coach = coaches[game.id]}
        {@const on = coach?.enabled()}
        <article class="game" class:off={!on}>
          <div class="top">
            <div class="mark" aria-hidden="true">{game.title.slice(0, 1)}</div>
            <OnOffSwitch
              {on}
              label={game.title}
              disabled={!coach || on === undefined}
              title={on ? tr("Nook kijkt mee terwijl je speelt", "Nook watches while you play") : tr("Uit: geen schermafbeeldingen, geen tokens", "Off: no screenshots, no tokens")}
              onchange={(value) => coach?.setEnabled(value)}
            />
          </div>
          <div class="info">
            <h2>{game.title}</h2>
            <p class="muted">{coaches[game.id]?.tagline() ?? ""}</p>
          </div>
          <button class="primary" disabled={!coaches[game.id]} onclick={() => (open = game.id)}>{tr(`Open ${game.title}-coach`, `Open ${game.title} Coach`)}</button>
        </article>
      {:else}
        <p class="faint">{list ? tr("Nog geen games.", "No games yet.") : tr("Laden…", "Loading…")}</p>
      {/each}
    </div>
    <p class="faint more">{tr("Meer games volgen.", "More games will follow.")}</p>
  </div>
{/if}

<style>
  .gamer { padding: 28px clamp(20px, 4vw, 48px); overflow-y: auto; height: 100%; box-sizing: border-box; }
  .intro { max-width: 640px; margin: 0 0 22px; line-height: 1.5; }
  .games { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 12px; max-width: 880px; }
  .game { display: flex; flex-direction: column; gap: 14px; background: var(--graphite); border: 1px solid var(--line2); border-radius: var(--radius); padding: 18px; }
  .game.off .mark, .game.off .info { opacity: .6; }
  .top { display: flex; justify-content: space-between; align-items: center; gap: 12px; }
  .mark { width: 40px; height: 40px; display: grid; place-items: center; border-radius: var(--radius-control); background: var(--smoke); border: 1px solid var(--line2); font-weight: 700; font-size: 18px; }
  .info h2 { margin: 0 0 4px; font-size: 17px; font-weight: 600; }
  .info p { margin: 0; font-size: 12.5px; }
  .game button { align-self: flex-start; }
  .more { font-size: 12px; margin-top: 18px; }
</style>
