<script lang="ts">
  // A switch (`Toggle` in a settings row), tinted mint when on: the Mac's small switch on the desktop, the iPhone's
  // inside the companion (`.phone`).
  let { on, onchange, label }: { on: boolean; onchange: (on: boolean) => void; label: string } = $props();
</script>

<button class="switch" class:on role="switch" aria-checked={on} aria-label={label} onclick={() => onchange(!on)}><span></span></button>

<style>
  .switch { width: 32px; height: 18px; padding: 0; border-radius: 999px; background: var(--smoke) !important; border: 1px solid var(--line2) !important; position: relative; flex: none; transition: background 180ms ease; }
  .switch.on { background: var(--mint) !important; border-color: transparent !important; }
  .switch span { position: absolute; top: 1px; left: 1px; width: 14px; height: 14px; border-radius: 50%; background: #fff; box-shadow: 0 1px 2px rgba(0, 0, 0, 0.3); transition: transform 180ms ease; }
  .switch.on span { transform: translateX(14px); }
  :global(.phone) .switch { width: 51px; height: 31px; border: none !important; background: #39393d !important; transition: background var(--reveal); }
  :global(.phone) .switch.on { background: var(--mint) !important; }
  :global(.phone) .switch span { top: 2px; left: 2px; width: 27px; height: 27px; box-shadow: 0 2px 4px rgba(0, 0, 0, 0.25); transition: transform var(--reveal); }
  :global(.phone) .switch.on span { transform: translateX(20px); }
  @media (prefers-reduced-motion: reduce) { .switch, .switch span { transition: none !important; } }
</style>
