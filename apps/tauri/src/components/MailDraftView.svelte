<script lang="ts">
  // A mail draft in the chat: editable, and only gone after a click on Send (through the user's mail app). Either a
  // `compose_mail` draft stored with the chat (`draft` + `nookId`), or a mail an answer wrote as a ```mail block or a
  // quoted mail (`template`), which is not stored: its edits and state live in this card.
  import { brainApi, type MailDraft } from "../lib/brain";
  import { locale, tr } from "../lib/i18n.svelte";
  import type { MailTemplate } from "../lib/mail-block";
  import { hasInviteFile, inviteSummary } from "../lib/mail-invite";
  import Icon from "./Icon.svelte";

  let { draft: stored, nookId, template }: { draft?: MailDraft; nookId?: string; template?: MailTemplate } = $props();
  const blank = (): MailDraft => ({ id: "", to: "", cc: "", bcc: "", subject: "", body: "", state: "draft", error: "" });
  let local = $state<MailDraft | null>(null);
  // `from` stays on the card only: a mailto: link cannot set it, the mail app sends from the user's own account.
  const fromTemplate = (t: MailTemplate | undefined): MailDraft =>
    t ? { ...blank(), to: t.to, cc: t.cc, bcc: t.bcc, subject: t.subject, body: t.body } : blank();
  const draft = $derived<MailDraft>(local ?? stored ?? fromTemplate(template));
  const standalone = $derived(!stored || !nookId);
  let edit = $state<MailDraft>(blank());
  let editing = $state(false);
  let error = $state<string | null>(null);

  $effect(() => {
    if (!editing) edit = { ...draft };
  });

  const sent = $derived(draft.state === "sent");
  const inviteLine = $derived(draft.invite ? inviteSummary(draft.invite, locale()) : "");
  const canOpenInvite = $derived(hasInviteFile(draft));

  async function save() {
    error = null;
    try {
      if (standalone) local = { ...edit, state: "draft", error: "" };
      else await brainApi.mailUpdate(nookId!, edit);
      editing = false;
    } catch (e) {
      error = String(e);
    }
  }

  async function send() {
    error = null;
    try {
      if (standalone) {
        await brainApi.mailBlockOpen(edit, true);
        local = { ...edit, state: "sent", error: "" };
      } else await brainApi.mailSend(nookId!, edit);
      editing = false;
    } catch (e) {
      error = String(e);
    }
  }

  async function open() {
    error = null;
    try {
      if (standalone) {
        await brainApi.mailBlockOpen(edit, false);
        local = { ...edit, state: "opened", error: "" };
      } else await brainApi.mailOpen(nookId!, edit);
    } catch (e) {
      error = String(e);
    }
  }

  async function openInvite() {
    error = null;
    try {
      if (!standalone) await brainApi.mailOpenInvite(nookId!, edit);
    } catch (e) {
      error = String(e);
    }
  }
</script>

<div class="mail" class:sent class:card={!!template}>
  <div class="head">
    <strong>✉ {tr("Mailconcept", "Email draft")}</strong>
    <span class="faint">{sent ? tr("naar je mailprogramma gestuurd", "sent to your mail app") : draft.state === "opened" ? tr("geopend in je mailprogramma", "opened in your mail app") : tr("nog niet verstuurd", "not sent yet")}</span>
  </div>
  {#if editing}
    {#if template?.from}<div class="row"><span class="faint">{tr("Van", "From")}</span> {template.from}</div>{/if}
    <label>{tr("Aan", "To")} <input bind:value={edit.to} placeholder={tr("naam@voorbeeld.nl", "name@example.com")} /></label>
    <label>Cc <input bind:value={edit.cc} /></label>
    <label>Bcc <input bind:value={edit.bcc} /></label>
    <label>{tr("Onderwerp", "Subject")} <input bind:value={edit.subject} /></label>
    {#if inviteLine}
      <div class="invite-row">
        <Icon name="calendar" size={13} />
        <span class="invite-text">{tr("Uitnodiging: {summary}", "Invitation: {summary}", { summary: inviteLine })}</span>
      </div>
    {/if}
    <textarea bind:value={edit.body} rows="8"></textarea>
  {:else}
    {#if template?.from}<div class="row"><span class="faint">{tr("Van", "From")}</span> {template.from}</div>{/if}
    <div class="row"><span class="faint">{tr("Aan", "To")}</span> {draft.to || "—"}</div>
    {#if draft.cc}<div class="row"><span class="faint">Cc</span> {draft.cc}</div>{/if}
    {#if draft.bcc}<div class="row"><span class="faint">Bcc</span> {draft.bcc}</div>{/if}
    <div class="row"><span class="faint">{tr("Onderwerp", "Subject")}</span> <strong>{draft.subject || "—"}</strong></div>
    {#if inviteLine}
      <div class="invite-row">
        <Icon name="calendar" size={13} />
        <span class="invite-text">{tr("Uitnodiging: {summary}", "Invitation: {summary}", { summary: inviteLine })}</span>
        {#if canOpenInvite}
          <button class="ghost small" onclick={openInvite}>{tr("Open .ics", "Open .ics")}</button>
        {/if}
      </div>
    {/if}
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
  .mail.card { margin: 8px 0; line-height: 1.45; }
  .mail.sent { border-color: color-mix(in srgb, var(--mint) 35%, var(--line2)); }
  .head { display: flex; gap: 8px; align-items: baseline; }
  .row { font-size: 13px; }
  .row .faint { display: inline-block; width: 74px; }
  .invite-row { display: flex; align-items: center; gap: 6px; font-size: 12px; color: var(--iris, var(--text)); padding: 4px 0; }
  .invite-text { color: var(--text); flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  button.small { padding: 2px 8px; font-size: 11px; }
  .body { white-space: pre-wrap; user-select: text; border-top: 1px solid var(--line); padding-top: 6px; line-height: 1.45; }
  label { display: grid; grid-template-columns: 74px 1fr; align-items: center; font-size: 12px; color: var(--text2); }
  textarea { resize: vertical; line-height: 1.4; }
  .buttons { display: flex; justify-content: flex-end; gap: 8px; flex-wrap: wrap; }
  .err { color: var(--coral); font-size: 12px; margin: 0; }
</style>
