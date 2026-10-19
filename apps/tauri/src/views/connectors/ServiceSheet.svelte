<script lang="ts">
  // Alles over één dienst op één plek. Nog niet gekoppeld: drie stappen (sleutel halen, plakken, controleren).
  // Gekoppeld: hoe het gaat, aan/uit, de sleutel vervangen, extra accounts en ontkoppelen.
  import { openUrl } from "@tauri-apps/plugin-opener";
  import { untrack } from "svelte";
  import {
    connectorsApi, connectorEvents, health, summary,
    type Caps, type ConnectorInfo, type DeviceCode, type ServiceView,
  } from "../../lib/connectors";
  import ServiceIcon from "./ServiceIcon.svelte";
  import HealthPill from "./HealthPill.svelte";

  let { service: initial, info, caps, onclose, onchange }: {
    service: ServiceView;
    info: ConnectorInfo | undefined;
    caps: Caps;
    onclose: () => void;
    onchange: () => void;
  } = $props();

  // De beginwaarden, één keer: daarna houdt het venster zijn eigen staat bij.
  const start = untrack(() => ({ service: initial, info }));
  let service = $state(start.service);
  // Of het venster opende op een gekoppelde dienst: dan is het beheren, anders blijven de stappen staan tot het dicht gaat.
  const managing = start.info?.configured ?? false;
  const needsKey = start.info?.status.state.kind === "error" && (start.info.status.errorKind === "auth" || start.info.status.errorKind === "config");
  let current = $state<ConnectorInfo | undefined>(start.info);
  let drafts = $state<Record<string, string>>({});
  let note = $state("");
  let busy = $state(false);
  let replacing = $state(needsKey);
  let confirmDisconnect = $state(false);
  let showToken = $state(!managing && start.service.id !== "github");
  let device = $state<DeviceCode | null>(null);
  let newAccount = $state("");
  let accountTokens = $state<Record<string, string>>({});
  let showCaps = $state(false);

  const h = $derived(health(current));
  const isGithub = start.service.id === "github";

  $effect(() => {
    for (const f of service.fields) if (!f.secret) drafts[f.account] = service.values[f.account] ?? "";
    const un = connectorEvents.onSignIn(async (e) => {
      if (e.service !== "github") return;
      device = null;
      note = e.message;
      await reload();
    });
    return () => {
      un.then((f) => f());
    };
  });

  async function reload() {
    const all = await connectorsApi.overview();
    current = all.connectors.find((c) => c.id === service.id);
    const fresh = all.services.find((s) => s.id === service.id);
    if (fresh) service = fresh;
    onchange();
  }

  async function save() {
    busy = true;
    note = "Bewaard. Nook haalt de gegevens op…";
    try {
      current = (await connectorsApi.save(service.id, { ...drafts })) ?? current;
      for (const f of service.fields) if (f.secret) drafts[f.account] = "";
      replacing = false;
      note = "";
      await reload();
    } catch (e) {
      note = String(e);
    }
    busy = false;
  }

  async function paste() {
    try {
      const text = (await navigator.clipboard.readText()).trim();
      const secret = service.fields.find((f) => f.secret);
      if (!text || !secret) throw new Error();
      drafts[secret.account] = text;
      await save();
    } catch {
      note = "Er staat niets bruikbaars op je klembord.";
    }
  }

  async function setOn(on: boolean) {
    current = (await connectorsApi.toggle(service.id, on)) ?? current;
    onchange();
  }

  async function retry() {
    busy = true;
    current = (await connectorsApi.refresh(service.id)) ?? current;
    busy = false;
  }

  async function disconnect() {
    current = (await connectorsApi.disconnect(service.id)) ?? current;
    confirmDisconnect = false;
    await reload();
  }

  async function ghCli(account = "github") {
    busy = true;
    note = "";
    try {
      current = (await connectorsApi.githubCli(account)) ?? current;
      await reload();
    } catch (e) {
      note = String(e);
    }
    busy = false;
  }

  async function signIn(account = "github") {
    note = "";
    try {
      device = await connectorsApi.githubDeviceStart(account);
      await navigator.clipboard.writeText(device.userCode).catch(() => {});
    } catch (e) {
      note = String(e);
    }
  }

  async function addAccount() {
    await connectorsApi.addAccount(service.id, newAccount);
    newAccount = "";
    await reload();
  }

  async function saveAccountToken(id: string) {
    const token = accountTokens[id]?.trim();
    if (!token) return;
    busy = true;
    try {
      current = (await connectorsApi.setAccountToken(id, token)) ?? current;
      accountTokens[id] = "";
      await reload();
    } catch (e) {
      note = String(e);
    }
    busy = false;
  }

  const anyDraft = $derived(service.fields.some((f) => (drafts[f.account] ?? "").trim() && (f.secret || drafts[f.account] !== (service.values[f.account] ?? ""))));
