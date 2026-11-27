<script lang="ts">
  // Adding or managing a non-GitHub/GitLab code host (Gitea / Forgejo / Codeberg, GitCafe, Bitbucket, Azure DevOps)
  // in the shared SetupSheet layout (`ForgeSetupSheet` on macOS).
  import { openUrl } from "@tauri-apps/plugin-opener";
  import { untrack } from "svelte";
  import {
    codeHostMeta,
    codeHostTokenPage,
    connectorsApi,
    forgeDetail,
    forgeHealth,
    normalizeCodeHost,
    type CodeHostKind,
    type ForgeTokenCheck,
  } from "../../lib/connectors";
  import { tr } from "../../lib/i18n.svelte";
  import SetupCheckStep from "../../components/ui/SetupCheckStep.svelte";
  import SetupSheet from "../../components/ui/SetupSheet.svelte";
  import SetupStep from "../../components/ui/SetupStep.svelte";
  import SheetPart from "../../components/ui/SheetPart.svelte";
  import { setupCheck, type SetupCheckState } from "../../components/ui/setup-check";
  import ServiceIcon from "./ServiceIcon.svelte";

  let {
    kind,
    managing = null,
    onclose,
    onchange,
  }: {
    kind: CodeHostKind;
    managing?: string | null;
    onclose: () => void;
    onchange: () => void;
  } = $props();

  const host0 = untrack(() => managing);
  const meta = $derived(codeHostMeta(kind));
  let host = $state(host0 ?? (untrack(() => codeHostMeta(kind).fixedHost) ?? "codeberg.org"));
  let token = $state("");
  let note = $state("");
  let checking = $state(false);
  let check = $state<ForgeTokenCheck | null>(null);
  let saved = $state(false);
  let replacing = $state(false);
  let confirmDisconnect = $state(false);

  const target = $derived(host0 ?? meta.fixedHost ?? host);
  const normalizedTarget = $derived(normalizeCodeHost(target) ?? target);
  const tokenPage = $derived(codeHostTokenPage(kind, target));
  const canSave = $derived(normalizeCodeHost(target) !== null && token.trim().length > 0);
  const health = $derived(checking ? "busy" : forgeHealth(kind, check));

  const checkState = $derived<SetupCheckState>(
    checking
      ? setupCheck.checking()
      : check?.kind === "valid"
        ? setupCheck.passed(
            check.account
              ? tr("Gekoppeld als @{user} op {host}.", "Connected as @{user} on {host}.", {
                  user: check.account,
                  host: normalizedTarget,
                })
              : tr("Token geaccepteerd door {host}.", "Token accepted by {host}.", {
                  host: normalizedTarget,
                }),
          )
        : check?.kind === "rejected"
          ? setupCheck.failed(
              tr(
                "De codehost weigert dit token. Controleer of het de juiste rechten heeft en niet verlopen is.",
                "The code host rejected this token. Check that it has the right scopes and has not expired.",
              ),
            )
          : check?.kind === "unreachable"
            ? setupCheck.failed(
                tr(
                  "Nook kon {host} niet bereiken. Het token is bewaard; Nook probeert het opnieuw zodra het nodig is.",
                  "Nook couldn't reach {host}. The token is saved; Nook tries again as soon as it's needed.",
                  { host: normalizedTarget },
                ),
              )
            : setupCheck.idle(),
  );

  $effect(() => {
    if (host0 && meta.canCheckToken) untrack(() => verify(host0));
  });

  async function verify(verifyHost = host0 ?? normalizedTarget) {
    if (!meta.canCheckToken) return;
    checking = true;
    try {
      check = await connectorsApi.forgeCheck(kind, verifyHost);
    } catch {
      check = { kind: "unreachable" };
    }
    checking = false;
  }

  async function save() {
    if (!canSave) return;
    note = "";
    checking = true;
    try {
      const result = await connectorsApi.forgeSave(kind, target, token);
      check = result.check;
      token = "";
      saved = true;
      replacing = false;
      onchange();
      if (!host0 && !meta.canCheckToken) {
        onclose();
      }
    } catch (e) {
      const msg = String(e);
      if (msg.toLowerCase().includes("weigert") || msg.toLowerCase().includes("rejected")) {
        check = { kind: "rejected" };
      }
      note = msg;
    }
    checking = false;
  }

  async function paste() {
    try {
      const text = (await navigator.clipboard.readText()).trim();
      if (!text) throw new Error();
      token = text;
      if (canSave) await save();
    } catch {
      note = tr("Er staat niets bruikbaars op je klembord.", "There's nothing usable on your clipboard.");
    }
  }

  async function disconnect() {
    if (host0) await connectorsApi.forgeRemove(host0);
    onchange();
    onclose();
  }
