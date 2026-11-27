<script lang="ts">
  // "Add project" palette (`AddProjectPalette` on macOS, #1482, AG-113) with four sources:
  // New project (empty Git repository from a name), Local folder (disk picker), Git URL (clone),
  // and GitHub repository (`owner/repo`, clone).
  import { open as openDialog } from "@tauri-apps/plugin-dialog";
  import Ico from "../../components/ui/Ico.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import { workspaceApi } from "../../lib/workspace/api";
  import { workspace } from "../../lib/workspace/store.svelte";
  import {
    githubCloneUrl,
    isValidCloneUrl,
    repositoryUrlFromPage,
    sanitizeProjectName,
  } from "../../lib/workspace/project-sources";

  let {
    onadded,
    onclose,
  }: {
    onadded: (folder: string) => void;
    onclose: () => void;
  } = $props();

  type Step = "sources" | "name" | "gitURL" | "github";

  interface SourceItem {
    id: string;
    icon: string;
    title: string;
    detail: string;
    steps: boolean;
    run: () => void;
  }

  let step = $state<Step>("sources");
  let text = $state("");
  let index = $state(0);
  let busy = $state(false);
  let error = $state<string | null>(null);
  let inputEl = $state<HTMLInputElement | null>(null);

  const near = $derived(workspace.settings?.lastProject || null);

  const allSources = $derived<SourceItem[]>([
    {
      id: "new",
      icon: "folder-plus",
      title: tr("Nieuw project", "New project"),
      detail: tr("Begin een nieuwe Git-repository met een naam", "Start a new Git repository from a name"),
      steps: true,
      run: () => go("name"),
    },
    {
      id: "folder",
      icon: "folder-git",
      title: tr("Lokale map", "Local folder"),
      detail: tr("Kies een map op schijf", "Browse a folder on disk"),
      steps: false,
      run: () => chooseFolder(),
    },
    {
      id: "url",
      icon: "link",
      title: tr("Git-URL", "Git URL"),
      detail: tr("Clone vanaf een externe URL", "Clone from a remote URL"),
      steps: true,
      run: () => go("gitURL"),
    },
    {
      id: "github",
      icon: "code",
      title: tr("GitHub-repository", "GitHub repository"),
      detail: tr("Clone GitHub eigenaar/repo", "Clone GitHub owner/repo"),
      steps: true,
      run: () => go("github"),
    },
  ]);

  const sources = $derived.by(() => {
    const q = text.trim().toLowerCase();
    if (step !== "sources" || !q) return allSources;
    return allSources.filter(
      (s) => s.title.toLowerCase().includes(q) || s.detail.toLowerCase().includes(q),
    );
  });

  const cleanName = $derived(sanitizeProjectName(text));
  const cloneUrl = $derived.by(() => {
    const typed = text.trim();
    if (step === "github") return githubCloneUrl(typed) ?? "";
    if (step === "gitURL") return repositoryUrlFromPage(typed);
    return "";
  });

  const valid = $derived(
    step === "name" ? cleanName.length > 0 : step === "gitURL" || step === "github" ? isValidCloneUrl(cloneUrl) : false,
  );

  const prompt = $derived.by(() => {
    switch (step) {
      case "sources":
        return tr("Project toevoegen", "Add project");
      case "name":
        return tr("Projectnaam", "Project name");
      case "gitURL":
        return tr("https://github.com/eigenaar/repo of git@…", "https://github.com/owner/repo or git@…");
      case "github":
        return tr("eigenaar/repo", "owner/repo");
    }
  });

  const stepTitle = $derived.by(() => {
    switch (step) {
      case "sources":
        return tr("Bronnen", "Sources");
      case "name":
        return tr("Nieuw project", "New project");
      case "gitURL":
        return tr("Git-URL", "Git URL");
      case "github":
        return tr("GitHub-repository", "GitHub repository");
    }
  });

  const fieldIcon = $derived(step === "sources" ? "search" : step === "name" ? "folder-plus" : "link");

  $effect(() => {
    // Re-focus input whenever step changes or palette opens.
    void step;
    requestAnimationFrame(() => inputEl?.focus());
  });

  function go(next: Step) {
    step = next;
    text = "";
    index = 0;
    error = null;
  }

  function escape() {
    if (busy) return;
    if (step === "sources") onclose();
    else go("sources");
  }

  function onInput() {
    index = 0;
    error = null;
  }

  function onKeydown(e: KeyboardEvent) {
    if (e.key === "Escape") {
      e.preventDefault();
      e.stopPropagation();
      escape();
      return;
    }
    if (step === "sources") {
      if (e.key === "ArrowDown") {
        e.preventDefault();
        index = Math.min(index + 1, Math.max(0, sources.length - 1));
      } else if (e.key === "ArrowUp") {
        e.preventDefault();
        index = Math.max(index - 1, 0);
      } else if (e.key === "Enter") {
        e.preventDefault();
        submit();
      }
    } else if (e.key === "Enter") {
      e.preventDefault();
      submit();
    }
  }

  async function pinAndOpen(folder: string) {
    if (!(workspace.settings?.favoriteProjects ?? []).includes(folder)) {
      await workspaceApi.toggleFavoriteProject(folder);
    }
    await workspace.refresh();
    onadded(folder);
  }

  async function chooseFolder() {
    if (busy) return;
    busy = true;
    error = null;
    try {
      const picked = await openDialog({
        directory: true,
        multiple: false,
        title: tr("Project toevoegen", "Add project"),
      });
      if (typeof picked !== "string" || !picked) {
        busy = false;
        return;
      }
      await pinAndOpen(picked);
    } catch (e) {
      error = String(e);
    } finally {
      busy = false;
    }
  }

  async function createProject() {
    if (!valid || busy) return;
    busy = true;
    error = null;
    try {
      const folder = await workspaceApi.createProject(cleanName, near);
      await workspace.refresh();
      onadded(folder);
    } catch (e) {
      error = String(e);
    } finally {
      busy = false;
    }
  }

  async function cloneProject() {
    if (!valid || busy) return;
    busy = true;
    error = null;
    try {
      const folder = await workspaceApi.clone(cloneUrl, near);
      await pinAndOpen(folder);
    } catch (e) {
      error = String(e);
    } finally {
      busy = false;
    }
  }

  function submit() {
    if (step === "sources") {
      const item = sources[index];
      if (item) item.run();
    } else if (step === "name") {
      createProject();
    } else {
      cloneProject();
    }
  }
