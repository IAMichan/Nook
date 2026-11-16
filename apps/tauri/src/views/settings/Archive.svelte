<script lang="ts">
  // Settings › Agents › Archive (`ArchiveSettingsSection` on the Mac): everything put away, newest first, each with
  // Restore and Delete. Coding agent sessions first (where this computer runs them), then Nook's own conversations. A
  // search narrows both; each list ends in "Delete all archived…" (what the search found, while searching), asked once
  // with the count, and never takes something that still works.
  import { onMount } from "svelte";
  import { api, events } from "../../lib/api";
  import { nook, relativeTime } from "../../lib/state.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import { toast } from "../../lib/toast.svelte";
  import { deletable, folderName, shownArchived } from "../../lib/archive";
  import { workspace } from "../../lib/workspace/store.svelte";
  import { workspaceApi, type WorkspaceRun } from "../../lib/workspace/api";
  import type { ConversationSummary } from "../../lib/types";
  import Icon from "../../components/Icon.svelte";

  const agentsHere = $derived(!!nook.info?.capabilities.terminals);
  let conversations = $state<ConversationSummary[]>([]);
  let query = $state("");
  /// What waits for a yes: one row (`run:<id>`, `nook:<id>`) or a whole list (`all:runs`, `all:nooks`).
  let confirming = $state<string | null>(null);

  async function loadConversations() {
    conversations = await api.nooks(true).catch(() => []);
  }
  onMount(() => {
    loadConversations();
    if (agentsHere) workspace.start().catch(() => {});
    const un = events.onNookUpdated(() => loadConversations());
    return () => {
      un.then((f) => f());
    };
  });

  const sessions = $derived(shownArchived(workspace.runs, query, (r) => r.archived, (r) => [r.title, r.projectPath], (r) => r.updatedAt));
  const chats = $derived(shownArchived(conversations, query, (c) => c.archived, (c) => [c.title, c.preview], (c) => c.updated));
  const sessionBusy = (r: WorkspaceRun) => workspace.isRunning(r.id) || r.status === "running" || r.status === "preparing" || r.status === "waitingApproval";
  const deletableSessions = $derived(deletable(sessions, sessionBusy));
  const deletableChats = $derived(deletable(chats, (c) => c.status === "working"));
  const searching = $derived(query.trim().length > 0);

  async function attempt(work: () => Promise<unknown>, failure: string) {
    try {
      await work();
    } catch (e) {
      toast.error(failure, e);
    } finally {
      confirming = null;
    }
  }

  const restoreSession = (r: WorkspaceRun) => attempt(async () => { await workspaceApi.archive(r.id, false); await workspace.refresh(); }, tr("Kon de sessie niet terugzetten", "Could not restore the session"));
  const deleteSession = (r: WorkspaceRun) => attempt(async () => { await workspaceApi.remove(r.id); await workspace.refresh(); }, tr("Kon de sessie niet verwijderen", "Could not delete the session"));
  const restoreChat = (c: ConversationSummary) => attempt(async () => { await api.setNookFlags(c.id, { archived: false }); await Promise.all([loadConversations(), nook.refreshList()]); }, tr("Kon het gesprek niet terugzetten", "Could not restore the conversation"));
  const deleteChat = (c: ConversationSummary) => attempt(async () => { await api.deleteNook(c.id); await loadConversations(); }, tr("Kon het gesprek niet verwijderen", "Could not delete the conversation"));
  const deleteAllSessions = () => attempt(async () => { for (const r of deletableSessions) await workspaceApi.remove(r.id); await workspace.refresh(); }, tr("Kon de sessie niet verwijderen", "Could not delete the session"));
  const deleteAllChats = () => attempt(async () => { for (const c of deletableChats) await api.deleteNook(c.id); await loadConversations(); }, tr("Kon het gesprek niet verwijderen", "Could not delete the conversation"));
</script>

