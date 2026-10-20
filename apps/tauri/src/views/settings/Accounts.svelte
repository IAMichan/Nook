<script lang="ts">
  // Accounts & koppelingen: bovenaan wat gekoppeld is, daaronder per soort de diensten met Koppel en een stappenplan,
  // dan MCP-servers, WhatsApp live, GitLab en wat er van de Mac (nog) niet kan op dit apparaat.
  import {
    categories, connectorsApi, connectorEvents, health, summary,
    type ConnectorInfo, type Overview, type RemoteView, type ServiceView,
  } from "../../lib/connectors";
  import ServiceIcon from "../connectors/ServiceIcon.svelte";
  import HealthPill from "../connectors/HealthPill.svelte";
  import ServiceSheet from "../connectors/ServiceSheet.svelte";
  import McpServers from "../connectors/McpServers.svelte";
  import WhatsApp from "../connectors/WhatsApp.svelte";
  import WatchedPulls from "../connectors/WatchedPulls.svelte";

  let overview = $state<Overview | null>(null);
  let sheet = $state<ServiceView | null>(null);
  let query = $state("");
  let connecting = $state<string | null>(null);
  let failures = $state<Record<string, string>>({});
  let gitlabHost = $state("gitlab.com");
  let gitlabToken = $state("");
  let gitlabError = $state("");

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
  const matches = (text: string) => !query.trim() || text.toLowerCase().includes(query.trim().toLowerCase());

  const linkedServices = $derived((overview?.services ?? []).filter((s) => byId.get(s.id)?.configured));
  const linkedRemote = $derived((overview?.remote ?? []).filter((r) => r.server));
  const openServices = $derived((overview?.services ?? []).filter((s) => !byId.get(s.id)?.configured && matches(`${s.title} ${s.tagline} ${s.capabilities}`)));
  const openRemote = $derived((overview?.remote ?? []).filter((r) => !r.server && matches(`${r.name} ${r.tagline}`)));

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

  async function saveGitlab() {
    gitlabError = "";
    try {
      overview!.gitlab = await connectorsApi.gitlabSave(gitlabHost, gitlabToken);
      gitlabToken = "";
    } catch (e) {
      gitlabError = String(e);
    }
  }
</script>

<h2>Accounts & koppelingen</h2>
<p class="muted">Verbind een dienst en Nook kan er meteen mee werken. Inloggen gebeurt op de site van de dienst zelf; sleutels en tokens blijven in de kluis van je systeem. Elke koppeling laat zien wat Nook ermee kan lezen en doen; schrijven gebeurt altijd pas na jouw Uitvoeren.</p>