</script>

<!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
<div class="backdrop" onclick={onclose}>
  <div
    class="palette"
    role="dialog"
    aria-modal="true"
    aria-label={tr("Project toevoegen", "Add project")}
    tabindex="-1"
    onclick={(e) => e.stopPropagation()}
    onkeydown={onKeydown}
  >
    <div class="field-bar">
      {#if step !== "sources"}
        <button
          type="button"
          class="bar-icon"
          title={tr("Terug", "Back")}
          aria-label={tr("Terug", "Back")}
          disabled={busy}
          onclick={() => go("sources")}
        >
          <Ico name="arrow-left" size={15} />
        </button>
      {:else}
        <span class="bar-glyph"><Ico name={fieldIcon} size={15} /></span>
      {/if}
      <input
        bind:this={inputEl}
        type="text"
        bind:value={text}
        oninput={onInput}
        placeholder={prompt}
        aria-label={prompt}
        disabled={busy}
      />
      <button
        type="button"
        class="bar-icon"
        title={tr("Sluit", "Close")}
        aria-label={tr("Sluit", "Close")}
        disabled={busy}
        onclick={onclose}
      >
        <Ico name="x" size={15} />
      </button>
    </div>

    <div class="divider"></div>

    <div class="body">
      <div class="section-label">{stepTitle}</div>

      {#if step === "sources"}
        {#if sources.length === 0}
          <div class="empty">{tr("Geen passende bronnen", "No matching sources")}</div>
        {:else}
          {#each sources as source, i (source.id)}
            <button
              type="button"
              class="source-row"
              class:selected={i === index}
              onmouseenter={() => (index = i)}
              onclick={() => {
                index = i;
                submit();
              }}
            >
              <span class="row-icon"><Ico name={source.icon} size={16} stroke={1.9} /></span>
              <span class="row-text">
                <span class="row-title">{source.title}</span>
                <span class="row-detail">{source.detail}</span>
              </span>
              {#if source.steps}
                <span class="row-chev"><Ico name="chevron-right" size={14} stroke={2} /></span>
              {/if}
            </button>
          {/each}
        {/if}
      {:else}
        <button
          type="button"
          class="source-row"
          class:selected={valid && !busy}
          disabled={!valid || busy}
          onclick={submit}
        >
          <span class="row-icon">
            <Ico name={step === "name" ? "folder-plus" : "download"} size={16} stroke={1.9} />
          </span>
          <span class="row-text">
            <span class="row-title">
              {#if busy}
                {tr("Bezig…", "Working…")}
              {:else if step === "name"}
                {tr("Maken", "Create")}
              {:else}
                {tr("Kloon", "Clone")}
              {/if}
            </span>
            {#if valid}
              <span class="row-detail">{step === "name" ? cleanName : cloneUrl}</span>
            {/if}
          </span>
          {#if valid && !busy}
            <kbd class="key-hint">↵</kbd>
          {/if}
        </button>
      {/if}

      {#if error}
        <p class="err">{error}</p>
      {/if}
    </div>
  </div>
</div>

<style>
  .backdrop {
    position: fixed;
    inset: 0;
    z-index: 80;
    display: grid;
    place-items: start center;
    padding-top: 12vh;
    background: color-mix(in srgb, var(--bg) 55%, transparent);
  }
  .palette {
    width: 460px;
    max-width: calc(100vw - 32px);
    background: var(--menu);
    border: 1px solid var(--line2);
    border-radius: var(--radius-card);
    box-shadow: var(--shadow-popover);
    overflow: hidden;
    display: flex;
    flex-direction: column;
  }
  .field-bar {
    display: flex;
    align-items: center;
    gap: var(--space-8);
    height: 44px;
    padding: 0 var(--space-12);
  }
  .bar-glyph {
    display: inline-flex;
    align-items: center;
    color: var(--text3);
    flex: none;
  }
  .bar-icon {
    display: grid;
    place-items: center;
    width: 26px;
    height: 26px;
    padding: 0;
    border: 0;
    border-radius: var(--radius-control);
    background: transparent;
    color: var(--text2);
    cursor: pointer;
    flex: none;
  }
  .bar-icon:hover:not(:disabled) {
    background: var(--smoke);
    color: var(--paper);
  }
  .field-bar input {
    flex: 1;
    min-width: 0;
    height: 100%;
    padding: 0;
    border: 0;
    background: transparent;
    color: var(--paper);
    font: var(--text-body);
    outline: none;
    box-shadow: none;
  }
  .field-bar input::placeholder {
    color: var(--text3);
  }
  .divider {
    height: 1px;
    background: var(--line2);
  }
  .body {
    padding: var(--space-8);
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
  }
  .section-label {
    padding: var(--space-4) var(--space-8);
    font: var(--text-label);
    color: var(--text3);
  }
  .source-row {
    display: flex;
    align-items: center;
    gap: var(--space-12);
    width: 100%;
    padding: var(--space-8) var(--space-12);
    border: 0;
    border-radius: var(--radius-chip);
    background: transparent;
    color: var(--paper);
    text-align: left;
    cursor: pointer;
  }
  .source-row.selected,
  .source-row:hover:not(:disabled) {
    background: var(--row-hover);
  }
  .source-row:disabled {
    opacity: 0.48;
    cursor: default;
  }
  .row-icon {
    display: inline-flex;
    align-items: center;
    color: var(--text2);
    flex: none;
  }
  .source-row.selected .row-icon {
    color: var(--paper);
  }
  .row-text {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    min-width: 0;
    flex: 1;
  }
  .row-title {
    font: var(--text-emphasis);
    color: var(--paper);
  }
  .row-detail {
    font: var(--text-detail);
    color: var(--text3);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .row-chev {
    display: inline-flex;
    align-items: center;
    color: var(--text3);
    flex: none;
  }
  .key-hint {
    padding: var(--space-2) var(--space-6);
    border: 1px solid var(--line2);
    border-radius: var(--radius-chip);
    font: var(--text-detail);
    color: var(--text2);
    flex: none;
  }
  .empty {
    padding: var(--space-16) var(--space-8);
    text-align: center;
    font: var(--text-detail);
    color: var(--text3);
  }
  .err {
    margin: var(--space-4) var(--space-8) 0;
    font: var(--text-detail);
    color: var(--coral);
  }
</style>
