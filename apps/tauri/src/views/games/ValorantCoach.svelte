<script lang="ts">
  // The Valorant Coach: the match in progress, what Nook advises, the enemy's patterns, my habits, and the memory of
  // every round. The coach itself is `nook_core::games::valorant` (Rust); this page shows it and words it.
  import { games, clock, coachingText, confidenceLabel, generalText, habitText, statusLabel, type ValorantCatalog } from "../../lib/games";
  import { gamer } from "../../lib/gamer.svelte";
  import { english, tr } from "../../lib/i18n.svelte";
  import { nook } from "../../lib/state.svelte";
  import { toast } from "../../lib/toast.svelte";
  import Icon from "../../components/Icon.svelte";
  import OnOffSwitch from "../../components/OnOffSwitch.svelte";
  import LogEvent from "./LogEvent.svelte";

  let { onback }: { onback: () => void } = $props();

  let catalog = $state<ValorantCatalog | null>(null);
  let looking = $state(false);

  $effect(() => {
    gamer.start();
    games.catalog().then((c) => (catalog = c)).catch(() => {});
  });

  const lang = $derived(english() ? "en" : "nl");
  const view = $derived(gamer.view);
  const match = $derived(view?.current ?? null);
  const analysis = $derived(view?.analysis ?? null);
  const patterns = $derived((analysis?.patterns ?? []).filter((p) => p.occurrences >= 2));
  const seenOnce = $derived((analysis?.patterns ?? []).length - patterns.length);
  const round = $derived(match?.rounds[match.rounds.length - 1]?.number ?? 1);
  const canSee = $derived(!!nook.info?.capabilities.screenPart);

  const agentName = (id: string | null) => catalog?.agents.find((a) => a.id === id)?.name ?? id ?? "—";
  const abilityName = (agent: string | null, id: string | null) =>
    catalog?.agents.find((a) => a.id === agent)?.abilities.find((b) => b.id === id)?.name ?? id ?? "";

  const status = $derived(
    !view ? tr("Laden…", "Loading…")
    : view.looking ? tr("Kijkt naar je scherm…", "Looking at your screen…")
    : !view.prefs.enabled ? tr("Gamer Mode staat uit", "Gamer Mode is off")
    : view.inGame ? tr("Kijkt mee", "Watching")
    : tr("Wacht op Valorant", "Waiting for Valorant"),
  );

  async function lookNow() {
    looking = true;
    try {
      const added = await games.look();
      if (added) toast.success(tr(`${added} gebeurtenis(sen) onthouden`, `Remembered ${added} event(s)`));
      else toast.info(tr("Niets nieuws gezien", "Nothing new seen"), gamer.view?.lastError ?? undefined);
    } catch (e) {
      toast.error(tr("Kon niet naar je scherm kijken", "Could not look at your screen"), e);
    }
    looking = false;
  }

  function newMatch() {
    gamer.run(() => games.startMatch(match?.map ?? null, match?.myAgent ?? null), tr("Kon geen nieuw potje starten", "Could not start a new match"));
  }

  const icon = (severity: string) => (severity === "success" ? "✓" : severity === "warning" ? "⚠" : "•");
  const effectLabel = (effect: string) =>
    effect === "hit" ? tr("raakte mij", "caught me") : effect === "avoided" ? tr("ontweken", "avoided") : effect === "destroyed" ? tr("kapot", "destroyed") : tr("gezien", "seen");
  const time = (iso: string | null) => (iso ? new Date(iso).toLocaleTimeString(english() ? "en-GB" : "nl-NL", { hour: "2-digit", minute: "2-digit", second: "2-digit" }) : "—");
</script>

