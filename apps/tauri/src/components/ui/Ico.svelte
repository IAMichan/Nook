<script lang="ts">
  // A Lucide icon as the iPhone's `NookIcon` draws it: in the text color around it, at the given size.
  import { LUCIDE } from "../../lib/lucide";
  let { name, size = 16, stroke = 2, fill = "none" }: { name: string; size?: number; stroke?: number; fill?: string } = $props();
</script>

<svg width={size} height={size} viewBox="0 0 24 24" {fill} stroke="currentColor" stroke-width={stroke} stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" style="flex:none">{@html LUCIDE[name] ?? ""}</svg>
