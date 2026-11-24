<script lang="ts">
  // Antigravity runs in Nook on Google's own ACP server, installed once (the Mac's `AntigravitySetupRow`): the pinned
  // release for this computer, checked before anything is unpacked. Shown where you start an Antigravity session.
  import { invoke } from "@tauri-apps/api/core";
  import { listen } from "@tauri-apps/api/event";
  import { tr } from "../../../lib/i18n.svelte";
  import { workspace } from "../../../lib/workspace/store.svelte";

  type Setup = { supported: boolean; installed: boolean; busy: boolean; version: string; downloadBytes: number };
  type Progress = { phase: "downloading" | "verifying" | "unpacking" | "checking" | "done" | "failed"; fraction: number; error?: string | null };

  let setup = $state<Setup | null>(null);
  let progress = $state<Progress | null>(null);

  async function load() {
    setup = await invoke<Setup>("antigravity_setup").catch(() => null);
  }

  $effect(() => {
    load();
    const off = listen<Progress>("antigravity-install", (e) => {
      progress = e.payload;
      if (e.payload.phase === "done" || e.payload.phase === "failed") {
        load();
        workspace.refresh();
      }
    });
    return () => { off.then((f) => f()); };
  });

  function install() {
    progress = { phase: "downloading", fraction: 0 };
    invoke("antigravity_install").catch((e) => (progress = { phase: "failed", fraction: 0, error: String(e) }));
  }

  const size = (bytes: number) => `${Math.round(bytes / 1_000_000)} MB`;
  const working = $derived(!!progress && progress.phase !== "done" && progress.phase !== "failed");
  const phaseText = $derived(
    progress?.phase === "verifying" ? tr("Controleren…", "Verifying…")
      : progress?.phase === "unpacking" ? tr("Uitpakken…", "Unpacking…")
        : progress?.phase === "checking" ? tr("Proefstart…", "Test start…") : "",
  );
</script>

{#if setup?.supported}
  <div class="setup">
    <div class="line">
      <span class:needed={!setup.installed}>
        {setup.installed
          ? tr("ACP-server {version} geïnstalleerd", "ACP server {version} installed", { version: setup.version })
          : tr("Antigravity draait in Nook op Google's eigen ACP-server. Eenmalig installeren ({size} download).", "Antigravity runs in Nook on Google's own ACP server. Install it once ({size} download).", { size: size(setup.downloadBytes) })}
      </span>
      <span class="spacer"></span>
      {#if working && progress?.phase === "downloading"}
        <progress max="1" value={progress.fraction}></progress><span class="pct">{Math.round(progress.fraction * 100)}%</span>
      {:else if working}
        <span class="busy">{phaseText}</span>
      {:else if !setup.installed}
        <button class="ghost small" onclick={install}>{tr("Installeren", "Install")}</button>
      {/if}
    </div>
    {#if progress?.phase === "failed" && progress.error}<p class="err">{progress.error}</p>{/if}
    {#if !setup.installed}
      <p class="note">{tr("De download komt van dl.google.com en wordt op grootte en SHA-256 gecontroleerd voordat er iets wordt uitgepakt. Inloggen gaat met je Google-account in je browser, per Nook-account.", "The download comes from dl.google.com and is checked on size and SHA-256 before anything is unpacked. You sign in with your Google account in your browser, per Nook account.")}</p>
    {/if}
  </div>
{/if}

<style>
  .setup { display: flex; flex-direction: column; gap: var(--space-6); padding: 0 var(--space-8); font: var(--text-detail); }
  .line { display: flex; align-items: center; gap: var(--space-8); }
  .line > span:first-child { color: var(--text3); }
  .line > span.needed { color: var(--amber); }
  .spacer { flex: 1; }
  progress { width: 90px; accent-color: var(--paper); }
  .pct { color: var(--text3); font-variant-numeric: tabular-nums; }
  .busy { color: var(--text3); }
  .small { font: var(--text-control); padding: var(--space-4) var(--space-8); }
  .note { margin: 0; color: var(--text3); }
  .err { margin: 0; color: var(--coral); }
</style>
