<script lang="ts">
  // WhatsApp's accounts and its gateway in Settings (`WhatsAppInstallRow`, `WhatsAppAccountList`,
  // `WhatsAppAddAccountSheet` on the Mac): installing GOWA with one click, every linked account with its state, its QR
  // while it links, rename and remove, and "Another WhatsApp account" with its own numbered steps.
  import { listen } from "@tauri-apps/api/event";
  import { connectorsApi, connectorEvents, type GowaState, type GowaStep, type WhatsAppAccount } from "../../lib/connectors";
  import { tr } from "../../lib/i18n.svelte";
  import { ask } from "../../lib/confirm.svelte";
  import QRCodeView from "../../components/ui/QRCodeView.svelte";
  import Sheet from "../../components/ui/Sheet.svelte";
  import Spinner from "../../components/ui/Spinner.svelte";

  let { gateway, enabled }: { gateway: string; enabled: boolean } = $props();

  let accounts = $state<WhatsAppAccount[]>([]);
  let gowa = $state<GowaState | null>(null);
  let renaming = $state<string | null>(null);
  let newName = $state("");
  let adding = $state(false);
  let addName = $state("");
  let added = $state<string | null>(null);
  let linking = $state(false);
  let error = $state("");

  const busy = (s: GowaStep | undefined) => !!s && ["checking", "downloading", "verifying", "installing"].includes(s.step);
  const first = $derived(accounts[0]);
  const addedAccount = $derived(accounts.find((a) => a.id === added && added !== null));

  async function load() {
    try {
      [accounts, gowa] = await Promise.all([connectorsApi.whatsappAccounts(), connectorsApi.whatsappGowaState()]);
    } catch {
      // Keep current state when previewing without the backend.
    }
  }

  $effect(() => {
    load();
    const a = connectorEvents.onChanged(load);
    const b = listen<GowaStep>("whatsapp-gowa-install", (e) => gowa && (gowa = { ...gowa, step: e.payload }));
    // While an account links, its QR renews itself.
    const timer = setInterval(() => accounts.some((x) => x.link.kind !== "connected") && load(), 4000);
    return () => {
      a.then((f) => f());
      b.then((f) => f());
      clearInterval(timer);
    };
  });

  function stepLine(s: GowaStep): string {
    switch (s.step) {
      case "checking": return tr("Nieuwste versie zoeken\u2026", "Looking for the latest version\u2026");
      case "downloading": return tr("Downloaden ({n} MB)\u2026", "Downloading ({n} MB)\u2026", { n: s.megabytes });
      case "verifying": return tr("Controleren\u2026", "Checking\u2026");
      case "installing": return tr("Installeren\u2026", "Installing\u2026");
      case "done": return tr("GOWA {version} is ge\u00efnstalleerd en gestart.", "GOWA {version} is installed and running.", { version: s.version });
      case "failed": return s.message;
      default: return tr("E\u00e9n klik: Nook haalt GOWA van GitHub, controleert het bestand en start het alleen op deze computer.", "One click: Nook gets GOWA from GitHub, checks the file and runs it on this computer only.");
    }
  }

  async function install(update: boolean) {
    error = "";
    try {
      await connectorsApi.whatsappInstallGowa(update);
    } catch (e) {
      error = String(e);
    }
    await load();
  }

  async function remove(account: WhatsAppAccount) {
    const yes = await ask({
      question: tr("{name} verwijderen?", "Remove {name}?", { name: account.title || "WhatsApp" }),
      detail: tr("Nook ontkoppelt dit account bij de gateway en vergeet wat het ervan op deze computer bewaarde. Je chats blijven op je telefoon.", "Nook unlinks this account at the gateway and forgets what it kept of it on this computer. Your chats stay on your phone."),
      confirmTitle: tr("Verwijderen", "Remove"),
    });
    if (!yes) return;
    await connectorsApi.whatsappAccountRemove(account.id);
    await load();
  }

  async function saveName(account: WhatsAppAccount) {
    await connectorsApi.whatsappAccountRename(account.id, newName);
    renaming = null;
    await load();
  }

  async function add() {
    if (added !== null || linking) return;
    linking = true;
    error = "";
    try {
      added = await connectorsApi.whatsappAccountAdd(addName);
      await load();
    } catch (e) {
      error = String(e);
    } finally {
      linking = false;
    }
  }

  function closeAdd() {
    adding = false;
    added = null;
    addName = "";
  }

  const failing = (a: WhatsAppAccount) => ["unreachable", "unauthorized", "failed"].includes(a.link.kind);
</script>

