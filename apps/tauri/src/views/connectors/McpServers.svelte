<script lang="ts">
  // De MCP-servers die je zelf toevoegde, als rijen in dezelfde vorm als elke andere koppeling: klik voor de opdracht,
  // de tools, testen en verwijderen. Toevoegen gebeurt in de catalogus (McpAddSheet).
  import { connectorsApi, health, type ConnectorInfo, type McpTool, type McpView } from "../../lib/connectors";
  import ServiceIcon from "./ServiceIcon.svelte";
  import HealthPill from "./HealthPill.svelte";

  let { servers, connectors, onchange }: { servers: McpView[]; connectors: ConnectorInfo[]; onchange: () => void } = $props();

  let open = $state<string | null>(null);
  let tested = $state<Record<string, McpTool[] | string>>({});
  let confirmRemove = $state<string | null>(null);

  const own = $derived(servers.filter((s) => !s.config.serviceId));

  async function test(id: string) {
    tested[id] = "Testen…";
    try {
      tested[id] = await connectorsApi.mcpTest(id);
    } catch (e) {
      tested[id] = String(e);
    }
    onchange();
  }

  function info(s: McpView) {
    return connectors.find((c) => c.id === `mcp.${s.config.id}`);
  }
</script>

{#each own as s (s.config.id)}
  {@const i = info(s)}
  <div class="row">
    <button class="plain" onclick={() => (open = open === s.config.id ? null : s.config.id)}>
      <ServiceIcon domain={s.domain} title={s.config.name} />
      <span class="text">
        <span>{s.config.name}</span>
        <span class="faint small">{i?.status.state.kind === "error" ? i.status.state.message : i?.status.headline ? `${i.status.headline} · ${i.status.detail}` : s.target}</span>
      </span>
    </button>
    <HealthPill health={s.config.enabled ? health(i) : "off"} />
    <input type="checkbox" checked={s.config.enabled} title="Aan of uit" onchange={async (e) => { await connectorsApi.mcpSetEnabled(s.config.id, e.currentTarget.checked); onchange(); }} />
  </div>
  {#if open === s.config.id}
    <div class="details">
      <div class="faint small">Opdracht of adres</div>
      <code>{s.target}</code>
      {#if s.config.secretNames.length}<div class="faint small">Sleutels in de kluis: {s.config.secretNames.join(", ")}</div>{/if}
      <div class="faint small">Beschikbare tools ({(Array.isArray(tested[s.config.id]) ? (tested[s.config.id] as McpTool[]) : s.tools).length})</div>
      {#each Array.isArray(tested[s.config.id]) ? (tested[s.config.id] as McpTool[]) : s.tools as t (t.name)}
        <div class="tool"><span class="tag" class:act={!t.readOnly}>{t.readOnly ? "Lezen" : "Actie (met toestemming)"}</span> <strong title={t.name}>{t.title || t.name}</strong> <span class="faint">{t.description}</span></div>
      {:else}
        <p class="faint small">Nog geen tools gevonden of de server start nog op.</p>
      {/each}
      {#if typeof tested[s.config.id] === "string"}<p class="small">{tested[s.config.id]}</p>{/if}
      <div class="inline">
        <button onclick={() => test(s.config.id)}>Test</button>
        {#if confirmRemove === s.config.id}
          <span class="faint small">{s.config.name} verwijderen? De sleutels van deze server gaan ook uit de kluis.</span>
          <button onclick={() => (confirmRemove = null)}>Annuleer</button>
          <button class="danger" onclick={async () => { await connectorsApi.mcpRemove(s.config.id); confirmRemove = null; onchange(); }}>Verwijderen</button>
        {:else}
          <button class="danger" onclick={() => (confirmRemove = s.config.id)}>Verwijderen</button>
        {/if}
      </div>
    </div>
  {/if}
{/each}

<style>
  .plain { display: flex; gap: 12px; align-items: center; background: none; border: none; padding: 0; text-align: left; flex: 1; min-width: 0; }
  .plain:hover { background: none; }
  .text { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
  .text span:last-child { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .small { font-size: 11px; }
  .details { padding: 4px 0 12px 42px; display: flex; flex-direction: column; gap: 6px; border-bottom: 1px solid var(--line); }
  .details code { font-family: var(--mono); font-size: 11px; word-break: break-all; user-select: text; }
  .tool { font-size: 12px; }
  .tag { font-size: 10px; padding: 1px 6px; border-radius: 6px; background: var(--smoke); color: var(--text2); }
  .tag.act { color: var(--amber); }
</style>
