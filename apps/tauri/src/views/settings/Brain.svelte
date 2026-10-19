<script lang="ts">
  // Brein: welke AI denkt. Lokaal eerst; een externe AI is een bewuste keuze.
  import { openUrl } from "@tauri-apps/plugin-opener";
  import { api } from "../../lib/api";
  import { nook } from "../../lib/state.svelte";
  import type { ProviderId, ProviderInfo } from "../../lib/types";

  let providers = $state<ProviderInfo[]>([]);
  let models = $state<string[]>([]);
  let modelError = $state<string | null>(null);
  let keyMask = $state<string | null>(null);
  let keyInput = $state("");

  const s = $derived(nook.settings!);
  const current = $derived(providers.find((p) => p.id === s.provider));
  const model = $derived(s.providerModels[s.provider] ?? current?.defaultModel ?? "");

  $effect(() => {
    api.providers().then((p) => (providers = p));
  });

  $effect(() => {
    const id = s.provider;
    models = [];
    modelError = null;
    keyInput = "";
    api.keyStatus(id).then((m) => (keyMask = m));
  });

  async function fetchModels() {
    modelError = null;
    try {
      models = await api.listModels(s.provider);
      if (!models.length) modelError = "Geen modellen gevonden.";
    } catch (e) {
      modelError = String(e);
    }
  }

  async function saveKey() {
    keyMask = await api.setKey(s.provider, keyInput);
    keyInput = "";
    nook.info = await api.appInfo();
  }

  function setModel(m: string) {
    nook.saveSettings({ providerModels: { ...s.providerModels, [s.provider]: m } });
  }

  function chooseProvider(id: ProviderId) {
    nook.saveSettings({ provider: id });
  }
</script>

<h2>Brein</h2>
<p class="muted">Lokaal eerst: met Ollama of LM Studio verlaat niets je computer en kost het niets per vraag. Een externe AI kies je bewust; Nook schakelt nooit zelf naar de cloud.</p>
<div class="providers">
  {#each providers as p (p.id)}
    <button class="provider" class:on={p.id === s.provider} onclick={() => chooseProvider(p.id)}>
      <span>{p.title}</span>
      <span class="faint">{p.isLocal ? "op deze computer" : p.needsKey ? "API-sleutel" : "abonnement"}</span>
    </button>
  {/each}
</div>
{#if current}
  <div class="group">
    {#if current.needsKey}
      <div class="row">
        <span>Sleutel</span>
        <div class="inline">
          {#if keyMask}<code>{keyMask}</code>{/if}
          <input type="password" placeholder={current.keyPlaceholder} bind:value={keyInput} />
          <button onclick={saveKey} disabled={!keyInput.trim() && !keyMask}>{keyInput.trim() ? "Bewaar" : "Weghalen"}</button>
        </div>
      </div>
      <p class="faint note">De sleutel staat in de kluis van je systeem (Windows Referentiebeheer, GNOME Keyring/KWallet), nooit in een bestand. <a href={current.keyUrl} onclick={(e) => { e.preventDefault(); openUrl(current.keyUrl); }}>Sleutel maken</a></p>
    {:else if current.isLocal}
      <p class="faint note">Draait {current.title.split(" (")[0]} nog niet? <a href={current.keyUrl} onclick={(e) => { e.preventDefault(); openUrl(current.keyUrl); }}>Download</a> en start hem, en haal dan de modellen op.</p>
    {/if}
    <div class="row">
      <span>Model</span>
      <div class="inline">
        <input value={model} onchange={(e) => setModel(e.currentTarget.value)} list="models" />
        <datalist id="models">
          {#each [...new Set([...current.suggestedModels, ...models])] as m (m)}<option value={m}></option>{/each}
        </datalist>
        <button onclick={fetchModels}>Modellen ophalen</button>
      </div>
    </div>
    {#if models.length}
      <div class="models">
        {#each models as m (m)}<button class:on={m === model} onclick={() => setModel(m)}>{m}</button>{/each}
      </div>
    {/if}
    {#if modelError}<p class="err">{modelError}</p>{/if}
    {#if s.provider === "claude"}
      <label class="row"><span>Zoeken op het web</span><input type="checkbox" checked={s.webSearch} onchange={(e) => nook.saveSettings({ webSearch: e.currentTarget.checked })} /></label>
    {/if}
  </div>
{/if}
      
