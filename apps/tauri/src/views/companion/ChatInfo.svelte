<script lang="ts">
  // A chat's info as the Mac shows it (`inboxInfo`): its picture and name, a group's description or a person's bio,
  // the details its app gives, and a group's admins and people.
  import { onMount } from "svelte";
  import { companion, detailLabel, detailValue, type ClientView, type InboxChatDigest, type InboxChatInfo } from "../../lib/companion";
  import { tr } from "../../lib/i18n.svelte";
  import InboxAvatar from "./ui/InboxAvatar.svelte";
  import Ico from "../../components/ui/Ico.svelte";

  let { chat, onclose, took }: { chat: InboxChatDigest; onclose: () => void; took: (v: ClientView) => void } = $props();
  let info = $state<InboxChatInfo | null>(null);
  let failed = $state(false);

  onMount(async () => {
    const r = await companion.call({ op: "inboxInfo", item: chat.id });
    if (r.response?.inboxInfo) info = r.response.inboxInfo;
    else { failed = true; took(r.view); }
  });
  const marks = $derived(info ? [
    info.verified && tr("Geverifieerd", "Verified"),
    info.bot && tr("Een bot", "A bot"),
    info.blocked && tr("Geblokkeerd in {app}", "Blocked in {app}", { app: chat.appName }),
    info.adminsOnly && tr("Alleen beheerders kunnen berichten sturen", "Only admins can send messages"),
  ].filter((m): m is string => !!m) : []);
</script>

<div class="info">
  <div class="bar"><span></span><strong>{tr("Chatinfo", "Chat info")}</strong><button class="link" onclick={onclose}>{tr("Klaar", "Done")}</button></div>
  <div class="scroll">
    <div class="head">
      <InboxAvatar id={chat.id} name={chat.name} app={chat.app} size={72} />
      <strong>{chat.name}</strong>
      <small>{chat.account ? `${chat.appName} · ${chat.account}` : chat.appName}</small>
    </div>
    {#if !info && !failed}<div class="spinner"></div>{/if}
    {#if failed}<p class="none">{tr("Je Mac kon de info van deze chat niet geven.", "Your Mac could not give this chat's info.")}</p>{/if}
    {#if info}
      {#if marks.length}<div class="marks">{#each marks as m (m)}<span><Ico name="info" size={12} />{m}</span>{/each}</div>{/if}
      {#if info.about}
        <h3>{tr("Over", "About")}</h3>
        <p class="card about">{info.about}</p>
      {/if}
      {#if info.details.length}
        <h3>{tr("Details", "Details")}</h3>
        <div class="card">
          {#each info.details as d (d.key + d.value)}<div class="row"><small>{detailLabel(d.key)}</small><span>{detailValue(d.key, d.value)}</span></div>{/each}
        </div>
      {/if}
      {#if info.admins.length}
        <h3>{tr("Beheerders", "Admins")}</h3>
        <div class="card">{#each info.admins as a (a)}<div class="row person"><InboxAvatar name={a} size={28} badge={false} /><span>{a}</span></div>{/each}</div>
      {/if}
      {#if info.members.length}
        <h3>{tr("Leden ({n})", "Members ({n})", { n: info.members.length })}</h3>
        <div class="card">{#each info.members as m (m)}<div class="row person"><InboxAvatar name={m} size={28} badge={false} /><span>{m}</span></div>{/each}</div>
      {/if}
    {/if}
  </div>
</div>

<style>
  .info { flex: 1; min-height: 0; display: flex; flex-direction: column; padding-top: 10px; }
  .bar { display: grid; grid-template-columns: 1fr auto 1fr; align-items: center; padding: 8px 16px; }
  .bar strong { font: 600 17px var(--font); }
  .link { justify-self: end; font: 600 17px var(--font) !important; }
  .scroll { flex: 1; overflow-y: auto; padding: 12px 16px 24px; display: flex; flex-direction: column; gap: 8px; }
  .head { display: flex; flex-direction: column; align-items: center; gap: 6px; padding: 8px 0 12px; }
  .head strong { font: var(--pt-strong); color: var(--paper); text-align: center; }
  .head small { font: var(--pt-caption); color: var(--text3); }
  .spinner { margin: 24px auto; width: 24px; height: 24px; border-radius: 50%; border: 3px solid var(--smoke); border-top-color: var(--text2); animation: spin 0.8s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }
  .none { margin: 0; padding: 24px 0; text-align: center; font: var(--pt-body); color: var(--text2); }
  .marks { display: flex; flex-wrap: wrap; justify-content: center; gap: 6px; }
  .marks span { display: inline-flex; align-items: center; gap: 4px; padding: 4px 10px; border-radius: 999px; background: var(--smoke); font: var(--pt-caption); color: var(--text2); }
  h3 { margin: 12px 0 0 12px; font: var(--pt-label); color: var(--text3); }
  .card { margin: 0; background: var(--surface); border-radius: 12px; }
  .about { padding: 12px 16px; font: var(--pt-body); white-space: pre-wrap; overflow-wrap: anywhere; }
  .row { display: flex; flex-direction: column; gap: 2px; padding: 10px 16px; font: var(--pt-body); overflow-wrap: anywhere; }
  .row.person { flex-direction: row; align-items: center; gap: 10px; }
  .row + .row { border-top: 0.5px solid var(--hairline); }
  .row small { font: var(--pt-caption); color: var(--text3); }
</style>
