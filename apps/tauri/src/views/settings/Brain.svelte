<script lang="ts">
  // Brain (the Mac's `brainSection`): what Nook thinks with, said once at the top; then on this computer or an online
  // service, and each section below follows from that choice: for local the advised models, the connection check and
  // every other runtime folded away; for external the service, signing in, its model and who reads your screen.
  // Local first; an external AI is a choice made on purpose.
  import { invoke } from "@tauri-apps/api/core";
  import { listen } from "@tauri-apps/api/event";
  import { openUrl } from "@tauri-apps/plugin-opener";
  import { api } from "../../lib/api";
  import { brainApi } from "../../lib/brain";
  import Ico from "../../components/ui/Ico.svelte";
  import ModelAdvice from "../../components/ModelAdvice.svelte";
  import { nook } from "../../lib/state.svelte";
  import type { ProviderId, ProviderInfo } from "../../lib/types";
  import { tr } from "../../lib/i18n.svelte";
  import StatusRow from "./StatusRow.svelte";
  import InfoLabel from "./InfoLabel.svelte";
  import Segmented from "./Segmented.svelte";
  import Fold from "./Fold.svelte";

  interface LocalEvalCaseResult {
    id: string;
    question: string;
    answer: string;
    passed: boolean;
    missing: string[];
    forbidden: string[];
    seconds: number;
    usedEvidence: boolean;
    retriedGrounding: boolean;
  }

  interface LocalEvalProgress {
    done: number;
    total: number;
    currentId: string;
    latest: LocalEvalCaseResult | null;
  }

  interface LocalEvalReport {
    modelLabel: string;
    mode: string;
    evidenceFirst: boolean;
    checkAnswers: boolean;
    passed: number;
    total: number;
    scorePercent: number;
    totalSeconds: number;
    averageSeconds: number;
    finishedAt: string;
    historyLine: string;
    cancelled: boolean;
    failure: string | null;
    results: LocalEvalCaseResult[];
  }

  const EVAL_HISTORY_KEY = "nook.localEvalHistory";
  const MAX_EVAL_HISTORY = 12;

  function loadEvalHistory(): string[] {
    try {
      const raw = localStorage.getItem(EVAL_HISTORY_KEY);
      if (!raw) return [];
      const parsed = JSON.parse(raw);
      return Array.isArray(parsed) ? parsed.filter((x): x is string => typeof x === "string").slice(0, MAX_EVAL_HISTORY) : [];
    } catch {
      return [];
    }
  }

  function saveEvalHistory(lines: string[]) {
    try {
      localStorage.setItem(EVAL_HISTORY_KEY, JSON.stringify(lines.slice(0, MAX_EVAL_HISTORY)));
    } catch {
      /* storage unavailable */
    }
  }

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

  // OpenRouter: sign in on its own page instead of making a key (PKCE, the Mac's OpenRouterSignIn).
  let signingIn = $state(false);
  let signInError = $state<string | null>(null);
  async function openrouterSignIn() {
    signingIn = true;
    signInError = null;
    try {
      keyMask = await api.openrouterSignIn();
      nook.info = await api.appInfo();
    } catch (e) {
      signInError = String(e);
    } finally {
      signingIn = false;
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
    if (!providers.find((p) => p.id === id)?.isLocal) {
      try { localStorage.setItem("brain.external", id); } catch { /* remembering is a convenience */ }
    }
    nook.saveSettings({ provider: id });
  }

  // Local or external: switching goes back to the last one of that kind.
  const isLocal = $derived(current?.isLocal ?? true);
  const localProviders = $derived(providers.filter((p) => p.isLocal));
  const externalProviders = $derived(providers.filter((p) => !p.isLocal));
  function chooseKind(kind: "local" | "external") {
    if (kind === "local") {
      const id = localProviders[0]?.id;
      if (id) chooseProvider(id);
      return;
    }
    let last: string | null = null;
    try { last = localStorage.getItem("brain.external"); } catch { /* not remembered */ }
    const id = externalProviders.find((p) => p.id === last)?.id ?? externalProviders.find((p) => p.isSubscription)?.id ?? externalProviders[0]?.id;
    if (id) chooseProvider(id);
  }
  let foldOpen = $state(false);

  // Screen work: who reads the screen while an external brain answers (the Mac's ScreenBrainSection).
  let localModels = $state<string[]>([]);
  $effect(() => {
    if (current && !current.isLocal) {
      Promise.all([
        api.listModels("ollama").then((m) => m.map((x) => `ollama:${x}`)).catch(() => [] as string[]),
        api.listModels("lmstudio").then((m) => m.map((x) => `lmstudio:${x}`)).catch(() => [] as string[]),
      ]).then(([a, b]) => (localModels = [...a, ...b]));
    }
  });
  const chosenName = $derived(current?.title.split(" (")[0] ?? "");
  const screenKept = $derived(s.localOnlySources.includes("screen"));
  const screenChoice = $derived(screenKept ? s.screenBrain : "external");
  const screenOptions = $derived(s.screenBrain && !localModels.includes(s.screenBrain) ? [...localModels, s.screenBrain] : localModels);
  const workerName = $derived(s.screenBrain.split(":").slice(1).join(":"));

  function chooseScreen(value: string) {
    const others = s.localOnlySources.filter((x) => x !== "screen");
    if (value === "external") nook.saveSettings({ localOnlySources: others });
    else nook.saveSettings({ localOnlySources: [...others, "screen"], screenBrain: value });
  }

  // Testen en meten (`LocalEvalRunner` on the Mac).
  let testing = $state(false);
  let testResult = $state<{ ok: boolean; text: string } | null>(null);
  let evalRunning = $state(false);
  let evalDone = $state(0);
  let evalTotal = $state(20);
  let evalResults = $state<LocalEvalCaseResult[]>([]);
  let evalTotalSeconds = $state(0);
  let evalFailure = $state<string | null>(null);
  let evalHistory = $state<string[]>(loadEvalHistory());
  const passed = $derived(evalResults.filter((r) => r.passed).length);
  const evalGood = $derived(evalResults.length > 0 && passed * 4 >= evalResults.length * 3);

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
    if (evalRunning) return;
    evalRunning = true;
    evalDone = 0;
    evalTotal = 20;
    evalResults = [];
    evalTotalSeconds = 0;
    evalFailure = null;
    const un = await listen<LocalEvalProgress>("brain-local-eval", (e) => {
      evalDone = e.payload.done;
      evalTotal = e.payload.total;
      if (e.payload.latest) {
        evalResults = [...evalResults, e.payload.latest];
        evalTotalSeconds = evalResults.reduce((acc, item) => acc + item.seconds, 0);
      }
    });
    try {
      const report = await invoke<LocalEvalReport>("brain_local_eval_run", { caseIds: null });
      evalResults = report.results;
      evalDone = report.results.length;
      evalTotal = report.total;
      evalTotalSeconds = report.totalSeconds;
      evalFailure = report.failure;
      if (!report.cancelled && !report.failure && report.historyLine) {
        evalHistory = [report.historyLine, ...evalHistory].slice(0, MAX_EVAL_HISTORY);
        saveEvalHistory(evalHistory);
      }
    } catch (e) {
      evalFailure = String(e);
    } finally {
      un();
      evalRunning = false;
    }
  }

  async function cancelEval() {
    try {
      await invoke<boolean>("brain_local_eval_cancel");
    } catch {
      /* ignore */
    }
  }
