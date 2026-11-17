<script lang="ts">
  // The brain chip under the composer (the Mac's `BrainChip`): the model Nook thinks with, and behind it a picker with a
  // rail of places (this computer, and each agent Nook can think through with your own sign-in), a search, and stars.
  // A service with an API key is set up in Settings › Brain.
  import { api } from "../lib/api";
  import { brainApi, type ServerModel } from "../lib/brain";
  import { nook } from "../lib/state.svelte";
  import { tr } from "../lib/i18n.svelte";
  import type { ProviderInfo } from "../lib/types";
  import { loadFavorites, models, pillText, placeOf, places, toggleFavorite, type PickerModel } from "../lib/brain-chip";

  let open = $state(false);
  let root = $state<HTMLDivElement>();
  let servers = $state<ServerModel[]>([]);
  let providers = $state<ProviderInfo[]>([]);
  let place = $state("local");
  let query = $state("");
  let favorites = $state(new Set<string>());

  $effect(() => {
    api.providers().then((p) => (providers = p));
  });

  const settings = $derived(nook.settings);
  const local = $derived(nook.info?.brainLocal ?? false);
  const ready = $derived(nook.info?.brainReady ?? false);
  const text = $derived(settings ? pillText(settings, providers, tr("eerste model", "first model")) : (nook.info?.brainLabel ?? ""));
  const rail = $derived(places(providers, tr("Op deze computer", "On this computer")));
  const list = $derived(settings ? models(place, settings, providers, servers, query, favorites) : []);

  async function toggle() {
    open = !open;
    if (!open || !settings) return;
    place = placeOf(settings, providers);
    query = "";
    favorites = loadFavorites(place);
    servers = (await brainApi.advice()).servers;
  }

  function choosePlace(id: string) {
    place = id;
    favorites = loadFavorites(id);
  }

  async function pick(model: PickerModel) {
    open = false;
    if (model.pick.kind === "local") {
      nook.settings = await brainApi.useLocal(model.pick.server, model.pick.name);
    } else {
      const { provider, model: name } = model.pick;
      await nook.saveSettings((s) => ({ provider: provider as typeof s.provider, providerModels: { ...s.providerModels, [provider]: name } }));
    }
    nook.info = await api.appInfo();
  }

  function star(e: MouseEvent, id: string) {
    e.stopPropagation();
    favorites = toggleFavorite(place, id);
  }

  function openSettings() {
    open = false;
    localStorage.setItem("settings.section", "brain");
    api.showMain("settings");
  }
</script>

<svelte:window onclick={(e) => open && !root?.contains(e.target as Node) && (open = false)} />

<div class="brain" bind:this={root}>
  <button class="chip" class:local class:off={!ready} onclick={toggle}
    title={tr("Het model waarmee Nook nu denkt. Lokaal: blijft op je computer, kost niets per vraag.", "The model Nook thinks with right now. Local: stays on your computer, costs nothing per question.")}>
    {local ? tr("● lokaal", "● local") : tr("○ extern", "○ external")} · {text}{ready ? "" : tr(" · niet klaar", " · not ready")}
  </button>
  {#if open}
    <div class="menu" role="dialog" aria-label={tr("Brein kiezen", "Choose the brain")}>
      <div class="rail">
        {#each rail as p (p.id)}
          <button class="ghost place" class:on={p.id === place} onclick={() => choosePlace(p.id)}>{p.name}</button>
        {/each}
      </div>
      <div class="models">
        <input class="search" placeholder={tr("Zoek een model", "Search models")} bind:value={query} />
        <p class="faint detail">
          {place === "local"
            ? tr("Blijft op je computer. Kost niets per vraag.", "Stays on your computer. Costs nothing per question.")
            : tr("Je vragen gaan naar {name}. Bronnen die alleen op deze computer mogen, blijven hier.", "Your questions go to {name}. Sources kept on this computer stay here.", { name: rail.find((r) => r.id === place)?.name ?? "" })}
        </p>
        {#each list as m (m.id)}
          <div class="row" class:chosen={m.chosen}>
            <button class="ghost item" onclick={() => pick(m)}>
              <span>{m.chosen ? "✓ " : ""}{m.title}</span>
              {#if m.trailing}<span class="faint">{m.trailing}</span>{/if}
            </button>
            <button class="ghost star" class:on={favorites.has(m.id)} onclick={(e) => star(e, m.id)}
              aria-label={favorites.has(m.id) ? tr("Uit favorieten", "Remove from favourites") : tr("Favoriet", "Favourite")}>{favorites.has(m.id) ? "★" : "☆"}</button>
          </div>
        {:else}
          <p class="faint item">{place === "local" ? tr("Nog geen model op deze computer. Kies er een in Brein-instellingen.", "No model on this computer yet. Choose one in Brain settings.") : tr("Geen modellen gevonden.", "No models found.")}</p>
        {/each}
        <div class="sep"></div>
        <button class="ghost item" onclick={openSettings}>{tr("Brein-instellingen…", "Brain settings…")}</button>
      </div>
    </div>
  {/if}
</div>

<style>
  .brain { position: relative; min-width: 0; margin-left: auto; max-width: 100%; }
  .chip { max-width: 100%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 11px; padding: 2px 8px; border-radius: 999px; background: none; color: var(--text3); }
  .chip.local { color: var(--text2); }
  .chip.off { color: var(--amber); }
  .menu { position: absolute; bottom: 32px; right: 0; display: flex; gap: 6px; width: min(460px, 86vw); max-height: 360px; box-shadow: var(--shadow-popover); z-index: 20; background: var(--smoke); border: 1px solid var(--line2); border-radius: 10px; padding: 6px; }
  .rail { display: flex; flex-direction: column; gap: 2px; min-width: 130px; border-right: 1px solid var(--line2); padding-right: 6px; overflow-y: auto; }
  .place { text-align: left; font-size: 12px; padding: 4px 6px; margin: 0; color: var(--text2); }
  .place.on { color: var(--paper); background: var(--row-hover); }
  .models { flex: 1; min-width: 0; overflow-y: auto; }
  .search { width: 100%; font-size: 12px; margin-bottom: 4px; }
  .detail { font-size: 11px; margin: 2px 6px 6px; }
  .row { display: flex; align-items: center; }
  .item { display: flex; justify-content: space-between; gap: 8px; flex: 1; min-width: 0; text-align: left; font-size: 12px; padding: 4px 6px; margin: 0; }
  .row.chosen .item { color: var(--paper); }
  .star { font-size: 12px; padding: 2px 6px; margin: 0; color: var(--text3); }
  .star.on { color: var(--amber); }
  .sep { border-top: 1px solid var(--line2); margin: 4px 0; }
  @media (max-width: 640px) {
    .brain { margin-left: 0; }
    .menu { left: 0; right: auto; }
  }
</style>
