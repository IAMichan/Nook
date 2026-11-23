<script lang="ts">
  // Settings › Sessions › Editor & browser (`WorkspaceSettingsSection` parts openIn and browser on the Mac): the editor
  // and terminal a session's folder opens in, then Nook's browser: its search engine, where an agent's links open, and
  // the pages it remembers. Sign-ins, saved passwords, trusted certificates, extensions and the default browser are left
  // out on Windows (docs/WINDOWS-PARITY.md, UI-27): Nook's browser window keeps nothing.
  import { tr } from "../../lib/i18n.svelte";
  import { ask } from "../../lib/confirm.svelte";
  import { workspaceApi, type WorkspaceSettings } from "../../lib/workspace/api";
  import { workspace } from "../../lib/workspace/store.svelte";
  import { openInApi, searchEngines, setLinkTarget, type OpenInPrefs } from "../../lib/workspace/open-in";

  let s = $state<WorkspaceSettings | null>(null);
  let prefs = $state<OpenInPrefs | null>(null);
  let editors = $state<{ id: string; name: string }[]>([]);
  let terminals = $state<{ id: string; name: string }[]>([{ id: "nook", name: "Nook" }]);
  let kept = $state(0);
  let error = $state<string | null>(null);

  $effect(() => {
    workspace.start().then(() => (s = workspace.settings ? { ...workspace.settings } : null));
    workspaceApi.editors().then((e) => (editors = e)).catch(() => {});
    openInApi.terminals().then((t) => (terminals = t)).catch(() => {});
    openInApi.prefs().then((p) => (prefs = p)).catch((e) => (error = String(e)));
    openInApi.historyCount().then((n) => (kept = n)).catch(() => {});
  });

  async function saveEditor() {
    if (!s) return;
    try {
      await workspaceApi.saveSettings($state.snapshot(s));
      await workspace.refresh();
    } catch (e) {
      error = String(e);
    }
  }

  async function savePrefs(change: Partial<OpenInPrefs>) {
    if (!prefs) return;
    try {
      prefs = await openInApi.save({ ...$state.snapshot(prefs), ...change });
      setLinkTarget(prefs.linkTarget);
      if (!prefs.rememberHistory) kept = 0;
    } catch (e) {
      error = String(e);
    }
  }

  async function clearHistory() {
    const ok = await ask({
      question: tr("De browsergeschiedenis wissen?", "Clear the browser history?"),
      detail: tr("Elke pagina die je in de browser van Nook bezocht, wordt vergeten.", "Every page you visited in Nook’s browser is forgotten."),
      confirmTitle: tr("Geschiedenis wissen", "Clear history"),
    });
    if (!ok) return;
    await openInApi.clearHistory().catch((e) => (error = String(e)));
    kept = 0;
  }
</script>

<h3>{tr("Openen in", "Open in")}</h3>
<div class="group">
  <label class="row"><span>{tr("Editor", "Editor")}</span>
    {#if s}
      <select bind:value={s.editor} onchange={saveEditor}>
        <option value="">{tr("Verkenner", "File Explorer")}</option>
        {#each editors as e (e.id)}<option value={e.id}>{e.name}</option>{/each}
        {#if s.editor && !editors.some((e) => e.id === s!.editor)}<option value={s.editor}>{s.editor}</option>{/if}
      </select>
    {/if}
  </label>
  <label class="row"><span>{tr("Terminal", "Terminal")}</span>
    {#if prefs}
      <select value={prefs.terminal} onchange={(e) => savePrefs({ terminal: e.currentTarget.value })}>
        {#each terminals as t (t.id)}<option value={t.id}>{t.name}</option>{/each}
        {#if !terminals.some((t) => t.id === prefs!.terminal)}<option value={prefs.terminal}>{prefs.terminal}</option>{/if}
      </select>
    {/if}
  </label>
</div>

{#if prefs}
  <h3>{tr("De browser van Nook", "Nook's browser")}</h3>
  <div class="group">
    <label class="row"><span>{tr("Zoekmachine in de browser", "Browser search engine")}</span>
      <select value={prefs.searchEngine} onchange={(e) => savePrefs({ searchEngine: e.currentTarget.value as OpenInPrefs["searchEngine"] })}>
        {#each searchEngines as engine (engine.id)}<option value={engine.id}>{engine.name}</option>{/each}
      </select>
    </label>
    <label class="row"><span>{tr("Links in een gesprek openen in", "Open links in a conversation in")}</span>
      <select value={prefs.linkTarget} onchange={(e) => savePrefs({ linkTarget: e.currentTarget.value as OpenInPrefs["linkTarget"] })}>
        <option value="app">{tr("De browser van Nook", "Nook's browser")}</option>
        <option value="system">{tr("Je eigen browser", "Your own browser")}</option>
      </select>
    </label>
    <label class="row">
      <span>
        {tr("Bezochte pagina's onthouden", "Remember visited pages")}<br />
        <small>{tr("Terwijl je typt stelt de adresbalk pagina's voor die je eerder bezocht. Pagina's die agents openen blijven erbuiten. Uitzetten wist ze.", "The address bar suggests pages you visited before while you type. Pages agents open are left out. Turning this off clears them.")}</small>
      </span>
      <input type="checkbox" role="switch" checked={prefs.rememberHistory} onchange={(e) => savePrefs({ rememberHistory: e.currentTarget.checked })} />
    </label>
    {#if prefs.rememberHistory && kept > 0}
      <div class="row">
        <span>
          {tr("Bezochte pagina's", "Visited pages")}<br />
          <small>{tr("{n} pagina's onthouden op deze computer.", "{n} pages remembered on this computer.", { n: kept })}</small>
        </span>
        <button class="small" onclick={clearHistory}>{tr("Geschiedenis wissen", "Clear history")}</button>
      </div>
    {/if}
  </div>
{/if}
{#if error}<p class="err">{error}</p>{/if}

<style>
  small { font: var(--text-detail); line-height: 1.3; color: var(--text2); display: inline-block; }
  .err { color: var(--coral); font: var(--text-detail); }
</style>
