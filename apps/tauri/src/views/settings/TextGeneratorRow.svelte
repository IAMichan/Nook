<script lang="ts">
  // One kind of text (`TextGeneratorRow` on macOS, SV-65): picker between the coding agent's CLI and
  // any API provider, plus model input, inline API key prompt when missing, and a live Test button.
  import { api } from "../../lib/api";
  import { brainApi } from "../../lib/brain";
  import { tr } from "../../lib/i18n.svelte";
  import {
    apiTextProviders,
    formatTextGenerator,
    parseTextGenerator,
    textGeneratorProviderName,
    type TextGenerator,
  } from "../../lib/text-generation";
  import type { ProviderId, ProviderInfo } from "../../lib/types";

  let {
    label,
    value = "agent",
    providers,
    agentOption = tr("Coding agent (Claude Code of Codex)", "Coding agent (Claude Code or Codex)"),
    onchange,
  }: {
    label: string;
    value?: string;
    providers: ProviderInfo[];
    agentOption?: string;
    onchange: (stored: string) => void;
  } = $props();

  const claudeApiLabel = $derived(tr("Claude · API-sleutel", "Claude · API key"));
  const apiChoices = $derived(apiTextProviders(providers));
  const generator = $derived<TextGenerator>(parseTextGenerator(value, providers));
  const selectedProvider = $derived<ProviderInfo | null>(
    generator.kind === "api" ? (apiChoices.find((p) => p.id === generator.provider) ?? null) : null,
  );
  const selectedName = $derived(
    selectedProvider ? textGeneratorProviderName(selectedProvider, claudeApiLabel) : "",
  );

  let modelDraft = $state("");
  let keyDraft = $state("");
  let keyMask = $state<string | null>(null);
  let savingKey = $state(false);
  let keyError = $state<string | null>(null);
  let testing = $state(false);
  let testResult = $state<{ ok: boolean; message: string } | null>(null);

  $effect(() => {
    modelDraft = generator.kind === "api" ? generator.model : "";
  });

  $effect(() => {
    const provider = selectedProvider;
    keyDraft = "";
    keyError = null;
    testResult = null;
    if (!provider || !provider.needsKey) {
      keyMask = null;
      return;
    }
    let cancelled = false;
    api.keyStatus(provider.id).then((mask) => {
      if (!cancelled) keyMask = mask;
    }).catch(() => {
      if (!cancelled) keyMask = null;
    });
    return () => {
      cancelled = true;
    };
  });

  const needsKeyNow = $derived(!!selectedProvider && selectedProvider.needsKey && !keyMask);

  function selectProvider(raw: string) {
    testResult = null;
    if (raw === "agent") {
      onchange("agent");
      return;
    }
    onchange(formatTextGenerator({ kind: "api", provider: raw as ProviderId, model: "" }));
  }

  function saveModel() {
    if (!selectedProvider) return;
    const clean = modelDraft.trim();
    const next = formatTextGenerator({ kind: "api", provider: selectedProvider.id, model: clean });
    if (next !== value) onchange(next);
  }

  async function saveKey() {
    if (!selectedProvider) return;
    const clean = keyDraft.trim();
    if (!clean) return;
    savingKey = true;
    keyError = null;
    try {
      keyMask = await api.setKey(selectedProvider.id, clean);
      keyDraft = "";
      testResult = null;
    } catch (e) {
      keyError = String(e);
    } finally {
      savingKey = false;
    }
  }

  async function runTest() {
    if (!selectedProvider) return;
    saveModel();
    testing = true;
    testResult = null;
    try {
      const model = modelDraft.trim();
      const answer = await brainApi.testTextGenerator(selectedProvider.id, model);
      const shownModel = model || selectedProvider.defaultModel || selectedName;
      testResult = {
        ok: true,
        message: tr("{model} antwoordde: {answer}", "{model} answered: {answer}", {
          model: shownModel,
          answer: answer.slice(0, 40),
        }),
      };
    } catch (e) {
      testResult = { ok: false, message: String(e) };
    } finally {
      testing = false;
    }
  }
</script>

<div class="tg-block">
  <label class="row">
    <span>{label}</span>
    <select value={selectedProvider ? selectedProvider.id : "agent"} onchange={(e) => selectProvider(e.currentTarget.value)}>
      <option value="agent">{agentOption}</option>
      {#each apiChoices as p (p.id)}
        <option value={p.id}>{textGeneratorProviderName(p, claudeApiLabel)}</option>
      {/each}
    </select>
  </label>

  {#if selectedProvider}
    <div class="tg-sub">
      <label class="row">
        <span>{tr("Model", "Model")}</span>
        <input
          class="tg-input"
          value={modelDraft}
          placeholder={selectedProvider.defaultModel || tr("Het model dat de server geladen heeft", "The model the server has loaded")}
          oninput={(e) => { modelDraft = e.currentTarget.value; testResult = null; }}
          onblur={saveModel}
          onkeydown={(e) => { if (e.key === "Enter") { e.preventDefault(); saveModel(); } }}
        />
      </label>

      {#if needsKeyNow}
        <div class="row">
          <span>
            {tr("API-sleutel", "API key")}<br />
            <small>{tr("{name} heeft een API-sleutel nodig. Tot die er is, schrijft de coding agent deze tekst.", "{name} needs an API key. Until it has one, the coding agent writes this text.", { name: selectedName })}</small>
            {#if keyError}<br /><small class="err">{keyError}</small>{/if}
          </span>
          <span class="tg-inline">
            <input
              type="password"
              class="tg-input"
              placeholder={selectedProvider.keyPlaceholder}
              bind:value={keyDraft}
              onkeydown={(e) => { if (e.key === "Enter") { e.preventDefault(); saveKey(); } }}
            />
            <button type="button" disabled={savingKey || !keyDraft.trim()} onclick={saveKey}>
              {tr("Sleutel bewaren", "Save key")}
            </button>
          </span>
        </div>
      {/if}

      <div class="row">
        <span class="tg-status">
          {#if testResult}
            <small class={testResult.ok ? "ok" : "err"}>{testResult.message}</small>
          {:else}
            <small>{tr("Verbinding", "Connection")}</small>
          {/if}
        </span>
        <button type="button" disabled={testing || needsKeyNow} onclick={runTest}>
          {testing ? tr("Testen…", "Testing…") : tr("Test", "Test")}
        </button>
      </div>
    </div>
  {/if}
</div>

<style>
  .tg-block {
    border-bottom: 1px solid var(--separator);
  }
  .tg-block:last-child {
    border-bottom: none;
  }
  .tg-block > .row {
    border-bottom: none;
  }
  .tg-sub {
    padding-left: var(--space-12);
    border-left: 2px solid var(--separator);
    margin: 0 0 var(--space-8) var(--space-4);
  }
  .tg-sub .row:last-child {
    border-bottom: none;
  }
  .tg-input {
    min-width: 180px;
  }
  .tg-inline {
    display: inline-flex;
    align-items: center;
    gap: var(--space-6);
  }
  .tg-status .ok {
    color: var(--ok);
  }
  .tg-status .err {
    color: var(--err);
  }
</style>
