<script lang="ts">
  // MCP-servers: de open standaard om Nook aan je programma's te koppelen. Kant-en-klare koppelingen in één klik,
  // of plak een opdracht (npx, uvx), een Claude Desktop-configuratie of een https-adres.
  import { openUrl } from "@tauri-apps/plugin-opener";
  import { connectorsApi, health, type Caps, type ConnectorInfo, type McpTool, type McpView } from "../../lib/connectors";
  import ServiceIcon from "./ServiceIcon.svelte";
  import HealthPill from "./HealthPill.svelte";

  let { servers, connectors, caps, onchange }: { servers: McpView[]; connectors: ConnectorInfo[]; caps: Caps; onchange: () => void } = $props();

  interface Preset {
    id: string;
    name: string;
    detail: string;
    domain: string | null;
    command: string;
    env: { name: string; label: string; placeholder: string }[];
    help: string | null;
  }

  // Geen geheugenserver hier: geheugen zit in Nook zelf (Instellingen › Geheugen), zonder Node of npx.
  const presets: Preset[] = [
    { id: "filesystem", name: "Bestanden & mappen", detail: "Laat Nook documenten en mappen op deze computer direct doorzoeken en lezen.", domain: null, command: "npx -y @modelcontextprotocol/server-filesystem ~/Desktop ~/Documents ~/Downloads", env: [], help: null },
    { id: "github", name: "GitHub MCP", detail: "Beheer repositories, issues en commits via de officiële MCP-server.", domain: "github.com", command: "npx -y @modelcontextprotocol/server-github", env: [{ name: "GITHUB_PERSONAL_ACCESS_TOKEN", label: "GitHub Personal Access Token", placeholder: "ghp_..." }], help: "https://github.com/settings/tokens/new" },
    { id: "brave-search", name: "Brave Search", detail: "Laat Nook live op het internet zoeken naar actuele informatie.", domain: "brave.com", command: "npx -y @modelcontextprotocol/server-brave-search", env: [{ name: "BRAVE_API_KEY", label: "Brave Search API-sleutel", placeholder: "BSA..." }], help: "https://brave.com/search/api/" },
    { id: "puppeteer", name: "Web Browser (Puppeteer)", detail: "Laat Nook webpagina's openen, formulieren bekijken en data extraheren.", domain: "pptr.dev", command: "npx -y @modelcontextprotocol/server-puppeteer", env: [], help: null },
    { id: "postgres", name: "PostgreSQL Database", detail: "Lees tabellen, schema's en voer queries uit op je database.", domain: "postgresql.org", command: "npx -y @modelcontextprotocol/server-postgres postgresql://localhost/mydb", env: [], help: null },
  ];

  let adding = $state(false);
  let preset = $state<Preset | null>(null);
  let name = $state("");
  let target = $state("");
  let remote = $state(false);
  let secrets = $state("");
  let envDrafts = $state<Record<string, string>>({});
  let problem = $state("");
  let open = $state<string | null>(null);
  let tested = $state<Record<string, McpTool[] | string>>({});
  let confirmRemove = $state<string | null>(null);

  const own = $derived(servers.filter((s) => !s.config.serviceId));

  function start(p: Preset | null) {
    preset = p;
    name = p?.name ?? "";
    target = p?.command ?? "";
    remote = false;
    secrets = "";
    envDrafts = {};
    problem = "";
    adding = true;
  }

  async function smartPaste() {
    try {
      const text = await navigator.clipboard.readText();
      await usePasted(text);
    } catch {
      problem = "Er staat niets bruikbaars op je klembord.";
    }
  }

  async function usePasted(text: string) {
    if (!text.trim()) return;
    const p = await connectorsApi.mcpPaste(text);
    target = p.target;
    remote = p.remote;
    if (p.secrets) secrets = p.secrets;
    if (!name.trim()) name = p.name;
  }

  async function add() {
    problem = "";
    const extra = Object.entries(envDrafts).filter(([, v]) => v.trim()).map(([k, v]) => `${k}=${v.trim()}`);
    try {
      await connectorsApi.mcpAdd(name.trim() || "MCP-server", target, remote, [secrets, ...extra].filter(Boolean).join("\n"));
      adding = false;
      onchange();
    } catch (e) {
      problem = String(e);
    }
  }

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

<p class="muted">Model Context Protocol (MCP) is de open standaard om Nook te koppelen aan je favoriete programma's. Tools die alleen lezen gebruikt Nook bij een antwoord; al het andere wordt een actie die pas na jouw Uitvoeren gebeurt.</p>

