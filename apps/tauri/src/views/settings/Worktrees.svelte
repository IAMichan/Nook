<script lang="ts">
  // Settings › Sessions › Worktrees (`WorkspaceSettingsSection` part worktrees + `SourceControlGlobalRows` +
  // `WorktreeCleanupReportView` on the Mac): where new worktrees go, source-control defaults, cleanup rules,
  // stale worktree status, latest cleanup report and orphan folders.
  import { invoke } from "@tauri-apps/api/core";
  import { open as openDialog } from "@tauri-apps/plugin-dialog";
  import { nook } from "../../lib/state.svelte";
  import { workspaceApi, type WorkspaceSettings } from "../../lib/workspace/api";
  import { workspace } from "../../lib/workspace/store.svelte";
  import { readableSize } from "../../lib/maintenance";
  import { tr } from "../../lib/i18n.svelte";
  import type { Settings } from "../../lib/types";

  type SubmodulesMode = "recursive" | "topLevel" | "skip";
  type KeepWhenMode = "uncommittedChanges" | "anyLocalFiles" | "editedTrackedFiles";

  interface WorktreeSettings {
    fastWorktrees: boolean;
    submodules: SubmodulesMode;
    autoPullDefaultBranch: boolean;
    cloneHostLayout: boolean;
    cleanupOnMerge: boolean;
    cleanupSettledDays: number;
    cleanupInactiveDays: number;
    cleanupUnchanged: boolean;
    cleanupOnDelete: boolean;
    keepWhen: KeepWhenMode;
  }

  interface WorktreeCleanupEntry {
    path: string;
    title: string | null;
    outcome: "removed" | "kept" | "failed";
    reason: string;
    bytes: number | null;
  }

  interface WorktreeOrphan {
    path: string;
    bytes: number;
  }

  interface WorktreeCleanupReport {
    finishedAt: string;
    entries: WorktreeCleanupEntry[];
    orphans: WorktreeOrphan[];
    bytesFreed: number;
  }

  interface WorktreeCleanupStatus {
    totalWorktrees: number;
    staleCount: number;
    orphans: WorktreeOrphan[];
    latestReport: WorktreeCleanupReport | null;
  }

  const DEFAULT_WORKTREES: WorktreeSettings = {
    fastWorktrees: true,
    submodules: "recursive",
    autoPullDefaultBranch: false,
    cloneHostLayout: false,
    cleanupOnMerge: true,
    cleanupSettledDays: 7,
    cleanupInactiveDays: 0,
    cleanupUnchanged: false,
    cleanupOnDelete: false,
    keepWhen: "uncommittedChanges",
  };

  let ws = $state<WorkspaceSettings | null>(null);
  let status = $state<WorktreeCleanupStatus | null>(null);
  let cleaning = $state(false);
  let error = $state<string | null>(null);

  const rules = $derived.by<WorktreeSettings>(() => {
    const raw = (nook.settings as unknown as { worktrees?: Partial<WorktreeSettings> } | null)?.worktrees;
    return { ...DEFAULT_WORKTREES, ...(raw ?? {}) };
  });

  async function refreshStatus() {
    try {
      status = await invoke<WorktreeCleanupStatus>("workspace_worktree_cleanup_status");
    } catch {
      // Command may not be wired yet in older builds; keep UI usable.
    }
  }

  $effect(() => {
    workspace.start().then(() => {
      ws = workspace.settings ? { ...workspace.settings } : null;
    });
    refreshStatus();
  });

  async function saveWorkspace() {
    if (!ws) return;
    error = null;
    try {
      await workspaceApi.saveSettings($state.snapshot(ws));
      await workspace.refresh();
      await refreshStatus();
    } catch (e) {
      error = String(e);
    }
  }

  async function saveRules(patch: Partial<WorktreeSettings>) {
    error = null;
    try {
      const next: WorktreeSettings = { ...rules, ...patch };
      await nook.saveSettings({ worktrees: next } as unknown as Partial<Settings>);
      await refreshStatus();
    } catch (e) {
      error = String(e);
    }
  }

  /// " Team/Michan " → "team/michan", matching `normalized_branch_prefix` in core; empty becomes "nook".
  function normalizedPrefix(raw: string): string {
    const parts = raw
      .split("/")
      .map((p) => p.trim())
      .filter((p) => /[\p{L}\p{N}]/u.test(p))
      .map((p) =>
        p
          .normalize("NFKD")
          .replace(/[\u0300-\u036f]/g, "")
          .toLowerCase()
          .replace(/[^a-z0-9]+/g, "-")
          .replace(/^-+|-+$/g, "")
          .slice(0, 32)
          .replace(/-+$/, ""),
      )
      .filter(Boolean);
    return parts.length ? parts.join("/") : "nook";
  }

  async function chooseRoot() {
    const picked = await openDialog({ directory: true, multiple: false }).catch(() => null);
    if (typeof picked === "string" && ws) {
      ws.worktreeRoot = picked;
      saveWorkspace();
    }
  }

  async function runCleanupNow() {
    cleaning = true;
    error = null;
    try {
      const report = await invoke<WorktreeCleanupReport>("workspace_worktree_cleanup_now");
      await refreshStatus();
      if (status) {
        status = { ...status, latestReport: report, orphans: report.orphans };
      } else {
        status = { totalWorktrees: 0, staleCount: 0, orphans: report.orphans, latestReport: report };
      }
      await workspace.refresh();
    } catch (e) {
      error = String(e);
    } finally {
      cleaning = false;
    }
  }

  async function revealFolder(path: string) {
    error = null;
    try {
      await invoke("workspace_reveal_path", { path });
    } catch (e) {
      error = String(e);
    }
  }

  function outcomeLabel(outcome: WorktreeCleanupEntry["outcome"]): string {
    switch (outcome) {
      case "removed":
        return tr("Verwijderd", "Removed");
      case "kept":
        return tr("Bewaard", "Kept");
      default:
        return tr("Mislukt", "Failed");
    }
  }

  function reasonLabel(reason: string): string {
    switch (reason) {
      case "mergedPullRequest":
        return tr("pull request gemerged", "pull request merged");
      case "settled":
        return tr("sessie afgerond", "session settled");
      case "inactive":
        return tr("sessie stil", "session quiet");
      case "unchanged":
        return tr("niets naast de basisbranch", "nothing beyond the base branch");
      case "deletedSession":
        return tr("sessie verwijderd", "session deleted");
      case "active":
        return tr("in gebruik", "in use");
      case "openTerminal":
        return tr("er staat een terminal open", "a terminal is open in it");
      case "shared":
        return tr("een andere sessie gebruikt hem", "another session uses it");
      case "symlink":
        return tr("een symbolische koppeling", "a symbolic link");
      case "branchChanged":
        return tr("er staat een andere branch uitgecheckt", "another branch is checked out");
      case "uncommittedChanges":
        return tr("lokale wijzigingen", "local changes");
      case "unpushedCommits":
        return tr("commits die niet gepusht zijn", "commits that are not pushed");
      default:
        return reason;
    }
  }

  function folderName(path: string): string {
    const clean = path.replace(/[\\/]+$/, "");
    const idx = Math.max(clean.lastIndexOf("/"), clean.lastIndexOf("\\"));
    return idx >= 0 ? clean.slice(idx + 1) : clean;
  }

  const report = $derived(status?.latestReport ?? null);
  const removedCount = $derived(report ? report.entries.filter((e) => e.outcome === "removed").length : 0);
  const keptCount = $derived(report ? report.entries.filter((e) => e.outcome === "kept").length : 0);
  const failedCount = $derived(report ? report.entries.filter((e) => e.outcome === "failed").length : 0);
  const orphans = $derived(status?.orphans ?? []);
