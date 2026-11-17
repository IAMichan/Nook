<script lang="ts">
  // Forwarding a message as the Mac's forward picker does it: tick up to ten chats Nook can write in, then send it to
  // all of them at once (`inboxAct` `forward`).
  import { MAX_FORWARD, type InboxChatDigest, type InboxLine } from "../../lib/companion";
  import { tr } from "../../lib/i18n.svelte";
  import InboxAvatar from "./ui/InboxAvatar.svelte";
  import SearchField from "./ui/SearchField.svelte";
  import Ico from "./ui/Ico.svelte";

  let { line, chats, from, onsend, onclose }: {
    line: InboxLine; chats: InboxChatDigest[]; from: string; onsend: (targets: string[]) => void; onclose: () => void;
  } = $props();
  let query = $state("");
  let chosen = $state<string[]>([]);
  const words = $derived(query.toLowerCase().split(/\s+/).filter(Boolean));
  const list = $derived(
    chats
      .filter((c) => c.canSend && c.id !== from && (!c.kind || c.kind === "chats"))
      .filter((c) => words.every((w) => `${c.name} ${c.appName}`.toLowerCase().includes(w)))
      .sort((a, b) => b.last - a.last),
  );
  function toggle(id: string) {
    if (chosen.includes(id)) chosen = chosen.filter((c) => c !== id);
    else if (chosen.length < MAX_FORWARD) chosen = [...chosen, id];
  }
</script>

<div class="picker">
  <div class="bar">
    <button class="link plain" onclick={onclose}>{tr("Annuleer", "Cancel")}</button>
    <strong>{tr("Doorsturen naar", "Forward to")}</strong>
    <button class="link" disabled={!chosen.length} onclick={() => onsend(chosen)}>{tr("Verstuur", "Send")}</button>
  </div>
  <div class="top">
    <p class="message">{line.text || line.attachment || ""}</p>
    <SearchField bind:value={query} placeholder={tr("Zoek chats", "Search chats")} />
    <small>{tr("{n} van {max} gekozen", "{n} of {max} chosen", { n: chosen.length, max: MAX_FORWARD })}</small>
  </div>
  <div class="scroll">
    {#if !list.length}<p class="none">{tr("Geen chat gevonden.", "No chat matches.")}</p>{/if}
    {#each list as c (c.id)}
      {@const on = chosen.includes(c.id)}
      <button class="row" class:on aria-pressed={on} disabled={!on && chosen.length >= MAX_FORWARD} onclick={() => toggle(c.id)}>
        <InboxAvatar id={c.id} name={c.name} app={c.app} size={36} />
        <span class="text"><strong>{c.name}</strong><small>{c.account ? `${c.appName} · ${c.account}` : c.appName}</small></span>
        <span class="tick">{#if on}<Ico name="check" size={14} stroke={3} />{/if}</span>
      </button>
    {/each}
  </div>
</div>

<style>
  .picker { flex: 1; min-height: 0; display: flex; flex-direction: column; padding-top: 10px; }
  .bar { display: grid; grid-template-columns: 1fr auto 1fr; align-items: center; padding: 8px 16px; }
  .bar strong { font: 600 17px var(--font); }
  .link { justify-self: end; font: 600 17px var(--font) !important; }
  .link.plain { justify-self: start; font-weight: 400 !important; }
  .top { display: flex; flex-direction: column; gap: 8px; padding: 8px 16px; }
  .top small { font: var(--pt-caption); color: var(--text3); padding: 0 4px; }
  .message { margin: 0; padding: 10px 12px; background: var(--surface); border-radius: 12px; font: var(--pt-detail); color: var(--text2); display: -webkit-box; -webkit-line-clamp: 3; line-clamp: 3; -webkit-box-orient: vertical; overflow: hidden; white-space: pre-wrap; }
  .scroll { flex: 1; overflow-y: auto; padding: 0 8px 24px; }
  .none { margin: 0; padding: 24px 0; text-align: center; font: var(--pt-body); color: var(--text2); }
  .row { width: 100%; display: flex; align-items: center; gap: 12px; padding: 10px 12px; text-align: left; border-radius: 12px; }
  .row.on { background: var(--surface) !important; }
  .text { flex: 1; min-width: 0; display: flex; flex-direction: column; }
  .text strong { font: var(--pt-strong); color: var(--text-strong); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .text small { font: var(--pt-caption); color: var(--text3); }
  .tick { width: 24px; height: 24px; border-radius: 50%; border: 1.5px solid var(--smoke); display: inline-flex; align-items: center; justify-content: center; flex: none; }
  .on .tick { background: var(--iris); border-color: var(--iris); color: var(--on-iris); }
</style>
