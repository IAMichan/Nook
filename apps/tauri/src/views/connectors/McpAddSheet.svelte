<script lang="ts" module>
  // Kant-en-klare MCP-servers voor de catalogus van Accounts & koppelingen.
  export interface Preset {
    id: string;
    name: string;
    detail: string;
    domain: string | null;
    command: string;
    /** The command is an address of a server on this computer or the internet, not a program to start. */
    remote?: boolean;
    /** `prefix` goes before the typed value, such as "Bearer " for an Authorization header. */
    env: { name: string; label: string; placeholder: string; prefix?: string }[];
    help: string | null;
    /** The category chip it is listed under. */
    category: string;
  }

  // Geen geheugenserver hier: geheugen zit in Nook zelf (Instellingen › Geheugen), zonder Node of npx.
  export const presets: Preset[] = [
    { id: "filesystem", name: "Bestanden & mappen", detail: "Laat Nook documenten en mappen op deze computer direct doorzoeken en lezen.", domain: null, command: "npx -y @modelcontextprotocol/server-filesystem ~/Desktop ~/Documents ~/Downloads", env: [], help: null, category: "local" },
    { id: "github", name: "GitHub MCP", detail: "Beheer repositories, issues en commits via de officiële MCP-server.", domain: "github.com", command: "npx -y @modelcontextprotocol/server-github", env: [{ name: "GITHUB_PERSONAL_ACCESS_TOKEN", label: "GitHub Personal Access Token", placeholder: "ghp_..." }], help: "https://github.com/settings/tokens/new", category: "development" },
    { id: "brave-search", name: "Brave Search", detail: "Laat Nook live op het internet zoeken naar actuele informatie.", domain: "brave.com", command: "npx -y @modelcontextprotocol/server-brave-search", env: [{ name: "BRAVE_API_KEY", label: "Brave Search API-sleutel", placeholder: "BSA..." }], help: "https://brave.com/search/api/", category: "work" },
    { id: "beeper", name: "Beeper", detail: "Laat Nook je chats uit WhatsApp, Signal en andere netwerken zoeken en lezen via Beeper Desktop op deze computer.", domain: "beeper.com", command: "http://localhost:23373/v0/mcp", remote: true, env: [{ name: "Authorization", label: "Beeper-toegangstoken", placeholder: "Plak je token", prefix: "Bearer " }], help: "https://developers.beeper.com/desktop-api/", category: "automation" },
    { id: "puppeteer", name: "Web Browser (Puppeteer)", detail: "Laat Nook webpagina's openen, formulieren bekijken en data extraheren.", domain: "pptr.dev", command: "npx -y @modelcontextprotocol/server-puppeteer", env: [], help: null, category: "automation" },
    { id: "postgres", name: "PostgreSQL Database", detail: "Lees tabellen, schema's en voer queries uit op je database.", domain: "postgresql.org", command: "npx -y @modelcontextprotocol/server-postgres postgresql://localhost/mydb", env: [], help: null, category: "development" },
  ];
</script>

<script lang="ts">
  // Een MCP-server toevoegen: een kant-en-klare, of plak een opdracht (npx, uvx), een Claude Desktop-configuratie of
  // een https-adres. Tools die alleen lezen gebruikt Nook bij een antwoord; al het andere wordt een actie die pas na
  // jouw Uitvoeren gebeurt.
  import { openUrl } from "@tauri-apps/plugin-opener";
  import { untrack } from "svelte";
  import { connectorsApi, type Caps } from "../../lib/connectors";

  let { preset: initial, caps, onclose, onchange }: { preset: Preset | null; caps: Caps; onclose: () => void; onchange: () => void } = $props();

  const preset = untrack(() => initial);
  let name = $state(preset?.name ?? "");
  let target = $state(preset?.command ?? "");
  let remote = $state(preset?.remote ?? false);
  let secrets = $state("");
  let envDrafts = $state<Record<string, string>>({});
  let problem = $state("");

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
    const extra = Object.entries(envDrafts).filter(([, v]) => v.trim()).map(([k, v]) => `${k}=${preset?.env.find((e) => e.name === k)?.prefix ?? ""}${v.trim()}`);
    try {
      await connectorsApi.mcpAdd(name.trim() || "MCP-server", target, remote, [secrets, ...extra].filter(Boolean).join("\n"));
      onchange();
      onclose();
    } catch (e) {
      problem = String(e);
    }
  }
</script>

<div class="backdrop" role="presentation" onclick={(e) => e.target === e.currentTarget && onclose()}>
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
      <button onclick={onclose}>Annuleer</button>
      <button class="primary" onclick={add} disabled={!target.trim()}>Toevoegen</button>
    </div>
  </div>
</div>

<style>
  .small { font-size: 11px; }
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
  .inline { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
  .err { color: var(--coral); font-size: 12px; }
</style>
