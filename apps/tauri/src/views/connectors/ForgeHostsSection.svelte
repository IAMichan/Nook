<script lang="ts">
  // Code hosts section in Settings › Pull requests (`ForgeHostsSection` on macOS):
  // GitLab (`GitLabRow` / `GitLabSheet`) and Gitea / Forgejo / Codeberg, GitCafe, Bitbucket, Azure DevOps
  // (`ForgeHostRow` / `ForgeSheet`), with "+ Add code host" in the section header.
  import { CODE_HOST_KINDS, codeHostMeta, type CodeHostKind } from "../../lib/connectors";
  import { tr } from "../../lib/i18n.svelte";
  import Ico from "../../components/ui/Ico.svelte";
  import GitLabRow from "./GitLabRow.svelte";
  import GitLabSheet from "./GitLabSheet.svelte";
  import ForgeHostRow from "./ForgeHostRow.svelte";
  import ForgeSheet from "./ForgeSheet.svelte";

  let {
    gitlabHosts = [],
    forgeHosts = [],
    onchange,
  }: {
    gitlabHosts: string[];
    forgeHosts: string[];
    onchange: () => void;
  } = $props();

  let menuOpen = $state(false);
  let adding = $state<CodeHostKind | null>(null);

  function pick(kind: CodeHostKind) {
    menuOpen = false;
    adding = kind;
  }
</script>

<div class="section-head">
  <h3>{tr("Codehosts", "Code hosts")}</h3>
  <div class="menu-wrap">
    <button class="head-action" type="button" onclick={() => (menuOpen = !menuOpen)}>
      <Ico name="plus" size={14} />{tr("Codehost toevoegen", "Add code host")}
    </button>
    {#if menuOpen}
      <div class="menu" role="menu">
        {#each CODE_HOST_KINDS as kind (kind)}
          <button type="button" class="menu-item" role="menuitem" onclick={() => pick(kind)}>
            {codeHostMeta(kind).menuName}
          </button>
        {/each}
      </div>
    {/if}
  </div>
</div>
<p class="section-info">
  {tr(
    "Met een token voor GitLab, Gitea, Forgejo, Codeberg, GitCafe, Bitbucket of Azure DevOps opent een pull request daar in Nook zoals een op GitHub.",
    "With a token for GitLab, Gitea, Forgejo, Codeberg, GitCafe, Bitbucket or Azure DevOps, a pull request there opens in Nook like one on GitHub.",
  )}
</p>

<div class="group">
  {#if gitlabHosts.length === 0 && forgeHosts.length === 0}
    <div class="empty">
      <strong>{tr("Nog geen codehost toegevoegd", "No code host added yet")}</strong>
      <span>
        {tr(
          "Voeg GitLab, Gitea, Forgejo, Codeberg, GitCafe, Bitbucket of Azure DevOps toe om hun pull requests in Nook te lezen en te reviewen.",
          "Add GitLab, Gitea, Forgejo, Codeberg, GitCafe, Bitbucket or Azure DevOps to read and review their pull requests in Nook.",
        )}
      </span>
    </div>
  {:else}
    {#each gitlabHosts as host (host)}
      <GitLabRow {host} {onchange} />
    {/each}
    {#each forgeHosts as host (host)}
      <ForgeHostRow {host} {onchange} />
    {/each}
  {/if}
</div>

{#if adding === "gitlab"}
  <GitLabSheet onclose={() => (adding = null)} {onchange} />
{:else if adding !== null}
  <ForgeSheet kind={adding} onclose={() => (adding = null)} {onchange} />
{/if}

<style>
  .menu-wrap { position: relative; }
  .menu {
    position: absolute;
    right: 0;
    top: calc(100% + var(--space-4));
    min-width: 220px;
    padding: var(--space-4);
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: var(--radius-card);
    box-shadow: var(--shadow-popover);
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    z-index: 20;
  }
  .menu-item {
    background: none;
    border: none;
    text-align: left;
    padding: var(--space-6) var(--space-8);
    border-radius: var(--radius-chip);
    font: var(--text-body);
    color: var(--paper);
  }
  .menu-item:hover {
    background: var(--row-hover);
  }
  .empty { display: flex; flex-direction: column; gap: var(--space-4); padding: var(--space-16) 0; }
  .empty strong { font: var(--text-emphasis); color: var(--paper); }
  .empty span { font: var(--text-detail); line-height: 1.4; color: var(--text2); }
</style>
