<script lang="ts">
  // Een gekoppelde GitLab-host als rij, zoals elke andere dienst: de staat (live nagevraagd bij GitLab) met de
  // gebruikersnaam, en een klik opent het beheervenster.
  import { connectorsApi, gitlabDetail, gitlabHealth, type GitLabCheck } from "../../lib/connectors";
  import ServiceIcon from "./ServiceIcon.svelte";
  import HealthPill from "./HealthPill.svelte";
  import GitLabSheet from "./GitLabSheet.svelte";

  let { host, onchange }: { host: string; onchange: () => void } = $props();
  let check = $state<GitLabCheck | null>(null);
  let managing = $state(false);

  async function refresh() {
    check = null;
    try {
      check = await connectorsApi.gitlabCheck(host);
    } catch {
      check = { kind: "unreachable" };
    }
  }

  $effect(() => {
    void host;
    refresh();
  });
</script>

<div class="row">
  <button class="plain" onclick={() => (managing = true)} title="Klik om GitLab te beheren">
    <ServiceIcon domain="gitlab.com" title="GitLab" />
    <span class="text">
      <span>GitLab</span>
      <span class="faint small" class:warn={check?.kind === "rejected"}>{gitlabDetail(host, check)}</span>
    </span>
  </button>
  <HealthPill health={gitlabHealth(check)} />
</div>

{#if managing}
  <GitLabSheet managing={host} onclose={() => { managing = false; refresh(); }} {onchange} />
{/if}

<style>
  .plain { display: flex; gap: 12px; align-items: center; background: none; border: none; padding: 0; text-align: left; flex: 1; min-width: 0; }
  .plain:hover { background: none; }
  .text { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
  .text span:last-child { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .small { font-size: 11px; }
  .warn { color: var(--amber); }
</style>
