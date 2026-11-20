<script lang="ts">
  // Saved prompts in a composer (`PromptLibrary`, `PromptVariablesSheet` on the Mac): using one puts its words in the
  // field, after asking for the values of its `{{variables}}` in a strip above the composer; "Save as prompt…" keeps
  // what you typed under a title and an optional `/trigger`.
  import { tr } from "../../../lib/i18n.svelte";
  import { cleanTrigger, prompts, render, variables, type SavedPrompt } from "../../../lib/workspace/prompts.svelte";
  import { toast } from "../../../lib/toast.svelte";

  let { draft = $bindable(""), textarea }: { draft: string; textarea: HTMLTextAreaElement | undefined } = $props();

  let filling = $state<{ prompt: SavedPrompt; values: Record<string, string> } | null>(null);
  let saving = $state<{ title: string; trigger: string; body: string } | null>(null);

  $effect(() => prompts.load());

  function place(text: string) {
    // A `/trigger` typed to find the prompt gives way to its words.
    draft = /^\/\S*$/.test(draft.trim()) || !draft.trim() ? text : `${draft.trimEnd()}\n\n${text}`;
    requestAnimationFrame(() => { textarea?.focus(); textarea?.setSelectionRange(draft.length, draft.length); });
  }

  /// Uses a prompt: at once when every variable has a value to start from, else after the strip asked for them.
  export function use(prompt: SavedPrompt) {
    const asked = variables(prompt.body);
    if (asked.some((v) => !v.defaultValue)) {
      filling = { prompt, values: Object.fromEntries(asked.map((v) => [v.name, v.defaultValue])) };
      if (/^\/\S*$/.test(draft.trim())) draft = "";
    } else {
      place(render(prompt.body, {}));
    }
  }

  /// "Save as prompt…": the words in the field, titled by their first ones.
  export function openSave() {
    const body = draft.trim();
    if (!body) return;
    saving = { body, title: body.split(/\s+/).slice(0, 6).join(" "), trigger: "" };
  }

  async function save() {
    if (!saving) return;
    const kept = await prompts.save({ title: saving.title, body: saving.body, trigger: saving.trigger }).catch(() => false);
    if (kept) toast.success(tr("Prompt bewaard", "Prompt saved"));
    saving = null;
  }

  function focusFirst(node: HTMLElement) {
    node.querySelector<HTMLInputElement>("input")?.focus();
  }
</script>

{#if filling}
  <form class="strip" use:focusFirst onsubmit={(e) => { e.preventDefault(); place(render(filling!.prompt.body, filling!.values)); filling = null; }}>
    <strong>{filling.prompt.title}</strong>
    {#each Object.keys(filling.values) as name (name)}
      <label><span>{name}</span><input bind:value={filling.values[name]} /></label>
    {/each}
    <span class="row"><button type="button" class="ghost" onclick={() => (filling = null)}>{tr("Annuleer", "Cancel")}</button><button type="submit" class="primary">{tr("Gebruik", "Use")}</button></span>
  </form>
{:else if saving}
  <form class="strip" use:focusFirst onsubmit={(e) => { e.preventDefault(); save(); }}>
    <strong>{tr("Bewaar als prompt", "Save as prompt")}</strong>
    <label><span>{tr("Titel", "Title")}</span><input bind:value={saving.title} /></label>
    <label><span>{tr("Trigger (optioneel)", "Trigger (optional)")}</span><input bind:value={saving.trigger} placeholder="/summarize" oninput={() => saving && (saving.trigger = cleanTrigger(saving.trigger))} /></label>
    <span class="row"><button type="button" class="ghost" onclick={() => (saving = null)}>{tr("Annuleer", "Cancel")}</button><button type="submit" class="primary" disabled={!saving.title.trim()}>{tr("Bewaar", "Save")}</button></span>
  </form>
{/if}

<style>
  .strip { display: flex; flex-direction: column; gap: var(--space-6); padding: var(--space-8) var(--space-12); border: 1px solid var(--line2); border-radius: var(--radius-card); background: var(--surface); }
  .strip strong { font: var(--text-control); color: var(--paper); }
  label { display: flex; align-items: center; gap: var(--space-8); font: var(--text-detail); color: var(--text3); }
  label span { width: 120px; flex: none; }
  label input { flex: 1; min-width: 0; font: var(--text-body); padding: var(--space-4) var(--space-8); }
  .row { display: flex; justify-content: flex-end; gap: var(--space-6); }
</style>