<div class="coach">
  <header>
    <button class="ghost icon-button" onclick={onback} title={tr("Terug naar Gamer Mode", "Back to Gamer Mode")} aria-label={tr("Terug", "Back")}><Icon name="back" /></button>
    <h2>Valorant Coach</h2>
    <span class="pill"><span class="dot" class:working={view?.looking} class:unread={view?.prefs.enabled && view?.inGame && !view?.looking} class:waiting={view?.prefs.enabled && !view?.inGame}></span>{status}</span>
    <span class="spacer"></span>
    <button disabled={!canSee || looking || view?.looking || !view?.prefs.enabled} onclick={lookNow} title={view?.prefs.enabled ? tr("Maak nu een schermafbeelding en laat het brein hem lezen", "Take a screenshot now and let the brain read it") : tr("Zet Valorant eerst aan in Gamer Mode", "Switch Valorant on in Gamer Mode first")}>{tr("Kijk nu", "Look now")}</button>
    <button onclick={() => gamer.run(games.nextRound, tr("Kon niet naar de volgende ronde", "Could not move to the next round"))}>{tr("Volgende ronde", "Next round")}</button>
    <button onclick={newMatch}>{tr("Nieuw potje", "New match")}</button>
  </header>

  {#if view}
    <div class="grid">
      <section class="card session">
        <h3>{tr("Huidige sessie", "Current session")}</h3>
        <dl>
          <dt>Game</dt><dd>Valorant</dd>
          <dt>{tr("Map", "Map")}</dt>
          <dd>
            <select value={match?.map ?? ""} onchange={(e) => gamer.run(() => games.setMatch(e.currentTarget.value || null, match?.myAgent ?? null), tr("Kon de map niet zetten", "Could not set the map"))}>
              <option value="">{tr("Onbekend", "Unknown")}</option>
              {#each catalog?.maps ?? [] as m (m)}<option value={m}>{m}</option>{/each}
            </select>
          </dd>
          <dt>{tr("Mijn agent", "My agent")}</dt>
          <dd>
            <select value={match?.myAgent ?? ""} onchange={(e) => gamer.run(() => games.setMatch(match?.map ?? null, e.currentTarget.value || null), tr("Kon je agent niet zetten", "Could not set your agent"))}>
              <option value="">{tr("Onbekend", "Unknown")}</option>
              {#each catalog?.agents ?? [] as a (a.id)}<option value={a.id}>{a.name}</option>{/each}
            </select>
          </dd>
          <dt>{tr("Ronde", "Round")}</dt><dd>{round}</dd>
          <dt>{tr("Status", "Session status")}</dt><dd>{status}</dd>
          <dt>Gamer Mode</dt>
          <dd>
            <OnOffSwitch
              on={view.prefs.enabled}
              label="Gamer Mode"
              onchange={(value) => gamer.run(() => games.savePrefs({ ...view.prefs, enabled: value }), tr("Kon Gamer Mode niet wijzigen", "Could not change Gamer Mode"))}
            />
          </dd>
          <dt>{tr("Laatst gekeken", "Last look")}</dt><dd>{time(view.lastLook)}</dd>
        </dl>
        {#if view.lastError}<p class="err">{view.lastError}</p>{/if}
        {#if !canSee}<p class="faint note">{tr("Op dit apparaat kan Nook niet naar het scherm kijken; log gebeurtenissen zelf hieronder.", "Nook can't look at the screen on this device; log events yourself below.")}</p>{/if}
      </section>

      <section class="card">
        <h3>{tr("Recente coaching", "Recent coaching")}</h3>
        {#each (analysis?.insights ?? []).slice(0, 5) as insight (insight.id)}
          {@const text = coachingText(insight, lang)}
          <article class="insight {insight.severity}">
            <strong><span aria-hidden="true">{icon(insight.severity)}</span> {text.title}</strong>
            <p>{text.body}</p>
            <span class="faint small">{tr("Ronde", "Round")} {insight.round}</span>
          </article>
        {:else}
          <p class="faint">{tr("Nog geen advies. Nook leert de tegenstander per ronde kennen.", "No advice yet. Nook learns the other team round by round.")}</p>
        {/each}
      </section>

      <section class="card">
        <h3>{tr("Patronen van de tegenstander", "Enemy patterns")}</h3>
        {#each patterns as p (p.key)}
          <article class="pattern" class:faded={p.status.state !== "active"}>
            <div class="line"><strong>{p.agentName}</strong><span class="badge {p.status.state}">{statusLabel(p.status, p.occurrences, lang)}</span></div>
            <div>{p.abilityName} · {p.location}</div>
            <div class="faint small">
              {tr(`${p.occurrences} keer gebruikt`, `Used ${p.occurrences} times`)} · {tr("rondes", "rounds")} {p.rounds.join(", ")}
              {#if p.typicalTime !== null} · ~{clock(p.typicalTime)}{/if}
              · {tr("Zekerheid", "Confidence")}: {confidenceLabel(p.confidence, lang)}
            </div>
          </article>
        {:else}
          <p class="faint">{tr("Nog geen herhaling gezien.", "No repeats seen yet.")}</p>
        {/each}
        {#if seenOnce > 0}<p class="faint small">{tr(`${seenOnce} setup(s) één keer gezien.`, `${seenOnce} setup(s) seen once.`)}</p>{/if}
      </section>

      <section class="card">
        <h3>{tr("Mijn gewoontes", "My habits")}</h3>
        {#each analysis?.habits ?? [] as habit, i (i)}
          {@const text = habitText(habit, lang)}
          <article class="insight warning"><strong>{text.title}</strong><p>{text.body}</p></article>
        {:else}
          <p class="faint">{tr("Geen terugkerende fouten. Mooi zo.", "No recurring mistakes. Nice.")}</p>
        {/each}
      </section>

      {#if analysis?.general.length}
        <section class="card">
          <h3>{tr("Algemene kennis", "General knowledge")}</h3>
          <p class="faint small">{tr("Over de agents van de tegenstander, niet uit dit potje.", "About the enemy agents, not from this match.")}</p>
          <ul>{#each analysis.general as tip (tip.agentName + tip.abilityName)}<li>{generalText(tip, lang)}</li>{/each}</ul>
        </section>
      {/if}

      <section class="card wide">
        <h3>{tr("Gebeurtenis loggen", "Log an event")}</h3>
        {#if catalog}<LogEvent {catalog} {round} />{/if}
      </section>

      <section class="card wide">
        <h3>{tr("Geheugen van dit potje", "Match memory")}</h3>
        {#each [...(match?.rounds ?? [])].reverse() as r (r.number)}
          <div class="round">
            <div class="line"><strong>{tr("Ronde", "Round")} {r.number}</strong><span class="faint small">{r.closed ? tr("klaar", "done") : tr("bezig", "in progress")}</span></div>
            {#each r.events as e (e.id)}
              <div class="event">
                <span>
                  {#if e.kind === "utility"}{agentName(e.agent)} · {abilityName(e.agent, e.ability)} · {e.location} · {effectLabel(e.effect)}
                  {:else if e.kind === "death"}{tr("Dood bij", "Died at")} {e.location}
                  {:else}{tr("Kill bij", "Kill at")} {e.location}{/if}
                  {#if e.roundTime !== null}<span class="faint"> · {clock(e.roundTime)}</span>{/if}
                  <span class="faint"> · {e.source === "screen" ? `${tr("scherm", "screen")} ${Math.round(e.confidence * 100)}%` : tr("zelf gelogd", "logged")}</span>
                </span>
                <button class="ghost small" title={tr("Vergeet dit", "Forget this")} onclick={() => gamer.run(() => games.remove(e.id), tr("Kon het niet vergeten", "Could not forget it"))}>✕</button>
              </div>
            {:else}
              <p class="faint small">{tr("Niets gezien.", "Nothing seen.")}</p>
            {/each}
          </div>
        {/each}
        {#if view.history.length}
          <h3>{tr("Eerdere potjes", "Earlier matches")}</h3>
          <p class="faint small">{tr("Apart bewaard; ze tellen niet mee voor dit potje.", "Kept apart; they don't count toward this match.")}</p>
          {#each view.history.slice(0, 5) as h (h.id)}
            <div class="event"><span>{new Date(h.started).toLocaleDateString(english() ? "en-GB" : "nl-NL")} · {h.map ?? "?"} · {agentName(h.myAgent)} · {h.rounds} {tr("rondes", "rounds")} · {h.patterns} {tr("patronen", "patterns")}</span></div>
          {/each}
        {/if}
      </section>
    </div>
  {:else}
    <p class="faint pad">{tr("Laden…", "Loading…")}</p>
  {/if}
</div>

<style>
  .coach { display: flex; flex-direction: column; height: 100%; min-height: 0; }
  header { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; padding: 14px clamp(16px, 3vw, 32px); border-bottom: 1px solid var(--line); }
  header h2 { margin: 0; font-size: 18px; font-weight: 600; }
  .icon-button { display: grid; place-items: center; width: 32px; height: 32px; padding: 0; }
  .pill { display: inline-flex; align-items: center; gap: 7px; font-size: 12px; color: var(--text2); background: var(--smoke); border: 1px solid var(--line2); border-radius: 999px; padding: 4px 10px; }
  .pill .dot { background: var(--text3); }
  .spacer { flex: 1; }
  .grid { flex: 1; overflow-y: auto; display: grid; grid-template-columns: repeat(auto-fill, minmax(300px, 1fr)); gap: 12px; padding: 20px clamp(16px, 3vw, 32px) 40px; align-content: start; }
  .card { background: var(--graphite); border: 1px solid var(--line2); border-radius: var(--radius); padding: 14px 16px; min-width: 0; }
  .card.wide { grid-column: 1 / -1; }
  .card h3 { margin: 0 0 10px; font-size: 13px; color: var(--text2); font-weight: 600; }
  dl { display: grid; grid-template-columns: auto 1fr; gap: 8px 14px; margin: 0; align-items: center; font-size: 13px; }
  dt { color: var(--text3); }
  dd { margin: 0; }
  dd select { width: 100%; }
  .insight { border-left: 3px solid var(--line2); padding: 6px 0 6px 10px; margin-bottom: 10px; }
  .insight.warning { border-color: var(--amber); }
  .insight.success { border-color: var(--mint); }
  .insight p { margin: 4px 0; font-size: 12.5px; line-height: 1.45; color: var(--text2); user-select: text; }
  .pattern { padding: 8px 0; border-bottom: 1px solid var(--line); font-size: 13px; display: flex; flex-direction: column; gap: 3px; }
  .pattern:last-of-type { border-bottom: none; }
  .pattern.faded { opacity: .7; }
  .line { display: flex; justify-content: space-between; align-items: center; gap: 8px; }
  .badge { font-size: 11px; border-radius: 999px; padding: 2px 8px; background: var(--smoke); color: var(--text2); }
  .badge.active { color: var(--amber); }
  .badge.changed { color: var(--violet); }
  .small { font-size: 11.5px; }
  ul { margin: 6px 0 0; padding-left: 18px; font-size: 12.5px; color: var(--text2); line-height: 1.5; }
  .round { padding: 8px 0; border-bottom: 1px solid var(--line); }
  .event { display: flex; justify-content: space-between; align-items: center; gap: 8px; font-size: 12.5px; padding: 3px 0; user-select: text; }
  .event button { padding: 2px 8px; }
  .err { color: var(--coral); font-size: 12px; user-select: text; }
  .note { font-size: 12px; }
  .pad { padding: 24px; }
  @media (max-width: 640px) {
    .grid { grid-template-columns: 1fr; padding: 12px; }
  }
</style>
