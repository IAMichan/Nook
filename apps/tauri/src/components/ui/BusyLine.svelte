<script lang="ts">
  // A status line while something runs (`BusyLine`): a small spinner and what is happening ("Opening the browser…").
  // `tone`: secondary (the usual), tertiary (beside other metadata), inherit (the color around it).
  import Spinner from "./Spinner.svelte";
  let { text, tone = "secondary" }: { text: string; tone?: "secondary" | "tertiary" | "inherit" } = $props();
</script>

<span class="busy {tone}" role="status"><Spinner size={11} /><span>{text}</span></span>

<style>
  .busy { display: inline-flex; align-items: center; gap: var(--space-6); font: var(--text-detail); min-width: 0; }
  .busy > span:last-child { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .secondary { color: var(--text2); }
  .tertiary { color: var(--text3); }
  .inherit { color: inherit; }
</style>
