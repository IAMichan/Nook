<script lang="ts">
  // Allow or Deny (`DecisionButton`): a full-width capsule; Allow in iris, Deny in a soft coral.
  import Ico from "./Ico.svelte";
  let { kind, label, onclick }: { kind: "allow" | "deny"; label: string; onclick: () => void } = $props();
</script>

<button class="decision press {kind}" {onclick}><Ico name={kind === "allow" ? "check" : "x"} size={14} stroke={3} />{label}</button>

<style>
  .decision { flex: 1; min-height: 46px; border-radius: 999px; display: inline-flex; align-items: center; justify-content: center; gap: 6px; font: 600 17.14px var(--font) !important; }
  .allow { background: var(--iris); color: var(--on-iris) !important; }
  .deny { background: rgba(255, 100, 103, 0.12); border: 1px solid rgba(255, 100, 103, 0.3) !important; color: var(--coral) !important; }
</style>
