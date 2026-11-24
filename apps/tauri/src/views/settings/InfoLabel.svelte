<script lang="ts">
  // A row's name with a small ⓘ after it that tells more on hover (`SettingInfoLabel`): the explanation stays out of
  // the row until you ask for it.
  import Ico from "../../components/ui/Ico.svelte";
  import { tip } from "../../components/ui/tip";
  let { label, info }: { label: string; info: string } = $props();
</script>

<span class="info-label">{label}<span class="i" use:tip={info} tabindex="-1" role="img" aria-label={info}><Ico name="info" size={14} stroke={1.75} /></span></span>

<style>
  .info-label { display: inline-flex; align-items: center; gap: var(--space-4); }
  .i { display: inline-grid; place-items: center; color: var(--text2); cursor: help; }
</style>
