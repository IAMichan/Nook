<script lang="ts">
  // Accounts & koppelingen: één pagina in één vorm. Een zoekveld met categorieën, wat jou nodig heeft, je koppelingen
  // (één rijvorm voor elke dienst, ook GitLab en je eigen MCP-servers), wat er op dit apparaat is, en één catalogus van
  // alles wat je kunt toevoegen (één kaartvorm, met een label dat zegt hoe: inloggen, een sleutel of MCP).
  // Een nieuwe dienst krijgt een rij en een kaart in deze vormen, en een stappenvenster als hij stappen nodig heeft;
  // nooit een eigen sectie.
  // Settings shows it in two parts, as the Mac's `ConnectionsPage`: Chat apps (the chat apps on this device, WhatsApp)
  // and Services (everything else).
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
  import MailAccounts from "../connectors/MailAccounts.svelte";
  import { services, type ServicePrefs } from "../../lib/services";
  import { nook } from "../../lib/state.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import Ico from "../../components/ui/Ico.svelte";

  let { part = "services" }: { part?: "chats" | "services" } = $props();
  let overview = $state<Overview | null>(null);
  let prefs = $state<ServicePrefs | null>(null);
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
    if (part === "services" && nook.info?.capabilities.desktop) {
      services.prefs().then((p) => (prefs = p)).catch(() => {});
    }
    const un = connectorEvents.onChanged(load);
    return () => {
      un.then((f) => f());
    };
  });

  async function setOnlineLyrics(on: boolean) {
    if (!prefs) return;
    prefs = { ...prefs, onlineLyrics: on };
    prefs = await services.savePrefs($state.snapshot(prefs)).catch(() => prefs);
  }

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
  const showCustomMcp = $derived(shows("automation", tr("Zelf een andere MCP-server toevoegen", "Add another MCP server yourself") + " MCP"));
  const hasCatalogue = $derived(!!github || oneClick.length + withKey.length + shownPresets.length > 0 || showGitlab || showCustomMcp);

  // On this device: WhatsApp live, and what the Mac can that this platform cannot.
  const local = $derived((overview?.local ?? []).filter((l) => shows("local", `${l.title} ${l.reason}`)));
  const showMusic = $derived(!!prefs && shows("local", `${tr("Muziek", "Music")} ${tr("Songteksten online opzoeken", "Look up lyrics online")} lrclib.net`));

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
    if (connecting === s.id) return s.id === "github" ? tr("Nook neemt je GitHub-login over…", "Nook is taking over your GitHub login…") : tr("Log in bij {name} in het venster dat net openging. Nook gaat daarna vanzelf verder.", "Sign in to {name} in the window that just opened. Nook carries on by itself after that.", { name: s.title });
    return failures[s.id] ?? summary(info, s.tagline);
  }
</script>


