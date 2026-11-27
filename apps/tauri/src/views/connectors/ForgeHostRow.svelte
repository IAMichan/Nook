<script lang="ts">
  // A connected non-GitHub/GitLab code host row (`ForgeHostRow` on macOS).
  import {
    classifyCodeHost,
    codeHostMeta,
    connectorsApi,
    forgeDetail,
    forgeHealth,
    type ForgeTokenCheck,
  } from "../../lib/connectors";
  import { tr } from "../../lib/i18n.svelte";
  import ServiceIcon from "./ServiceIcon.svelte";
  import HealthPill from "./HealthPill.svelte";
  import ForgeSheet from "./ForgeSheet.svelte";

  let { host, onchange }: { host: string; onchange: () => void } = $props();
  const kind = $derived(classifyCodeHost(host));
  const meta = $derived(codeHostMeta(kind));
  let check = $state<ForgeTokenCheck | null>(null);
  let managing = $state(false);

  async function refresh() {
    if (!meta.canCheckToken) {
      check = null;
      return;
    }
    check = null;
    try {
      check = await connectorsApi.forgeCheck(kind, host);
    } catch {
      check = { kind: "unreachable" };
    }
  }

  $effect(() => {
    void host;
    void kind;
    refresh();
  });
</script>

<div class="row">
  <button
    class="plain"
    onclick={() => (managing = true)}
    title={tr("Klik om {host} te beheren", "Click to manage {host}", { host })}
  >
    <ServiceIcon domain={meta.domain} title={meta.name} />
    <span class="text">
      <span>{meta.fixedHost === null ? host : meta.name}</span>
      <span class="faint small" class:warn={check?.kind === "rejected"}>{forgeDetail(host, kind, check)}</span>
    </span>
  </button>
  <HealthPill health={forgeHealth(kind, check)} />
</div>

{#if managing}
  <ForgeSheet
    {kind}
    managing={host}
    onclose={() => {
      managing = false;
      refresh();
    }}
    {onchange}
  />
{/if}

<style>
  .plain { display: flex; gap: var(--space-12); align-items: center; background: none; border: none; padding: 0; text-align: left; flex: 1; min-width: 0; }
  .plain:hover { background: none; }
  .text { display: flex; flex-direction: column; gap: var(--space-2); min-width: 0; }
  .text span:last-child { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .small { font: var(--text-detail); }
  .warn { color: var(--amber); }
</style>
