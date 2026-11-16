<script lang="ts">
  // The repositories on top of the Actions page, as tabs (`ActionsRepoBar` on the Mac): one click goes from one
  // repository's runs to another's, and each tab says how its repository stands (a spinning ring while something runs,
  // a cross when a workflow's newest run failed; nothing when all is well). The tabs keep their order; × takes one off.
  import type { RepoStatus } from "../../../lib/actions";
  import { tr } from "../../../lib/i18n.svelte";
  import RunMark from "./RunMark.svelte";

  let {
    tabs, value, statuses, onpick, onclose,
  }: {
    tabs: string[];
    value: string | null;
    statuses: Record<string, RepoStatus | null>;
    onpick: (name: string) => void;
    onclose: (name: string) => void;
  } = $props();

  const owner = (repo: string) => repo.split("/")[0] ?? "";
  const short = (repo: string) => repo.split("/")[1] ?? repo;
  // A tab names the repository alone, unless another tab has a repository of the same name.
  const title = (repo: string) =>
    tabs.filter((t) => short(t).toLowerCase() === short(repo).toLowerCase()).length > 1 ? repo : short(repo);
  const isOn = (repo: string) => repo.toLowerCase() === (value ?? "").toLowerCase();

  function help(repo: string, status: RepoStatus | null | undefined): string {
    const parts = [repo];
    if (status?.active) parts.push(tr("{n} bezig", "{n} running", { n: status.active }));
    if (status?.failing) parts.push(tr("{n} mislukt", "{n} failing", { n: status.failing }));
    return parts.join(" · ");
  }

  // The open tab stays in sight when it changes by a key or a pick in the list.
  let strip = $state<HTMLElement | null>(null);
  $effect(() => {
    void value;
    strip?.querySelector<HTMLElement>(".tab.on")?.scrollIntoView({ block: "nearest", inline: "nearest", behavior: "smooth" });
  });
</script>

<div class="tabs" role="tablist" aria-label={tr("Repositories", "Repositories")} bind:this={strip}>
  {#each tabs as repo (repo)}
    {@const status = statuses[repo.toLowerCase()]}
    <div class="tab" class:on={isOn(repo)} title={help(repo, status)}>
      <button class="pick" role="tab" aria-selected={isOn(repo)} onclick={() => onpick(repo)}>
        <img class="avatar" src={`https://github.com/${owner(repo)}.png?size=32`} alt="" loading="lazy" />
        <span class="name">{title(repo)}</span>
        <!-- Calm by default: a mark only when something runs or a workflow is broken. -->
        {#if status && (status.active || status.failing)}<RunMark outcome={status.outcome} running={status.running} />{/if}
      </button>
      {#if tabs.length > 1}
        <button class="close" title={tr("Tab sluiten", "Close tab")} aria-label={tr("Tab sluiten", "Close tab")} onclick={() => onclose(repo)}>×</button>
      {/if}
    </div>
  {/each}
</div>

<style>
  .tabs { display: flex; gap: 2px; min-width: 0; flex: 1; overflow-x: auto; scrollbar-width: none; }
  .tab { display: flex; align-items: center; flex: none; height: 30px; border-radius: 8px; padding-right: 2px; }
  .tab:hover { background: var(--smoke); }
  .tab.on { background: var(--smoke); box-shadow: inset 0 0 0 1px var(--line2); }
  .pick { display: flex; align-items: center; gap: 6px; height: 100%; padding: 0 6px 0 10px; border: none; background: none; color: var(--text2); font-size: 12.5px; white-space: nowrap; }
  .pick:hover:not(:disabled), .close:hover:not(:disabled) { border-color: transparent; }
  .pick:hover:not(:disabled) { background: none; }
  .tab:hover .pick { color: var(--paper); }
  .tab.on .pick { color: var(--paper); font-weight: 600; }
  .avatar { width: 16px; height: 16px; border-radius: 50%; background: var(--field); opacity: 0.75; }
  .tab:hover .avatar, .tab.on .avatar { opacity: 1; }
  .close { width: 18px; height: 18px; display: grid; place-items: center; padding: 0; border: none; border-radius: 5px; background: none; color: var(--text3); font-size: 13px; line-height: 1; opacity: 0; }
  .tab:hover .close, .close:focus-visible { opacity: 1; }
  .close:hover { color: var(--paper); background: var(--field); }
</style>