</script>

<div class="group">
  <StatusRow done={!!nook.info?.brainReady}
    title={nook.info?.brainReady ? tr("Nook denkt met {name}.", "Nook thinks with {name}.", { name: nook.info?.brainLabel ?? "" }) : tr("Kies een brein", "Choose a brain")}
    detail={nook.info?.brainReady ? "" : tr("Claude, een andere AI of gratis op je computer.", "Claude, another AI, or free on your computer.")} />
</div>

<h3>{tr("Waar Nook denkt", "Where Nook thinks")}</h3>
<div class="group">
  <div class="row">
    <InfoLabel label={tr("Nook denkt", "Nook thinks")} info={tr("Lokaal eerst: met Ollama of LM Studio verlaat niets je computer en kost het niets per vraag. Een externe AI kies je bewust; Nook schakelt nooit zelf naar de cloud.", "Local first: with Ollama or LM Studio nothing leaves your computer and nothing costs per question. You choose an external AI on purpose; Nook never switches to the cloud by itself.")} />
    <Segmented label={tr("Nook denkt", "Nook thinks")} value={isLocal ? "local" : "external"} onchange={chooseKind}
      options={[{ value: "local", label: tr("Lokaal op je computer", "Locally on your computer") }, { value: "external", label: tr("Extern", "External") }]} />
  </div>