</script>

<div class="backdrop" role="presentation" onclick={(e) => e.target === e.currentTarget && onclose()}>
  <div class="sheet" role="dialog" aria-label={service.title}>
    <header>
      <ServiceIcon domain={service.domain} title={service.title} size={44} />
      <div>
        <h3>{service.title}</h3>
        <p class="muted">{managing ? summary(current, service.tagline) : `Koppel ${service.title} in een paar eenvoudige stappen aan Nook.`}</p>
      </div>
    </header>

    <div class="body">
      {#if managing}
        <div class="line">
          <HealthPill health={h} />
          {#if h === "broken" || h === "needsYou"}<button onclick={retry} disabled={busy}>Opnieuw proberen</button>{/if}
        </div>
        <label class="toggle">
          <span><strong>Koppeling gebruiken</strong><br /><span class="faint">Wanneer ingeschakeld kan Nook deze dienst gebruiken voor context en acties.</span></span>
          <input type="checkbox" checked={current?.on ?? true} onchange={(e) => setOn(e.currentTarget.checked)} />
        </label>
        <h4>Sleutels & beveiliging</h4>
        {#if replacing || service.fields.some((f) => !f.secret)}
          {#if isGithub}{@render githubButtons("github")}{/if}
          {@render fields()}
        {:else}
          <div class="line">
            <span class="faint">🔒 Sleutel veilig bewaard in de kluis van je systeem</span>
            <button onclick={() => (replacing = true)}>Vervang sleutel</button>
          </div>
        {/if}
        {#if isGithub}{@render extraAccounts()}{/if}
      {:else}
        {#if isGithub}
          {@render githubButtons("github")}
          <button class="link" onclick={() => (showToken = !showToken)}>{showToken ? "▾" : "▸"} Liever handmatig een token invullen?</button>
        {/if}
        {#if showToken}
          <ol class="steps">
            <li class:done={current?.configured}>
              <strong>{service.signupUrl ? `Haal een sleutel op bij ${service.title}` : "Waar vind je dit?"}</strong>
              <p class="muted">{service.help}</p>
              {#if service.signupUrl}<button onclick={() => openUrl(service.signupUrl!)}>Open {service.title} ↗</button>{/if}
            </li>
            <li class:done={current?.configured}>
              <strong>{service.id === "icalfeeds" ? "Plak je ICS-adressen" : service.id === "customsources" ? "Zet je bronnen erin" : "Plak je sleutel of token"}</strong>
              {@render fields()}
            </li>
            <li class:done={current?.status.state.kind === "ok"}>
              <strong>Verbinding controleren</strong>
              {@render result()}
            </li>
          </ol>
        {:else if isGithub && current?.configured}
          {@render result()}
        {/if}
      {/if}

      {#if note}<p class="note">{note}</p>{/if}

      {#if service.capabilities}
        <button class="link" onclick={() => (showCaps = !showCaps)}>{showCaps ? "▾" : "▸"} Wat kan Nook met deze dienst?</button>
        {#if showCaps}<p class="muted">{service.capabilities}</p>{/if}
      {/if}
    </div>

    <footer>
      {#if current?.configured}
        {#if confirmDisconnect}
          <span class="faint">Weet je zeker dat je deze koppeling wilt verwijderen?</span>
          <button onclick={() => (confirmDisconnect = false)}>Annuleer</button>
          <button class="danger" onclick={disconnect}>Ontkoppel</button>
        {:else}
          <button class="danger" onclick={() => (confirmDisconnect = true)}>Ontkoppel</button>
        {/if}
      {/if}
      <span class="spacer"></span>
      <button class="primary" onclick={onclose}>{current?.status.state.kind === "ok" ? "Klaar" : "Sluit"}</button>
    </footer>
  </div>
</div>

{#snippet fields()}
  <div class="fields">
    {#each service.fields as f (f.account)}
      <label>
        {#if service.fields.length > 1}<span class="faint">{f.label}</span>{/if}
        {#if f.secret && service.id !== "customsources" && service.id !== "icalfeeds"}
          <input type="password" placeholder={service.stored.includes(f.account) ? "Bewaard in je kluis" : f.placeholder} bind:value={drafts[f.account]} />
        {:else if f.secret}
          <textarea rows="3" placeholder={service.stored.includes(f.account) ? "Bewaard in je kluis (plak opnieuw om te vervangen)" : f.placeholder} bind:value={drafts[f.account]}></textarea>
        {:else}
          <input placeholder={f.placeholder} bind:value={drafts[f.account]} />
        {/if}
      </label>
    {/each}
    <div class="line">
      {#if service.fields.some((f) => f.secret)}<button onclick={paste} disabled={busy}>Plak van klembord</button>{/if}
      <button class="primary" onclick={save} disabled={busy || !anyDraft}>Bewaar</button>
    </div>
  </div>
{/snippet}

{#snippet result()}
  {#if h === "notLinked"}
    <p class="muted">Vul eerst je gegevens in bij stap 2.</p>
  {:else if h === "busy"}
    <p class="muted">Nook controleert of de verbinding werkt…</p>
  {:else if h === "working" || h === "needsYou"}
    <p class="ok">✓ Gelukt! Nook is gekoppeld met {service.title}. {current?.status.headline ?? ""}</p>
  {:else}
    <p class="bad">⚠ {summary(current, service.tagline)}</p>
    <button onclick={retry}>Opnieuw proberen</button>
  {/if}
{/snippet}

{#snippet githubButtons(account: string)}
  <div class="github">
    {#if caps.deviceFlow}
      <button class="primary wide" onclick={() => signIn(account)}>Koppel met GitHub</button>
      <p class="faint">De snelste manier: log in met één klik via je browser.</p>
    {/if}
    {#if device}
      <div class="code">
        <code>{device.userCode}</code>
        <span class="muted">Plak deze code op GitHub. Hij staat al op je klembord.</span>
        <button onclick={() => openUrl(device!.verificationUri)}>Open GitHub opnieuw</button>
      </div>
    {/if}
    {#if caps.ghCli}
      <button class={caps.deviceFlow ? "" : "primary wide"} onclick={() => ghCli(account)} disabled={busy}>Gebruik mijn GitHub CLI-login</button>
      <p class="faint">Heb je <code>gh auth login</code> al gedaan? Dan neemt Nook die login over, zonder token te plakken.</p>
    {/if}
  </div>
{/snippet}

{#snippet extraAccounts()}
  <h4>Accounts</h4>
  {#each service.accounts as a (a.id)}
    <div class="account">
      <input
        value={a.label}
        placeholder={a.primary ? "bijv. Persoonlijk" : "Naam"}
        onchange={async (e) => { await connectorsApi.renameAccount(a.id, e.currentTarget.value); await reload(); }}
      />
      <span class="faint">{a.identity ?? (a.hasToken ? "" : "geen token")}</span>
      {#if !a.primary}
        <input type="password" placeholder={a.hasToken ? "Bewaard in je kluis" : "ghp_… / github_pat_…"} bind:value={accountTokens[a.id]} />
        <button onclick={() => saveAccountToken(a.id)} disabled={busy || !accountTokens[a.id]?.trim()}>Bewaar</button>
        {#if caps.ghCli}<button class="ghost" onclick={() => ghCli(a.id)} title="Neem de login van gh over">gh</button>{/if}
        <button class="ghost danger" onclick={async () => { await connectorsApi.removeAccount(a.id); await reload(); }}>Verwijder</button>
      {/if}
    </div>
  {/each}
  <div class="line">
    <input placeholder="Nog een account, bijv. Werk" bind:value={newAccount} />
    <button onclick={addAccount}>Account toevoegen</button>
  </div>
  <p class="faint small">Met meer accounts kies je per chat welke mogen. Nook kiest zelf het account dat bij de vraag past; bij een actie staat het account altijd in het plan, en twijfelt Nook, dan vraagt hij het.</p>
{/snippet}

<style>
  .backdrop { position: fixed; inset: 0; background: rgba(0, 0, 0, 0.55); display: grid; place-items: center; z-index: 50; padding: 16px; }
  .sheet { background: var(--graphite); border: 1px solid var(--line2); border-radius: 18px; width: min(560px, 100%); max-height: 90vh; display: flex; flex-direction: column; overflow: hidden; }
  header { display: flex; gap: 14px; align-items: center; padding: 18px 20px 8px; }
  header h3 { margin: 0; font-size: 16px; }
  header p { margin: 2px 0 0; font-size: 12px; }
  .body { padding: 8px 20px 12px; overflow-y: auto; display: flex; flex-direction: column; gap: 10px; }
  footer { display: flex; align-items: center; gap: 8px; padding: 12px 20px; border-top: 1px solid var(--line); }
  .spacer { flex: 1; }
  h4 { margin: 8px 0 0; font-size: 13px; }
  .line { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
  .line input { flex: 1; min-width: 160px; }
  .toggle { display: flex; justify-content: space-between; align-items: center; gap: 16px; }
  .steps { margin: 0; padding-left: 0; list-style: none; counter-reset: step; display: flex; flex-direction: column; gap: 14px; }
  .steps li { counter-increment: step; position: relative; padding-left: 34px; }
  .steps li::before { content: counter(step); position: absolute; left: 0; top: -1px; width: 22px; height: 22px; border-radius: 50%; background: var(--smoke); display: grid; place-items: center; font-size: 12px; font-weight: 600; }
  .steps li.done::before { content: "✓"; background: var(--mint); color: var(--ink); }
  .steps p { margin: 4px 0 8px; font-size: 12px; }
  .fields { display: flex; flex-direction: column; gap: 8px; margin-top: 6px; }
  .fields label { display: flex; flex-direction: column; gap: 3px; }
  .fields input, .fields textarea { width: 100%; }
  textarea { font-family: var(--mono); font-size: 12px; resize: vertical; }
  .ok { color: var(--mint); margin: 4px 0; }
  .bad { color: var(--coral); margin: 4px 0; }
  .note { font-size: 12px; color: var(--text2); margin: 0; }
  .link { background: none; border: none; padding: 0; color: var(--text2); text-align: left; }
  .link:hover { background: none; color: var(--paper); }
  .github { display: flex; flex-direction: column; gap: 6px; }
  .github p { margin: 0 0 4px; font-size: 12px; }
  .wide { width: 100%; padding: 9px; }
  .code { display: flex; flex-direction: column; gap: 6px; padding: 10px; border: 1px dashed var(--line2); border-radius: 10px; }
  .code code { font-size: 20px; letter-spacing: 3px; font-family: var(--mono); }
  .account { display: grid; grid-template-columns: 1fr auto; gap: 6px; align-items: center; padding: 6px 0; border-bottom: 1px solid var(--line); }
  .account > input:first-child { grid-column: 1; }
  .small { font-size: 11px; }
</style>
