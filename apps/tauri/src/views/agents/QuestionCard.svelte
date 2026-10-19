<script lang="ts">
  // Een meerkeuzevraag van een agent (AskUserQuestion), vraag voor vraag. "In terminal" laat de agent het zelf vragen.
  import { agentApi, type QuestionRequest } from "../../lib/agents";
  import { agents } from "../../lib/agents.svelte";

  let { request }: { request: QuestionRequest } = $props();
  let index = $state(0);
  let answers = $state<string[][]>([]);
  let chosen = $state<string[]>([]);
  let busy = $state(false);

  const item = $derived(request.items[Math.min(index, request.items.length - 1)]);

  async function next(labels: string[]) {
    const all = [...answers, labels];
    if (index + 1 < request.items.length) {
      answers = all;
      chosen = [];
      index += 1;
      return;
    }
    busy = true;
    try {
      await agentApi.answer(request.id, all);
    } catch (e) {
      agents.error = String(e);
    }
    busy = false;
    agents.refresh();
  }

  function toggle(label: string) {
    chosen = chosen.includes(label) ? chosen.filter((c) => c !== label) : [...chosen, label];
  }

  async function terminal() {
    try {
      await agentApi.answerInTerminal(request.id);
    } catch (e) {
      agents.error = String(e);
    }
    agents.refresh();
  }
</script>

<div class="question">
  <div class="context faint">
    <span class="dot waiting"></span>
    {request.agentName} · {request.project} vraagt{#if item.header} · {item.header}{/if}{#if request.items.length > 1} · {index + 1} van {request.items.length}{/if}
  </div>
  <div class="title">{item.question}</div>
  <div class="options">
    {#each item.options as option (option.label)}
      {#if item.multiSelect}
        <label class="option" class:on={chosen.includes(option.label)}>
          <input type="checkbox" checked={chosen.includes(option.label)} onchange={() => toggle(option.label)} />
          <span><strong>{option.label}</strong>{#if option.description}<br /><span class="faint">{option.description}</span>{/if}</span>
        </label>
      {:else}
        <button class="option" disabled={busy} onclick={() => next([option.label])}>
          <strong>{option.label}</strong>{#if option.description}<span class="faint">{option.description}</span>{/if}
        </button>
      {/if}
    {/each}
  </div>
  <div class="buttons">
    <button class="ghost" onclick={terminal}>In terminal</button>
    <span class="spacer"></span>
    {#if item.multiSelect}<button class="primary" disabled={busy || !chosen.length} onclick={() => next(chosen)}>Verstuur</button>{/if}
  </div>
</div>

<style>
  .question { background: var(--graphite); border: 1px solid var(--line2); border-radius: 16px; padding: 12px 14px; display: flex; flex-direction: column; gap: 8px; }
  .context { display: flex; align-items: center; gap: 6px; font-size: 12px; }
  .title { font-weight: 600; font-size: 14px; }
  .options { display: flex; flex-direction: column; gap: 6px; max-height: 260px; overflow-y: auto; }
  .option { display: flex; flex-direction: column; align-items: flex-start; gap: 2px; text-align: left; padding: 8px 10px; }
  label.option { flex-direction: row; gap: 8px; background: var(--smoke); border: 1px solid var(--line2); border-radius: 9px; }
  label.option.on { border-color: var(--iris); }
  .option .faint { font-size: 12px; }
  .buttons { display: flex; gap: 6px; }
  .spacer { flex: 1; }
</style>
