<script lang="ts">
  // Small capsule on a connection catalogue card or tile (the Mac's `ConnectMethodBadge` in `ServiceRows.swift`):
  // filled in `--iris` for one-click sign-in, soft tinted for key/MCP, with a spinner while connecting.
  import Spinner from "../../components/ui/Spinner.svelte";
  import type { ConnectMethod } from "../../lib/connectors";
  import { tr } from "../../lib/i18n.svelte";
  import { connectMethodBadgeSpec } from "../../lib/settings-ui";

  let {
    method,
    text = null,
    busy = false,
  }: {
    method: ConnectMethod;
    /** Replaces the method's default label (e.g. Retry, Cancel). */
    text?: string | null;
    /** Shows a small spinner instead of the badge while connecting. */
    busy?: boolean;
  } = $props();

  const spec = $derived(connectMethodBadgeSpec(method, text));
</script>

{#if busy}
  <span class="busy" role="status" aria-label={tr("Bezig", "Busy")}><Spinner size={12} /></span>
{:else}
  <span class="connect-method-badge" class:filled={spec.filled}>{spec.label}</span>
{/if}

<style>
  .busy { display: inline-grid; place-items: center; flex: none; color: var(--text2); }
  .connect-method-badge {
    flex: none;
    display: inline-grid;
    place-items: center;
    padding: var(--space-4) var(--space-12);
    border-radius: var(--radius-control);
    font: var(--text-label);
    line-height: 1.25;
    white-space: nowrap;
    color: var(--iris);
    background: color-mix(in srgb, var(--iris) 14%, transparent);
  }
  .connect-method-badge.filled {
    color: var(--on-iris);
    background: var(--iris);
  }
</style>