</script>

{#if !ws}
  <p class="faint">{tr("Laden…", "Loading…")}</p>
{:else}
  <h3>{tr("Nieuwe worktrees", "New worktrees")}</h3>
  <div class="group">
    <div class="row">
      <span>{tr("Map voor worktrees", "Worktree folder")}</span>
      <span class="inline">
        <span class="path">{ws.worktreeRoot || "~/.nook/worktrees"}</span>
        <button class="small" onclick={chooseRoot}>{tr("Wijzig…", "Change…")}</button>
        {#if ws.worktreeRoot}
          <button
            class="small"
            onclick={() => {
              ws!.worktreeRoot = "";
              saveWorkspace();
            }}
          >
            {tr("Standaard", "Default")}
          </button>
        {/if}
      </span>
    </div>

    <div class="row">
      <span>{tr("Prefix voor branches", "Branch prefix")}</span>
      <span class="inline">
        <input
          class="prefix"
          placeholder="nook"
          aria-label={tr("Prefix voor branches", "Branch prefix")}
          value={ws.branchPrefix ?? "nook"}
          onchange={(e) => {
            ws!.branchPrefix = normalizedPrefix(e.currentTarget.value);
            e.currentTarget.value = ws!.branchPrefix;
            saveWorkspace();
          }}
        />
        <span class="example">
          {tr("bijv. {prefix}/fix-login-3fa2", "e.g. {prefix}/fix-login-3fa2", {
            prefix: normalizedPrefix(ws.branchPrefix ?? "nook"),
          })}
        </span>
      </span>
    </div>

    <label class="row">
      <span>
        {tr("Snelle worktrees", "Fast worktrees")}<br />
        <small>
          {tr(
            "Nieuwe worktrees zijn copy-on-write-klonen van een bewaarde checkout als het bestandssysteem dat ondersteunt, zodat een grote repository snel opent; alles wat afwijkt gebruikt gewoon git worktree add.",
            "New worktrees are copy-on-write clones of a cached checkout when the filesystem supports it, so a large repository opens quickly; anything unusual uses plain git worktree add.",
          )}
        </small>
      </span>
      <input
        type="checkbox"
        role="switch"
        checked={rules.fastWorktrees}
        onchange={(e) => saveRules({ fastWorktrees: e.currentTarget.checked })}
      />
    </label>

    <label class="row">
      <span>
        {tr("Submodules", "Submodules")}<br />
        <small>
          {tr(
            "Hoe een nieuwe worktree de submodules van de repository uitcheckt. Overslaan als een setupscript het doet.",
            "How a new worktree checks out the repository's submodules. Skip when a setup script does it.",
          )}
        </small>
      </span>
      <select
        value={rules.submodules}
        onchange={(e) => saveRules({ submodules: e.currentTarget.value as SubmodulesMode })}
      >
        <option value="recursive">{tr("Alle, recursief", "All, recursively")}</option>
        <option value="topLevel">{tr("Alleen het bovenste niveau", "Top level only")}</option>
        <option value="skip">{tr("Overslaan", "Skip")}</option>
      </select>
    </label>

    <label class="row">
      <span>
        {tr("Standaardbranch bijhouden", "Keep the default branch up to date")}<br />
        <small>
          {tr(
            "Ongeveer elke 15 minuten haalt Nook de standaardbranch op en spoelt de hoofdcheckout vooruit, alleen als die op die branch staat, geen wijzigingen heeft en er geen sessie in werkt. Nooit een merge.",
            "About every 15 minutes Nook fetches the default branch and fast-forwards the main checkout, only when it is on that branch, has no changes, and no session works in it. Never a merge.",
          )}
        </small>
      </span>
      <input
        type="checkbox"
        role="switch"
        checked={rules.autoPullDefaultBranch}
        onchange={(e) => saveRules({ autoPullDefaultBranch: e.currentTarget.checked })}
      />
    </label>

    <label class="row">
      <span>
        {tr("Klonen naar host/eigenaar/repo", "Clone into host/owner/repo")}<br />
        <small>
          {tr(
            "Een kloon komt in github.com/eigenaar/repo onder ~/Developer (of onder de map waar de indeling van je huidige project begint).",
            "A clone goes to github.com/owner/repo under ~/Developer (or under the folder your current project's layout starts at).",
          )}
        </small>
      </span>
      <input
        type="checkbox"
        role="switch"
        checked={rules.cloneHostLayout}
        onchange={(e) => saveRules({ cloneHostLayout: e.currentTarget.checked })}
      />
    </label>
  </div>

  <h3>{tr("Worktrees opruimen", "Worktree cleanup")}</h3>
  <div class="group">
    <label class="row">
      <span>{tr("Worktree verwijderen zodra de pull request is gemerged", "Remove the worktree once its pull request is merged")}</span>
      <input
        type="checkbox"
        role="switch"
        checked={rules.cleanupOnMerge}
        onchange={(e) => saveRules({ cleanupOnMerge: e.currentTarget.checked })}
      />
    </label>

    <label class="row">
      <span>{tr("Worktree verwijderen na een afgeronde sessie", "Remove the worktree after a settled session")}</span>
      <select
        value={rules.cleanupSettledDays}
        onchange={(e) => saveRules({ cleanupSettledDays: Number(e.currentTarget.value) })}
      >
        <option value={0}>{tr("Nooit", "Never")}</option>
        {#each [3, 7, 30] as n (n)}
          <option value={n}>{tr("{n} dagen", "{n} days", { n })}</option>
        {/each}
      </select>
    </label>

    <label class="row">
      <span>{tr("Worktree verwijderen na een stille sessie", "Remove the worktree after a quiet session")}</span>
      <select
        value={rules.cleanupInactiveDays}
        onchange={(e) => saveRules({ cleanupInactiveDays: Number(e.currentTarget.value) })}
      >
        <option value={0}>{tr("Nooit", "Never")}</option>
        {#each [3, 7, 30] as n (n)}
          <option value={n}>{tr("{n} dagen", "{n} days", { n })}</option>
        {/each}
      </select>
    </label>

    <label class="row">
      <span>{tr("Worktree verwijderen zonder commits naast de basisbranch", "Remove a worktree with no commits beyond its base branch")}</span>
      <input
        type="checkbox"
        role="switch"
        checked={rules.cleanupUnchanged}
        onchange={(e) => saveRules({ cleanupUnchanged: e.currentTarget.checked })}
      />
    </label>

    <label class="row">
      <span>{tr("Worktree verwijderen als de laatste sessie erin verwijderd wordt", "Remove the worktree when its last session is deleted")}</span>
      <input
        type="checkbox"
        role="switch"
        checked={rules.cleanupOnDelete}
        onchange={(e) => saveRules({ cleanupOnDelete: e.currentTarget.checked })}
      />
    </label>

    <label class="row">
      <span>
        {tr("Worktree laten staan bij", "Keep a worktree with")}<br />
        <small>
          {tr(
            "Niet-gecommitte wijzigingen: gewijzigde en nieuwe bestanden houden de worktree; genegeerde bestanden zoals builds en .env gaan mee. Alle lokale bestanden: ook genegeerde bestanden houden hem (behalve node_modules). Gewijzigde gevolgde bestanden: alleen wijzigingen in gevolgde bestanden houden hem.",
            "Uncommitted changes: edited and new files keep the worktree; ignored files such as builds and .env go with it. Any local files: ignored files keep it too (except node_modules). Edited tracked files: only edits to tracked files keep it.",
          )}
        </small>
      </span>
      <select
        value={rules.keepWhen}
        onchange={(e) => saveRules({ keepWhen: e.currentTarget.value as KeepWhenMode })}
      >
        <option value="uncommittedChanges">{tr("Niet-gecommitte wijzigingen", "Uncommitted changes")}</option>
        <option value="anyLocalFiles">{tr("Alle lokale bestanden", "Any local files")}</option>
        <option value="editedTrackedFiles">{tr("Gewijzigde gevolgde bestanden", "Edited tracked files")}</option>
      </select>
    </label>

    <div class="row cleanup-action">
      <div class="summary-col">
        <span class="label">{tr("Laatste opruimronde", "Latest cleanup")}</span>
        <small class="faint">
          {#if status}
            {#if status.staleCount > 0}
              {tr("{stale} van {total} worktrees klaar om op te ruimen.", "{stale} of {total} worktrees ready to clean up.", {
                stale: status.staleCount,
                total: status.totalWorktrees,
              })}
            {:else if status.totalWorktrees > 0}
              {tr("{total} worktrees actief, geen verouderde worktrees.", "{total} active worktrees, no stale worktrees.", {
                total: status.totalWorktrees,
              })}
            {:else}
              {tr("Geen extra worktrees gevonden.", "No extra worktrees found.")}
            {/if}
          {/if}
        </small>
        <small class="faint">
          {#if !report}
            {tr("Er is nog niet opgeruimd.", "No cleanup has run yet.")}
          {:else if report.entries.length === 0}
            {tr("Geen regel was van toepassing op een worktree.", "No rule applied to any worktree.")}
          {:else}
            {tr("{removed} verwijderd · {kept} bewaard · {failed} mislukt", "{removed} removed · {kept} kept · {failed} failed", {
              removed: removedCount,
              kept: keptCount,
              failed: failedCount,
            })}
            {#if report.bytesFreed > 0}
              · {tr("{size} vrijgemaakt", "{size} freed", { size: readableSize(report.bytesFreed) })}
            {/if}
          {/if}
        </small>
      </div>
      <button class="small" disabled={cleaning} onclick={runCleanupNow}>
        {cleaning ? tr("Opruimen…", "Cleaning up…") : tr("Nu opruimen", "Clean up now")}
      </button>
    </div>

    {#if report && report.entries.length > 0}
      <div class="report-list">
        {#each report.entries as entry (entry.path + entry.outcome)}
          <div class="report-entry">
            <div class="entry-main">
              <span class="entry-title">{entry.title || folderName(entry.path)}</span>
              <span class="outcome {entry.outcome}">{outcomeLabel(entry.outcome)}</span>
            </div>
            <div class="entry-meta">
              <span class="path">{entry.path}</span>
              <span class="faint">
                {reasonLabel(entry.reason)}{#if entry.bytes != null && entry.bytes > 0} · {readableSize(entry.bytes)}{/if}
              </span>
            </div>
          </div>
        {/each}
      </div>
    {/if}
  </div>

  {#if orphans.length > 0}
    <h3>{tr("Mappen die geen sessie gebruikt", "Folders no session uses")}</h3>
    <p class="section-info">
      {tr(
        "In de worktreemap van Nook, al een uur niet aangeraakt en door geen sessie gebruikt. Opruimen verwijdert ze nooit; haal ze weg onder Worktrees als je ze niet meer nodig hebt.",
        "In Nook's worktree folder, untouched for an hour and used by no session. Cleanup never removes them; remove them under Worktrees if you no longer need them.",
      )}
    </p>
    <div class="group">
      {#each orphans as orphan (orphan.path)}
        <div class="row">
          <div class="summary-col">
            <span class="entry-title">{folderName(orphan.path)}</span>
            <small class="path">{orphan.path}</small>
          </div>
          <span class="inline">
            <span class="faint">{readableSize(orphan.bytes)}</span>
            <button class="small" onclick={() => revealFolder(orphan.path)}>
              {tr("Toon in Verkenner", "Show in Explorer")}
            </button>
          </span>
        </div>
      {/each}
    </div>
  {/if}

  {#if error}<p class="err">{error}</p>{/if}
{/if}

<style>
  small { font: var(--text-detail); line-height: 1.3; color: var(--text2); display: inline-block; }
  .inline { display: flex; gap: var(--space-8); align-items: center; }
  .path { font: var(--text-code); color: var(--text2); word-break: break-all; user-select: text; }
  .prefix { width: 160px; }
  .example { color: var(--text2); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .cleanup-action { align-items: flex-start; }
  .summary-col { display: flex; flex-direction: column; gap: var(--space-2); min-width: 0; flex: 1; }
  .label { color: var(--paper); font: var(--text-body); }
  .report-list { display: flex; flex-direction: column; border-top: 1px solid var(--separator); padding: var(--space-8) 0; gap: var(--space-8); }
  .report-entry { display: flex; flex-direction: column; gap: var(--space-2); padding: var(--space-4) 0; }
  .entry-main { display: flex; align-items: center; justify-content: space-between; gap: var(--space-8); }
  .entry-title { color: var(--paper); font: var(--text-emphasis); min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .entry-meta { display: flex; flex-direction: column; gap: var(--space-2); font: var(--text-detail); }
  .outcome { font: var(--text-caption); padding: var(--space-2) var(--space-6); border-radius: var(--radius-chip); background: var(--smoke); color: var(--text2); flex: none; }
  .outcome.removed { color: var(--mint); }
  .outcome.kept { color: var(--amber); }
  .outcome.failed { color: var(--coral); }
  .err { color: var(--coral); font: var(--text-detail); }
</style>
