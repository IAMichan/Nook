<script lang="ts">
  // The brain chip in the composer (the Mac's `BrainChip`): the model Nook thinks with, and behind it the one model
  // picker of Nook (`ModelPicker`): a rail of places on the left (this computer, then each agent Nook can think through
  // with your own sign-in, as its logo) with a "+" at its foot that opens Settings › Brain, and on the right the shown
  // place's column: its name, a line about it, a search field and the models, with a star for favorites.
  import { api } from "../lib/api";
  import { brainApi, type ServerModel } from "../lib/brain";
  import { nook } from "../lib/state.svelte";
  import { tr } from "../lib/i18n.svelte";
  import { brandFor } from "../lib/brand-logos";
  import Ico from "./ui/Ico.svelte";
  import Dropdown from "./ui/Dropdown.svelte";
  import DropdownRow from "./ui/DropdownRow.svelte";
  import AgentMark from "../views/companion/ui/AgentMark.svelte";
  import type { ProviderInfo } from "../lib/types";
  import { activeModel, loadFavorites, models, pillText, placeOf, places, toggleFavorite, type PickerModel } from "../lib/brain-chip";

  let open = $state(false);
  let servers = $state<ServerModel[]>([]);
  let providers = $state<ProviderInfo[]>([]);
  let place = $state("local");
  let query = $state("");
  let highlight = $state(0);
  let favorites = $state(new Set<string>());

  $effect(() => {
    api.providers().then((p) => (providers = p));
  });

  const settings = $derived(nook.settings);
  const local = $derived(nook.info?.brainLocal ?? false);
  const ready = $derived(nook.info?.brainReady ?? false);
  const text = $derived(settings ? pillText(settings, providers, tr("Geen model gekozen", "No model chosen")) : (nook.info?.brainLabel ?? ""));
  const rail = $derived(places(providers, tr("Op deze computer", "On this computer")));
  const chosenPlace = $derived(settings ? placeOf(settings, providers) : "local");
  const list = $derived(settings ? models(place, settings, providers, servers, query, favorites) : []);
  const shown = $derived(rail.find((r) => r.id === place));
  /** The maker's mark on the pill: the agent's, or the local model's own when its name says it. */
  const pillBrand = $derived.by(() => {
    if (!settings) return null;
    const info = providers.find((p) => p.id === settings.provider);
    if (!local && info) return info.title;
    const model = activeModel(settings, providers);
    return model && brandFor(model.toLowerCase()) ? model : null;
  });

  async function opened() {
    if (!settings) return;
    place = chosenPlace;
    query = "";
    highlight = 0;
    favorites = loadFavorites(place);
    servers = (await brainApi.advice()).servers;
  }

  function choosePlace(id: string) {
    place = id;
    query = "";
    highlight = 0;
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

  function openSettings() {
    open = false;
    localStorage.setItem("settings.section", "brain");
    api.showMain("settings");
  }

  // ↑/↓ move over the models while the search keeps the keyboard; Return picks the highlighted one.
  function keys(e: KeyboardEvent) {
    if (e.key === "ArrowDown") { e.preventDefault(); highlight = Math.min(highlight + 1, list.length - 1); }
    else if (e.key === "ArrowUp") { e.preventDefault(); highlight = Math.max(highlight - 1, 0); }
    else if (e.key === "Enter" && list[highlight]) { e.preventDefault(); pick(list[highlight]); }
  }

  function focusOnMount(node: HTMLInputElement) {
    node.focus();
  }
</script>

<Dropdown bind:open width={340} onopen={opened} label={tr("Brein kiezen", "Choose the brain")}>
  {#snippet trigger({ toggle, open })}
    <!-- The brain chip as the Mac's (`ComposerPill`): its mark and the model, a chevron for the panel. -->
    <button class="composer-pill" class:off={!ready} class:open onclick={toggle}
      title={`${local ? tr("Lokaal: blijft op je computer, kost niets per vraag.", "Local: stays on your computer, costs nothing per question.") : tr("Extern: je vragen gaan naar deze dienst.", "External: your questions go to this service.")}${ready ? "" : "\n" + tr("Niet klaar", "Not ready")}`}
      aria-label={tr("Het model waarmee Nook nu denkt", "The model Nook thinks with right now")} aria-expanded={open}>
      {#if pillBrand}<AgentMark agent={pillBrand} size={14} />{:else}<Ico name="cpu" size={15} />{/if}<span>{text}</span><Ico name="chevron-down" size={10} stroke={2.5} />
    </button>
  {/snippet}
  {#snippet children()}
    <div class="picker">
      <div class="rail">
        {#each rail as p, i (p.id)}
          {#if i === 1}<span class="rail-line" aria-hidden="true"></span>{/if}
          <button class="place" class:on={p.id === place} onclick={() => choosePlace(p.id)} title={p.name} aria-label={p.name} aria-pressed={p.id === place}>
            {#if p.isLocal}<Ico name="laptop" size={16} />{:else}<AgentMark agent={p.name} size={18} />{/if}
            {#if p.id === chosenPlace && p.id !== place}<span class="dot" aria-hidden="true"></span>{/if}
          </button>
        {/each}
        <span class="rail-space"></span>
        <button class="place add" onclick={openSettings} title={tr("Een model of dienst toevoegen in Brein-instellingen", "Add a model or service in Brain settings")} aria-label={tr("Toevoegen", "Add")}><Ico name="plus" size={14} /></button>
      </div>
      <div class="column">
        <div class="dd-header">{shown?.name ?? ""}</div>
        {#if shown?.isLocal}
          <p class="place-detail">{tr("Blijft op je computer. Kost niets per vraag.", "Stays on your computer. Costs nothing per question.")}</p>
        {/if}
        <label class="search">
          <Ico name="search" size={14} />
          <input use:focusOnMount bind:value={query} oninput={() => (highlight = 0)} onkeydown={keys} placeholder={tr("Zoek modellen…", "Search models…")} aria-label={tr("Zoek modellen", "Search models")} />
        </label>
        <div class="list">
          {#each list as m, i (m.id)}
            <DropdownRow brand={brandFor(m.title.toLowerCase()) ? m.title : undefined} symbol={brandFor(m.title.toLowerCase()) ? undefined : (place === "local" ? "cpu" : undefined)}
              title={m.title} trailing={m.trailing} chosen={m.chosen} highlighted={i === highlight && query.length > 0}
              favorite={favorites.has(m.id)} onstar={() => (favorites = toggleFavorite(place, m.id))} onclick={() => pick(m)} />
          {:else}
            <p class="empty">{place === "local" ? tr("Nog geen model op deze computer. Kies er een in Brein-instellingen.", "No model on this computer yet. Choose one in Brain settings.") : tr("Geen modellen gevonden", "No models found")}</p>
          {/each}
        </div>
      </div>
    </div>
  {/snippet}
</Dropdown>

<style>
  .off { color: var(--amber); }
  /* The panel's own padding goes: the rail runs to its edges, as `ModelPicker` draws it. */
  .picker { display: flex; align-items: stretch; margin: calc(-1 * var(--space-4)); min-height: 0; }
  .rail {
    display: flex; flex-direction: column; align-items: center; gap: var(--space-4); width: 44px; flex: none;
    padding: var(--space-6); background: color-mix(in srgb, var(--paper) 3%, transparent); border-right: 1px solid var(--line2);
  }
  .rail-line { width: 18px; height: 1px; margin: var(--space-2) 0; background: var(--line2); flex: none; }
  .rail-space { flex: 1; }
  .place {
    position: relative; display: grid; place-items: center; width: 32px; height: 32px; flex: none; padding: 0; margin: 0;
    border: 0; border-radius: var(--radius-control); background: transparent; color: var(--paper);
  }
  .place:hover { background: var(--smoke); }
  .place.on { background: color-mix(in srgb, var(--paper) 8%, transparent); }
  .place.add { color: var(--text3); }
  .dot { position: absolute; top: var(--space-4); right: var(--space-4); width: 4px; height: 4px; border-radius: 50%; background: color-mix(in srgb, var(--paper) 70%, transparent); }
  .column { display: flex; flex-direction: column; flex: 1; min-width: 0; padding: 0 var(--space-4) var(--space-4); }
  .place-detail { margin: 0; padding: 0 var(--space-8) var(--space-4); font: var(--text-detail); color: var(--text3); }
  .search { display: flex; align-items: center; gap: var(--space-6); padding: var(--space-6) var(--space-8); border-bottom: 1px solid var(--line2); color: var(--text3); }
  .search input { flex: 1; min-width: 0; padding: 0; margin: 0; border: 0; outline: 0; background: transparent; font: var(--text-body); color: var(--paper); box-shadow: none; }
  .search input::placeholder { color: var(--text3); }
  .list { max-height: 240px; overflow-y: auto; padding: var(--space-4) 0; }
  .empty { margin: 0; padding: 10px; font: var(--text-detail); color: var(--text3); }
</style>
