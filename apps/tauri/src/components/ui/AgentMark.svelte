<script lang="ts">
  // An agent's logo (`AgentLogo`, `AgentMark`): its brand's real mark, Antigravity's arch, or its first letter on a soft tile.
  import { BRAND_COLORS, BRAND_PATHS, brandFor } from "../../lib/brand-logos";
  let { agent, size = 16, quiet = false }: { agent: string; size?: number; quiet?: boolean } = $props();
  const name = $derived(agent.toLowerCase());
  const brand = $derived(name.includes("antigravity") ? null : brandFor(name));
  const gid = `g${Math.random().toString(36).slice(2, 8)}`;
  const gradient = $derived(brand === "gemini" || brand === "gemma");
  const color = $derived(brand ? (BRAND_COLORS[brand] ?? "var(--iris)") : "var(--text-strong)");
  // The brands' own gradient colours: Gemini's blue to violet, Antigravity's blue, red and yellow.
  const GEMINI = ["#4f8bf7", "#9b72f2"];
  const ANTIGRAVITY = ["#4f8bf7", "#ea4335", "#fbbc04"];
</script>

<span class="logo" class:quiet style:width="{size}px" style:height="{size}px" role="img" aria-label={agent}>
  {#if brand}
    <svg viewBox="0 0 24 24" width={size} height={size}>
      {#if gradient}<defs><linearGradient id={gid} x1="0" y1="1" x2="1" y2="0"><stop offset="0" stop-color={GEMINI[0]} /><stop offset="1" stop-color={GEMINI[1]} /></linearGradient></defs>{/if}
      <path d={BRAND_PATHS[brand]} fill-rule="evenodd" fill={gradient ? `url(#${gid})` : color} />
    </svg>
  {:else if name.includes("antigravity")}
    <span class="tile" style:border-radius="{size * 0.28}px" style:background="var(--menu)" style:border="0.5px solid var(--line2)">
      <svg viewBox="0 0 24 24" width={size * 0.56} height={size * 0.56}>
        <defs><linearGradient id={gid} x1="0" y1="1" x2="1" y2="0"><stop offset="0" stop-color={ANTIGRAVITY[0]} /><stop offset="0.5" stop-color={ANTIGRAVITY[1]} /><stop offset="1" stop-color={ANTIGRAVITY[2]} /></linearGradient></defs>
        <path d="M2 22 12 2 22 22M7.2 15.2H16.8" fill="none" stroke="url(#{gid})" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" />
      </svg>
    </span>
  {:else}
    <span class="tile letter" style:border-radius="{size * 0.28}px" style:font-size="{size * 0.52}px">{agent.slice(0, 1).toUpperCase()}</span>
  {/if}
</span>

<style>
  .logo { display: inline-flex; flex: none; align-items: center; justify-content: center; }
  .logo.quiet { filter: saturate(0); opacity: 0.6; }
  .tile { width: 100%; height: 100%; display: flex; align-items: center; justify-content: center; }
  .letter { background: color-mix(in srgb, var(--text-strong) 20%, transparent); color: var(--text-strong); font-weight: 700; font-family: var(--font); }
</style>
