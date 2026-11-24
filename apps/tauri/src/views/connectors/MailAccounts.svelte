<script lang="ts">
  // Mail & calendar accounts (Microsoft Outlook/365 via device-code flow, Google Gmail/Calendar via PKCE browser
  // sign-in). Matches Nook's connection row design and theme tokens; refresh tokens stay in the system keychain only.
  import { invoke } from "@tauri-apps/api/core";
  import { openUrl } from "@tauri-apps/plugin-opener";
  import { connectorEvents, inCategory, matchesQuery } from "../../lib/connectors";
  import { ask } from "../../lib/confirm.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import ServiceIcon from "./ServiceIcon.svelte";
  import HealthPill from "./HealthPill.svelte";
  import Sheet from "../../components/ui/Sheet.svelte";
  import Spinner from "../../components/ui/Spinner.svelte";

  type Provider = "microsoft" | "google";

  interface MailAccount {
    id: string;
    provider: Provider;
    address: string;
    name: string;
    calendar: boolean;
  }

  interface MailAccountsView {
    accounts: MailAccount[];
    microsoftReady: boolean;
    googleReady: boolean;
    hasCustomMicrosoft: boolean;
    hasCustomGoogle: boolean;
  }

  interface DeviceCode {
    userCode: string;
    verificationUri: string;
    interval: number;
    expiresIn: number;
  }

  let { query = "", category = null, onchange }: { query?: string; category?: string | null; onchange?: () => void } = $props();

  let view = $state<MailAccountsView>({
    accounts: [],
    microsoftReady: true,
    googleReady: true,
    hasCustomMicrosoft: false,
    hasCustomGoogle: false,
  });
  let error = $state("");
  let renaming = $state<string | null>(null);
  let renameValue = $state("");

  // Sign-in sheet state
  let sheet = $state<Provider | null>(null);
  let accountLabel = $state("");
  let device = $state<DeviceCode | null>(null);
  let busy = $state(false);
  let copied = $state(false);
  let sheetError = $state("");

  // Optional custom OAuth client IDs (when build-time app IDs are absent)
  let showCustomIds = $state(false);
  let msClientId = $state("");
  let googleClientId = $state("");
  let googleClientSecret = $state("");
  let savingIds = $state(false);

  const visible = $derived.by(() => {
    if (!inCategory(category, "work")) return false;
    const names = view.accounts.map((a) => `${a.name} ${a.address} ${a.provider}`).join(" ");
    return matchesQuery(
      query,
      `mail email e-mail outlook microsoft 365 hotmail gmail google calendar agenda ${names}`,
    );
  });

  async function load() {
    try {
      view = await invoke<MailAccountsView>("mail_accounts_list");
    } catch {
      // Backend commands may not be registered in preview mode.
    }
  }

  $effect(() => {
    load();
    const un = connectorEvents.onChanged(load);
    return () => {
      un.then((f) => f());
    };
  });

  function openSheet(provider: Provider) {
    sheet = provider;
    accountLabel = "";
    device = null;
    busy = false;
    copied = false;
    sheetError = "";
    showCustomIds = provider === "microsoft" ? !view.microsoftReady : !view.googleReady;
  }

  function closeSheet() {
    sheet = null;
    device = null;
    busy = false;
    sheetError = "";
  }

  async function saveCustomIds() {
    savingIds = true;
    sheetError = "";
    try {
      view = await invoke<MailAccountsView>("mail_save_client_config", {
        microsoftClientId: sheet === "microsoft" ? msClientId.trim() : null,
        googleClientId: sheet === "google" ? googleClientId.trim() : null,
        googleClientSecret: sheet === "google" ? googleClientSecret.trim() : null,
      });
      if ((sheet === "microsoft" && view.microsoftReady) || (sheet === "google" && view.googleReady)) {
        showCustomIds = false;
      }
    } catch (e) {
      sheetError = String(e);
    } finally {
      savingIds = false;
    }
  }

  async function startMicrosoft() {
    busy = true;
    sheetError = "";
    try {
      const code = await invoke<DeviceCode>("mail_microsoft_start");
      device = code;
      if (navigator.clipboard?.writeText) {
        navigator.clipboard.writeText(code.userCode).then(() => (copied = true)).catch(() => {});
      }
      openUrl(code.verificationUri).catch(() => {});
      await invoke<MailAccount>("mail_microsoft_finish", {
        userCode: code.userCode,
        name: accountLabel.trim() || null,
      });
      await load();
      onchange?.();
      closeSheet();
    } catch (e) {
      sheetError = String(e);
      busy = false;
    }
  }

  async function startGoogle() {
    busy = true;
    sheetError = "";
    try {
      await invoke<MailAccount>("mail_google_sign_in", {
        name: accountLabel.trim() || null,
      });
      await load();
      onchange?.();
      closeSheet();
    } catch (e) {
      sheetError = String(e);
      busy = false;
    }
  }

  async function toggleCalendar(account: MailAccount, calendar: boolean) {
    error = "";
    try {
      await invoke<MailAccount>("mail_account_set_calendar", { id: account.id, calendar });
      await load();
      onchange?.();
    } catch (e) {
      error = String(e);
    }
  }

  async function saveRename(account: MailAccount) {
    error = "";
    try {
      await invoke<MailAccount>("mail_account_rename", { id: account.id, name: renameValue.trim() });
      renaming = null;
      await load();
      onchange?.();
    } catch (e) {
      error = String(e);
    }
  }

  async function removeAccount(account: MailAccount) {
    const label = account.name || account.address;
    const confirmed = await ask({
      question: tr("{name} ontkoppelen?", "Disconnect {name}?", { name: label }),
      detail: tr(
        "Nook verwijdert dit mailaccount en wist het token uit je sleutelhanger. Je mails en agenda blijven gewoon bij {provider} staan.",
        "Nook removes this mail account and clears its token from your keychain. Your mail and calendar stay safely with {provider}.",
        { provider: account.provider === "microsoft" ? "Microsoft" : "Google" },
      ),
      confirmTitle: tr("Ontkoppelen", "Disconnect"),
    });
    if (!confirmed) return;
    error = "";
    try {
      await invoke("mail_account_remove", { id: account.id });
      await load();
      onchange?.();
    } catch (e) {
      error = String(e);
    }
  }

  function providerTitle(provider: Provider): string {
    return provider === "microsoft" ? "Microsoft" : "Google";
  }

  function providerDomain(provider: Provider): string {
    return provider === "microsoft" ? "outlook.com" : "gmail.com";
  }
