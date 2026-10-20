<script lang="ts">
  // The mark before a notice: a check when the agent is done, an exclamation mark when it failed, and a filled speech
  // bubble with dots when it waits on you (it reads as "your turn" better than an hourglass).
  import type { NoticeTone } from "../lib/notice";
  let { tone, size = 14 }: { tone: NoticeTone; size?: number } = $props();
</script>

<svg class="mark {tone}" width={size} height={size} viewBox="0 0 16 16" aria-hidden="true">
  {#if tone === "done"}
    <path d="M3 8.5 6.4 12 13 4.5" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" />
  {:else if tone === "failed"}
    <path d="M8 2.5v7" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" />
    <circle cx="8" cy="13" r="1.4" fill="currentColor" />
  {:else}
    <path d="M8 1.5c3.9 0 7 2.5 7 5.6s-3.1 5.6-7 5.6c-.8 0-1.6-.1-2.3-.3L2.2 14l.9-3C1.8 10 1 8.6 1 7.1 1 4 4.1 1.5 8 1.5Z" fill="currentColor" />
    <circle cx="5" cy="7.1" r="1" fill="var(--notch)" />
    <circle cx="8" cy="7.1" r="1" fill="var(--notch)" />
    <circle cx="11" cy="7.1" r="1" fill="var(--notch)" />
  {/if}
</svg>

<style>
  .mark { flex: none; }
  .done { color: var(--mint); }
  .failed { color: var(--coral); }
  .waiting { color: var(--amber); }
</style>
