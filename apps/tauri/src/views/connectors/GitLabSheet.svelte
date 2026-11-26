<script lang="ts">
  // GitLab in the shared SetupSheet layout. Not yet linked: three numbered steps (create token, paste token,
  // check the connection). Linked (`managing` a host): status pill beside the title, replace key, disconnect.
  import { openUrl } from "@tauri-apps/plugin-opener";
  import { untrack } from "svelte";
  import { connectorsApi, gitlabDetail, gitlabHealth, type GitLabCheck } from "../../lib/connectors";
  import { tr } from "../../lib/i18n.svelte";
  import SetupCheckStep from "../../components/ui/SetupCheckStep.svelte";
  import SetupSheet from "../../components/ui/SetupSheet.svelte";
  import SetupStep from "../../components/ui/SetupStep.svelte";
  import SheetPart from "../../components/ui/SheetPart.svelte";
  import { setupCheck, type SetupCheckState } from "../../components/ui/setup-check";
  import ServiceIcon from "./ServiceIcon.svelte";

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

  const checkState = $derived<SetupCheckState>(
    checking
      ? setupCheck.checking()
      : check?.kind === "valid"
        ? setupCheck.passed(
            tr(
              "Gekoppeld als @{user} op {host}. Nook kan er nu merge requests voor je zoeken.",
              "Connected as @{user} on {host}. Nook can now find merge requests there for you.",
              { user: check.username, host: normalized(host) },
            ),
          )
        : check?.kind === "rejected"
          ? setupCheck.failed(
              tr(
                "GitLab weigert dit token. Controleer of het scope api heeft en niet verlopen is.",
                "GitLab rejects this token. Check that it has the api scope and hasn't expired.",
              ),
            )
          : check?.kind === "unreachable"
            ? setupCheck.failed(
                tr(
                  "Nook kon {host} niet bereiken. Het token is bewaard; Nook probeert het opnieuw zodra het nodig is.",
                  "Nook couldn't reach {host}. The token is saved; Nook tries again as soon as it's needed.",
                  { host: normalized(host) },
                ),
              )
            : setupCheck.idle(),
  );

  function normalized(raw: string): string {
    const text = raw.trim().toLowerCase().replace(/^https?:\/\//, "").split("/")[0];
    return /^[\p{L}\p{N}.:-]+$/u.test(text) && (text.includes(".") || text.startsWith("localhost")) ? text : "gitlab.com";
  }

  $effect(() => {
    if (host0) untrack(() => verify(host0));
  });

  async function verify(target = host0 ?? normalized(host)) {
    checking = true;
    try {
      check = await connectorsApi.gitlabCheck(target);
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

<SetupSheet
  title="GitLab"
  subtitle={host0
    ? gitlabDetail(host0, checking ? null : check)
    : tr("Koppel {name} in een paar eenvoudige stappen aan Nook.", "Connect {name} to Nook in a few simple steps.", { name: "GitLab" })}
  status={host0 ? health : undefined}
  {onclose}
>
  {#snippet icon()}
    <ServiceIcon domain="gitlab.com" title="GitLab" size={44} />
  {/snippet}

  {#if host0}
    {#if check?.kind === "unreachable" && !checking}
      <div class="line">
        <button type="button" onclick={() => verify(host0)}>{tr("Opnieuw proberen", "Try again")}</button>
      </div>
    {/if}
    <SheetPart title={tr("Sleutels & beveiliging", "Keys & security")}>
      {#if replacing || check?.kind === "rejected"}
        {@render tokenField()}
      {:else}
        <div class="line">
          <span class="faint">{tr("Sleutel veilig bewaard in de kluis van je systeem", "Key stored safely in your system's keychain")}</span>
          <button type="button" onclick={() => (replacing = true)}>{tr("Vervang sleutel", "Replace key")}</button>
        </div>
      {/if}
    </SheetPart>
  {:else}
    <SetupStep number={1} title={tr("Maak een toegangstoken", "Create an access token")} done={saved}>
      <p class="step-note">
        {tr(
          "Maak op de tokenpagina van GitLab een persoonlijk toegangstoken met scope api.",
          "On GitLab's token page, create a personal access token with the api scope.",
        )}
      </p>
      <button type="button" class="link" onclick={() => (showSelfHosted = !showSelfHosted)}>
        {showSelfHosted ? "▾" : "▸"} {tr("Eigen GitLab-server", "Self-hosted GitLab server")}
      </button>
      {#if showSelfHosted}
        <div class="selfhosted">
          <input placeholder={tr("Host (bijv. gitlab.com)", "Host (e.g. gitlab.com)")} bind:value={host} />
          <span class="faint small">
            {tr(
              "Gebruik je GitLab op je eigen server? Vul het adres in voordat je de tokenpagina opent.",
              "Using GitLab on your own server? Fill in the address before you open the token page.",
            )}
          </span>
        </div>
      {/if}
      <button type="button" onclick={() => openUrl(tokenPage)}>{tr("Open tokenpagina", "Open token page")} ↗</button>
    </SetupStep>

    <SetupStep number={2} title={tr("Plak het token", "Paste the token")} done={saved}>
      {@render tokenField()}
    </SetupStep>

    <SetupCheckStep
      number={3}
      detail={tr("Vul eerst je token in bij stap 2.", "Fill in your token in step 2 first.")}
      checkingLabel={tr("Nook controleert of de verbinding werkt…", "Nook is checking whether the connection works…")}
      state={checkState}
      oncheck={saved ? () => verify(normalized(host)) : undefined}
      disabled={checking}
    />
  {/if}

  {#if note}<p class="bad small">{note}</p>{/if}

  {#snippet footer()}
    {#if host0}
      {#if confirmDisconnect}
        <span class="faint">{tr("Weet je zeker dat je deze koppeling wilt verwijderen?", "Are you sure you want to remove this connection?")}</span>
        <button type="button" onclick={() => (confirmDisconnect = false)}>{tr("Annuleer", "Cancel")}</button>
        <button type="button" class="danger" onclick={disconnect}>{tr("Ontkoppel", "Disconnect")}</button>
      {:else}
        <button type="button" class="danger" onclick={() => (confirmDisconnect = true)}>{tr("Ontkoppel", "Disconnect")}</button>
      {/if}
    {/if}
    <span class="spacer"></span>
    <button type="button" class="primary" onclick={onclose}>{saved || host0 ? tr("Klaar", "Done") : tr("Sluit", "Close")}</button>
  {/snippet}
</SetupSheet>

{#snippet tokenField()}
  <div class="fields">
    <input type="password" placeholder="glpat-…" bind:value={token} onkeydown={(e) => e.key === "Enter" && save()} />
    <div class="line">
      <button type="button" onclick={paste} disabled={checking}>{tr("Plak van klembord", "Paste from clipboard")}</button>
      <button type="button" class="primary" onclick={save} disabled={checking || !token.trim()}>{tr("Bewaar", "Save")}</button>
    </div>
  </div>
{/snippet}

<style>
  .spacer { flex: 1; }
  .line { display: flex; gap: var(--space-8); align-items: center; flex-wrap: wrap; }
  .step-note { margin: 0; font: var(--text-detail); line-height: 1.4; color: var(--text2); }
  .selfhosted { display: flex; flex-direction: column; gap: var(--space-4); width: 100%; }
  .selfhosted input { max-width: 260px; }
  .fields { display: flex; flex-direction: column; gap: var(--space-8); width: 100%; }
  .fields input { width: 100%; }
  .bad { color: var(--coral); margin: 0; }
  .small { font: var(--text-meta); }
  .link { background: none; border: none; padding: 0; color: var(--text2); text-align: left; }
  .link:hover { background: none; color: var(--paper); }
</style>
