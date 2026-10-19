<script lang="ts">
  // Welk lokaal model past bij deze computer: met één klik installeren (Ollama, met voortgang) of een model gebruiken
  // dat al draait. LM Studio tonen we alleen als hij draait; modellen downloaden doe je daar in LM Studio zelf.
  import { openUrl } from "@tauri-apps/plugin-opener";
  import { api } from "../lib/api";
  import { brainApi, type BrainAdvice, type PullProgress, type Recommendation, type ServerModel } from "../lib/brain";
  import { nook } from "../lib/state.svelte";

  let { compact = false }: { compact?: boolean } = $props();
  let advice = $state<BrainAdvice | null>(null);
  let progress = $state<Record<string, PullProgress>>({});
  let error = $state<string | null>(null);

  async function refresh() {
    advice = await brainApi.advice();
  }

  $effect(() => {
    refresh();
    const un = brainApi.onPull((p) => {
      progress[p.model] = p;
      if (p.done && !p.error) {
        use({ server: "ollama", name: p.model });
        refresh();
      }
    });
    return () => {
      un.then((f) => f());
    };
  });

  async function install(model: string) {
    error = null;
    progress[model] = { model, status: "starten…", fraction: 0, done: false, error: null };
    try {
      await brainApi.pull(model);
    } catch (e) {
      error = String(e);
      delete progress[model];
    }
  }

  async function use(m: ServerModel) {
    nook.settings = await brainApi.useLocal(m.server, m.name);
    nook.info = await api.appInfo();
  }

  const current = $derived(nook.settings ? (nook.settings.providerModels[nook.settings.provider] ?? "") : "");
  const isCurrent = (m: ServerModel) => nook.settings?.provider === m.server && current === m.name;

  function modelOf(r: Recommendation): string {
    return r.choice.kind === "pull" ? r.choice.option.id : r.choice.kind === "server" ? r.choice.model.name : "";
  }

  const lmstudio = $derived(advice?.servers.filter((s) => s.server === "lmstudio") ?? []);
  const ollama = $derived(advice?.servers.filter((s) => s.server === "ollama") ?? []);
</script>

{#if !advice}
  <p class="faint">Kijken wat er op deze computer draait…</p>
{:else}
  <div class="advice">
    <p class="faint note">Deze computer heeft {advice.memoryGb} GB werkgeheugen.</p>
    {#each (compact ? advice.recommendations.slice(0, 1) : advice.recommendations) as r (r.title + modelOf(r))}
      {@const model = modelOf(r)}
      {@const p = progress[model]}
      <div class="rec">
        <div class="text">
          <strong>{r.title}</strong>
          <span class="faint">{r.reason}</span>
          {#if p && !p.done}
            <div class="bar"><div style="width: {Math.round((p.fraction ?? 0) * 100)}%"></div></div>
            <span class="faint small">{p.status}{p.fraction != null ? ` · ${Math.round(p.fraction * 100)}%` : ""}</span>
          {:else if p?.error}
            <span class="err">{p.error}</span>
          {/if}
        </div>
        {#if r.choice.kind === "pull"}
          {#if r.ready}
            {@const m = { server: "ollama" as const, name: model }}
            <button class:primary={!isCurrent(m)} disabled={isCurrent(m)} onclick={() => use(m)}>{isCurrent(m) ? "In gebruik" : "Gebruik"}</button>
          {:else if !advice.ollamaRunning}
            <button onclick={() => openUrl("https://ollama.com/download")}>Ollama downloaden</button>
          {:else}
            <button class="primary" disabled={!!p && !p.done} onclick={() => install(model)}>
              {p && !p.done ? "Bezig…" : `Installeer (${r.choice.option.sizeGb} GB)`}
            </button>
          {/if}
        {:else if r.choice.kind === "server"}
          {@const m = r.choice.model}
          <button class:primary={!isCurrent(m)} disabled={isCurrent(m)} onclick={() => use(m)}>{isCurrent(m) ? "In gebruik" : "Gebruik"}</button>
        {/if}
      </div>
    {/each}
    {#if error}<p class="err">{error}</p>{/if}
    {#if !compact && (ollama.length || lmstudio.length)}
      <h3>Draait nu</h3>
      <div class="models">
        {#each [...ollama, ...lmstudio] as m (m.server + m.name)}
          <button class:on={isCurrent(m)} onclick={() => use(m)}>{m.name} <span class="faint">· {m.server === "ollama" ? "Ollama" : "LM Studio"}</span></button>
        {/each}
      </div>
    {/if}
    {#if !compact && !lmstudio.length}
      <p class="faint note">LM Studio verschijnt hier zodra de server draait (Developer › Start server).</p>
    {/if}
  </div>
{/if}

<style>
  .advice { display: flex; flex-direction: column; gap: 8px; }
  .rec { display: flex; justify-content: space-between; align-items: center; gap: 14px; padding: 10px 12px; border: 1px solid var(--line); border-radius: 10px; background: var(--field); }
  .text { display: flex; flex-direction: column; gap: 3px; min-width: 0; flex: 1; }
  .text .faint { font-size: 12px; }
  .small { font-size: 11px; }
  .bar { height: 4px; border-radius: 2px; background: var(--line2); overflow: hidden; margin-top: 4px; }
  .bar div { height: 100%; background: var(--iris); transition: width 0.3s; }
  .err { color: var(--coral); font-size: 12px; }
  .note { margin: 0; font-size: 12px; }
  h3 { margin: 10px 0 4px; font-size: 13px; color: var(--text2); }
  .models { display: flex; flex-wrap: wrap; gap: 6px; }
  .models button { font-size: 12px; padding: 3px 9px; }
  .models button.on { border-color: var(--iris); }
</style>
