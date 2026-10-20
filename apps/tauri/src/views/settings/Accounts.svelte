<script lang="ts">
  // Accounts & koppelingen: één pagina in één vorm. Een zoekveld met categorieën, wat jou nodig heeft, je koppelingen
  // (één rijvorm voor elke dienst, ook GitLab en je eigen MCP-servers), wat er op dit apparaat is, en één catalogus van
  // alles wat je kunt toevoegen (één kaartvorm, met een label dat zegt hoe: inloggen, een sleutel of MCP).
  // Een nieuwe dienst krijgt een rij en een kaart in deze vormen, en een stappenvenster als hij stappen nodig heeft;
  // nooit een eigen sectie.
  import {
    connectorsApi, connectorEvents, health, inCategory, matchesQuery, summary,
    type ConnectorInfo, type Overview, type RemoteView, type ServiceView,
  } from "../../lib/connectors";
  import ServiceIcon from "../connectors/ServiceIcon.svelte";
  import HealthPill from "../connectors/HealthPill.svelte";
  import ServiceSheet from "../connectors/ServiceSheet.svelte";
  import McpServers from "../connectors/McpServers.svelte";
  import McpAddSheet, { presets, type Preset } from "../connectors/McpAddSheet.svelte";
  import WhatsApp from "../connectors/WhatsApp.svelte";
  import CatalogueCard from "../connectors/CatalogueCard.svelte";
  import CategoryChips from "../connectors/CategoryChips.svelte";
  import GitLabRow from "../connectors/GitLabRow.svelte";
  import GitLabSheet from "../connectors/GitLabSheet.svelte";
  import WatchedPulls from "../connectors/WatchedPulls.svelte";

  let overview = $state<Overview | null>(null);
  let sheet = $state<ServiceView | null>(null);
  let query = $state("");
  let category = $state<string | null>(null);
  let connecting = $state<string | null>(null);
  let failures = $state<Record<string, string>>({});
  let gitlabSetup = $state(false);
  let mcpAdd = $state<{ preset: Preset | null } | null>(null);

  async function load() {
    overview = await connectorsApi.overview();
  }

  $effect(() => {
    load();
    const un = connectorEvents.onChanged(load);
    return () => {
      un.then((f) => f());
    };
  });

  const byId = $derived(new Map((overview?.connectors ?? []).map((c) => [c.id, c])));
  const remoteInfo = (r: RemoteView): ConnectorInfo | undefined => (r.server ? byId.get(`mcp.${r.server}`) : undefined);
  const shows = (cat: string, text: string) => inCategory(category, cat) && matchesQuery(query, text);
  const serviceText = (s: ServiceView) => `${s.title} ${s.tagline} ${s.capabilities}`;
  const remoteIds = $derived(new Set((overview?.remote ?? []).map((r) => r.id)));

  // Yours: every connected service, whatever way it was connected.
  const linkedServices = $derived((overview?.services ?? []).filter((s) => byId.get(s.id)?.configured && shows(s.category, serviceText(s))));
  const linkedRemote = $derived((overview?.remote ?? []).filter((r) => r.server && connecting !== r.id && shows(r.category, `${r.name} ${r.tagline}`)));
  const gitlabHosts = $derived(shows("development", "GitLab merge requests") ? (overview?.gitlab ?? []) : []);
  const ownServers = $derived(
    (overview?.mcp ?? []).filter((s) => !s.config.serviceId && shows("automation", `${s.config.name} ${s.target} MCP`)),
  );
  const serviceNeedsYou = (s: ServiceView) => health(byId.get(s.id)) === "needsYou";
  const remoteNeedsYou = (r: RemoteView) => health(remoteInfo(r)) === "needsYou";
  const needsYou = $derived(linkedServices.some(serviceNeedsYou) || linkedRemote.some(remoteNeedsYou));
  const hasYours = $derived(linkedServices.length + linkedRemote.length + gitlabHosts.length + ownServers.length > 0);

  // The catalogue: everything you can add, sign-in first because that is the easiest.
  const github = $derived(
    (overview?.services ?? []).find((s) => s.id === "github" && !byId.get(s.id)?.configured && shows(s.category, serviceText(s))),
  );
  const oneClick = $derived(
    (overview?.remote ?? []).filter((r) => (!r.server || connecting === r.id) && !byId.get(r.id)?.configured && shows(r.category, `${r.name} ${r.tagline}`)),
  );
  const withKey = $derived(
    (overview?.services ?? []).filter((s) => !byId.get(s.id)?.configured && s.id !== "github" && !remoteIds.has(s.id) && shows(s.category, serviceText(s))),
  );
  const showGitlab = $derived(!(overview?.gitlab ?? []).length && shows("development", "GitLab merge requests"));
  const shownPresets = $derived(presets.filter((p) => shows(p.category, `${p.name} ${p.detail} MCP`)));
  const showCustomMcp = $derived(shows("automation", "Zelf een andere MCP-server toevoegen MCP"));
  const hasCatalogue = $derived(!!github || oneClick.length + withKey.length + shownPresets.length > 0 || showGitlab || showCustomMcp);

  // On this device: WhatsApp live, and what the Mac can that this platform cannot.
  const showWhatsApp = $derived(shows("local", "WhatsApp live"));
  const local = $derived((overview?.local ?? []).filter((l) => shows("local", `${l.title} ${l.reason}`)));

  async function toggle(id: string, on: boolean) {
    await connectorsApi.toggle(id, on);
    await load();
  }

  async function connectRemote(r: RemoteView) {
    connecting = r.id;
    delete failures[r.id];
    try {
      await connectorsApi.mcpConnectService(r.id);
    } catch (e) {
      failures[r.id] = String(e);
    }
    connecting = null;
    await load();
  }

  async function disconnectRemote(r: RemoteView) {
    if (r.server) await connectorsApi.mcpRemove(r.server);
    await load();
  }

  /** GitHub signs in too: its own login (device flow, in the sheet that shows the code) or the GitHub CLI login. */
  async function signInGithub(s: ServiceView) {
    if (!overview?.caps.ghCli || overview.caps.deviceFlow) {
      sheet = s;
      return;
    }
    connecting = "github";
    delete failures.github;
    try {
      await connectorsApi.githubCli("github");
    } catch (e) {
      failures.github = String(e);
    }
    connecting = null;
    await load();
  }

  /** "Herstel" repairs by signing in again where it can, never via a new key: GitHub's login (or the gh login), or the
   *  service's own sign-in page (Notion, Stripe, Vercel). Otherwise the sheet explains what is wrong. */
  async function repair(s: ServiceView) {
    const h = health(byId.get(s.id));
    if (s.id === "github" && h === "needsYou") {
      await signInGithub(s);
      if (failures.github) sheet = s;
      return;
    }
    if (h === "needsYou" && remoteIds.has(s.id) && overview?.caps.browserSignIn) {
      connecting = s.id;
      delete failures[s.id];
      try {
        await connectorsApi.repairBySignIn(s.id);
      } catch (e) {
        failures[s.id] = String(e);
      }
      connecting = null;
      await load();
      return;
    }
    sheet = s;
  }

  function serviceDetail(s: ServiceView, info: ConnectorInfo | undefined): string {
    if (connecting === s.id) return s.id === "github" ? "Nook neemt je GitHub-login over…" : `Log in bij ${s.title} in het venster dat net openging. Nook gaat daarna vanzelf verder.`;
    return failures[s.id] ?? summary(info, s.tagline);
  }
