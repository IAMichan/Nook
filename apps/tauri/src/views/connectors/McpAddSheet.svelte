<script lang="ts" module>
  // Ready-made MCP servers for the Accounts & connections catalog.
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

  import { tr } from "../../lib/i18n.svelte";

  // Names and details are getters, so they follow the interface language when read.
  export const presets: Preset[] = [
    { id: "filesystem", get name() { return tr("Bestanden & mappen", "Files & folders"); }, get detail() { return tr("Laat Nook documenten en mappen op deze computer direct doorzoeken en lezen.", "Let Nook search and read documents and folders on this computer directly."); }, domain: null, command: "npx -y @modelcontextprotocol/server-filesystem ~/Desktop ~/Documents ~/Downloads", env: [], help: null, category: "local" },
    { id: "github", name: "GitHub MCP", get detail() { return tr("Beheer repositories, issues en commits via de officiële MCP-server.", "Manage repositories, issues and commits through the official MCP server."); }, domain: "github.com", command: "npx -y @modelcontextprotocol/server-github", env: [{ name: "GITHUB_PERSONAL_ACCESS_TOKEN", label: "GitHub Personal Access Token", placeholder: "ghp_..." }], help: "https://github.com/settings/tokens/new", category: "development" },
    { id: "brave-search", name: "Brave Search", get detail() { return tr("Laat Nook live op het internet zoeken naar actuele informatie.", "Let Nook search the web live for up-to-date information."); }, domain: "brave.com", command: "npx -y @modelcontextprotocol/server-brave-search", env: [{ name: "BRAVE_API_KEY", get label() { return tr("Brave Search API-sleutel", "Brave Search API key"); }, placeholder: "BSA..." }], help: "https://brave.com/search/api/", category: "work" },
    { id: "puppeteer", name: "Web Browser (Puppeteer)", get detail() { return tr("Laat Nook webpagina's openen, formulieren bekijken en data extraheren.", "Let Nook open web pages, look at forms and extract data."); }, domain: "pptr.dev", command: "npx -y @modelcontextprotocol/server-puppeteer", env: [], help: null, category: "automation" },
    { id: "postgres", get name() { return tr("PostgreSQL-database", "PostgreSQL Database"); }, get detail() { return tr("Lees tabellen, schema's en voer queries uit op je database.", "Read tables and schemas and run queries on your database."); }, domain: "postgresql.org", command: "npx -y @modelcontextprotocol/server-postgres postgresql://localhost/mydb", env: [], help: null, category: "development" },
  ];
</script>

<script lang="ts">
  // Add an MCP server inside the shared `SetupSheet` with numbered `SetupStep`s ending in `SetupCheckStep`.
  import { openUrl } from "@tauri-apps/plugin-opener";
  import { untrack } from "svelte";
  import { connectorsApi, type Caps } from "../../lib/connectors";
  import Ico from "../../components/ui/Ico.svelte";
  import SetupCheckStep from "../../components/ui/SetupCheckStep.svelte";
  import SetupSheet from "../../components/ui/SetupSheet.svelte";
  import SetupStep from "../../components/ui/SetupStep.svelte";
  import { setupCheck, type SetupCheckState } from "../../components/ui/setup-check";
  import ServiceIcon from "./ServiceIcon.svelte";

  let { preset: initial, caps, onclose, onchange }: { preset: Preset | null; caps: Caps; onclose: () => void; onchange: () => void } = $props();

  const preset = untrack(() => initial);
  let name = $state(preset?.name ?? "");
  let target = $state(preset?.command ?? "");
  let remote = $state(preset?.remote ?? false);
  let secrets = $state("");
  let envDrafts = $state<Record<string, string>>({});
  let problem = $state("");

  const readyToAdd = $derived(target.trim().length > 0);
  const checkStepNumber = $derived(preset?.env.length ? 4 : 3);
  const checkState = $derived<SetupCheckState>(
    problem
      ? setupCheck.failed(problem)
      : readyToAdd
        ? setupCheck.passed(
            tr(
              "Klaar om toe te voegen. Nook start en controleert de server zodra je op Toevoegen klikt.",
              "Ready to add. Nook starts and checks the server once you click Add.",
            ),
          )
        : setupCheck.idle(),
  );

  async function smartPaste() {
    try {
      const text = await navigator.clipboard.readText();
      await usePasted(text);
    } catch {
      problem = tr("Er staat niets bruikbaars op je klembord.", "There's nothing usable on your clipboard.");
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
      await connectorsApi.mcpAdd(name.trim() || tr("MCP-server", "MCP server"), target, remote, [secrets, ...extra].filter(Boolean).join("\n"));
      onchange();
      onclose();
    } catch (e) {
      problem = String(e);
    }
  }
</script>

<SetupSheet
  title={preset ? tr("{name} toevoegen", "Add {name}", { name: preset.name }) : tr("MCP-server toevoegen", "Add MCP server")}
  subtitle={tr("Volg de eenvoudige stappen om deze koppeling te activeren.", "Follow the simple steps to turn on this connection.")}
  {onclose}