</script>

{#if visible}
  <h3>{tr("Mail en agenda", "Mail & calendar")}</h3>
  <div class="group">
    {#each view.accounts as account (account.id)}
      <div class="row">
        <span class="plain">
          <ServiceIcon domain={providerDomain(account.provider)} title={providerTitle(account.provider)} />
          <span class="text">
            <span>
              {account.name || account.address}
              <span class="faint small"> · {providerTitle(account.provider)}</span>
            </span>
            <span class="faint small">
              {account.name ? `${account.address} · ` : ""}{account.calendar
                ? tr("Mail en agenda actief", "Mail & calendar active")
                : tr("Alleen mail", "Mail only")}
            </span>
          </span>
        </span>
        <HealthPill health="working" />
        <label class="cal-toggle" title={tr("Agenda lezen en afspraken maken voor dit account", "Read calendar and create events for this account")}>
          <span class="faint small">{tr("Agenda", "Calendar")}</span>
          <input
            type="checkbox"
            role="switch"
            checked={account.calendar}
            onchange={(e) => toggleCalendar(account, e.currentTarget.checked)}
          />
        </label>
        <button
          class="ghost small-btn"
          onclick={() => {
            renaming = renaming === account.id ? null : account.id;
            renameValue = account.name;
          }}
        >
          {tr("Hernoemen", "Rename")}
        </button>
        <button class="ghost small-btn danger" onclick={() => removeAccount(account)}>
          {tr("Ontkoppel", "Disconnect")}
        </button>
      </div>
      {#if renaming === account.id}
        <div class="rename-row">
          <input
            bind:value={renameValue}
            placeholder={tr("Naam, bijv. Werk of Privé", "Label, e.g. Work or Personal")}
            onkeydown={(e) => e.key === "Enter" && saveRename(account)}
          />
          <button class="primary small-btn" onclick={() => saveRename(account)}>{tr("Bewaar", "Save")}</button>
          <button class="ghost small-btn" onclick={() => (renaming = null)}>{tr("Annuleer", "Cancel")}</button>
        </div>
      {/if}
    {/each}

    <div class="row">
      <span class="plain">
        <ServiceIcon domain="outlook.com" title="Microsoft" />
        <span class="text">
          <span>{tr("Microsoft (Outlook / 365)", "Microsoft (Outlook / 365)")}</span>
          <span class="faint small">{tr("Mail lezen, zoeken, versturen en agenda via Microsoft Graph", "Read, search, send mail and sync calendar via Microsoft Graph")}</span>
        </span>
      </span>
      <button onclick={() => openSheet("microsoft")}>
        {view.accounts.some((a) => a.provider === "microsoft")
          ? tr("Account toevoegen", "Add account")
          : tr("Koppelen", "Connect")}
      </button>
    </div>

    <div class="row">
      <span class="plain">
        <ServiceIcon domain="gmail.com" title="Google" />
        <span class="text">
          <span>{tr("Google (Gmail & Agenda)", "Google (Gmail & Calendar)")}</span>
          <span class="faint small">{tr("Mail lezen, zoeken, versturen en Google Agenda koppelen", "Read, search, send mail and connect Google Calendar")}</span>
        </span>
      </span>
      <button onclick={() => openSheet("google")}>
        {view.accounts.some((a) => a.provider === "google")
          ? tr("Account toevoegen", "Add account")
          : tr("Koppelen", "Connect")}
      </button>
    </div>
  </div>
  {#if error}<p class="err">{error}</p>{/if}
  <p class="note">
    {tr(
      "Nook bewaart nooit mails op schijf. Alleen het vernieuwingstoken staat veilig in de sleutelhanger van dit apparaat.",
      "Nook never stores emails on disk. Only the refresh token is kept in this device's keychain.",
    )}
  </p>
{/if}

{#if sheet}
  <Sheet
    onclose={closeSheet}
    label={sheet === "microsoft"
      ? tr("Microsoft-account koppelen", "Connect Microsoft account")
      : tr("Google-account koppelen", "Connect Google account")}
  >
    <div class="sheet-body">
      <div class="sheet-head">
        <ServiceIcon domain={providerDomain(sheet)} title={providerTitle(sheet)} />
        <div class="text">
          <strong>
            {sheet === "microsoft"
              ? tr("Microsoft-account koppelen", "Connect Microsoft account")
              : tr("Google-account koppelen", "Connect Google account")}
          </strong>
          <span class="faint small">
            {sheet === "microsoft"
              ? tr("Log in bij Microsoft met een eenmalige code. Nook ziet je wachtwoord nooit.", "Sign in to Microsoft with a one-time code. Nook never sees your password.")
              : tr("Log in bij Google in je browser. Nook ontvangt alleen een token voor mail en agenda.", "Sign in to Google in your browser. Nook only receives a token for mail and calendar.")}
          </span>
        </div>
      </div>

      <label class="field">
        <span class="faint small">{tr("Label (optioneel)", "Label (optional)")}</span>
        <input
          bind:value={accountLabel}
          disabled={busy}
          placeholder={tr("bijv. Werk of Privé", "e.g. Work or Personal")}
        />
      </label>

      {#if sheet === "microsoft"}
        {#if device}
          <div class="code-box">
            <code class="device-code">{device.userCode}</code>
            <span class="faint small">
              {copied
                ? tr("Code gekopieerd. Vul hem in op de Microsoft-pagina die net openging.", "Code copied. Enter it on the Microsoft page that just opened.")
                : tr("Vul deze code in op de Microsoft-pagina om in te loggen.", "Enter this code on the Microsoft page to sign in.")}
            </span>
            <div class="actions">
              <button onclick={() => device && openUrl(device.verificationUri)}>
                {tr("Open Microsoft opnieuw", "Open Microsoft again")}
              </button>
              <span class="waiting">
                <Spinner size={14} />
                <span class="faint small">{tr("Wachten op bevestiging…", "Waiting for confirmation…")}</span>
              </span>
            </div>
          </div>
        {:else}
          <button class="primary wide" disabled={busy || !view.microsoftReady} onclick={startMicrosoft}>
            {#if busy}<Spinner size={14} />{/if}
            {tr("Inloggen bij Microsoft", "Sign in with Microsoft")}
          </button>
        {/if}
      {:else}
        <button class="primary wide" disabled={busy || !view.googleReady} onclick={startGoogle}>
          {#if busy}<Spinner size={14} />{/if}
          {busy
            ? tr("Wachten op Google-login in je browser…", "Waiting for Google sign-in in your browser…")
            : tr("Inloggen bij Google", "Sign in with Google")}
        </button>
      {/if}

      <div class="custom-toggle">
        <button class="ghost small-btn" onclick={() => (showCustomIds = !showCustomIds)}>
          {showCustomIds
            ? tr("Verberg eigen OAuth-app", "Hide custom OAuth app")
            : tr("Eigen OAuth client-id gebruiken", "Use custom OAuth client ID")}
        </button>
      </div>

      {#if showCustomIds}
        <div class="custom-box">
          {#if sheet === "microsoft"}
            <label class="field">
              <span class="faint small">{tr("Microsoft Application (client) ID", "Microsoft Application (client) ID")}</span>
              <input
                bind:value={msClientId}
                placeholder={view.hasCustomMicrosoft ? tr("Bewaard in je kluis", "Stored in your keychain") : "00000000-0000-0000-0000-000000000000"}
              />
            </label>
          {:else}
            <label class="field">
              <span class="faint small">{tr("Google OAuth Client ID", "Google OAuth Client ID")}</span>
              <input
                bind:value={googleClientId}
                placeholder={view.hasCustomGoogle ? tr("Bewaard in je kluis", "Stored in your keychain") : "123456.apps.googleusercontent.com"}
              />
            </label>
            <label class="field">
              <span class="faint small">{tr("Google Client Secret (optioneel)", "Google Client Secret (optional)")}</span>
              <input
                type="password"
                bind:value={googleClientSecret}
                placeholder={tr("Alleen nodig voor desktop-apps met secret", "Only needed for desktop apps with a secret")}
              />
            </label>
          {/if}
          <div class="actions">
            <button disabled={savingIds} onclick={saveCustomIds}>{tr("Client-id bewaren", "Save client ID")}</button>
          </div>
        </div>
      {/if}

      {#if sheetError}<p class="err">{sheetError}</p>{/if}

      <div class="sheet-foot">
        <button class="ghost" onclick={closeSheet}>{tr("Sluiten", "Close")}</button>
      </div>
    </div>
  </Sheet>
{/if}

<style>
  .plain { display: flex; gap: var(--space-12); align-items: center; flex: 1; min-width: 0; }
  .text { display: flex; flex-direction: column; gap: var(--space-2); min-width: 0; }
  .text span:last-child { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .small { font: var(--text-detail); line-height: 1.3; }
  .small-btn { font: var(--text-label); padding: var(--space-4) var(--space-8); }
  .cal-toggle { display: inline-flex; align-items: center; gap: var(--space-6); cursor: pointer; }
  .rename-row { display: flex; gap: var(--space-8); align-items: center; padding: var(--space-8) var(--row-pad-x); border-top: 1px solid var(--separator); }
  .rename-row input { flex: 1; }
  .err { color: var(--coral); font: var(--text-detail); margin: var(--space-8) 0 0; }
  .sheet-body { padding: var(--space-16); display: flex; flex-direction: column; gap: var(--space-12); }
  .sheet-head { display: flex; gap: var(--space-12); align-items: center; }
  .sheet-head strong { font: var(--text-emphasis); color: var(--paper); }
  .field { display: flex; flex-direction: column; gap: var(--space-4); }
  .wide { width: 100%; display: inline-flex; justify-content: center; align-items: center; gap: var(--space-8); }
  .code-box { display: flex; flex-direction: column; gap: var(--space-8); padding: var(--space-12); border: 1px solid var(--line2); border-radius: var(--radius-card); background: var(--field); align-items: flex-start; }
  .device-code { font: var(--text-code); letter-spacing: 0.08em; color: var(--paper); user-select: text; }
  .actions { display: flex; align-items: center; gap: var(--space-12); flex-wrap: wrap; }
  .waiting { display: inline-flex; align-items: center; gap: var(--space-6); }
  .custom-toggle { display: flex; justify-content: flex-start; }
  .custom-box { display: flex; flex-direction: column; gap: var(--space-8); padding: var(--space-12); border: 1px solid var(--line); border-radius: var(--radius-card); background: var(--field); }
  .sheet-foot { display: flex; justify-content: flex-end; border-top: 1px solid var(--separator); padding-top: var(--space-12); }
</style>