</script>

<h2>Accounts & koppelingen</h2>
<p class="muted">Verbind een dienst en Nook kan er meteen mee werken. Inloggen gebeurt op de site van de dienst zelf; sleutels en tokens blijven in de kluis van je systeem. Elke koppeling laat zien wat Nook ermee kan lezen en doen; schrijven gebeurt altijd pas na jouw Uitvoeren.</p>

{#if overview}
  <input class="search" placeholder="Zoek een koppeling of wat hij kan" bind:value={query} />
  <CategoryChips bind:selected={category} />

  {#if needsYou}
    <h3>Heeft jou nodig</h3>
    <div class="group">
      {#each linkedServices.filter(serviceNeedsYou) as s (s.id)}{@render serviceRow(s)}{/each}
      {#each linkedRemote.filter(remoteNeedsYou) as r (r.id)}{@render remoteRow(r)}{/each}
    </div>
  {/if}

  {#if hasYours && (linkedServices.some((s) => !serviceNeedsYou(s)) || linkedRemote.some((r) => !remoteNeedsYou(r)) || gitlabHosts.length || ownServers.length)}
    <h3>Jouw koppelingen</h3>
    <div class="group">
      {#each linkedServices.filter((s) => !serviceNeedsYou(s)) as s (s.id)}{@render serviceRow(s)}{/each}
      {#each linkedRemote.filter((r) => !remoteNeedsYou(r)) as r (r.id)}{@render remoteRow(r)}{/each}
      {#each gitlabHosts as host (host)}<GitLabRow {host} onchange={load} />{/each}
      <McpServers servers={ownServers} connectors={overview.connectors} onchange={load} />
    </div>
  {:else if !hasYours && !query.trim() && category === null}
    <p class="faint empty">Nog niets gekoppeld. Koppel GitHub, je agenda via een ICS-adres, Stripe of een andere dienst hieronder. Dan kan Nook vragen beantwoorden met alles wat jij weet.</p>
  {/if}

  <!-- Right below your connected services, once a GitHub account is connected (as on the Mac). -->
  {#if byId.get("github")?.configured}<WatchedPulls />{/if}

  {#if showWhatsApp || local.length}
    <h3>Op dit apparaat</h3>
    {#if showWhatsApp}<WhatsApp />{/if}
    {#if local.length}
      <div class="group">
        {#each local as l (l.id)}
          <div class="row local"><span><strong>{l.title}</strong> <span class="mark">—</span><br /><span class="faint small">{l.reason}</span></span></div>
        {/each}
      </div>
      <p class="faint small">Bestanden en het klembord leest Nook met de onderdelen van dit platform zelf; die staan bij hun eigen instellingen.</p>
    {/if}
  {/if}

  {#if hasCatalogue}
    <h3>Dienst toevoegen</h3>
    <div class="cards">
      {#if github}
        {@const gh = github}
        <CatalogueCard
          title={gh.title}
          domain={gh.domain || null}
          method="signIn"
          detail={connecting === "github" ? "Nook neemt je GitHub-login over…" : (failures.github ?? gh.tagline)}
          bad={!!failures.github}
          badge={failures.github ? "Opnieuw proberen" : undefined}
          busy={connecting === "github"}
          help={`Log in bij ${gh.title}, zonder eerst een token te maken`}
          onclick={() => signInGithub(gh)}
          alt={{ label: "Met een token", help: "Liever zelf een token plakken", onclick: () => (sheet = gh) }}
        />
      {/if}
      {#each oneClick as r (r.id)}
        {@const keyAlternative = overview.services.find((s) => s.id === r.id)}
        <CatalogueCard
          title={r.name}
          domain={r.domain}
          method="signIn"
          detail={failures[r.id] ?? (connecting === r.id ? `Log in bij ${r.name} in het venster dat net openging. Nook gaat daarna vanzelf verder.` : r.tagline)}
          bad={!!failures[r.id]}
          badge={failures[r.id] ? "Opnieuw proberen" : undefined}
          busy={connecting === r.id}
          disabled={!overview.caps.browserSignIn || connecting === r.id}
          help={overview.caps.browserSignIn ? `Log in bij ${r.name} op zijn eigen site` : "Inloggen via de browser kan op Android nog niet."}
          onclick={() => connectRemote(r)}
          alt={keyAlternative ? { label: "Met sleutel", help: "Liever een API-sleutel plakken dan inloggen", onclick: () => (sheet = keyAlternative) } : undefined}
        />
      {/each}
      {#each withKey as s (s.id)}
        <CatalogueCard title={s.title} domain={s.domain || null} method="key" detail={s.tagline} help={`Koppel ${s.title} met een sleutel, stap voor stap`} onclick={() => (sheet = s)} />
      {/each}
      {#if showGitlab}
        <CatalogueCard title="GitLab" domain="gitlab.com" method="key" detail="Merge requests op gitlab.com of je eigen host" onclick={() => (gitlabSetup = true)} />
      {/if}
      {#each shownPresets as p (p.id)}
        <CatalogueCard
          title={p.name}
          domain={p.domain}
          method="mcp"
          detail={p.detail}
          disabled={!overview.caps.stdio}
          help={overview.caps.stdio ? undefined : "Op Android kan Nook geen programma's starten: alleen servers met een https-adres werken hier."}
          onclick={() => (mcpAdd = { preset: p })}
        />
      {/each}
      {#if showCustomMcp}
        <CatalogueCard
          title="Zelf een andere MCP-server toevoegen"
          method="mcp"
          detail="Plak een opdracht (npx, uvx), een Claude Desktop JSON-configuratie of een web-adres."
          onclick={() => (mcpAdd = { preset: null })}
        />
      {/if}
    </div>
    <p class="faint small">Eén kaart, één klik. Inloggen gebeurt op de site van de dienst zelf; bij een sleutel laat Nook stap voor stap zien waar je die vindt; MCP koppelt elk ander programma. Tools van een MCP-server die alleen lezen gebruikt Nook bij een antwoord; al het andere wordt een actie die pas na jouw Uitvoeren gebeurt.</p>
  {:else if !hasYours && !showWhatsApp && !local.length}
    <p class="faint empty">Niets gevonden voor “{query.trim()}”. Probeer een andere naam, of voeg het als MCP-server toe.</p>
  {/if}
{/if}

{#snippet serviceRow(s: ServiceView)}
  {@const info = byId.get(s.id)}
  {@const h = health(info)}
  <div class="row">
    <button class="plain" onclick={() => (sheet = s)} title="Klik om {s.title} te beheren">
      <ServiceIcon domain={s.domain || null} title={s.title} />
      <span class="text">
        <span>{s.title}{#if s.accounts.filter((a) => a.hasToken).length > 1}<span class="faint"> · {s.accounts.filter((a) => a.hasToken).length} accounts</span>{/if}</span>
        <span class="faint small" class:bad={h === "broken" || !!failures[s.id]}>{serviceDetail(s, info)}</span>
      </span>
    </button>
    {#if connecting === s.id}
      <span class="spin" aria-label="Bezig"></span>
    {:else if h === "broken" || h === "needsYou"}
      <button class="fix" class:broken={h === "broken"} onclick={() => repair(s)}>Herstel</button>
    {:else}
      <HealthPill health={h} />
    {/if}
    <input type="checkbox" checked={info?.on ?? true} title="Zet deze koppeling aan of uit" onchange={(e) => toggle(s.id, e.currentTarget.checked)} />
  </div>
{/snippet}

{#snippet remoteRow(r: RemoteView)}
  {@const info = remoteInfo(r)}
  {@const h = health(info)}
  <div class="row">
    <span class="plain">
      <ServiceIcon domain={r.domain} title={r.name} />
      <span class="text">
        <span>{r.name} <span class="faint small">· ingelogd</span></span>
        <span class="faint small">{h === "needsYou" ? `Log opnieuw in bij ${r.name}, dan kan Nook er weer bij.` : summary(info, r.tagline)}</span>
      </span>
    </span>
    {#if h === "needsYou"}<button class="fix" onclick={() => r.server && connectorsApi.mcpSignIn(r.server).then(load)}>Opnieuw autoriseren</button>{:else}<HealthPill health={h} />{/if}
    <button class="ghost danger" onclick={() => disconnectRemote(r)} title="Nook vraagt {r.name} de toegang in te trekken en verwijdert de sleutels uit je kluis.">Ontkoppel</button>
  </div>
{/snippet}

{#if sheet && overview}
  <ServiceSheet service={sheet} info={byId.get(sheet.id)} caps={overview.caps} onclose={() => { sheet = null; load(); }} onchange={load} />
{/if}
{#if gitlabSetup}
  <GitLabSheet onclose={() => { gitlabSetup = false; load(); }} onchange={load} />
{/if}
{#if mcpAdd && overview}
  <McpAddSheet preset={mcpAdd.preset} caps={overview.caps} onclose={() => (mcpAdd = null)} onchange={load} />
{/if}

<style>
  .plain { display: flex; gap: 12px; align-items: center; background: none; border: none; padding: 0; text-align: left; flex: 1; min-width: 0; }
  .plain:hover { background: none; }
  .text { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
  .text span:last-child { overflow: hidden; text-overflow: ellipsis; }
  .small { font-size: 11px; }
  .bad { color: var(--coral); }
  .fix { background: var(--amber); color: var(--ink); border: none; font-weight: 600; font-size: 12px; padding: 4px 10px; border-radius: 999px; }
  .fix.broken { background: var(--coral); color: var(--paper); }
  .spin { flex: none; width: 12px; height: 12px; border-radius: 50%; border: 1.5px solid var(--text2); border-top-color: transparent; animation: spin 0.8s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }
  .search { width: 100%; }
  .empty { margin-top: 16px; }
  .cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(240px, 1fr)); gap: 8px; margin-top: 12px; }
  .mark { color: var(--text3); }
  .local { justify-content: flex-start; }
</style>
