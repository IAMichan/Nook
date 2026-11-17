<script lang="ts">
  // A session's terminals, as the iPhone's Terminals: each with whether it runs and its last lines, every 4 seconds.
  import { onMount } from "svelte";
  import { companion, type ClientView, type TerminalDigest } from "../../lib/companion";
  import { tr } from "../../lib/i18n.svelte";
  import NavBar from "./ui/NavBar.svelte";
  import Ico from "../../components/ui/Ico.svelte";
  import EmptyState from "../../components/ui/EmptyState.svelte";
  let { session, onback, took }: { view?: ClientView; session: string; onback: () => void; took: (v: ClientView) => void } = $props();
  let terminals = $state<TerminalDigest[] | null>(null);
  async function load() {
    if (document.visibilityState !== "visible") return;
    const r = await companion.call({ op: "terminals", session });
    if (r.response) terminals = r.response.terminals ?? [];
    else took(r.view);
  }
  onMount(() => {
    load();
    const timer = setInterval(load, 4000);
    return () => clearInterval(timer);
  });
</script>

<div class="terms">
  <NavBar onback={onback}>{#snippet center()}<strong class="t">{tr("Terminals", "Terminals")}</strong>{/snippet}</NavBar>
  <div class="scroll">
    {#if terminals === null}<div class="spinner"></div>
    {:else if !terminals.length}<EmptyState icon="terminal" title={tr("Geen terminals", "No terminals")} text={tr("Deze sessie heeft geen terminal open op de Mac.", "This session has no terminal open on the Mac.")} />
    {:else}
      {#each terminals as t (t.id)}
        <section>
          <span class="label"><Ico name={t.running ? "circle-play" : "circle-stop"} size={14} />{t.title}</span>
          <pre>{t.output}</pre>
        </section>
      {/each}
    {/if}
  </div>
</div>

<style>
  .terms { display: flex; flex-direction: column; height: 100%; min-height: 0; }
  .t { font: var(--pt-strong); }
  .scroll { flex: 1; overflow-y: auto; padding: 12px 16px 24px; display: flex; flex-direction: column; gap: 16px; }
  section { display: flex; flex-direction: column; gap: 6px; }
  .label { display: flex; align-items: center; gap: 6px; font: var(--pt-label); color: var(--paper); }
  pre { margin: 0; padding: 8px; background: var(--well); border-radius: 8px; font: var(--pt-code); font-size: 11px; color: var(--text3); white-space: pre-wrap; overflow-wrap: anywhere; max-height: 50vh; overflow-y: auto; user-select: text; }
  .spinner { margin: 60px auto; width: 26px; height: 26px; border-radius: 50%; border: 3px solid var(--smoke); border-top-color: var(--text2); animation: spin 0.8s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }
</style>