</div>
{#if !isLocal}<p class="note warn">{tr("Een externe AI krijgt je vraag en de context. Nook schakelt nooit vanzelf over.", "An external AI gets your question and its context. Nook never switches to one by itself.")}</p>{/if}

{#snippet connection()}
  <div class="row">
    <span>{tr("Verbinding", "Connection")}<br /><small>{#if testResult}<span class:ok={testResult.ok} class:err={!testResult.ok}>{testResult.text}</span>{:else}{tr("Laat het model een kort bericht beantwoorden, om te controleren of het werkt.", "Has the model answer a short message, to check that it works.")}{/if}</small></span>
    <button class="small" onclick={test} disabled={testing || !nook.info?.brainReady}>{testing ? tr("Testen…", "Testing…") : tr("Test verbinding", "Test connection")}</button>
  </div>
{/snippet}

{#if isLocal}
  <h3>{tr("Model", "Model")}</h3>
  <div class="group">
    <ModelAdvice rows />
    {@render connection()}
  </div>
  {#if current}
    <Fold keys={[tr("Draait met", "Runs with"), tr("Lokaal brein zelf starten", "Start the local brain myself")]} title={tr("Alle modellen en runtimes", "All models and runtimes")} summary={current.title.split(" (")[0]} bind:open={foldOpen}>
      {#if localProviders.length > 1}
        <div class="row">
          <span>{tr("Draait met", "Runs with")}</span>
          <Segmented label={tr("Draait met", "Runs with")} value={current.id} onchange={(id) => chooseProvider(id as ProviderId)}
            options={localProviders.map((p) => ({ value: p.id, label: p.title.split(" (")[0] }))} />
        </div>
      {/if}
      <p class="note">{tr("Draait {name} nog niet?", "{name} not running yet?", { name: current.title.split(" (")[0] })} <a href={current.keyUrl} onclick={(e) => { e.preventDefault(); openUrl(current.keyUrl); }}>{tr("Download", "Download")}</a> {tr("en start hem, en haal dan de modellen op.", "and start it, then fetch the models.")}</p>
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
      {#if models.length}
        <div class="models">
          {#each models as m (m)}<button class:on={m === model} onclick={() => setModel(m)}>{m}</button>{/each}
        </div>
      {/if}
      {#if modelError}<p class="note err">{modelError}</p>{/if}
      <label class="row">
        <span>{tr("Lokaal brein zelf starten", "Start the local brain myself")}<br /><small>{tr("Is Ollama of LM Studio geïnstalleerd maar niet gestart? Dan start Nook hem op de achtergrond.", "Ollama or LM Studio installed but not running? Then Nook starts it in the background.")}</small></span>
        <input type="checkbox" role="switch" checked={s.startLocalBrain} onchange={(e) => nook.saveSettings({ startLocalBrain: e.currentTarget.checked })} />
      </label>
    </Fold>
  {/if}
{:else if current}
  <h3>{tr("Dienst", "Service")}</h3>
  <div class="group">
    <div class="row">
      <InfoLabel label={tr("Aanbieder", "Provider")} info={tr("Een externe AI krijgt je vraag en de context. Nook schakelt nooit vanzelf over.", "An external AI gets your question and its context. Nook never switches to one by itself.")} />
      <select value={current.id} onchange={(e) => chooseProvider(e.currentTarget.value as ProviderId)}>
        <optgroup label={tr("Inloggen met je account", "Sign in with your account")}>
          {#each externalProviders.filter((p) => p.isSubscription) as p (p.id)}<option value={p.id}>{p.title}</option>{/each}
        </optgroup>
        <optgroup label={tr("Met een API-sleutel", "With an API key")}>
          {#each externalProviders.filter((p) => !p.isSubscription) as p (p.id)}<option value={p.id}>{p.title}</option>{/each}
        </optgroup>
      </select>
    </div>
  </div>
  {#if current.needsKey || current.isSubscription}
    <h3>{tr("Inloggen", "Sign in")}</h3>
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
      {#if current.id === "openrouter"}
        <div class="row">
          <span>{tr("Of log in bij OpenRouter", "Or sign in to OpenRouter")}<br /><span class="faint small">{tr("OpenRouter vraagt je in te loggen en Nook toe te staan, met een bestedingslimiet als je wilt. Nook krijgt een eigen sleutel.", "OpenRouter asks you to sign in and allow Nook, with a spending limit if you like. Nook gets a key of its own.")}</span>{#if signInError}<br /><span class="small err">{signInError}</span>{/if}</span>
          <button onclick={openrouterSignIn} disabled={signingIn}>{signingIn ? tr("Wacht op OpenRouter…", "Waiting for OpenRouter…") : tr("Inloggen", "Sign in")}</button>
        </div>
      {/if}
      <p class="note">{tr("De sleutel staat in de kluis van je systeem (Windows Referentiebeheer, GNOME Keyring/KWallet), nooit in een bestand.", "The key is kept in your system's keychain (Windows Credential Manager, GNOME Keyring/KWallet), never in a file.")} <a href={current.keyUrl} onclick={(e) => { e.preventDefault(); openUrl(current.keyUrl); }}>{tr("Sleutel maken", "Create a key")}</a></p>
    {:else}
      <p class="note">{tr("Nook denkt met je eigen login bij {name}: geen sleutel, binnen de limieten van je abonnement. Het draait afgeschermd: geen shell, geen bestanden, geen eigen plug-ins of MCP-servers.", "Nook thinks with your own sign-in to {name}: no key, within your plan's limits. It runs locked down: no shell, no files, none of your own plugins or MCP servers.", { name: current.title.split(" (")[0] })} {#if current.loginCommand}{tr("Installeer het en log één keer in met {command} in een terminal.", "Install it and sign in once with {command} in a terminal.", { command: current.loginCommand })}{/if} <a href={current.keyUrl} onclick={(e) => { e.preventDefault(); openUrl(current.keyUrl); }}>{tr("Installeren", "Install")}</a></p>
    {/if}
    </div>
  {/if}
  <h3>{tr("Model", "Model")}</h3>
  <div class="group">
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
    {#if models.length}
      <div class="models">
        {#each models as m (m)}<button class:on={m === model} onclick={() => setModel(m)}>{m}</button>{/each}
      </div>
    {/if}
    {#if modelError}<p class="note err">{modelError}</p>{/if}
    {@render connection()}
  </div>
{/if}

{#if current && !current.isLocal}
  <h3>{tr("Schermwerk", "Screen work")}</h3>
  <p class="faint note">{tr("Vragen over wat er op je scherm staat lezen je scherm. Laat dat een model op deze computer doen, dan blijft je scherm hier en beantwoordt je externe brein al het andere.", "Questions about what is on your screen read your screen. Let a model on this computer do that, and your screen stays here while your external brain answers everything else.")}</p>
  <div class="group">
    <div class="row">
      <span>{tr("Wie leest je scherm", "Who reads your screen")}</span>
      <select value={screenChoice} onchange={(e) => chooseScreen(e.currentTarget.value)}>
        <option value="external">{tr("{name} mag het lezen", "{name} may read it", { name: chosenName })}</option>
        <option value="">{tr("Niemand: schermwerk staat uit", "No one: screen work is off")}</option>
        {#each screenOptions as option (option)}
          <option value={option}>{tr("{name} op deze computer", "{name} on this computer", { name: option.split(":").slice(1).join(":") })}</option>
        {/each}
      </select>
    </div>
    {#if screenKept && s.screenBrain}
      <div class="row">
        <span>{tr("Wat het daarmee doet", "What it does with that")}</span>
        <select value={s.screenBrainRelays ? "passes" : "answers"} onchange={(e) => nook.saveSettings({ screenBrainRelays: e.currentTarget.value === "passes" })}>
          <option value="answers">{tr("Het antwoordt zelf", "It answers itself")}</option>
          <option value="passes">{tr("Het geeft {name} een korte, gefilterde notitie", "It gives {name} a short, filtered note", { name: chosenName })}</option>
        </select>
      </div>
    {/if}
  </div>
  <p class="faint note">
    {#if screenKept && s.screenBrain && s.screenBrainRelays}
      {tr("{name} leest je scherm op deze computer en geeft {chosen} alleen een korte notitie met wat de vraag nodig heeft. Geheimen, mailadressen en telefoonnummers gaan er eerst uit.", "{name} reads your screen on this computer and gives {chosen} only a short note with what the question needs. Secrets, mail addresses and phone numbers are taken out first.", { name: workerName, chosen: chosenName })}
    {:else if screenKept && s.screenBrain}
      {tr("Schermwerk draait op {name}, op deze computer. Je schermtekst gaat nooit naar {chosen}; andere vragen wel.", "Screen work runs on {name}, on this computer. Your screen text never goes to {chosen}; other questions do.", { name: workerName, chosen: chosenName })}
    {:else if !screenKept}
      {tr("Schermtekst gaat mee naar {name} bij vragen over je scherm.", "Screen text goes to {name} with questions about your screen.", { name: chosenName })}
    {:else if !localModels.length}
      {tr("Nog geen model op deze computer. Start Ollama of LM Studio met een model.", "No model on this computer yet. Start Ollama or LM Studio with a model.")}
    {:else}
      {tr("Je scherm blijft op deze computer. Vragen over je scherm krijgen geen scherm tot je hier een model kiest.", "Your screen stays on this computer. Questions about your screen get no screen until you choose a model here.")}
    {/if}
  </p>
{/if}

<h3>{tr("Kwaliteit van het lokale brein", "Local brain quality")}</h3>
<p class="section-info">{tr("Stelt het huidige brein 20 vragen met bekende antwoorden, zodat je in cijfers ziet of een wijziging helpt. Blijft op je computer.", "Asks the current brain 20 questions with known answers, to show in numbers whether a change helps. Stays on your computer.")}</p>
<div class="group">
  <label class="row"><span>{tr("Bewijs eerst", "Evidence first")}<br /><span class="faint small">{tr("Een extra stap citeert per document de zinnen die ertoe doen en antwoordt daaruit. Trager, minder verzinsels.", "An extra step quotes the sentences that matter from each document and answers from those. Slower, fewer inventions.")}</span></span><input type="checkbox" role="switch" checked={s.evidenceFirst} onchange={(e) => nook.saveSettings({ evidenceFirst: e.currentTarget.checked })} /></label>
  <label class="row"><span>{tr("Antwoorden controleren", "Check answers")}<br /><span class="faint small">{tr("Staat er een getal, tijd, adres of link in het antwoord dat in geen enkele bron voorkomt, dan schrijft het brein het antwoord opnieuw.", "If an answer contains a number, time, address or link that is in none of the sources, the brain writes the answer again.")}</span></span><input type="checkbox" role="switch" checked={s.checkAnswers} onchange={(e) => nook.saveSettings({ checkAnswers: e.currentTarget.checked })} /></label>
  <div class="row eval-bar">
    <div class="eval-controls">
      {#if evalRunning}
        <div class="eval-track" role="progressbar" aria-valuenow={evalDone} aria-valuemin={0} aria-valuemax={evalTotal}>
          <div class="eval-fill" style="width: {evalTotal ? Math.round((evalDone / evalTotal) * 100) : 0}%"></div>
        </div>
        <span class="mono faint small">{evalDone}/{evalTotal}</span>
        <button class="small" onclick={cancelEval}>{tr("Annuleer", "Cancel")}</button>
      {:else}
        <button class="small" onclick={evaluate} disabled={!nook.info?.brainReady}>{tr("Meet dit brein", "Measure this brain")}</button>
      {/if}
    </div>
    {#if evalResults.length > 0 && !evalRunning}
      <span class="mono eval-score" class:ok={evalGood} class:warn={!evalGood}>{tr("{passed} van {total} goed · {seconds} s", "{passed} of {total} right · {seconds} s", { passed, total: evalResults.length, seconds: Math.round(evalTotalSeconds) })}</span>
    {/if}
  </div>
  {#if evalFailure}
    <p class="note err">{evalFailure}</p>
  {/if}
  {#if evalResults.length > 0}
    <details class="eval-details">
      <summary class="row eval-summary">
        <span>{tr("Alle vragen", "All questions")}</span>
        <span class="mono faint small">{passed}/{evalResults.length}</span>
      </summary>
      <div class="eval-list">
        {#each evalResults as r (r.id)}
          <div class="eval-item">
            <div class="eval-q">
              <span class="eval-mark" class:ok={r.passed} class:err={!r.passed}><Ico name={r.passed ? "circle-check" : "circle-x"} size={14} stroke={1.75} /></span>
              <span class="eval-q-text">{r.question}</span>
              <span class="mono faint small">{r.seconds.toFixed(1)} s</span>
            </div>
            <p class="small faint eval-answer">{r.answer}</p>
            {#if !r.passed && (r.missing.length || r.forbidden.length)}
              <p class="small warn eval-missing">{tr("Ontbreekt of fout: {items}", "Missing or wrong: {items}", { items: [...r.missing, ...r.forbidden.map((f) => `✗ ${f}`)].join(", ") })}</p>
            {/if}
          </div>
        {/each}
      </div>
    </details>
  {/if}
  {#if evalHistory.length > 0}
    <div class="eval-history">
      <span class="faint small">{tr("Eerdere metingen", "Earlier measurements")}</span>
      {#each evalHistory as entry, idx (idx)}
        <span class="mono small">{entry}</span>
      {/each}
    </div>
  {/if}
</div>

<style>
  .small { font: var(--text-detail); }
  .mono { font-variant-numeric: tabular-nums; }
  .warn { color: var(--amber) !important; }
  .ok { color: var(--mint); }
  .err { color: var(--coral); }
  .eval-bar { gap: var(--space-12); }
  .eval-controls { display: flex; align-items: center; gap: var(--space-8); flex: 1; min-width: 0; }
  .eval-track { width: 140px; height: 6px; border-radius: 999px; background: var(--smoke); overflow: hidden; flex: none; }
  .eval-fill { height: 100%; border-radius: 999px; background: var(--paper); transition: width 160ms ease; }
  .eval-score { font: var(--text-body); white-space: nowrap; }
  .eval-details { border-top: 1px solid var(--separator); }
  .eval-summary { cursor: pointer; list-style: none; }
  .eval-list { display: flex; flex-direction: column; gap: var(--space-12); padding: 0 var(--space-16) var(--space-12); }
  .eval-item { display: flex; flex-direction: column; gap: var(--space-4); padding-top: var(--space-8); border-top: 1px solid var(--separator); }
  .eval-item:first-child { border-top: none; padding-top: 0; }
  .eval-q { display: flex; align-items: center; gap: var(--space-8); }
  .eval-mark { display: inline-flex; flex: none; }
  .eval-q-text { flex: 1; min-width: 0; color: var(--paper); }
  .eval-answer { margin: 0; white-space: pre-wrap; display: -webkit-box; -webkit-line-clamp: 3; line-clamp: 3; -webkit-box-orient: vertical; overflow: hidden; user-select: text; }
  .eval-missing { margin: 0; }
  .eval-history { display: flex; flex-direction: column; gap: var(--space-4); padding: var(--space-12) var(--space-16); border-top: 1px solid var(--separator); }
</style>