{#snippet item(key: string, title: string, detail: string, when: string, busy: boolean, restore: () => void, remove: () => void)}
  <div class="row item">
    {#if confirming === key}
      <span>{tr("{title} definitief verwijderen?", "Delete {title} for good?", { title })}</span>
      <span class="inline">
        <button class="ghost" onclick={() => (confirming = null)}>{tr("Annuleren", "Cancel")}</button>
        <button class="danger" onclick={remove}>{tr("Verwijderen", "Delete")}</button>
      </span>
    {:else}
      <span class="text">
        <span class="title">{title}</span>
        <span class="faint detail">{detail ? detail + " · " : ""}{relativeTime(when)}</span>
      </span>
      <span class="inline">
        <button disabled={busy} onclick={restore}>{tr("Terugzetten", "Restore")}</button>
        <button class="ghost danger" disabled={busy} title={tr("Verwijderen", "Delete")} aria-label={tr("Verwijderen", "Delete")} onclick={() => (confirming = key)}><Icon name="x" size={14} /></button>
      </span>
    {/if}
  </div>
{/snippet}

{#snippet deleteAll(key: string, count: number, question: string, detail: string, run: () => void)}
  {#if count > 0}
    {#if confirming === key}
      <div class="confirm">
        <span><strong>{question}</strong><br /><small class="faint">{detail}</small></span>
        <span class="inline">
          <button class="ghost" onclick={() => (confirming = null)}>{tr("Annuleren", "Cancel")}</button>
          <button class="danger" onclick={run}>{tr("Verwijderen", "Delete")}</button>
        </span>
      </div>
    {:else}
      <button class="ghost danger all" onclick={() => (confirming = key)}>
        {searching ? tr("{n} gevonden verwijderen…", "Delete {n} found…", { n: count }) : tr("Alle gearchiveerde verwijderen…", "Delete all archived…")}
      </button>
    {/if}
  {/if}
{/snippet}

<h2>{tr("Archief", "Archive")}</h2>
<input class="search" bind:value={query} placeholder={tr("Zoek in het archief", "Search the archive")} aria-label={tr("Zoek in het archief", "Search the archive")} />

{#if agentsHere}
  <h3>{tr("Sessies", "Sessions")}</h3>
  <div class="group">
    {#if sessions.length === 0}<p class="faint empty">{tr("Geen gearchiveerde sessies", "No archived sessions")}</p>{/if}
    {#each sessions as r (r.id)}
      {@render item("run:" + r.id, r.title || tr("Sessie", "Session"), [workspace.provider(r.provider)?.name ?? r.provider, folderName(r.projectPath)].join(" · "), r.updatedAt, sessionBusy(r), () => restoreSession(r), () => deleteSession(r))}
    {/each}
    {@render deleteAll("all:runs", deletableSessions.length,
      tr("{n} gearchiveerde sessies verwijderen?", "Delete {n} archived sessions?", { n: deletableSessions.length }),
      tr("Hun geschiedenis verdwijnt definitief uit Nook. Worktrees worden opgeruimd zoals bij het verwijderen van één sessie. Sessies die nog werken blijven staan.", "Their history leaves Nook for good. Worktrees are cleaned up as when you delete one session. Sessions that are still working stay."),
      deleteAllSessions)}
  </div>
{/if}

<h3>{tr("Nook-gesprekken", "Nook conversations")}</h3>
<div class="group">
  {#if chats.length === 0}<p class="faint empty">{tr("Geen gearchiveerde gesprekken", "No archived conversations")}</p>{/if}
  {#each chats as c (c.id)}
    {@render item("nook:" + c.id, c.title, c.preview, c.updated, c.status === "working", () => restoreChat(c), () => deleteChat(c))}
  {/each}
  {@render deleteAll("all:nooks", deletableChats.length,
    tr("{n} gearchiveerde gesprekken verwijderen?", "Delete {n} archived conversations?", { n: deletableChats.length }),
    tr("Ze verdwijnen definitief uit Nook. Gesprekken waarop Nook nog antwoordt blijven staan.", "They leave Nook for good. Conversations Nook is still answering stay."),
    deleteAllChats)}
</div>

<style>
  .search { width: 100%; max-width: 360px; }
  .item { flex-wrap: nowrap; padding: var(--space-12) 0; }
  .text { display: flex; flex-direction: column; gap: var(--space-2); min-width: 0; }
  .title { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .detail { font: var(--text-detail); color: var(--text3); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .inline { flex: none; }
  .empty { margin: 0; padding: var(--space-16) 0; font: var(--text-detail); }
  .all { margin: var(--space-8) 0; }
  .confirm { display: flex; justify-content: space-between; align-items: center; gap: var(--space-16); padding: var(--space-12) 0; }
  small { font: var(--text-detail); }
</style>
