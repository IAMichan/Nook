<script lang="ts">
  // Een mailconcept in de chat: aan te passen, en pas weg na een klik op Versturen (via je mailprogramma).
  import { brainApi, type MailDraft } from "../lib/brain";
  import { tr } from "../lib/i18n.svelte";

  let { draft, nookId }: { draft: MailDraft; nookId: string } = $props();
  let edit = $state<MailDraft>({ id: "", to: "", cc: "", subject: "", body: "", state: "draft", error: "" });
  let editing = $state(false);
  let error = $state<string | null>(null);

  $effect(() => {
    if (!editing) edit = { ...draft };
  });

  const sent = $derived(draft.state === "sent");

  async function save() {
    error = null;
    try {
      await brainApi.mailUpdate(nookId, edit);
      editing = false;
    } catch (e) {
      error = String(e);
    }
  }

  async function send() {
    error = null;
    try {
      await brainApi.mailSend(nookId, edit);
      editing = false;
    } catch (e) {
      error = String(e);
    }
  }

  async function open() {
    error = null;
    try {
      await brainApi.mailOpen(nookId, edit);
    } catch (e) {
      error = String(e);
    }
  }
</script>

<div class="mail" class:sent>
  <div class="head">
    <strong>✉ {tr("Mailconcept", "Email draft")}</strong>
    <span class="faint">{sent ? tr("naar je mailprogramma gestuurd", "sent to your mail app") : draft.state === "opened" ? tr("geopend in je mailprogramma", "opened in your mail app") : tr("nog niet verstuurd", "not sent yet")}</span>
  </div>
  {#if editing}
    <label>{tr("Aan", "To")} <input bind:value={edit.to} placeholder={tr("naam@voorbeeld.nl", "name@example.com")} /></label>
    <label>Cc <input bind:value={edit.cc} /></label>
    <label>{tr("Onderwerp", "Subject")} <input bind:value={edit.subject} /></label>
    <textarea bind:value={edit.body} rows="8"></textarea>
  {:else}
    <div class="row"><span class="faint">{tr("Aan", "To")}</span> {draft.to || "—"}</div>
    {#if draft.cc}<div class="row"><span class="faint">Cc</span> {draft.cc}</div>{/if}
    <div class="row"><span class="faint">{tr("Onderwerp", "Subject")}</span> <strong>{draft.subject}</strong></div>
    <div class="body">{draft.body}</div>
  {/if}
  {#if error || draft.error}<p class="err">{error ?? draft.error}</p>{/if}
  {#if !sent}
    <div class="buttons">
      {#if editing}
        <button class="ghost" onclick={() => (editing = false)}>{tr("Annuleer", "Cancel")}</button>
        <button onclick={save}>{tr("Bewaar", "Save")}</button>
      {:else}
        <button class="ghost" onclick={() => (editing = true)}>{tr("Aanpassen", "Edit")}</button>
        <button class="ghost" onclick={open}>{tr("Open in mailprogramma", "Open in mail app")}</button>
      {/if}
      <button class="primary" onclick={send} disabled={!edit.to.trim()}>{tr("Versturen", "Send")}</button>
    </div>
  {/if}
</div>

<style>
  .mail { margin-top: 8px; border: 1px solid var(--line2); border-radius: 12px; padding: 10px 12px; background: var(--field); display: flex; flex-direction: column; gap: 6px; }
  .mail.sent { border-color: color-mix(in srgb, var(--mint) 35%, var(--line2)); }
  .head { display: flex; gap: 8px; align-items: baseline; }
  .row { font-size: 13px; }
  .row .faint { display: inline-block; width: 74px; }
  .body { white-space: pre-wrap; user-select: text; border-top: 1px solid var(--line); padding-top: 6px; line-height: 1.45; }
  label { display: grid; grid-template-columns: 74px 1fr; align-items: center; font-size: 12px; color: var(--text2); }
  textarea { resize: vertical; line-height: 1.4; }
  .buttons { display: flex; justify-content: flex-end; gap: 8px; flex-wrap: wrap; }
  .err { color: var(--coral); font-size: 12px; margin: 0; }
</style>
