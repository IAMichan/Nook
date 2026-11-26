<script lang="ts">
  // The brain chip in the composer (the Mac's `BrainChip`): the model Nook thinks with, opening the one shared
  // `ModelPickerDropdown` (this computer's local models, then each agent Nook can think through with your own sign-in).
  import { api } from "../lib/api";
  import { brainApi, type ServerModel } from "../lib/brain";
  import { nook } from "../lib/state.svelte";
  import { tr } from "../lib/i18n.svelte";
  import { brandFor } from "../lib/brand-logos";
  import type { ModelPickerList, ModelPickerPlace } from "../lib/model-picker";
  import Ico from "./ui/Ico.svelte";
  import ModelPickerDropdown from "./ui/ModelPickerDropdown.svelte";
  import AgentMark from "../views/companion/ui/AgentMark.svelte";
  import type { ProviderInfo } from "../lib/types";
  import { activeModel, loadFavorites, models, pillText, placeOf, places, toggleFavorite, type PickerModel } from "../lib/brain-chip";

  let open = $state(false);
  let servers = $state<ServerModel[]>([]);
  let providers = $state<ProviderInfo[]>([]);
  let favorites = $state(new Set<string>());

  $effect(() => {
    api.providers().then((p) => (providers = p));
  });

  const settings = $derived(nook.settings);
  const local = $derived(nook.info?.brainLocal ?? false);
  const ready = $derived(nook.info?.brainReady ?? false);
  const text = $derived(settings ? pillText(settings, providers, tr("Geen model gekozen", "No model chosen")) : (nook.info?.brainLabel ?? ""));
  const chosenPlace = $derived(settings ? placeOf(settings, providers) : "local");
  const rail = $derived<ModelPickerPlace[]>(
    places(providers, tr("Op deze computer", "On this computer")).map((p) => ({
      id: p.id,
      name: p.name,
      isLocal: p.isLocal,
      detail: p.isLocal ? tr("Blijft op je computer. Kost niets per vraag.", "Stays on your computer. Costs nothing per question.") : undefined,
    })),
  );
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
    servers = (await brainApi.advice()).servers;
  }

  function placeChanged(id: string) {
    favorites = loadFavorites(id);
  }

  async function pick(model: PickerModel) {
    if (model.pick.kind === "local") {
      nook.settings = await brainApi.useLocal(model.pick.server, model.pick.name);
    } else {
      const { provider, model: name } = model.pick;
      await nook.saveSettings((s) => ({ provider: provider as typeof s.provider, providerModels: { ...s.providerModels, [provider]: name } }));
    }
    nook.info = await api.appInfo();
  }

  function listFor(place: ModelPickerPlace, query: string): ModelPickerList {
    if (!settings) return { models: [] };
    const found = models(place.id, settings, providers, servers, query, favorites);
    return {
      models: found.map((m) => ({
        id: m.id,
        title: m.title,
        brand: brandFor(m.title.toLowerCase()) ? m.title : undefined,
        symbol: brandFor(m.title.toLowerCase()) ? undefined : (place.isLocal ? "cpu" : undefined),
        trailing: m.trailing,
        chosen: m.chosen,
        favorite: favorites.has(m.id),
        onstar: () => (favorites = toggleFavorite(place.id, m.id)),
        onpick: () => { void pick(m); },
      })),
      emptyNote: place.isLocal
        ? tr("Nog geen model op deze computer. Kies er een in Brein-instellingen.", "No model on this computer yet. Choose one in Brain settings.")
        : tr("Geen modellen gevonden", "No models found"),
    };
  }

  function openSettings() {
    localStorage.setItem("settings.section", "brain");
    api.showMain("settings");
  }
</script>

<ModelPickerDropdown
  bind:open
  places={rail}
  chosenId={chosenPlace}
  list={listFor}
  addHelp={tr("Een model of dienst toevoegen in Brein-instellingen", "Add a model or service in Brain settings")}
  onadd={openSettings}
  onopen={opened}
  onplacechange={placeChanged}
  label={tr("Brein kiezen", "Choose the brain")}
>
  {#snippet trigger({ toggle, open })}
    <!-- The brain chip as the Mac's (`ComposerPill`): its mark and the model, a chevron for the panel. -->
    <button class="composer-pill" class:off={!ready} class:open onclick={toggle}
      title={`${local ? tr("Lokaal: blijft op je computer, kost niets per vraag.", "Local: stays on your computer, costs nothing per question.") : tr("Extern: je vragen gaan naar deze dienst.", "External: your questions go to this service.")}${ready ? "" : "\n" + tr("Niet klaar", "Not ready")}`}
      aria-label={tr("Het model waarmee Nook nu denkt", "The model Nook thinks with right now")} aria-expanded={open}>
      {#if pillBrand}<AgentMark agent={pillBrand} size={14} />{:else}<Ico name="cpu" size={15} />{/if}<span>{text}</span><Ico name="chevron-down" size={10} stroke={2.5} />
    </button>
  {/snippet}
</ModelPickerDropdown>

<style>
  .off { color: var(--amber); }
</style>
