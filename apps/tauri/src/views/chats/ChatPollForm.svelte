<script lang="ts">
  // A poll to send, above the chat's field (`ChatPollForm` on the Mac): the question, the options (one empty field is
  // always there for the next, up to twelve), "Allow multiple answers", and Send once it can go.
  import { tr } from "../../lib/i18n.svelte";
  import Ico from "../../components/ui/Ico.svelte";
  import IconButton from "../../components/ui/IconButton.svelte";

  let { onsend, onclose }: { onsend: (poll: { question: string; options: string[]; multiple: boolean }) => Promise<void>; onclose: () => void } = $props();

  const MAX_OPTIONS = 12;
  let question = $state("");
  let options = $state<string[]>(["", ""]);
  let multiple = $state(false);
  let sending = $state(false);
  let failed = $state("");

  // One empty option is always there to type the next in, up to the most allowed.
  $effect(() => {
    if (options.length < MAX_OPTIONS && options.every((o) => o.trim())) options = [...options, ""];
  });

  const clean = $derived.by(() => {
    const seen = new Set<string>();
    return options.map((o) => o.trim()).filter((o) => o && !seen.has(o.toLowerCase()) && seen.add(o.toLowerCase()));
  });
  const problem = $derived.by(() => {
    const q = question.trim();
    if (!q) return tr("Stel eerst een vraag.", "Ask a question first.");
    if (q.length > 255) return tr("De vraag is te lang.", "The question is too long.");
    if (options.filter((o) => o.trim()).length !== clean.length) return tr("Elke optie mag maar één keer voorkomen.", "Each option may appear only once.");
    if (clean.length < 2) return tr("Geef minstens twee opties.", "Give at least two options.");
    if (clean.length > MAX_OPTIONS) return tr("Hoogstens {n} opties.", "At most {n} options.", { n: MAX_OPTIONS });
    if (clean.some((o) => o.length > 100)) return tr("Een optie is te lang (hoogstens 100 tekens).", "An option is too long (at most 100 characters).");
    return null;
  });

  async function send() {
    if (problem || sending) return;
    sending = true;
    failed = "";
    try {
      await onsend({ question: question.trim(), options: clean, multiple });
      onclose();
    } catch (e) {
      failed = String(e);
    } finally {
      sending = false;
    }
  }
</script>

<div class="panel" role="dialog" aria-label={tr("Peiling", "Poll")}>
  <div class="head">
    <Ico name="chart-column" size={13} />
    <span class="title">{tr("Peiling", "Poll")}</span>
    <IconButton title={tr("Sluiten", "Close")} size={22} onclick={onclose}><Ico name="x" size={11} stroke={2.4} /></IconButton>
  </div>
  <!-- svelte-ignore a11y_autofocus -->
  <input class="field" autofocus placeholder={tr("Stel een vraag", "Ask a question")} bind:value={question} maxlength="300" />
  {#each options as _, i (i)}
    <span class="option">
      <input class="field" placeholder={tr("Optie {n}", "Option {n}", { n: i + 1 })} bind:value={options[i]} maxlength="120" onkeydown={(e) => e.key === "Enter" && send()} />
      {#if options.length > 2 && options[i].trim()}
        <IconButton title={tr("Verwijderen", "Remove")} size={22} onclick={() => (options = options.filter((_, j) => j !== i))}><Ico name="circle-minus" size={13} /></IconButton>
      {/if}
    </span>
  {/each}
  <label class="multiple"><input type="checkbox" role="switch" bind:checked={multiple} />{tr("Meerdere antwoorden toestaan", "Allow multiple answers")}</label>
  <div class="foot">
    <span class="note">{failed || (question.trim() || clean.length ? problem ?? "" : "")}</span>
    <button class="primary small" disabled={!!problem || sending} onclick={send}><Ico name="arrow-up" size={12} stroke={2.6} />{tr("Verstuur", "Send")}</button>
  </div>
</div>

<style>
  .panel { display: flex; flex-direction: column; gap: var(--space-6); padding: var(--space-8); border: 1px solid var(--field-stroke); border-radius: var(--radius-sheet); background: var(--composer-tray); max-height: 320px; overflow-y: auto; }
  .head { display: flex; align-items: center; gap: var(--space-6); color: var(--text2); }
  .title { flex: 1; font: var(--text-label); color: var(--paper); }
  .option { display: flex; align-items: center; gap: var(--space-4); }
  .option .field { flex: 1; }
  .multiple { display: flex; align-items: center; justify-content: space-between; gap: var(--space-8); font: var(--text-body); color: var(--text2); }
  .foot { display: flex; align-items: center; gap: var(--space-8); }
  .note { flex: 1; font: var(--text-detail); color: var(--text3); }
  .primary.small { display: inline-flex; align-items: center; gap: var(--space-4); }
</style>
