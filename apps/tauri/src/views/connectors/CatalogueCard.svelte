<script lang="ts">
  // De ene kaartvorm van alles wat je kunt toevoegen in Instellingen › Accounts & koppelingen: icoon, naam, één regel
  // en een label dat zegt hoe het koppelt (Inloggen, Met sleutel, MCP). Inloggen is gevuld, omdat dat het makkelijkst is.
  import { methodLabel, type ConnectMethod } from "../../lib/connectors";
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
    <ServiceIcon {domain} {title} size={32} />
    <span class="text">
      <strong>{title}</strong>
      <span class="detail" class:bad>{detail}</span>
    </span>
    {#if busy}
      <span class="spin" aria-label="Bezig"></span>
    {:else}
      <span class="badge {method}">{badge ?? methodLabel[method]}</span>
    {/if}
  </button>
  {#if alt}<button class="alt" onclick={alt.onclick} title={alt.help}>{alt.label}</button>{/if}
</div>

<style>
  .card { display: flex; flex-direction: column; background: var(--smoke); border: 1px solid var(--line2); border-radius: 12px; overflow: hidden; }
  .main { display: flex; gap: 10px; align-items: center; text-align: left; padding: 10px 12px; background: none; border: none; border-radius: 0; flex: 1; }
  .main:hover:not(:disabled) { background: #2a2a33; }
  .text { display: flex; flex-direction: column; gap: 2px; flex: 1; min-width: 0; }
  .detail { font-size: 11px; color: var(--text2); overflow: hidden; text-overflow: ellipsis; display: -webkit-box; -webkit-line-clamp: 2; line-clamp: 2; -webkit-box-orient: vertical; }
  .detail.bad { color: var(--coral); }
  .badge { flex: none; font-size: 11px; font-weight: 600; padding: 3px 10px; border-radius: 999px; white-space: nowrap; color: var(--iris); background: color-mix(in srgb, var(--iris) 14%, transparent); }
  .badge.signIn { color: var(--on-iris); background: var(--iris); }
  .spin { flex: none; width: 12px; height: 12px; border-radius: 50%; border: 1.5px solid var(--text2); border-top-color: transparent; animation: spin 0.8s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }
  .alt { background: none; border: none; border-top: 1px solid var(--line2); border-radius: 0; font-size: 11px; color: var(--text2); padding: 5px 12px; text-align: left; }
  .alt:hover { color: var(--paper); background: none; }
</style>