{#if part === "chats"}
  <h3>{tr("Chat-apps", "Chat apps")}</h3>
  <WhatsApp />
{:else if overview}
  <label class="search-card conn-search">
    <Ico name="search" size={13} />
    <input placeholder={tr("Zoek in je koppelingen", "Search your connections")} aria-label={tr("Zoek een koppeling of wat hij kan", "Search for a connection or what it can do")} bind:value={query} />
    {#if query}
      <button type="button" class="clear" onclick={() => (query = "")} aria-label={tr("Wissen", "Clear")}><Ico name="circle-x" size={14} /></button>
    {/if}
  </label>
  <CategoryChips bind:selected={category} />

  {#if needsYou}
    <h3>{tr("Heeft jou nodig", "Needs you")}</h3>
    <div class="group">
      {#each linkedServices.filter(serviceNeedsYou) as s (s.id)}{@render serviceRow(s)}{/each}
      {#each linkedRemote.filter(remoteNeedsYou) as r (r.id)}{@render remoteRow(r)}{/each}
    </div>
  {/if}

  {#if hasYours && (linkedServices.some((s) => !serviceNeedsYou(s)) || linkedRemote.some((r) => !remoteNeedsYou(r)) || gitlabHosts.length || ownServers.length)}
    <h3>{tr("Jouw koppelingen", "Your connections")}</h3>
    <div class="group">
      {#each linkedServices.filter((s) => !serviceNeedsYou(s)) as s (s.id)}{@render serviceRow(s)}{/each}
      {#each linkedRemote.filter((r) => !remoteNeedsYou(r)) as r (r.id)}{@render remoteRow(r)}{/each}
      {#each gitlabHosts as host (host)}<GitLabRow {host} onchange={load} />{/each}
      <McpServers servers={ownServers} connectors={overview.connectors} onchange={load} />
    </div>
  {/if}

  <MailAccounts {query} {category} onchange={load} />

  {#if local.length}
    <h3>{tr("Op dit apparaat", "On this device")}</h3>
    <div class="group">
      {#each local as l (l.id)}
        <div class="row local"><span><strong>{l.title}</strong> <span class="mark">—</span><br /><span class="faint small">{l.reason}</span></span></div>
      {/each}
    </div>
    <p class="note">{tr("Bestanden en het klembord leest Nook met de onderdelen van dit platform zelf; die staan bij hun eigen instellingen.", "Nook reads files and the clipboard with this platform's own parts; they have their own settings.")}</p>
  {/if}

  {#if hasCatalogue}
    {@const nothingYet = !hasYours && !query.trim() && category === null}
    <!-- With nothing linked, the Mac's Services card: what to do first, and the services to pick from in the same card. -->
    <h3>{nothingYet ? tr("Diensten", "Services") : tr("Dienst toevoegen", "Add a service")}</h3>
    <div class="group catalogue">
    {#if nothingYet}
      <div class="nothing">
        <strong>{tr("Nog niets gekoppeld", "Nothing linked yet")}</strong>
        <span>{tr("Koppel de diensten die je gebruikt, dan kan Nook meelezen en helpen. Kies er hieronder een. Chat-apps koppel je onder Chat-apps.", "Link the services you use, and Nook can read along and help. Pick one below. Chat apps are linked under Chat apps.")}</span>
      </div>
    {/if}
    <div class="cards">
      {#if github}
        {@const gh = github}
        <CatalogueCard
          title={gh.title}
          domain={gh.domain || null}
          method="signIn"
          detail={connecting === "github" ? tr("Nook neemt je GitHub-login over…", "Nook is taking over your GitHub login…") : (failures.github ?? gh.tagline)}
          bad={!!failures.github}
          badge={failures.github ? tr("Opnieuw proberen", "Try again") : undefined}
          busy={connecting === "github"}
          help={tr("Log in bij {name}, zonder eerst een token te maken", "Sign in to {name} without making a token first", { name: gh.title })}
          onclick={() => signInGithub(gh)}
          alt={{ label: tr("Met een token", "With a token"), help: tr("Liever zelf een token plakken", "Rather paste a token yourself"), onclick: () => (sheet = gh) }}
        />
      {/if}
      {#each oneClick as r (r.id)}
        {@const keyAlternative = overview.services.find((s) => s.id === r.id)}
        <CatalogueCard
          title={r.name}
          domain={r.domain}
          method="signIn"
          detail={failures[r.id] ?? (connecting === r.id ? tr("Log in bij {name} in het venster dat net openging. Nook gaat daarna vanzelf verder.", "Sign in to {name} in the window that just opened. Nook carries on by itself after that.", { name: r.name }) : r.tagline)}
          bad={!!failures[r.id]}
          badge={failures[r.id] ? tr("Opnieuw proberen", "Try again") : undefined}
          busy={connecting === r.id}
          disabled={!overview.caps.browserSignIn || connecting === r.id}
          help={overview.caps.browserSignIn ? tr("Log in bij {name} op zijn eigen site", "Sign in to {name} on its own site", { name: r.name }) : tr("Inloggen via de browser kan op Android nog niet.", "Signing in through the browser doesn't work on Android yet.")}
          onclick={() => connectRemote(r)}
          alt={keyAlternative ? { label: tr("Met sleutel", "With a key"), help: tr("Liever een API-sleutel plakken dan inloggen", "Rather paste an API key than sign in"), onclick: () => (sheet = keyAlternative) } : undefined}
        />
      {/each}
      {#each withKey as s (s.id)}
        <CatalogueCard title={s.title} domain={s.domain || null} method="key" detail={s.tagline} help={tr("Koppel {name} met een sleutel, stap voor stap", "Connect {name} with a key, step by step", { name: s.title })} onclick={() => (sheet = s)} />
      {/each}
      {#if showGitlab}
        <CatalogueCard title="GitLab" domain="gitlab.com" method="key" detail={tr("Merge requests op gitlab.com of je eigen host", "Merge requests on gitlab.com or your own host")} onclick={() => (gitlabSetup = true)} />
      {/if}
      {#each shownPresets as p (p.id)}
        <CatalogueCard
          title={p.name}
          domain={p.domain}
          method="mcp"
          detail={p.detail}
          disabled={!overview.caps.stdio}
          help={overview.caps.stdio ? undefined : tr("Op Android kan Nook geen programma's starten: alleen servers met een https-adres werken hier.", "On Android Nook can't start programs: only servers with an https address work here.")}
          onclick={() => (mcpAdd = { preset: p })}
        />
      {/each}
      {#if showCustomMcp}
        <CatalogueCard
          title={tr("Zelf een andere MCP-server toevoegen", "Add another MCP server yourself")}
          method="mcp"
          detail={tr("Plak een opdracht (npx, uvx), een Claude Desktop JSON-configuratie of een web-adres.", "Paste a command (npx, uvx), a Claude Desktop JSON configuration or a web address.")}
          onclick={() => (mcpAdd = { preset: null })}
        />
      {/if}
    </div>
    </div>
    <p class="note">{tr("Eén kaart, één klik. Inloggen gebeurt op de site van de dienst zelf; bij een sleutel laat Nook stap voor stap zien waar je die vindt; MCP koppelt elk ander programma. Tools van een MCP-server die alleen lezen gebruikt Nook bij een antwoord; al het andere wordt een actie die pas na jouw Uitvoeren gebeurt.", "One card, one click. Signing in happens on the service's own site; for a key Nook shows step by step where to find it; MCP connects any other program. Read-only tools from an MCP server are used in an answer; everything else becomes an action that only happens after you press Run.")}</p>
  {:else if !hasYours && !local.length && !showMusic}
    <p class="faint empty">{tr("Niets gevonden voor “{query}”. Probeer een andere naam, of voeg het als MCP-server toe.", "Nothing found for “{query}”. Try another name, or add it as an MCP server.", { query: query.trim() })}</p>
  {/if}

  {#if showMusic && prefs}
    <h3>{tr("Muziek", "Music")}</h3>
    <div class="group">
      <label class="row">
        <span>{tr("Songteksten online opzoeken", "Look up lyrics online")}<br /><small>{tr("De muziek-tab zoekt songteksten op lrclib.net. Alleen de titel, artiest, het album en de lengte van het spelende nummer worden verstuurd.", "The Music tab finds lyrics on lrclib.net. Only the title, artist, album and length of the playing track are sent.")}</small></span>
        <input type="checkbox" role="switch" checked={!!prefs.onlineLyrics} onchange={(e) => setOnlineLyrics(e.currentTarget.checked)} />
      </label>
    </div>
  {/if}
{/if}

{#snippet serviceRow(s: ServiceView)}
  {@const info = byId.get(s.id)}
  {@const h = health(info)}
  <div class="row">
    <button class="plain" onclick={() => (sheet = s)} title={tr("Klik om {name} te beheren", "Click to manage {name}", { name: s.title })}>
      <ServiceIcon domain={s.domain || null} title={s.title} />
      <span class="text">
        <span>{s.title}{#if s.accounts.filter((a) => a.hasToken).length > 1}<span class="faint"> · {tr("{n} accounts", "{n} accounts", { n: s.accounts.filter((a) => a.hasToken).length })}</span>{/if}</span>
        <span class="faint small" class:bad={h === "broken" || !!failures[s.id]}>{serviceDetail(s, info)}</span>
      </span>
    </button>
    {#if connecting === s.id}
      <span class="spin" aria-label={tr("Bezig", "Working")}></span>
    {:else if h === "broken" || h === "needsYou"}
      <button class="fix" class:broken={h === "broken"} onclick={() => repair(s)}>{tr("Herstel", "Fix")}</button>
    {:else}
      <HealthPill health={h} />
    {/if}
    <input type="checkbox" role="switch" checked={info?.on ?? true} title={tr("Zet deze koppeling aan of uit", "Turn this connection on or off")} onchange={(e) => toggle(s.id, e.currentTarget.checked)} />
  </div>
{/snippet}

{#snippet remoteRow(r: RemoteView)}
  {@const info = remoteInfo(r)}
  {@const h = health(info)}
  <div class="row">
    <span class="plain">
      <ServiceIcon domain={r.domain} title={r.name} />
      <span class="text">
        <span>{r.name} <span class="faint small">· {tr("ingelogd", "signed in")}</span></span>
        <span class="faint small">{h === "needsYou" ? tr("Log opnieuw in bij {name}, dan kan Nook er weer bij.", "Sign in to {name} again so Nook can reach it.", { name: r.name }) : summary(info, r.tagline)}</span>
      </span>
    </span>
    {#if h === "needsYou"}<button class="fix" onclick={() => r.server && connectorsApi.mcpSignIn(r.server).then(load)}>{tr("Opnieuw autoriseren", "Authorize again")}</button>{:else}<HealthPill health={h} />{/if}
    <button class="ghost danger" onclick={() => disconnectRemote(r)} title={tr("Nook vraagt {name} de toegang in te trekken en verwijdert de sleutels uit je kluis.", "Nook asks {name} to revoke access and removes the keys from your keychain.", { name: r.name })}>{tr("Ontkoppel", "Disconnect")}</button>
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
  .small { font: var(--text-detail); line-height: 1.3; }
  .bad { color: var(--coral); }
  .fix { background: var(--amber); color: var(--ink); border: none; font: var(--text-label); font-weight: 600; padding: 4px 10px; border-radius: var(--radius-pill); }
  .fix.broken { background: var(--coral); color: var(--paper); }
  .spin { flex: none; width: 12px; height: 12px; border-radius: 50%; border: 1.5px solid var(--text2); border-top-color: transparent; animation: spin 0.8s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }
  /* Spacing below the search card before CategoryChips. */
  .conn-search + :global(*) { margin-top: var(--space-12); }
  .empty { margin-top: var(--space-16); }
  /* The catalogue card: "Nothing linked yet" over a line, then the tiles three to a row, 8 px apart. */
  .catalogue { padding: 0; }
  .nothing { display: flex; flex-direction: column; gap: var(--space-4); padding: var(--space-16); border-bottom: 1px solid var(--separator); }
  .nothing strong { font: var(--text-emphasis); color: var(--paper); }
  .nothing span { font: var(--text-body); line-height: 1.4; color: var(--text2); }
  .cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(230px, 1fr)); gap: var(--space-8); padding: var(--space-16); }
  .mark { color: var(--text3); }
  .local { justify-content: flex-start; }
</style>