{#if gowa?.available && gateway === "gowa" && (!gowa.installed || busy(gowa.step))}
  <div class="row">
    <span>{tr("WhatsApp-koppeling (GOWA)", "WhatsApp gateway (GOWA)")}<br /><span class="faint small" class:warn={gowa.step.step === "failed"}>{stepLine(gowa.step)}</span></span>
    {#if busy(gowa.step)}
      <Spinner size={14} />
    {:else}
      <button class="primary" onclick={() => install(false)}>{tr("Installeren", "Install")}</button>
    {/if}
  </div>
{/if}

{#if enabled && accounts.length}
  {#each accounts as account (account.id)}
    <div class="account">
      <div class="row">
        <span class="inline">
          <span class="dot {account.link.kind === 'connected' ? 'unread' : account.link.kind === 'needsQr' || account.link.kind === 'connecting' ? 'waiting' : 'error'}"></span>
          <span><strong>{account.title}</strong><br /><span class="faint small">{account.statusLine}</span></span>
        </span>
        <span class="inline">
          {#if failing(account)}<button class="ghost small" onclick={() => connectorsApi.whatsappAccountRetry(account.id).then(load)}>{tr("Opnieuw", "Retry")}</button>{/if}
          {#if accounts.length > 1}
            <button class="ghost small" onclick={() => { renaming = account.id; newName = account.given; }}>{tr("Hernoemen", "Rename")}</button>
          {/if}
          {#if account.id}<button class="ghost small danger" onclick={() => remove(account)}>{tr("Verwijderen", "Remove")}</button>{/if}
        </span>
      </div>
      {#if renaming === account.id}
        <div class="inline rename">
          <input bind:value={newName} placeholder={account.id ? tr("Zakelijk", "Business") : tr("Priv\u00e9", "Personal")} onkeydown={(e) => e.key === "Enter" && saveName(account)} />
          <button class="primary small" onclick={() => saveName(account)}>{tr("Bewaar", "Save")}</button>
          <button class="ghost small" onclick={() => (renaming = null)}>{tr("Annuleer", "Cancel")}</button>
        </div>
      {/if}
      {#if account.id && account.qr}
        <div class="qr">
          <QRCodeView src={account.qr} label={tr("QR-code om WhatsApp te koppelen", "QR code to connect WhatsApp")} size={160} />
          <p class="muted small">{tr("Open WhatsApp of WhatsApp Business op de telefoon van dit account \u203a Instellingen \u203a Gekoppelde apparaten \u203a Apparaat koppelen, en scan deze code.", "Open WhatsApp or WhatsApp Business on this account's phone \u203a Settings \u203a Linked devices \u203a Link a device, and scan this code.")}</p>
        </div>
      {/if}
      {#if account.portBusy && account.port}
        <p class="faint small warn">{tr("Poort {port} is bezet: Nook kijkt elke 20 seconden zelf.", "Port {port} is taken: Nook checks every 20 seconds itself.", { port: account.port })}</p>
      {/if}
    </div>
  {/each}
  {#if first?.link.kind === "connected" || accounts.length > 1}
    <div class="stepaction">
      <span>{tr("Nog een WhatsApp-account", "Another WhatsApp account")}<br /><span class="faint small">{tr("Koppel ook je zakelijke nummer of een tweede telefoon. Elk account krijgt zijn eigen QR-code.", "Link your business number or a second phone too. Each account gets its own QR code.")}</span></span>
      <button onclick={() => (adding = true)}>{tr("Account toevoegen", "Add account")}</button>
    </div>
  {/if}
{/if}

{#if gowa?.available && gateway === "gowa" && gowa.nooksOwn && !busy(gowa.step)}
  <div class="row">
    <span>{tr("GOWA bijwerken", "Update GOWA")}<br /><span class="faint small">{gowa.step.step === "done" || gowa.step.step === "failed" ? stepLine(gowa.step) : tr("Nook haalt de nieuwste GOWA van GitHub; je koppeling blijft. Een GOWA van v\u00f3\u00f3r 9.3 toont geen peilingen.", "Nook gets the newest GOWA from GitHub; your link stays. A GOWA before 9.3 shows no polls.")}</span></span>
    <button onclick={() => install(true)}>{tr("Bijwerken", "Update")}</button>
  </div>
{/if}
{#if error}<p class="faint small warn">{error}</p>{/if}

{#if adding}
  <Sheet onclose={closeAdd} label={tr("Nog een WhatsApp-account", "Another WhatsApp account")}>
    <div class="sheethead">
      <strong>{tr("Nog een WhatsApp-account", "Another WhatsApp account")}</strong>
      <span class="faint small">{tr("Koppel ook je zakelijke nummer of een tweede telefoon. Elk account krijgt zijn eigen QR-code.", "Link your business number or a second phone too. Each account gets its own QR code.")}</span>
    </div>
    <ol class="steps">
      <li class:done={added !== null}>
        <span class="num">1</span>
        <div>
          <strong>{tr("Geef het account een naam", "Name the account")}</strong>
          {#if added === null}
            <div class="inline"><input bind:value={addName} placeholder={tr("Zakelijk", "Business")} onkeydown={(e) => e.key === "Enter" && add()} /></div>
            <button class="primary small" onclick={add} disabled={linking}>{tr("Koppelen", "Link")}</button>
          {:else}
            <span class="faint small">{addedAccount?.title ?? addName}</span>
          {/if}
        </div>
      </li>
      <li class:done={addedAccount?.link.kind === "connected"}>
        <span class="num">2</span>
        <div>
          <strong>{tr("Scan de QR-code met WhatsApp op je telefoon", "Scan the QR code with WhatsApp on your phone")}</strong>
          {#if added !== null && addedAccount && addedAccount.link.kind !== "connected"}
            {#if addedAccount.qr}
              <p class="faint small">{tr("Open WhatsApp of WhatsApp Business op de telefoon van dit account \u203a Instellingen \u203a Gekoppelde apparaten \u203a Apparaat koppelen, en scan deze code.", "Open WhatsApp or WhatsApp Business on this account's phone \u203a Settings \u203a Linked devices \u203a Link a device, and scan this code.")}</p>
              <QRCodeView src={addedAccount.qr} label={tr("QR-code om WhatsApp te koppelen", "QR code to connect WhatsApp")} size={160} />
            {:else}
              <div class="inline"><Spinner size={12} /><span class="faint small">{addedAccount.statusLine}</span></div>
            {/if}
          {:else if added === null}
            <p class="faint small">{tr("Open WhatsApp of WhatsApp Business op de telefoon van dit account \u203a Instellingen \u203a Gekoppelde apparaten \u203a Apparaat koppelen, en scan deze code.", "Open WhatsApp or WhatsApp Business on this account's phone \u203a Settings \u203a Linked devices \u203a Link a device, and scan this code.")}</p>
          {/if}
        </div>
      </li>
      <li class:done={addedAccount?.link.kind === "connected"}>
        <span class="num">3</span>
        <div>
          {#if addedAccount?.link.kind === "connected"}
            <span>{tr("{name} is gekoppeld: je chats staan in de Chats-tab.", "{name} is linked: your chats show in the Chats tab.", { name: addedAccount.title })}</span>
          {:else}
            <span class="faint small">{tr("Zodra de telefoon de code heeft gescand, zegt Nook dat het account gekoppeld is.", "Once its phone has scanned the code, Nook says the account is linked.")}</span>
          {/if}
        </div>
      </li>
    </ol>
    <div class="sheetfoot"><button class="primary" onclick={closeAdd}>{tr("Klaar", "Done")}</button></div>
  </Sheet>
{/if}

<style>
  .small { font: var(--text-detail); }
  .warn { color: var(--coral); }
  .account { padding: var(--space-4) 0; border-top: 1px solid var(--line); }
  .rename { padding: var(--space-4) 0; }
  .rename input { flex: 1; }
  .qr { display: flex; gap: var(--space-12); align-items: center; padding: var(--space-8) 0; }
  .stepaction { display: flex; flex-direction: column; align-items: flex-start; gap: var(--space-6); padding: var(--space-8) 0; border-top: 1px solid var(--line); }
  .danger { color: var(--coral); }
  .sheethead { display: flex; flex-direction: column; gap: var(--space-4); padding: var(--space-16) var(--space-16) var(--space-8); }
  .steps { list-style: none; margin: 0; padding: 0 var(--space-16); display: flex; flex-direction: column; gap: var(--space-12); overflow: auto; }
  .steps li { display: flex; gap: var(--space-8); align-items: flex-start; }
  .steps li > div { display: flex; flex-direction: column; gap: var(--space-6); align-items: flex-start; flex: 1; }
  .steps input { width: 100%; }
  .num { flex: none; width: 20px; height: 20px; border-radius: 50%; display: grid; place-items: center; font: var(--text-detail); background: var(--line2); color: var(--paper); }
  .done .num { background: var(--mint); color: var(--ink); }
  .sheetfoot { display: flex; justify-content: flex-end; padding: var(--space-12) var(--space-16) var(--space-16); }
</style>
