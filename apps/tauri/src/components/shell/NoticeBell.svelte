<script lang="ts">
  // The notices Nook gave (the Mac's `NoticeHistory`), behind the bell in the sidebar's head: one you missed (a card that
  // closed by itself, a strip while you were away, a notice held back in a meeting) can still be read, searched and
  // opened where it came from. A count while there are ones you have not seen; opening the list marks them seen.
  import { invoke } from "@tauri-apps/api/core";
  import { listen } from "@tauri-apps/api/event";
  import { tr } from "../../lib/i18n.svelte";
  import { relativeTime } from "../../lib/state.svelte";
  import { tip } from "../ui/tip";
  import Dropdown from "../ui/Dropdown.svelte";
  import SearchField from "../ui/SearchField.svelte";
  import Ico from "../ui/Ico.svelte";

  interface Entry { id: number; key: string; kind: "done" | "failed" | "waiting" | "info"; title: string; detail: string; context: string; date: number; route: string; seen: boolean }
  let { onopen }: { onopen: (route: string) => void } = $props();

  let open = $state(false);
  let unseen = $state(0);
  let query = $state("");
  let entries = $state<Entry[]>([]);

  $effect(() => {
    invoke<number>("notice_history_unseen").then((n) => (unseen = n)).catch(() => {});
    const un = listen<number>("notice-history", (e) => { unseen = e.payload; if (open) load(); });
    return () => { un.then((f) => f()).catch(() => {}); };
  });
  function load() {
    invoke<Entry[]>("notice_history", { query }).then((list) => (entries = list)).catch(() => {});
  }
  $effect(() => { if (open) { void query; load(); } });
  function opened() {
    query = "";
    load();
  }
  $effect(() => {
    if (!open || !unseen) return;
    // Seen once the list closes, so the dots show while you look.
    return () => { invoke("notice_history_seen", { id: null }).catch(() => {}); };
  });

  const marks: Record<Entry["kind"], { icon: string; tone: string }> = {
    done: { icon: "circle-check", tone: "var(--mint)" },
    failed: { icon: "circle-alert", tone: "var(--coral)" },
    waiting: { icon: "hand", tone: "var(--amber)" },
    info: { icon: "bell", tone: "var(--iris)" },
  };
</script>

<Dropdown bind:open below width={340} label={tr("Meldingen", "Notifications")} onopen={opened}>
  {#snippet trigger({ toggle })}
    <button class="ghost icon-button bell" class:on={open} aria-haspopup="dialog" aria-expanded={open} use:tip={tr("Meldingen", "Notifications")} aria-label={tr("Meldingen", "Notifications")} onclick={toggle}>
      <Ico name={unseen ? "bell-dot" : "bell"} size={15} />
      {#if unseen}<span class="count">{unseen > 9 ? "9+" : unseen}</span>{/if}
    </button>
  {/snippet}
  {#snippet children({ close })}
    <div class="dd-header">{tr("Meldingen", "Notifications")}</div>
    <div class="search"><SearchField bind:value={query} placeholder={tr("Zoek in meldingen", "Search notifications")} /></div>
    <div class="list">
      {#each entries as e (e.id)}
        <button class="entry" class:unseen={!e.seen} onclick={() => { invoke("notice_history_seen", { id: e.id }).catch(() => {}); close(); onopen(e.route); }}>
          <span class="mark" style:color={marks[e.kind].tone}><Ico name={marks[e.kind].icon} size={14} /></span>
          <span class="text">
            <span class="title">{e.title}</span>
            {#if e.detail}<span class="detail">{e.detail}</span>{/if}
            <span class="meta">{[e.context, relativeTime(new Date(e.date).toISOString())].filter(Boolean).join(" · ")}</span>
          </span>
          <span class="remove" role="button" tabindex="-1" aria-label={tr("Verwijder", "Remove")} onclick={(ev) => { ev.stopPropagation(); invoke("notice_history_remove", { id: e.id }).then(load).catch(() => {}); }} onkeydown={() => {}}><Ico name="x" size={11} /></span>
        </button>
      {:else}
        <p class="none">{query ? tr("Geen melding gevonden.", "No notification found.") : tr("Nog geen meldingen sinds Nook startte.", "No notifications since Nook started.")}</p>
      {/each}
    </div>
    {#if entries.length && !query}
      <div class="foot"><button class="ghost" onclick={() => invoke("notice_history_remove", { id: null }).then(load).catch(() => {})}>{tr("Alles wissen", "Clear all")}</button></div>
    {/if}
  {/snippet}
</Dropdown>

<style>
  .bell { position: relative; display: grid; place-items: center; width: 28px; height: 28px; padding: 0; border: 0; border-radius: var(--radius-control); color: var(--text2); }
  .bell:hover, .bell.on { background: var(--row-hover); color: var(--paper); }
  .count { position: absolute; top: 1px; right: 0; min-width: 13px; height: 13px; padding: 0 2px; border-radius: 999px; background: var(--amber); color: var(--ink); font: var(--text-caption); line-height: 13px; text-align: center; box-sizing: border-box; }
  .search { padding: 0 var(--space-4) var(--space-6); }
  .list { display: flex; flex-direction: column; max-height: 420px; overflow-y: auto; }
  .entry { position: relative; display: flex; gap: var(--space-8); align-items: flex-start; width: 100%; padding: var(--space-8); border: 0; border-radius: var(--radius-chip); background: transparent; text-align: left; color: var(--paper); }
  .entry:hover { background: var(--smoke); }
  .entry.unseen .title::after { content: ""; display: inline-block; width: 6px; height: 6px; margin-left: var(--space-6); border-radius: 50%; background: var(--iris); vertical-align: middle; }
  .mark { display: inline-flex; padding-top: 2px; flex: none; }
  .text { display: flex; flex-direction: column; gap: var(--space-2); min-width: 0; flex: 1; }
  .title { font: var(--text-emphasis); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .detail { font: var(--text-detail); color: var(--text2); display: -webkit-box; -webkit-line-clamp: 2; line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
  .meta { font: var(--text-caption); color: var(--text3); }
  .remove { display: none; place-items: center; width: 20px; height: 20px; border-radius: var(--radius-chip); color: var(--text3); flex: none; }
  .entry:hover .remove { display: grid; }
  .remove:hover { color: var(--paper); background: var(--row-hover); }
  .none { margin: 0; padding: var(--space-12) var(--space-8); font: var(--text-detail); color: var(--text3); }
  .foot { display: flex; justify-content: flex-end; padding: var(--space-4) var(--space-4) 0; border-top: 1px solid var(--hairline); margin-top: var(--space-4); }
  .foot .ghost { padding: var(--space-4) var(--space-8); font: var(--text-control); }
</style>
