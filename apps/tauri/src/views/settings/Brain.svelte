<script lang="ts">
  // Brein: welke AI denkt. Lokaal eerst; een externe AI is een bewuste keuze.
  import { openUrl } from "@tauri-apps/plugin-opener";
  import { api } from "../../lib/api";
  import { brainApi, type EvalResult } from "../../lib/brain";
  import ModelAdvice from "../../components/ModelAdvice.svelte";
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

  // Testen en meten.
  let testing = $state(false);
  let testResult = $state<{ ok: boolean; text: string } | null>(null);
  let evalRunning = $state(false);
  let evalProgress = $state<[number, number] | null>(null);
  let evalResults = $state<EvalResult[] | null>(null);
  const passed = $derived(evalResults?.filter((r) => r.passed).length ?? 0);

  async function test() {
    testing = true;
    testResult = null;
    try {
      testResult = { ok: true, text: await brainApi.test() };
    } catch (e) {
      testResult = { ok: false, text: String(e) };
    } finally {
      testing = false;
    }
  }

  async function evaluate() {
    evalRunning = true;
    evalResults = null;
    const un = await brainApi.onEval((p) => (evalProgress = p));
    try {
      evalResults = await brainApi.evaluate();
    } finally {
      un();
      evalRunning = false;
      evalProgress = null;
    }
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

{#if current?.isLocal || !nook.info?.brainReady}
  <h3>Lokaal model voor deze computer</h3>
  <ModelAdvice />
{/if}

<h3>Antwoorden</h3>
<div class="group">
  <label class="row"><span>Eerst bewijs zoeken, dan antwoorden<br /><span class="faint small">Nook haalt eerst de relevante zinnen uit je bronnen en antwoordt alleen daarmee.</span></span><input type="checkbox" checked={s.evidenceFirst} onchange={(e) => nook.saveSettings({ evidenceFirst: e.currentTarget.checked })} /></label>
  <label class="row"><span>Antwoorden controleren<br /><span class="faint small">Een antwoord dat niet op de bronnen steunt, vraagt Nook één keer opnieuw.</span></span><input type="checkbox" checked={s.checkAnswers} onchange={(e) => nook.saveSettings({ checkAnswers: e.currentTarget.checked })} /></label>
  <div class="row">
    <span>Werkt dit brein?{#if testResult}<br /><span class="small" class:ok={testResult.ok} class:err={!testResult.ok}>{testResult.text}</span>{/if}</span>
    <button onclick={test} disabled={testing}>{testing ? "Testen…" : "Test"}</button>
  </div>
  <div class="row">
    <span>Meet dit brein<br /><span class="faint small">Twintig vragen met bekende antwoorden: hoe goed gebruikt dit model je bronnen?</span></span>
    <button onclick={evaluate} disabled={evalRunning}>{evalRunning ? `Bezig ${evalProgress ? `${evalProgress[0]}/${evalProgress[1]}` : "…"}` : "Meet"}</button>
  </div>
</div>
{#if evalResults}
  <p class="note"><strong>{passed} van {evalResults.length}</strong> goed.</p>
  <div class="group">
    {#each evalResults as r (r.id)}
      <details class="row eval">
        <summary><span class:ok={r.passed} class:err={!r.passed}>{r.passed ? "✓" : "✗"}</span> {r.question}</summary>
        <p class="small">{r.answer}</p>
        {#if r.missing.length}<p class="small err">Mist: {r.missing.join(", ")}</p>{/if}
        {#if r.forbidden.length}<p class="small err">Had niet mogen zeggen: {r.forbidden.join(", ")}</p>{/if}
      </details>
    {/each}
  </div>
{/if}

<style>
  .small { font-size: 11px; }
  .ok { color: var(--mint); }
  .eval { display: block; }
  .eval summary { cursor: pointer; }
  .eval p { margin: 6px 0 0; white-space: pre-wrap; }
</style>
