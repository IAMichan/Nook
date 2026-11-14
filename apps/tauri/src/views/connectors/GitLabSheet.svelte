<script lang="ts">
  // GitLab in dezelfde vorm als elke andere dienst. Nog niet gekoppeld: drie stappen (token maken, plakken, Nook
  // controleert het bij GitLab). Gekoppeld (`managing` een host): hoe het gaat, de sleutel vervangen en ontkoppelen.
  // Een token dat GitLab weigert wordt nooit bewaard; een token dat Nook nog niet kan controleren wel.
  import { openUrl } from "@tauri-apps/plugin-opener";
  import { untrack } from "svelte";
  import { connectorsApi, gitlabDetail, gitlabHealth, type GitLabCheck } from "../../lib/connectors";
  import { tr } from "../../lib/i18n.svelte";
  import ServiceIcon from "./ServiceIcon.svelte";
  import HealthPill from "./HealthPill.svelte";

  let { managing = null, onclose, onchange }: { managing?: string | null; onclose: () => void; onchange: () => void } = $props();

  const host0 = untrack(() => managing);
  let host = $state(host0 ?? "gitlab.com");
  let showSelfHosted = $state(false);
  let token = $state("");
  let note = $state("");
  let checking = $state(false);
  let check = $state<GitLabCheck | null>(null);
  let saved = $state(false);
  let replacing = $state(false);
  let confirmDisconnect = $state(false);

  const health = $derived(checking ? "busy" : gitlabHealth(check));
  const tokenPage = $derived(`https://${normalized(host)}/-/user_settings/personal_access_tokens`);

  function normalized(raw: string): string {
    const text = raw.trim().toLowerCase().replace(/^https?:\/\//, "").split("/")[0];
    return /^[\p{L}\p{N}.:-]+$/u.test(text) && (text.includes(".") || text.startsWith("localhost")) ? text : "gitlab.com";
  }

  $effect(() => {
    if (host0) untrack(() => verify());
  });

  async function verify() {
    if (!host0) return;
    checking = true;
    try {
      check = await connectorsApi.gitlabCheck(host0);
    } catch {
      check = { kind: "unreachable" };
    }
    checking = false;
  }

  async function save() {
    if (!token.trim()) return;
    note = "";
    checking = true;
    try {
      const result = await connectorsApi.gitlabSave(host0 ?? host, token);
      check = result.check;
      token = "";
      saved = true;
      replacing = false;
      onchange();
    } catch (e) {
      check = String(e).includes("weigert") ? { kind: "rejected" } : check;
      note = String(e);
    }
    checking = false;
  }

  async function paste() {
    try {
      const text = (await navigator.clipboard.readText()).trim();
      if (!text) throw new Error();
      token = text;
      await save();
    } catch {
      note = tr("Er staat niets bruikbaars op je klembord.", "There's nothing usable on your clipboard.");
    }
  }

  async function disconnect() {
    if (host0) await connectorsApi.gitlabRemove(host0);
    onchange();
    onclose();
  }
</script>

<div class="backdrop" role="presentation" onclick={(e) => e.target === e.currentTarget && onclose()}>
  <div class="sheet" role="dialog" aria-label="GitLab">
    <header>
      <ServiceIcon domain="gitlab.com" title="GitLab" size={44} />
      <div>
        <h3>GitLab</h3>
        <p class="muted">{host0 ? gitlabDetail(host0, checking ? null : check) : tr("Koppel {name} in een paar eenvoudige stappen aan Nook.", "Connect {name} to Nook in a few simple steps.", { name: "GitLab" })}</p>
      </div>
    </header>

    <div class="body">
      {#if host0}
        <div class="line">
          <HealthPill {health} />
          {#if check?.kind === "unreachable" && !checking}<button onclick={verify}>{tr("Opnieuw proberen", "Try again")}</button>{/if}
        </div>
        <h4>{tr("Sleutels & beveiliging", "Keys & security")}</h4>
        {#if replacing || check?.kind === "rejected"}
          {@render tokenField()}
        {:else}
          <div class="line">
            <span class="faint">🔒 {tr("Sleutel veilig bewaard in de kluis van je systeem", "Key stored safely in your system's keychain")}</span>
            <button onclick={() => (replacing = true)}>{tr("Vervang sleutel", "Replace key")}</button>
          </div>
        {/if}
      {:else}
        <ol class="steps">
          <li class:done={saved}>
            <strong>{tr("Maak een toegangstoken", "Create an access token")}</strong>
            <p class="muted">{tr("Maak op de tokenpagina van GitLab een persoonlijk toegangstoken met scope api.", "On GitLab's token page, create a personal access token with the api scope.")}</p>
            <button class="link" onclick={() => (showSelfHosted = !showSelfHosted)}>{showSelfHosted ? "▾" : "▸"} {tr("Eigen GitLab-server", "Self-hosted GitLab server")}</button>
            {#if showSelfHosted}
              <div class="selfhosted">
                <input placeholder={tr("Host (bijv. gitlab.com)", "Host (e.g. gitlab.com)")} bind:value={host} />
                <span class="faint small">{tr("Gebruik je GitLab op je eigen server? Vul het adres in voordat je de tokenpagina opent.", "Using GitLab on your own server? Fill in the address before you open the token page.")}</span>
              </div>
            {/if}
            <button onclick={() => openUrl(tokenPage)}>{tr("Open tokenpagina", "Open token page")} ↗</button>
          </li>
          <li class:done={saved}>
            <strong>{tr("Plak het token", "Paste the token")}</strong>
            {@render tokenField()}
          </li>
          <li class:done={check?.kind === "valid"}>
            <strong>{tr("Verbinding controleren", "Check the connection")}</strong>
            {@render result()}
          </li>
        </ol>
      {/if}
      {#if note}<p class="bad small">{note}</p>{/if}
    </div>

    <footer>
      {#if host0}
        {#if confirmDisconnect}
          <span class="faint">{tr("Weet je zeker dat je deze koppeling wilt verwijderen?", "Are you sure you want to remove this connection?")}</span>
          <button onclick={() => (confirmDisconnect = false)}>{tr("Annuleer", "Cancel")}</button>
          <button class="danger" onclick={disconnect}>{tr("Ontkoppel", "Disconnect")}</button>
        {:else}
          <button class="danger" onclick={() => (confirmDisconnect = true)}>{tr("Ontkoppel", "Disconnect")}</button>
        {/if}
      {/if}
      <span class="spacer"></span>
      <button class="primary" onclick={onclose}>{saved || host0 ? tr("Klaar", "Done") : tr("Sluit", "Close")}</button>
    </footer>
  </div>
</div>

{#snippet tokenField()}
  <div class="fields">
    <input type="password" placeholder="glpat-…" bind:value={token} onkeydown={(e) => e.key === "Enter" && save()} />
    <div class="line">
      <button onclick={paste} disabled={checking}>{tr("Plak van klembord", "Paste from clipboard")}</button>
      <button class="primary" onclick={save} disabled={checking || !token.trim()}>{tr("Bewaar", "Save")}</button>
    </div>
  </div>
{/snippet}

{#snippet result()}
  {#if checking}
    <p class="muted">{tr("Nook controleert of de verbinding werkt…", "Nook is checking whether the connection works…")}</p>
  {:else if check?.kind === "valid"}
    <p class="ok">✓ {tr("Gekoppeld als @{user} op {host}. Nook kan er nu merge requests voor je zoeken.", "Connected as @{user} on {host}. Nook can now find merge requests there for you.", { user: check.username, host: normalized(host) })}</p>
  {:else if check?.kind === "rejected"}
    <p class="warn">⚠ {tr("GitLab weigert dit token. Controleer of het scope api heeft en niet verlopen is.", "GitLab rejects this token. Check that it has the api scope and hasn't expired.")}</p>
  {:else if check?.kind === "unreachable"}
    <p class="bad">⚠ {tr("Nook kon {host} niet bereiken. Het token is bewaard; Nook probeert het opnieuw zodra het nodig is.", "Nook couldn't reach {host}. The token is saved; Nook tries again as soon as it's needed.", { host: normalized(host) })}</p>
  {:else}
    <p class="muted">{tr("Vul eerst je token in bij stap 2.", "Fill in your token in step 2 first.")}</p>
  {/if}
{/snippet}

<style>
  .backdrop { position: fixed; inset: 0; background: rgba(0, 0, 0, 0.55); display: grid; place-items: center; z-index: 50; padding: 16px; }
  .sheet { background: var(--graphite); border: 1px solid var(--line2); border-radius: 18px; width: min(560px, 100%); max-height: 90vh; display: flex; flex-direction: column; overflow: hidden; }
  header { display: flex; gap: 14px; align-items: center; padding: 18px 20px 8px; }
  header h3 { margin: 0; font-size: 16px; }
  header p { margin: 2px 0 0; font-size: 12px; }
  .body { padding: 8px 20px 12px; overflow-y: auto; display: flex; flex-direction: column; gap: 10px; }
  footer { display: flex; align-items: center; gap: 8px; padding: 12px 20px; border-top: 1px solid var(--line); flex-wrap: wrap; }
  .spacer { flex: 1; }
  h4 { margin: 8px 0 0; font-size: 13px; }
  .line { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
  .steps { margin: 0; padding-left: 0; list-style: none; counter-reset: step; display: flex; flex-direction: column; gap: 14px; }
  .steps li { counter-increment: step; position: relative; padding-left: 34px; display: flex; flex-direction: column; align-items: flex-start; gap: 6px; }
  .steps li::before { content: counter(step); position: absolute; left: 0; top: -1px; width: 22px; height: 22px; border-radius: 50%; background: var(--smoke); display: grid; place-items: center; font-size: 12px; font-weight: 600; }
  .steps li.done::before { content: "✓"; background: var(--mint); color: var(--ink); }
  .steps p { margin: 0; font-size: 12px; }
  .selfhosted { display: flex; flex-direction: column; gap: 4px; width: 100%; }
  .selfhosted input { max-width: 260px; }
  .fields { display: flex; flex-direction: column; gap: 8px; width: 100%; }
  .fields input { width: 100%; }
  .ok { color: var(--mint); margin: 0; }
  .warn { color: var(--amber); margin: 0; }
  .bad { color: var(--coral); margin: 0; }
  .small { font-size: 11px; }
  .link { background: none; border: none; padding: 0; color: var(--text2); text-align: left; }
  .link:hover { background: none; color: var(--paper); }
</style>