{#if own.length}
  <div class="group">
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
            <div class="tool"><span class="tag" class:act={!t.readOnly}>{t.readOnly ? "Lezen" : "Actie (met toestemming)"}</span> <strong>{t.name}</strong> <span class="faint">{t.description}</span></div>
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
  </div>
{/if}

<h3>Populaire kant-en-klare koppelingen</h3>
<div class="cards">
  {#each presets as p (p.id)}
    <button class="card" onclick={() => start(p)} disabled={!caps.stdio}>
      <ServiceIcon domain={p.domain} title={p.name} size={32} />
      <span class="text"><strong>{p.name}</strong><span class="faint small">{p.detail}</span></span>
      <span class="plus">＋</span>
    </button>
  {/each}
  <button class="card" onclick={() => start(null)}>
    <ServiceIcon title="+" size={32} />
    <span class="text"><strong>Zelf een andere MCP-server toevoegen</strong><span class="faint small">Plak een opdracht (npx, uvx), een Claude Desktop JSON-configuratie of een web-adres.</span></span>
  </button>
</div>
{#if !caps.stdio}<p class="faint small">Op Android kan Nook geen programma's starten: alleen servers met een https-adres werken hier.</p>{/if}

{#if adding}
  <div class="backdrop" role="presentation" onclick={(e) => e.target === e.currentTarget && (adding = false)}>
    <div class="sheet" role="dialog" aria-label="MCP-server toevoegen">
      <h3>{preset ? `${preset.name} toevoegen` : "MCP-server toevoegen"}</h3>
      <p class="muted small">Volg de eenvoudige stappen om deze koppeling te activeren.</p>
      {#if !preset}
        <div class="paste">
          <strong>Slim plakken</strong>
          <span class="faint small">Heb je een opdracht of een configuratie gekopieerd? Klik op Plakken en Nook vult alle velden voor je in.</span>
          <button onclick={smartPaste}>Plakken</button>
        </div>
      {/if}
      <label>1. Geef de koppeling een herkenbare naam<input bind:value={name} placeholder="Naam" /></label>
      <div class="inline">
        <label><input type="radio" checked={!remote} onchange={() => (remote = false)} disabled={!caps.stdio} /> Programma op deze computer</label>
        <label><input type="radio" checked={remote} onchange={() => (remote = true)} /> Adres op internet</label>
      </div>
      <label>2. {remote ? "Adres" : "Opdracht"}<input bind:value={target} placeholder={remote ? "https://…/mcp" : "npx -y @modelcontextprotocol/server-…"} onpaste={(e) => { const t = e.clipboardData?.getData("text") ?? ""; if (t.trim().startsWith("{")) { e.preventDefault(); usePasted(t); } }} /></label>
      {#if preset?.env.length}
        <div class="faint small">3. Voer eventuele sleutels in</div>
        {#each preset.env as v (v.name)}
          <label>{v.label}<input type="password" placeholder={v.placeholder} bind:value={envDrafts[v.name]} /></label>
        {/each}
        {#if preset.help}<button class="link" onclick={() => openUrl(preset!.help!)}>Haal sleutel op ↗</button>{/if}
      {/if}
      <label>{remote ? "Sleutels (headers)" : "Sleutels (omgevingsvariabelen)"}
        <textarea rows="3" bind:value={secrets} placeholder={remote ? "Authorization: Bearer …" : "GITHUB_TOKEN=ghp_…"}></textarea>
        <span class="faint small">{remote ? "Eén per regel: Authorization: Bearer … Ze gaan naar de kluis." : "Eén per regel, zoals in de README: GITHUB_TOKEN=ghp_… Ze gaan naar de kluis."}</span>
      </label>
      <p class="warn small">{remote ? "Wat Nook aan deze server vraagt, gaat naar dat adres. Acties van de server vragen altijd eerst je goedkeuring." : "Een lokale MCP-server draait met jouw rechten op deze computer. Voeg alleen servers toe die je vertrouwt. Acties van de server vragen altijd eerst je goedkeuring."}</p>
      {#if problem}<p class="err">{problem}</p>{/if}
      <div class="inline end">
        <button onclick={() => (adding = false)}>Annuleer</button>
        <button class="primary" onclick={add} disabled={!target.trim()}>Toevoegen</button>
      </div>
    </div>
  </div>
{/if}

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
  .cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(240px, 1fr)); gap: 8px; }
  .card { display: flex; gap: 10px; align-items: center; text-align: left; padding: 10px 12px; }
  .card .text { flex: 1; }
  .plus { font-size: 18px; color: var(--text2); }
  .backdrop { position: fixed; inset: 0; background: rgba(0, 0, 0, 0.55); display: grid; place-items: center; z-index: 50; padding: 16px; }
  .sheet { background: var(--graphite); border: 1px solid var(--line2); border-radius: 18px; width: min(560px, 100%); max-height: 90vh; overflow-y: auto; padding: 18px 20px; display: flex; flex-direction: column; gap: 10px; }
  .sheet h3 { margin: 0; }
  .sheet label { display: flex; flex-direction: column; gap: 4px; }
  .sheet .inline label { flex-direction: row; align-items: center; gap: 6px; }
  .paste { display: flex; flex-direction: column; gap: 4px; padding: 10px; border: 1px dashed var(--line2); border-radius: 10px; align-items: flex-start; }
  textarea { font-family: var(--mono); font-size: 12px; }
  .warn { color: var(--amber); margin: 0; }
  .end { justify-content: flex-end; }
  .link { background: none; border: none; padding: 0; color: var(--text2); text-align: left; }
</style>
