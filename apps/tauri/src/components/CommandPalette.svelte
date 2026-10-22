<script lang="ts">
  import { onMount, type ComponentProps } from "svelte";
  import { api } from "../lib/api";
  import { nook } from "../lib/state.svelte";
  import { toast } from "../lib/toast.svelte";
  import type { ConversationSummary } from "../lib/types";
  import Icon from "./Icon.svelte";

  let { onclose, onnavigate, companionEnabled = false }: {
    onclose: () => void;
    onnavigate: (route: "chat" | "agents" | "workspace" | "companion" | "settings") => void;
    companionEnabled?: boolean;
  } = $props();

  type Command = { id: string; title: string; icon: ComponentProps<typeof Icon>["name"]; run: () => void | Promise<void> };
  let dialog: HTMLDialogElement;
  let input: HTMLInputElement;
  let query = $state("");
  let selected = $state(0);
  let results = $state<ConversationSummary[]>([]);
  let searching = $state(false);
  let searchError = $state(false);

  onMount(() => {
    const previous = document.activeElement;
    dialog.showModal();
    input.focus();
    return () => {
      dialog.close();
      if (previous instanceof HTMLElement && previous.isConnected) previous.focus();
    };
  });

  const commands = $derived.by((): Command[] => [
    { id: "new", title: "New Nook", icon: "plus", run: async () => { await nook.newNook(); onnavigate("chat"); } },
    { id: "chat", title: "Open chat", icon: "chat", run: () => onnavigate("chat") },
    { id: "agents", title: "Open agents", icon: "agents", run: () => onnavigate("agents") },
    ...(nook.info?.capabilities.terminals ? [{ id: "workspace", title: "Open workspace", icon: "workspace", run: () => onnavigate("workspace") } satisfies Command] : []),
    ...(companionEnabled ? [{ id: "companion", title: "Open companion", icon: "phone", run: () => onnavigate("companion") } satisfies Command] : []),
    { id: "settings", title: "Open settings", icon: "settings", run: () => onnavigate("settings") },
  ]);
  const items = $derived<Command[]>([
    ...commands.filter((c) => c.title.toLowerCase().includes(query.trim().toLowerCase())),
    ...(query.trim() ? results : nook.nooks.filter((n) => n.preview || n.id === nook.activeId).slice(0, 8)).map((n): Command => ({
      id: `nook:${n.id}`, title: n.title, icon: "chat", run: async () => { await nook.select(n.id); onnavigate("chat"); },
    })),
  ]);
  const activeIndex = $derived(Math.min(selected, Math.max(0, items.length - 1)));

  $effect(() => {
    const q = query.trim();
    selected = 0;
    results = [];
    searchError = false;
    searching = !!q;
    if (!q) return;
    let stale = false;
    const timer = setTimeout(async () => {
      try {
        const found = await api.searchNooks(q);
        if (!stale) results = found.slice(0, 12);
      } catch {
        if (!stale) searchError = true;
      } finally {
        if (!stale) searching = false;
      }
    }, 150);
    return () => { stale = true; clearTimeout(timer); };
  });

  async function choose(command: Command) {
    onclose();
    try { await command.run(); }
    catch (e) { toast.error("Could not open that item", e); }
  }

  function keys(e: KeyboardEvent) {
    if ((e.key === "ArrowDown" || e.key === "ArrowUp") && items.length) {
      e.preventDefault();
      input.focus();
      selected = (activeIndex + (e.key === "ArrowDown" ? 1 : -1) + items.length) % items.length;
      queueMicrotask(() => dialog.querySelector(`[data-index="${selected}"]`)?.scrollIntoView({ block: "nearest" }));
    } else if (e.key === "Enter" && !e.isComposing && e.target === input) {
      e.preventDefault();
      const command = items[activeIndex];
      if (command) choose(command);
    }
  }
</script>

<dialog bind:this={dialog} aria-label="Quick switcher" onclose={onclose} onkeydown={keys} onclick={(e) => { if (e.target === dialog) onclose(); }}>
  <div class="palette">
    <div class="search"><Icon name="search" size={20} /><input bind:this={input} bind:value={query} aria-label="Search actions and conversations" placeholder="Where would you like to go?" /><button class="ghost" onclick={onclose} aria-label="Close quick switcher">Esc</button></div>
    <div class="results">
      <div class="label">{query.trim() ? "RESULTS" : "QUICK ACTIONS & RECENT NOOKS"}</div>
      {#each items as command, i (command.id)}
        <button class="result" class:active={i === activeIndex} data-index={i} onclick={() => choose(command)} onfocus={() => (selected = i)}><Icon name={command.icon} /><span>{command.title}</span><small>{command.id.startsWith("nook:") ? "Conversation" : "Action"}</small></button>
      {:else}
        {#if !searching}<p class="empty">No matches. Try a different search.</p>{/if}
      {/each}
      {#if searching}<p class="note" role="status">Searching conversations…</p>{/if}
      {#if searchError}<p class="error" role="alert">Could not search conversations. Close and try again.</p>{/if}
    </div>
    <footer><span>↑ ↓ to navigate</span><span>Enter to open</span><span>Ctrl K to toggle</span></footer>
  </div>
</dialog>

<style>
  dialog { width: min(560px, calc(100vw - 32px)); max-height: calc(100dvh - 64px); padding: 0; margin: 12dvh auto auto; color: var(--paper); background: var(--graphite); border: 1px solid var(--line2); border-radius: var(--radius); box-shadow: var(--shadow-popover); overflow: hidden; }
  dialog::backdrop { background: #0009; backdrop-filter: blur(5px); }
  .palette { display: flex; flex-direction: column; max-height: calc(100dvh - 24dvh); }
  .search { display: flex; align-items: center; gap: 12px; padding: 14px 16px; border-bottom: 1px solid var(--line2); color: var(--text2); }
  input { flex: 1; min-width: 0; padding: 6px 0; border: 0; background: transparent; box-shadow: none; font-size: 14px; }
  input:focus-visible { box-shadow: none; }
  .search button { font-size: 10px; padding: 4px 6px; }
  .results { min-height: 0; overflow-y: auto; padding: 8px; }
  .label { padding: 10px; color: var(--text3); font-size: 9px; font-weight: 600; letter-spacing: 1.2px; }
  .result { display: flex; align-items: center; gap: 12px; width: 100%; padding: 11px 12px; text-align: left; background: transparent; border: 1px solid transparent; }
  .result.active { background: var(--smoke); border-color: var(--line2); }
  .result span { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  small { color: var(--text3); font-size: 10px; }
  footer { display: flex; flex-wrap: wrap; gap: 16px; padding: 12px 18px; border-top: 1px solid var(--line); color: var(--text3); font-size: 10px; }
  .note, .empty, .error { margin: 12px; font-size: 12px; color: var(--text2); }
  .error { color: var(--coral); }
  @media (max-width: 640px) { small { display: none; } }
</style>
