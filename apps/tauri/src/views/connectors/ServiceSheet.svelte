<script lang="ts">
  // Everything about one service in one sheet (`SetupSheet`). Not linked: three numbered steps (get key, paste key,
  // check the connection). Linked: status pill beside the title, In Nook toggle, Keys & security, extra accounts,
  // capabilities, and disconnect.
  import { openUrl } from "@tauri-apps/plugin-opener";
  import { untrack } from "svelte";
  import {
    connectorsApi, connectorEvents, health, summary,
    type Caps, type ConnectorInfo, type DeviceCode, type ServiceView,
  } from "../../lib/connectors";
  import { tr } from "../../lib/i18n.svelte";
  import SetupCheckStep from "../../components/ui/SetupCheckStep.svelte";
  import SetupSheet from "../../components/ui/SetupSheet.svelte";
  import SetupStep from "../../components/ui/SetupStep.svelte";
  import SheetPart from "../../components/ui/SheetPart.svelte";
  import StepAction from "../../components/ui/StepAction.svelte";
  import { setupCheckFromHealth, type SetupCheckState } from "../../components/ui/setup-check";
  import ServiceIcon from "./ServiceIcon.svelte";

  let { service: initial, info, caps, onclose, onchange }: {
    service: ServiceView;
    info: ConnectorInfo | undefined;
    caps: Caps;
    onclose: () => void;
    onchange: () => void;
  } = $props();

  const start = untrack(() => ({ service: initial, info }));
  let service = $state(start.service);
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

  const checkState = $derived<SetupCheckState>(
    setupCheckFromHealth(h, {
      passed: `${tr("Gelukt! Nook is gekoppeld met {name}.", "Done! Nook is connected to {name}.", { name: service.title })}${current?.status.headline ? ` ${current.status.headline}` : ""}`,
      failed: summary(current, service.tagline),
    }),
  );

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
    note = tr("Bewaard. Nook haalt de gegevens op…", "Saved. Nook is fetching the data…");
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
      note = tr("Er staat niets bruikbaars op je klembord.", "There's nothing usable on your clipboard.");
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

<SetupSheet
  title={service.title}
  subtitle={managing
    ? summary(current, service.tagline)
    : tr("Koppel {name} in een paar eenvoudige stappen aan Nook.", "Connect {name} to Nook in a few simple steps.", { name: service.title })}
  status={managing ? h : undefined}
  {onclose}
