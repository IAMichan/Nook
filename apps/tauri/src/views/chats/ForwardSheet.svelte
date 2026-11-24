<script lang="ts">
  // Forwarding a message (`ChatForwardPicker`): every chat Nook can write in, of every app, to search and tick; the
  // message goes to each after your click on Forward, and a toast says where it went.
  import { chatsApi } from "../../lib/connectors";
  import { appName, type ChatEntry } from "../../lib/chats-list";
  import { tr } from "../../lib/i18n.svelte";
  import { toast } from "../../lib/toast.svelte";
  import Sheet from "../../components/ui/Sheet.svelte";
  import SearchField from "../../components/ui/SearchField.svelte";
  import ListEmptyNote from "../../components/ui/ListEmptyNote.svelte";
  import Ico from "../../components/ui/Ico.svelte";
  import ChatQuote from "./ChatQuote.svelte";
  import ChatFace from "./ChatFace.svelte";

  let { targets, sender, text, onclose }: { targets: ChatEntry[]; sender: string; text: string; onclose: () => void } = $props();
  let query = $state("");
  let chosen = $state<string[]>([]);
  let sending = $state(false);
  const shown = $derived(targets.filter((t) => !query.trim() || t.name.toLowerCase().includes(query.trim().toLowerCase())));

  function toggle(key: string) {
    chosen = chosen.includes(key) ? chosen.filter((k) => k !== key) : [...chosen, key];
  }

  async function forward() {
    sending = true;
    const done: string[] = [];
    for (const key of chosen) {
      const target = targets.find((t) => t.key === key);
      try {
        await chatsApi.send(key, text, null);
        if (target) done.push(target.name);
      } catch (e) {
        toast.error(tr("Niet verstuurd: {error}", "Not sent: {error}", { error: String(e) }));
      }
    }
    sending = false;
    if (done.length) toast.success(tr("Doorgestuurd naar {names}", "Forwarded to {names}", { names: done.join(", ") }));
    onclose();
  }
</script>

<Sheet {onclose} label={tr("Bericht doorsturen", "Forward message")}>
  <div class="head">
    <strong>{tr("Bericht doorsturen", "Forward message")}</strong>
    <span class="spacer"></span>
    <button class="ghost small" onclick={onclose}>{tr("Annuleer", "Cancel")}</button>
    <button class="primary small" disabled={!chosen.length || sending} onclick={forward}>
      {chosen.length > 1 ? tr("Doorsturen naar {n}", "Forward to {n}", { n: chosen.length }) : tr("Doorsturen", "Forward")}
    </button>
  </div>
  <div class="quote"><ChatQuote {sender} {text} mine={false} /></div>
  <div class="search"><SearchField bind:value={query} placeholder={tr("Zoek een chat of groep", "Search a chat or group")} /></div>
  <div class="list">
    {#each shown as t (t.key)}
      <button class="row" class:on={chosen.includes(t.key)} aria-pressed={chosen.includes(t.key)} onclick={() => toggle(t.key)}>
        <ChatFace id={t.id} app={t.app} name={t.name} size={28} />
        <span class="name">{t.name}</span>
        <span class="app">{appName(t.app)}</span>
        <span class="box">{#if chosen.includes(t.key)}<Ico name="check" size={12} stroke={3} />{/if}</span>
      </button>
    {:else}
      <ListEmptyNote text={targets.length ? tr("Geen chat gevonden.", "No chat found.") : tr("Er is geen chat waarin Nook kan schrijven.", "There is no chat Nook can write in.")} />
    {/each}
  </div>
</Sheet>

<style>
  .head { display: flex; align-items: center; gap: var(--space-6); padding: var(--space-12) var(--space-16) var(--space-8); }
  .head strong { font: var(--text-title); color: var(--paper); }
  .spacer { flex: 1; }
  .small { height: 26px; padding: 0 var(--space-12); font: var(--text-label); font-weight: 600; }
  .quote, .search { padding: 0 var(--space-16) var(--space-8); }
  .list { overflow-y: auto; max-height: 50vh; padding: 0 var(--space-8) var(--space-12); display: flex; flex-direction: column; gap: var(--space-2); }
  .row { display: flex; align-items: center; gap: var(--space-8); padding: var(--space-6) var(--space-8); border: 0; border-radius: var(--radius-control); background: transparent; text-align: left; color: inherit; }
  .row:hover:not(:disabled) { background: var(--row-hover); border: 0; }
  .row.on { background: var(--row-selected); }
  .name { flex: 1; min-width: 0; font: var(--text-emphasis); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .app { font: var(--text-caption); color: var(--text3); }
  .box { width: 16px; height: 16px; display: grid; place-items: center; border: 1px solid var(--field-stroke); border-radius: 50%; color: var(--on-iris); }
  .on .box { background: var(--iris); border-color: var(--iris); }
</style>