</script>

<SetupSheet
  title={host0 ?? meta.menuName}
  subtitle={host0
    ? forgeDetail(host0, kind, checking && meta.canCheckToken ? null : check)
    : tr(
        "Het token blijft in je sleutelhanger en gaat alleen naar die host, via https.",
        "The token stays in your Keychain and goes only to that host, over https.",
      )}
  status={host0 && meta.canCheckToken ? health : undefined}
  {onclose}
>
  {#snippet icon()}
    <ServiceIcon domain={meta.domain} title={meta.name} size={44} />
  {/snippet}

  {#if host0}
    {#if check?.kind === "unreachable" && !checking && meta.canCheckToken}
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
      {#if kind === "bitbucket" || kind === "azureDevOps"}
        <p class="step-note">{meta.tokenDetail}</p>
      {/if}
    </SheetPart>
  {:else}
    <SetupStep number={1} title={tr("Maak een token", "Make a token")} done={saved}>
      {#if meta.fixedHost === null}
        <div class="selfhosted">
          <input
            placeholder={tr("Host (bijv. codeberg.org)", "Host (e.g. codeberg.org)")}
            bind:value={host}
            oninput={() => {
              note = "";
              check = null;
            }}
          />
        </div>
      {/if}
      <p class="step-note">{meta.tokenDetail}</p>
      <button type="button" disabled={!tokenPage} onclick={() => tokenPage && openUrl(tokenPage)}>
        {tr("Open tokenpagina", "Open token page")} ↗
      </button>
    </SetupStep>

    <SetupStep number={2} title={tr("Plak het token", "Paste the token")} done={saved}>
      {@render tokenField()}
    </SetupStep>

    {#if meta.canCheckToken}
      <SetupCheckStep
        number={3}
        detail={tr("Vul eerst je token in bij stap 2.", "Fill in your token in step 2 first.")}
        checkingLabel={tr("Nook controleert of de verbinding werkt…", "Nook is checking whether the connection works…")}
        state={checkState}
        oncheck={saved ? () => verify(normalizedTarget) : undefined}
        disabled={checking}
      />
    {:else}
      <SetupCheckStep
        number={3}
        detail={tr(
          "Nook bewaart dit token en gebruikt het zodra je een pull request voor {name} opent.",
          "Nook saves this token and uses it as soon as you open a pull request for {name}.",
          { name: meta.name },
        )}
        state={setupCheck.idle()}
        disabled={true}
      />
    {/if}
  {/if}

  {#if note}<p class="bad small">{note}</p>{/if}

  {#snippet footer()}
    {#if host0}
      <button type="button" onclick={() => openUrl(`https://${host0}`)}>
        {tr("{host} openen", "Open {host}", { host: host0 })} ↗
      </button>
      {#if confirmDisconnect}
        <span class="faint">{tr("Weet je zeker dat je deze koppeling wilt verwijderen?", "Are you sure you want to remove this connection?")}</span>
        <button type="button" onclick={() => (confirmDisconnect = false)}>{tr("Annuleer", "Cancel")}</button>
        <button type="button" class="danger" onclick={disconnect}>{tr("Ontkoppel", "Disconnect")}</button>
      {:else}
        <button type="button" class="danger" onclick={() => (confirmDisconnect = true)}>{tr("Ontkoppel", "Disconnect")}</button>
      {/if}
    {/if}
    <span class="spacer"></span>
    {#if host0 || meta.canCheckToken}
      <button type="button" class="primary" onclick={onclose}>
        {saved || host0 ? tr("Klaar", "Done") : tr("Sluit", "Close")}
      </button>
    {:else}
      <button type="button" onclick={onclose}>{tr("Annuleren", "Cancel")}</button>
      <button type="button" class="primary" onclick={save} disabled={checking || !canSave}>
        {tr("Toevoegen", "Add")}
      </button>
    {/if}
  {/snippet}
</SetupSheet>

{#snippet tokenField()}
  <div class="fields">
    <input
      type="password"
      placeholder={meta.tokenPrompt}
      bind:value={token}
      oninput={() => (note = "")}
      onkeydown={(e) => e.key === "Enter" && canSave && save()}
    />
    <div class="line">
      <button type="button" onclick={paste} disabled={checking}>{tr("Plak van klembord", "Paste from clipboard")}</button>
      {#if host0 || meta.canCheckToken}
        <button type="button" class="primary" onclick={save} disabled={checking || !canSave}>
          {tr("Bewaar", "Save")}
        </button>
      {/if}
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
</style>
