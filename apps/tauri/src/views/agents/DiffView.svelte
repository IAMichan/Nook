<script lang="ts">
  // Een diff: groen erbij, rood eraf, grijs context.
  import type { DiffLine } from "../../lib/agents";

  let { lines, max = 0 }: { lines: DiffLine[]; max?: number } = $props();
</script>

<pre class="diff" style={max ? `max-height:${max}px` : ""}>{#each lines as line, i (i)}<span class={line.kind}>{line.text}</span>
{/each}</pre>

<style>
  .diff {
    margin: 0;
    font-family: var(--mono);
    font-size: 11.5px;
    line-height: 1.45;
    background: var(--field);
    border: 1px solid var(--line2);
    border-radius: 10px;
    padding: 8px 10px;
    overflow: auto;
    white-space: pre;
    user-select: text;
  }
  .add { color: var(--mint); }
  .remove { color: var(--coral); }
  .context { color: var(--text3); }
</style>