>
  {#snippet icon()}
    <ServiceIcon domain={service.domain} title={service.title} size={44} />
  {/snippet}

  {#if managing}
    {#if h === "broken" || h === "needsYou"}
      <div class="line">
        <button type="button" onclick={retry} disabled={busy}>{tr("Opnieuw proberen", "Try again")}</button>
      </div>
    {/if}

    <SheetPart title={tr("Koppeling gebruiken", "Use connection")}>
      <label class="toggle">
        <span class="toggle-copy">
          <span class="faint">{tr("Wanneer ingeschakeld kan Nook deze dienst gebruiken voor context en acties.", "When on, Nook can use this service for context and actions.")}</span>
        </span>
        <input type="checkbox" role="switch" checked={current?.on ?? true} onchange={(e) => setOn(e.currentTarget.checked)} />
      </label>
    </SheetPart>

    <SheetPart title={tr("Sleutels & beveiliging", "Keys & security")}>
      {#if replacing && isGithub}
        {@render githubButtons("github")}
        <button type="button" class="link" onclick={() => (showToken = !showToken)}>
          {showToken ? "▾" : "▸"} {tr("Liever handmatig een token invullen?", "Rather enter a token by hand?")}
        </button>
        {#if showToken}{@render fields()}{/if}
      {:else if replacing || service.fields.some((f) => !f.secret)}
        {@render fields()}
      {:else}
        <div class="line">
          <span class="faint">{tr("Sleutel veilig bewaard in de kluis van je systeem", "Key stored safely in your system's keychain")}</span>
          <button type="button" onclick={() => (replacing = true)}>{tr("Vervang sleutel", "Replace key")}</button>
        </div>
      {/if}
    </SheetPart>

    {#if isGithub}
      <SheetPart title={tr("Accounts", "Accounts")}>
        {@render extraAccounts()}
      </SheetPart>
    {/if}
  {:else}
    {#if isGithub}
      <SetupStep number={1} title={tr("Koppel met GitHub", "Connect with GitHub")} done={!!current?.configured}>
        {@render githubButtons("github")}
        <button type="button" class="link" onclick={() => (showToken = !showToken)}>
          {showToken ? "▾" : "▸"} {tr("Liever handmatig een token invullen?", "Rather enter a token by hand?")}
        </button>
      </SetupStep>
    {/if}

    {#if showToken}
      <SetupStep
        number={isGithub ? 2 : 1}
        title={service.signupUrl ? tr("Haal een sleutel op bij {name}", "Get a key from {name}", { name: service.title }) : tr("Waar vind je dit?", "Where do you find this?")}
        done={!!current?.configured}
      >
        {#if service.signupUrl}
          <StepAction
            detail={service.help}
            button={`${tr("Open {name}", "Open {name}", { name: service.title })} ↗`}
            prominent={false}
            onclick={() => openUrl(service.signupUrl!)}
          />
        {:else}
          <p class="step-note">{service.help}</p>
        {/if}
      </SetupStep>

      <SetupStep
        number={isGithub ? 3 : 2}
        title={service.id === "icalfeeds"
          ? tr("Plak je ICS-adressen", "Paste your ICS addresses")
          : service.id === "customsources"
            ? tr("Zet je bronnen erin", "Add your sources")
            : tr("Plak je sleutel of token", "Paste your key or token")}
        done={!!current?.configured}
      >
        {@render fields()}
      </SetupStep>

      <SetupCheckStep
        number={isGithub ? 4 : 3}
        detail={tr("Vul eerst je gegevens in bij stap 2.", "Fill in your details in step 2 first.")}
        checkingLabel={tr("Nook controleert of de verbinding werkt…", "Nook is checking whether the connection works…")}
        state={checkState}
        oncheck={current?.configured ? retry : undefined}
        disabled={busy}
      />
    {:else if isGithub}
      <SetupCheckStep
        number={2}
        detail={tr("Log eerst in bij stap 1.", "Sign in in step 1 first.")}
        checkingLabel={tr("Nook controleert of de verbinding werkt…", "Nook is checking whether the connection works…")}
        state={checkState}
        oncheck={current?.configured ? retry : undefined}
        disabled={busy}
      />
    {/if}
  {/if}

  {#if note}<p class="note">{note}</p>{/if}

  {#if service.capabilities}
    <button type="button" class="link" onclick={() => (showCaps = !showCaps)}>
      {showCaps ? "▾" : "▸"} {tr("Wat kan Nook met deze dienst?", "What can Nook do with this service?")}
    </button>
    {#if showCaps}<p class="step-note">{service.capabilities}</p>{/if}
  {/if}

  {#snippet footer()}
    {#if current?.configured}
      {#if confirmDisconnect}
        <span class="faint">{tr("Weet je zeker dat je deze koppeling wilt verwijderen?", "Are you sure you want to remove this connection?")}</span>
        <button type="button" onclick={() => (confirmDisconnect = false)}>{tr("Annuleer", "Cancel")}</button>
        <button type="button" class="danger" onclick={disconnect}>{tr("Ontkoppel", "Disconnect")}</button>
      {:else}
        <button type="button" class="danger" onclick={() => (confirmDisconnect = true)}>{tr("Ontkoppel", "Disconnect")}</button>
      {/if}
    {/if}
    <span class="spacer"></span>
    <button type="button" class="primary" onclick={onclose}>{current?.status.state.kind === "ok" ? tr("Klaar", "Done") : tr("Sluit", "Close")}</button>
  {/snippet}
</SetupSheet>

{#snippet fields()}
  <div class="fields">
    {#each service.fields as f (f.account)}
      <label>
        {#if service.fields.length > 1}<span class="faint">{f.label}</span>{/if}
        {#if f.secret && service.id !== "customsources" && service.id !== "icalfeeds"}
          <input type="password" placeholder={service.stored.includes(f.account) ? tr("Bewaard in je kluis", "Stored in your keychain") : f.placeholder} bind:value={drafts[f.account]} />
        {:else if f.secret}
          <textarea rows="3" placeholder={service.stored.includes(f.account) ? tr("Bewaard in je kluis (plak opnieuw om te vervangen)", "Stored in your keychain (paste again to replace)") : f.placeholder} bind:value={drafts[f.account]}></textarea>
        {:else}
          <input placeholder={f.placeholder} bind:value={drafts[f.account]} />
        {/if}
      </label>
    {/each}
    <div class="line">
      {#if service.fields.some((f) => f.secret)}<button type="button" onclick={paste} disabled={busy}>{tr("Plak van klembord", "Paste from clipboard")}</button>{/if}
      <button type="button" class="primary" onclick={save} disabled={busy || !anyDraft}>{tr("Bewaar", "Save")}</button>
    </div>
  </div>
{/snippet}

{#snippet githubButtons(account: string)}
  <div class="github">
    {#if caps.deviceFlow}
      <button type="button" class="primary wide" onclick={() => signIn(account)}>{tr("Koppel met GitHub", "Connect with GitHub")}</button>
      <p class="faint step-note">{tr("De snelste manier: log in met één klik via je browser.", "The fastest way: sign in with one click in your browser.")}</p>
    {/if}
    {#if device}
      <div class="code">
        <code>{device.userCode}</code>
        <span class="step-note">{tr("Plak deze code op GitHub. Hij staat al op je klembord.", "Paste this code on GitHub. It's already on your clipboard.")}</span>
        <button type="button" onclick={() => openUrl(device!.verificationUri)}>{tr("Open GitHub opnieuw", "Open GitHub again")}</button>
      </div>
    {/if}
    {#if caps.ghCli}
      <button type="button" class={caps.deviceFlow ? "" : "primary wide"} onclick={() => ghCli(account)} disabled={busy}>{tr("Gebruik mijn GitHub CLI-login", "Use my GitHub CLI sign-in")}</button>
      <p class="faint step-note">{tr("Heb je {cmd} al gedaan? Dan neemt Nook die login over, zonder token te plakken.", "Already ran {cmd}? Then Nook takes over that sign-in, no token to paste.", { cmd: "gh auth login" })}</p>
    {/if}
  </div>
{/snippet}

{#snippet extraAccounts()}
  {#each service.accounts as a (a.id)}
    <div class="account">
      <input
        value={a.label}
        placeholder={a.primary ? tr("bijv. Persoonlijk", "e.g. Personal") : tr("Naam", "Name")}
        onchange={async (e) => { await connectorsApi.renameAccount(a.id, e.currentTarget.value); await reload(); }}
      />
      <span class="faint">{a.identity ?? (a.hasToken ? "" : tr("geen token", "no token"))}</span>
      {#if !a.primary}
        <input type="password" placeholder={a.hasToken ? tr("Bewaard in je kluis", "Stored in your keychain") : "ghp_… / github_pat_…"} bind:value={accountTokens[a.id]} />
        <button type="button" onclick={() => saveAccountToken(a.id)} disabled={busy || !accountTokens[a.id]?.trim()}>{tr("Bewaar", "Save")}</button>
        {#if caps.ghCli}<button type="button" class="ghost" onclick={() => ghCli(a.id)} title={tr("Neem de login van gh over", "Take over the gh sign-in")}>gh</button>{/if}
        <button type="button" class="ghost danger" onclick={async () => { await connectorsApi.removeAccount(a.id); await reload(); }}>{tr("Verwijder", "Remove")}</button>
      {/if}
    </div>
  {/each}
  <div class="line">
    <input placeholder={tr("Nog een account, bijv. Werk", "Another account, e.g. Work")} bind:value={newAccount} />
    <button type="button" onclick={addAccount}>{tr("Account toevoegen", "Add account")}</button>
  </div>
  <p class="faint small">{tr("Met meer accounts kies je per chat welke mogen. Nook kiest zelf het account dat bij de vraag past; bij een actie staat het account altijd in het plan, en twijfelt Nook, dan vraagt hij het.", "With more accounts you choose per chat which ones are allowed. Nook picks the account that fits the question; for an action the account is always in the plan, and when Nook isn't sure, it asks.")}</p>
{/snippet}

<style>
  .spacer { flex: 1; }
  .line { display: flex; gap: var(--space-8); align-items: center; flex-wrap: wrap; }
  .line input { flex: 1; min-width: 160px; }
  .toggle { display: flex; justify-content: space-between; align-items: center; gap: var(--space-16); }
  .toggle-copy { flex: 1; min-width: 0; }
  .step-note { margin: 0; font: var(--text-detail); line-height: 1.4; color: var(--text2); }
  .fields { display: flex; flex-direction: column; gap: var(--space-8); width: 100%; }
  .fields label { display: flex; flex-direction: column; gap: var(--space-4); }
  .fields input, .fields textarea { width: 100%; }
  textarea { font: var(--text-code); resize: vertical; }
  .note { font: var(--text-detail); color: var(--text2); margin: 0; }
  .link { background: none; border: none; padding: 0; color: var(--text2); text-align: left; }
  .link:hover { background: none; color: var(--paper); }
  .github { display: flex; flex-direction: column; gap: var(--space-6); width: 100%; }
  .wide { width: 100%; padding: var(--space-8); }
  .code { display: flex; flex-direction: column; gap: var(--space-6); padding: var(--space-12); border: 1px dashed var(--line2); border-radius: var(--radius-card); }
  .code code { font: var(--text-heading); font-family: var(--mono); letter-spacing: 3px; }
  .account { display: grid; grid-template-columns: 1fr auto; gap: var(--space-6); align-items: center; padding: var(--space-6) 0; border-bottom: 1px solid var(--line); }
  .account > input:first-child { grid-column: 1; }
  .small { font: var(--text-meta); margin: 0; }
</style>