{#if overview}
  <h3>Gekoppeld</h3>
  {#if linkedServices.length || linkedRemote.length}
    <div class="group">
      {#each linkedServices as s (s.id)}
        {@const info = byId.get(s.id)}
        {@const h = health(info)}
        <div class="row">
          <button class="plain" onclick={() => (sheet = s)} title="Klik om {s.title} te beheren">
            <ServiceIcon domain={s.domain || null} title={s.title} />
            <span class="text">
              <span>{s.title}{#if s.accounts.filter((a) => a.hasToken).length > 1}<span class="faint"> · {s.accounts.filter((a) => a.hasToken).length} accounts</span>{/if}</span>
              <span class="faint small" class:bad={h === "broken"}>{summary(info, s.tagline)}</span>
            </span>
          </button>
          {#if info?.status.state.kind === "error"}<button class="fix" onclick={() => (sheet = s)}>Herstel</button>{:else}<HealthPill health={h} text={h === "needsYou" ? "Wacht op jou" : undefined} />{/if}
          <input type="checkbox" checked={info?.on ?? true} title="Zet deze koppeling aan of uit" onchange={(e) => toggle(s.id, e.currentTarget.checked)} />
        </div>
      {/each}
      {#each linkedRemote as r (r.id)}
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
      {/each}
    </div>
  {:else}
    <p class="faint">Nog niets gekoppeld. Koppel GitHub, je agenda via een ICS-adres, Stripe of een andere dienst hieronder. Dan kan Nook vragen beantwoorden met alles wat jij weet.</p>
  {/if}

  <!-- Right below your connected services, once a GitHub account is connected (as on the Mac). -->
  {#if byId.get("github")?.configured}<WatchedPulls />{/if}

  <input class="search" placeholder="Zoek een koppeling of wat hij kan" bind:value={query} />

  {#each categories as cat (cat.id)}
    {@const services = openServices.filter((s) => s.category === cat.id)}
    {@const remote = openRemote.filter((r) => r.category === cat.id)}
    {#if services.length || remote.length}
      <h3>{cat.title}</h3>
      <div class="group">
        {#each remote as r (r.id)}
          {@const keyAlternative = openServices.find((s) => s.id === r.id)}
          <div class="row">
            <span class="plain">
              <ServiceIcon domain={r.domain} title={r.name} />
              <span class="text">
                <span>{r.name}</span>
                <span class="faint small" class:bad={!!failures[r.id]}>{failures[r.id] ?? (connecting === r.id ? `Log in bij ${r.name} in het venster dat net openging. Nook gaat daarna vanzelf verder.` : `${r.tagline} · inloggen bij ${r.name}`)}</span>
              </span>
            </span>
            {#if keyAlternative}<button class="ghost" onclick={() => (sheet = keyAlternative)} title="Liever een API-sleutel plakken dan inloggen">Met sleutel</button>{/if}
            {#if overview.caps.browserSignIn}
              <button class="primary" onclick={() => connectRemote(r)} disabled={connecting === r.id}>{connecting === r.id ? "Verbinden…" : failures[r.id] ? "Opnieuw proberen" : "Verbinden"}</button>
            {:else}
              <span class="faint small" title="Inloggen via de browser kan op Android nog niet.">—</span>
            {/if}
          </div>
        {/each}
        {#each services.filter((s) => !remote.some((r) => r.id === s.id)) as s (s.id)}
          <div class="row">
            <span class="plain">
              <ServiceIcon domain={s.domain || null} title={s.title} />
              <span class="text"><span>{s.title}</span><span class="faint small">{s.tagline} · {s.id === "github" ? "inloggen of een token" : "met een sleutel"}</span></span>
            </span>
            <button class="primary" onclick={() => (sheet = s)}>Koppel</button>
          </div>
        {/each}
      </div>
    {/if}
  {/each}

  <h3>MCP-servers</h3>
  <McpServers servers={overview.mcp} connectors={overview.connectors} caps={overview.caps} onchange={load} />

  <h3>WhatsApp live</h3>
  <WhatsApp />

  <h3>GitLab</h3>
  <div class="group">
    <p class="faint small">Een persoonlijk toegangstoken (scope api) laat Nook merge requests voor je zoeken en openen. Het blijft in je kluis en gaat alleen via https naar deze host.</p>
    {#each overview.gitlab as host (host)}
      <div class="row"><span class="inline"><ServiceIcon domain="gitlab.com" title="GitLab" size={22} />{host}</span><button class="ghost danger" onclick={async () => (overview!.gitlab = await connectorsApi.gitlabRemove(host))}>Verwijder</button></div>
    {:else}
      <p class="faint small">Nog geen GitLab-host gekoppeld.</p>
    {/each}
    <div class="row">
      <span class="inline wide">
        <input placeholder="Host (bijv. gitlab.com)" bind:value={gitlabHost} />
        <input type="password" placeholder="Toegangstoken" bind:value={gitlabToken} />
        <button onclick={saveGitlab} disabled={!gitlabToken.trim()}>Bewaar</button>
      </span>
    </div>
    {#if gitlabError}<p class="err">{gitlabError}</p>{/if}
  </div>

  <h3>Op deze computer</h3>
  <div class="group">
    {#each overview.local as l (l.id)}
      <div class="row local"><span><strong>{l.title}</strong> <span class="mark">—</span><br /><span class="faint small">{l.reason}</span></span></div>
    {/each}
  </div>
  <p class="faint small">Bestanden en het klembord leest Nook met de onderdelen van dit platform zelf; die staan bij hun eigen instellingen.</p>
{/if}

{#if sheet && overview}
  <ServiceSheet service={sheet} info={byId.get(sheet.id)} caps={overview.caps} onclose={() => { sheet = null; load(); }} onchange={load} />
{/if}

<style>
  .plain { display: flex; gap: 12px; align-items: center; background: none; border: none; padding: 0; text-align: left; flex: 1; min-width: 0; }
  .plain:hover { background: none; }
  .text { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
  .text span:last-child { overflow: hidden; text-overflow: ellipsis; }
  .small { font-size: 11px; }
  .bad { color: var(--coral); }
  .fix { background: var(--amber); color: var(--ink); border: none; font-weight: 600; font-size: 12px; padding: 4px 10px; }
  .search { width: 100%; margin-top: 18px; }
  .wide { width: 100%; }
  .wide input { flex: 1; }
  .mark { color: var(--text3); }
  .local { justify-content: flex-start; }
</style>
