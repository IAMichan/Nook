<script lang="ts">
  // "Hand off to another agent" (`switchProvider` on the Mac): the session goes on with another agent or account, with
  // what happened so far handed over ahead of your next message. Only between turns.
  import { agentApi, type AgentProfile } from "../../../lib/agents";
  import { automationApi } from "../../../lib/workspace/automation";
  import { isActive, type RunProvider, type WorkspaceRun } from "../../../lib/workspace/api";
  import { workspace } from "../../../lib/workspace/store.svelte";
  import { tr } from "../../../lib/i18n.svelte";

  let { run, onclose }: { run: WorkspaceRun; onclose: () => void } = $props();

  let profiles = $state<AgentProfile[]>([]);
  let error = $state<string | null>(null);
  let busy = $state(false);

  $effect(() => {
    agentApi.profiles().then((p) => (profiles = p)).catch(() => (profiles = []));
  });

  const choices = $derived(
    workspace.providers
      .filter((p) => p.supported && p.executable)
      .flatMap((p) => {
        const own = profiles.filter((x) => x.kind === p.provider);
        const accounts = own.length ? own : [{ id: p.provider, label: "" } as AgentProfile];
        return accounts.map((a) => ({ provider: p.provider as RunProvider, profileId: a.id, label: own.length > 1 ? `${p.name} · ${a.label || tr("Standaard", "Default")}` : p.name }));
      })
      .filter((c) => !(c.provider === run.provider && c.profileId === run.profileId)),
  );

  async function pick(provider: RunProvider, profileId: string) {
    busy = true;
    error = null;
    try {
      await automationApi.handOff(run.id, provider, profileId);
      await workspace.refresh();
      await workspace.loadTimeline(run.id);
      onclose();
    } catch (e) {
      error = String(e);
    } finally {
      busy = false;
    }
  }
</script>

<div class="menu wide" role="menu" tabindex="-1" onclick={(e) => e.stopPropagation()} onkeydown={(e) => { if (e.key === "Escape") onclose(); }}>
  <div class="mhead">{tr("Overdragen aan een andere agent", "Hand off to another agent")}</div>
  {#if isActive(run.status)}
    <p class="faint hint">{tr("Kan pas als de beurt klaar is.", "Possible once the turn is done.")}</p>
  {:else}
    {#each choices as c (c.provider + c.profileId)}
      <button disabled={busy} onclick={() => pick(c.provider, c.profileId)}>{c.label}</button>
    {:else}
      <p class="faint hint">{tr("Er staat geen andere agent op deze computer.", "There is no other agent on this computer.")}</p>
    {/each}
    <p class="faint hint">{tr("Wat er tot nu toe gebeurde, gaat mee met je volgende bericht en staat in de tijdlijn. Terug naar een agent die al meedeed, gaat verder met zijn eigen gesprek.", "What happened so far goes along with your next message and shows in the timeline. Going back to an agent that took part before continues its own conversation.")}</p>
  {/if}
  {#if error}<p class="err">{error}</p>{/if}
</div>

<style>
  .menu { position: absolute; bottom: 34px; left: 0; z-index: 21; background: var(--surface); border: 1px solid var(--line2); border-radius: var(--radius-panel); padding: 8px; display: flex; flex-direction: column; width: 300px; gap: 4px; box-shadow: var(--shadow-popover); }
  .menu button { background: none; border: none; text-align: left; padding: 6px 8px; border-radius: var(--radius-chip); font-size: 13px; }
  .menu button:hover:not(:disabled) { background: var(--row-hover); }
  .mhead { font-size: 12px; font-weight: 600; padding: 2px 8px; }
  .hint { font-size: 11.5px; margin: 2px 8px; }
  .err { color: var(--coral); font-size: 12px; margin: 2px 8px; }
</style>
