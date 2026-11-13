<script lang="ts">
  // Brein: welke AI denkt. Lokaal eerst; een externe AI is een bewuste keuze.
  import { openUrl } from "@tauri-apps/plugin-opener";
  import { api } from "../../lib/api";
  import { brainApi, type EvalResult } from "../../lib/brain";
  import ModelAdvice from "../../components/ModelAdvice.svelte";
  import { nook } from "../../lib/state.svelte";
  import type { ProviderId, ProviderInfo } from "../../lib/types";
  import { tr } from "../../lib/i18n.svelte";

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
      if (!models.length) modelError = tr("Geen modellen gevonden.", "No models found.");
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

<h2>{tr("Brein", "Brain")}</h2>
<p class="muted">{tr("Lokaal eerst: met Ollama of LM Studio verlaat niets je computer en kost het niets per vraag. Een externe AI kies je bewust; Nook schakelt nooit zelf naar de cloud.", "Local first: with Ollama or LM Studio nothing leaves your computer and nothing costs per question. You choose an external AI on purpose; Nook never switches to the cloud by itself.")}</p>
<div class="providers">
  {#each providers as p (p.id)}
    <button class="provider" class:on={p.id === s.provider} onclick={() => chooseProvider(p.id)}>
      <span>{p.title}</span>
      <span class="faint">{p.isLocal ? tr("op deze computer", "on this computer") : p.needsKey ? tr("API-sleutel", "API key") : tr("abonnement", "subscription")}</span>
    </button>
  {/each}
</div>
{#if current}
  <div class="group">
    {#if current.needsKey}
      <div class="row">
        <span>{tr("Sleutel", "Key")}</span>
        <div class="inline">
          {#if keyMask}<code>{keyMask}</code>{/if}
          <input type="password" placeholder={current.keyPlaceholder} bind:value={keyInput} />
          <button onclick={saveKey} disabled={!keyInput.trim() && !keyMask}>{keyInput.trim() ? tr("Bewaar", "Save") : tr("Weghalen", "Remove")}</button>
        </div>
      </div>
      <p class="faint note">{tr("De sleutel staat in de kluis van je systeem (Windows Referentiebeheer, GNOME Keyring/KWallet), nooit in een bestand.", "The key is kept in your system's keychain (Windows Credential Manager, GNOME Keyring/KWallet), never in a file.")} <a href={current.keyUrl} onclick={(e) => { e.preventDefault(); openUrl(current.keyUrl); }}>{tr("Sleutel maken", "Create a key")}</a></p>
    {:else if current.isLocal}
      <p class="faint note">{tr("Draait {name} nog niet?", "{name} not running yet?", { name: current.title.split(" (")[0] })} <a href={current.keyUrl} onclick={(e) => { e.preventDefault(); openUrl(current.keyUrl); }}>{tr("Download", "Download")}</a> {tr("en start hem, en haal dan de modellen op.", "and start it, then fetch the models.")}</p>
    {/if}
    <div class="row">
      <span>{tr("Model", "Model")}</span>
      <div class="inline">
        <input value={model} onchange={(e) => setModel(e.currentTarget.value)} list="models" />
        <datalist id="models">
          {#each [...new Set([...current.suggestedModels, ...models])] as m (m)}<option value={m}></option>{/each}
        </datalist>
        <button onclick={fetchModels}>{tr("Modellen ophalen", "Fetch models")}</button>
      </div>
    </div>
    {#if models.length}
      <div class="models">
        {#each models as m (m)}<button class:on={m === model} onclick={() => setModel(m)}>{m}</button>{/each}
      </div>
    {/if}
    {#if modelError}<p class="err">{modelError}</p>{/if}
    {#if s.provider === "claude"}
      <label class="row"><span>{tr("Zoeken op het web", "Search the web")}</span><input type="checkbox" checked={s.webSearch} onchange={(e) => nook.saveSettings({ webSearch: e.currentTarget.checked })} /></label>
    {/if}
  </div>
{/if}

{#if current?.isLocal || !nook.info?.brainReady}
  <h3>{tr("Lokaal model voor deze computer", "Local model for this computer")}</h3>
  <ModelAdvice />
{/if}

<h3>{tr("Antwoorden", "Answers")}</h3>
<div class="group">
  <label class="row"><span>{tr("Eerst bewijs zoeken, dan antwoorden", "Find evidence first, then answer")}<br /><span class="faint small">{tr("Nook haalt eerst de relevante zinnen uit je bronnen en antwoordt alleen daarmee.", "Nook first pulls the relevant sentences from your sources and answers only with those.")}</span></span><input type="checkbox" checked={s.evidenceFirst} onchange={(e) => nook.saveSettings({ evidenceFirst: e.currentTarget.checked })} /></label>
  <label class="row"><span>{tr("Antwoorden controleren", "Check answers")}<br /><span class="faint small">{tr("Een antwoord dat niet op de bronnen steunt, vraagt Nook één keer opnieuw.", "If an answer isn't backed by the sources, Nook asks once more.")}</span></span><input type="checkbox" checked={s.checkAnswers} onchange={(e) => nook.saveSettings({ checkAnswers: e.currentTarget.checked })} /></label>
  <div class="row">
    <span>{tr("Werkt dit brein?", "Does this brain work?")}{#if testResult}<br /><span class="small" class:ok={testResult.ok} class:err={!testResult.ok}>{testResult.text}</span>{/if}</span>
    <button onclick={test} disabled={testing}>{testing ? tr("Testen…", "Testing…") : tr("Test", "Test")}</button>
  </div>
  <div class="row">
    <span>{tr("Meet dit brein", "Measure this brain")}<br /><span class="faint small">{tr("Twintig vragen met bekende antwoorden: hoe goed gebruikt dit model je bronnen?", "Twenty questions with known answers: how well does this model use your sources?")}</span></span>
    <button onclick={evaluate} disabled={evalRunning}>{evalRunning ? (evalProgress ? tr("Bezig {done}/{total}", "Working {done}/{total}", { done: evalProgress[0], total: evalProgress[1] }) : tr("Bezig…", "Working…")) : tr("Meet", "Measure")}</button>
  </div>
</div>
{#if evalResults}
  <p class="note">{tr("{passed} van {total} goed.", "{passed} of {total} right.", { passed, total: evalResults.length })}</p>
  <div class="group">
    {#each evalResults as r (r.id)}
      <details class="row eval">
        <summary><span class:ok={r.passed} class:err={!r.passed}>{r.passed ? "✓" : "✗"}</span> {r.question}</summary>
        <p class="small">{r.answer}</p>
        {#if r.missing.length}<p class="small err">{tr("Mist: {items}", "Missing: {items}", { items: r.missing.join(", ") })}</p>{/if}
        {#if r.forbidden.length}<p class="small err">{tr("Had niet mogen zeggen: {items}", "Shouldn't have said: {items}", { items: r.forbidden.join(", ") })}</p>{/if}
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