>
  {#snippet icon()}
    {#if preset?.domain}
      <ServiceIcon domain={preset.domain} title={preset.name} size={44} />
    {:else}
      <div class="tile" aria-hidden="true"><Ico name="plug" size={20} /></div>
    {/if}
  {/snippet}

  {#if !preset}
    <div class="paste">
      <strong>{tr("Slim plakken", "Smart paste")}</strong>
      <span class="faint small">{tr("Heb je een opdracht of een configuratie gekopieerd? Klik op Plakken en Nook vult alle velden voor je in.", "Copied a command or a configuration? Click Paste and Nook fills in all the fields for you.")}</span>
      <button type="button" onclick={smartPaste}>{tr("Plakken", "Paste")}</button>
    </div>
  {/if}

  <SetupStep number={1} title={tr("Geef de koppeling een herkenbare naam", "Give the connection a recognizable name")} done={name.trim().length > 0}>
    <input class="full" bind:value={name} placeholder={tr("Naam", "Name")} />
  </SetupStep>

  <SetupStep number={2} title={remote ? tr("Adres", "Address") : tr("Opdracht", "Command")} done={readyToAdd}>
    <div class="inline">
      <label class="radio"><input type="radio" checked={!remote} onchange={() => (remote = false)} disabled={!caps.stdio} /> {tr("Programma op deze computer", "Program on this computer")}</label>
      <label class="radio"><input type="radio" checked={remote} onchange={() => (remote = true)} /> {tr("Adres op internet", "Address on the internet")}</label>
    </div>
    <input
      class="full"
      bind:value={target}
      placeholder={remote ? "https://…/mcp" : "npx -y @modelcontextprotocol/server-…"}
      onpaste={(e) => { const t = e.clipboardData?.getData("text") ?? ""; if (t.trim().startsWith("{")) { e.preventDefault(); usePasted(t); } }}
    />
    <label class="field">
      <span class="faint small">{remote ? tr("Sleutels (headers)", "Keys (headers)") : tr("Sleutels (omgevingsvariabelen)", "Keys (environment variables)")}</span>
      <textarea rows="3" bind:value={secrets} placeholder={remote ? "Authorization: Bearer …" : "GITHUB_TOKEN=ghp_…"}></textarea>
      <span class="faint small">{remote ? tr("Eén per regel: Authorization: Bearer … Ze gaan naar de kluis.", "One per line: Authorization: Bearer … They go to the keychain.") : tr("Eén per regel, zoals in de README: GITHUB_TOKEN=ghp_… Ze gaan naar de kluis.", "One per line, as in the README: GITHUB_TOKEN=ghp_… They go to the keychain.")}</span>
    </label>
  </SetupStep>

  {#if preset?.env.length}
    <SetupStep number={3} title={tr("Voer eventuele sleutels in", "Enter any keys")}>
      {#each preset.env as v (v.name)}
        <label class="field">
          <span class="faint small">{v.label}</span>
          <input type="password" placeholder={v.placeholder} bind:value={envDrafts[v.name]} />
        </label>
      {/each}
      {#if preset.help}
        <button type="button" class="link" onclick={() => openUrl(preset!.help!)}>{tr("Haal sleutel op", "Get a key")} ↗</button>
      {/if}
    </SetupStep>
  {/if}

  <SetupCheckStep
    number={checkStepNumber}
    title={tr("Klaar om toe te voegen", "Ready to add")}
    detail={tr("Vul eerst een opdracht of adres in bij stap 2.", "Enter a command or address in step 2 first.")}
    state={checkState}
  />

  <p class="warn small">{remote ? tr("Wat Nook aan deze server vraagt, gaat naar dat adres. Acties van de server vragen altijd eerst je goedkeuring.", "What Nook asks this server goes to that address. The server's actions always ask for your approval first.") : tr("Een lokale MCP-server draait met jouw rechten op deze computer. Voeg alleen servers toe die je vertrouwt. Acties van de server vragen altijd eerst je goedkeuring.", "A local MCP server runs with your permissions on this computer. Only add servers you trust. The server's actions always ask for your approval first.")}</p>

  {#snippet footer()}
    <span class="spacer"></span>
    <button type="button" onclick={onclose}>{tr("Annuleer", "Cancel")}</button>
    <button type="button" class="primary" onclick={add} disabled={!readyToAdd}>{tr("Toevoegen", "Add")}</button>
  {/snippet}
</SetupSheet>

<style>
  .tile {
    width: 40px;
    height: 40px;
    flex: none;
    display: grid;
    place-items: center;
    border-radius: var(--radius-card);
    background: var(--smoke);
    color: var(--paper);
  }
  .small { font: var(--text-meta); }
  .full { width: 100%; }
  .field { display: flex; flex-direction: column; gap: var(--space-4); width: 100%; }
  .field input, .field textarea { width: 100%; }
  .radio { display: inline-flex; align-items: center; gap: var(--space-6); }
  .paste { display: flex; flex-direction: column; gap: var(--space-6); padding: var(--space-12); border: 1px dashed var(--line2); border-radius: var(--radius-card); align-items: flex-start; }
  textarea { font: var(--text-code); resize: vertical; }
  .warn { color: var(--amber); margin: 0; }
  .link { background: none; border: none; padding: 0; color: var(--text2); text-align: left; }
  .link:hover { background: none; color: var(--paper); }
  .inline { display: flex; gap: var(--space-12); align-items: center; flex-wrap: wrap; }
  .spacer { flex: 1; }
</style>
