<script lang="ts">
  // Een meerkeuzevraag van een agent (AskUserQuestion), vraag voor vraag. "In terminal" laat de agent het zelf vragen.
  import { agentApi, type QuestionRequest } from "../../lib/agents";
  import { agents } from "../../lib/agents.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import { workspaceApi } from "../../lib/workspace/api";
  import { open as openDialog } from "@tauri-apps/plugin-dialog";
  import { compose, project, type ContextRef } from "../../lib/workspace/context-refs";
  import ComposerContext from "./run/ComposerContext.svelte";
  import Ico from "../../components/ui/Ico.svelte";

  let { request }: { request: QuestionRequest } = $props();
  let index = $state(0);
  let answers = $state<string[][]>([]);
  let chosen = $state<string[]>([]);
  let busy = $state(false);

  const item = $derived(request.items[Math.min(index, request.items.length - 1)]);
  const isLast = $derived(index + 1 >= request.items.length);

  // Your own answer instead of an option (`ws.question.own`), with files and pictures attached, pasted or dropped.
  let own = $state("");
  let ownField = $state<HTMLTextAreaElement>();
  let attached = $state<ContextRef[]>([]);
  let pictures = $state<string[]>([]);
  let context = $state<ReturnType<typeof ComposerContext>>();
  const hasOwn = $derived(!!own.trim() || attached.length + pictures.length > 0);

  function sendOwn() {
    if (!hasOwn) return;
    const text = project(compose(own, attached, []), pictures);
    own = "";
    attached = [];
    pictures = [];
    next([text]);
  }

  async function attach() {
    const picked = await openDialog({ multiple: true, title: tr("Bestand of map toevoegen", "Attach a file or folder") }).catch(() => null);
    for (const path of Array.isArray(picked) ? picked : picked ? [picked] : []) context?.addPath(path);
  }

  /// The preview as it shows in the code font (`QuestionPreview.display`): a fence around the whole of it taken off,
  /// trailing spaces too; the layout of the lines stays.
  function display(preview: string): string {
    let lines = preview.trim().split("\n");
    if (lines.length >= 2 && lines[0].startsWith("```") && lines[lines.length - 1].trim() === "```") lines = lines.slice(1, -1);
    return lines.map((l) => l.replace(/[ \t]+$/, "")).join("\n");
  }

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

  async function dismiss() {
    try {
      await workspaceApi.dismissQuestion(request.id);
    } catch (e) {
      agents.error = String(e);
    }
    agents.refresh();
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
    {request.agentName} · {tr("{project} vraagt", "{project} asks", { project: request.project })}{#if item.header} · {item.header}{/if}{#if request.items.length > 1} · {tr("{n} van {total}", "{n} of {total}", { n: index + 1, total: request.items.length })}{/if}
  </div>
  {#if request.restored}<div class="faint restored">{tr("Gevraagd voordat Nook opnieuw startte. Je antwoord gaat als bericht naar de agent en pakt het gesprek weer op.", "Asked before Nook restarted. Your answer goes to the agent as a message and picks the conversation up again.")}</div>{/if}
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
      <!-- What the option would look like, under it (Claude Code's `preview`). -->
      {#if option.preview}<pre class="preview">{display(option.preview)}</pre>{/if}
    {/each}
  </div>
  <div class="own">
    <ComposerContext bind:this={context} textarea={ownField} bind:draft={own} root={null} bind:attached bind:pictures mentions={[]} />
    <div class="own-row">
      <textarea bind:this={ownField} bind:value={own} rows="1" placeholder={tr("Of typ je eigen antwoord…", "Or type your own answer…")} disabled={busy}
        onkeydown={(e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); sendOwn(); } }}></textarea>
      <button class="ghost icon" title={tr("Bestand of map toevoegen", "Attach a file or folder")} aria-label={tr("Bestand of map toevoegen", "Attach a file or folder")} onclick={attach}><Ico name="paperclip" size={14} /></button>
      {#if hasOwn}<button class="primary" disabled={busy} onclick={sendOwn}>{isLast ? tr("Antwoorden", "Answer") : tr("Volgende", "Next")}</button>{/if}
    </div>
  </div>
  <div class="buttons">
    {#if request.restored}
      <button class="ghost" onclick={dismiss}>{tr("Deze vraag onbeantwoord laten", "Leave this question unanswered")}</button>
    {:else}
      <button class="ghost" onclick={terminal}>{tr("In terminal", "In terminal")}</button>
    {/if}
    <span class="spacer"></span>
    {#if item.multiSelect}<button class="primary" disabled={busy || !chosen.length} onclick={() => next(chosen)}>{tr("Verstuur", "Send")}</button>{/if}
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
  .preview { margin: 0 0 var(--space-4) var(--space-12); padding: var(--space-8) var(--space-12); border: 1px solid var(--line2); border-radius: var(--radius-control); background: var(--well); font: var(--text-code); white-space: pre; overflow-x: auto; max-height: 220px; color: var(--text2); }
  .own { position: relative; display: flex; flex-direction: column; gap: var(--space-6); }
  .own-row { display: flex; align-items: flex-start; gap: var(--space-6); }
  .own-row textarea { flex: 1; min-height: 32px; max-height: 120px; resize: none; field-sizing: content; font: var(--text-body); }
  .own .icon { width: 32px; height: 32px; padding: 0; display: grid; place-items: center; }
  .spacer { flex: 1; }
  .restored { font: var(--text-detail); }
</style>
