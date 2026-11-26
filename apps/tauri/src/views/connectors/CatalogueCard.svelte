<script lang="ts">
  // The one card shape for everything you can add in Settings › Services: icon, name, one line, and a
  // `ConnectMethodBadge` saying how it links (Sign in, With key, MCP).
  import type { ConnectMethod } from "../../lib/connectors";
  import ConnectMethodBadge from "../settings/ConnectMethodBadge.svelte";
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
    /** Replaces the method's word (e.g. Retry). */
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
    <ConnectMethodBadge {method} text={badge} {busy} />
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
  .alt { background: none; border: none; border-top: 1px solid var(--line2); border-radius: 0; font: var(--text-caption); color: var(--text2); padding: var(--space-4) var(--space-12); text-align: left; }
  .alt:hover { color: var(--paper); background: none; }
</style>
