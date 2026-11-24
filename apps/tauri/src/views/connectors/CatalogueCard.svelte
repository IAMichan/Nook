<script lang="ts">
  // De ene kaartvorm van alles wat je kunt toevoegen in Instellingen › Accounts & koppelingen: icoon, naam, één regel
  // en een label dat zegt hoe het koppelt (Inloggen, Met sleutel, MCP). Inloggen is gevuld, omdat dat het makkelijkst is.
  import { methodLabel, type ConnectMethod } from "../../lib/connectors";
  import { tr } from "../../lib/i18n.svelte";
  import ServiceIcon from "./ServiceIcon.svelte";

  let {
    title,
    detail,
    domain = null,
    method,
    badge,
    busy = false,
    bad = false,
    disabled = false,
    help,
    onclick,
    alt,
  }: {
    title: string;
    detail: string;
    domain?: string | null;
    method: ConnectMethod;
    /** Replaces the method's word (Opnieuw proberen). */
    badge?: string;
    busy?: boolean;
    bad?: boolean;
    disabled?: boolean;
    help?: string;
    onclick: () => void;
    /** A second, quieter way to connect, such as a key instead of signing in. */
    alt?: { label: string; help: string; onclick: () => void };
  } = $props();
</script>

<div class="card">
  <button class="main" {onclick} {disabled} title={help}>
    <ServiceIcon {domain} {title} size={28} />
    <span class="text">
      <strong>{title}</strong>
      <span class="detail" class:bad>{detail}</span>
    </span>
    {#if busy}
      <span class="spin" aria-label={tr("Bezig", "Busy")}></span>
    {:else}
      <span class="badge {method}">{badge ?? methodLabel[method]}</span>
    {/if}
  </button>
  {#if alt}<button class="alt" onclick={alt.onclick} title={alt.help}>{alt.label}</button>{/if}
</div>

<style>
  /* A tile as the Mac's connection catalogue draws it: graphite, card-round, no line; a 28 px icon, the name in 14 px
     medium, one line of detail, and the way to connect on the right (Sign in filled in Nook's color). */
  .card { display: flex; flex-direction: column; background: var(--graphite); border-radius: var(--radius-card); overflow: hidden; }
  .main { display: flex; gap: var(--space-12); align-items: center; text-align: left; padding: var(--space-8) var(--space-12) var(--space-8) var(--space-8); min-height: 50px; background: none; border: none; border-radius: 0; flex: 1; }
  .main:hover:not(:disabled) { background: var(--smoke); }
  .text { display: flex; flex-direction: column; gap: 1px; flex: 1; min-width: 0; }
  .text strong { font: var(--text-emphasis); line-height: 1.3; color: var(--paper); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .detail { font: var(--text-detail); line-height: 1.3; color: var(--text2); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .detail.bad { color: var(--coral); }
  .badge { flex: none; display: inline-grid; place-items: center; height: 28px; padding: 0 var(--space-12); border-radius: var(--radius-control); font: var(--text-control); white-space: nowrap; color: var(--iris); background: color-mix(in srgb, var(--iris) 14%, transparent); }
  .badge.signIn { color: var(--on-iris); background: var(--iris); }
  .spin { flex: none; width: 12px; height: 12px; border-radius: 50%; border: 1.5px solid var(--text2); border-top-color: transparent; animation: spin 0.8s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }
  .alt { background: none; border: none; border-top: 1px solid var(--line2); border-radius: 0; font: var(--text-caption); color: var(--text2); padding: var(--space-4) var(--space-12); text-align: left; }
  .alt:hover { color: var(--paper); background: none; }
</style>
