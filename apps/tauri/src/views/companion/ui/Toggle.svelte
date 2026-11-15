<script lang="ts">
  // A switch as the iPhone draws it, tinted mint.
  let { on, onchange, label }: { on: boolean; onchange: (on: boolean) => void; label: string } = $props();
</script>

<button class="switch" class:on role="switch" aria-checked={on} aria-label={label} onclick={() => onchange(!on)}><span></span></button>

<style>
  .switch { width: 51px; height: 31px; border-radius: 999px; background: #39393d !important; position: relative; flex: none; transition: background var(--reveal); }
  .switch.on { background: var(--mint) !important; }
  .switch span { position: absolute; top: 2px; left: 2px; width: 27px; height: 27px; border-radius: 50%; background: #fff; box-shadow: 0 2px 4px rgba(0, 0, 0, 0.25); transition: transform var(--reveal); }
  .switch.on span { transform: translateX(20px); }
</style>
