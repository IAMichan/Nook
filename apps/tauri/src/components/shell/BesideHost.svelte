<script lang="ts">
  // Mounts the tab beside the main one (split view) so it keeps its own list: the Agents and Chats tabs move their
  // list into the window's sidebar (`#sidebar-slot`) when they find it, and that sidebar is the main tab's, as on the
  // Mac. While the beside tab mounts, the slot is out of reach; it is back right after.
  import type { Snippet } from "svelte";
  let { children }: { children: Snippet } = $props();
  let ready = $state(false);

  $effect(() => {
    // Runs after the main tab's own views had their turn at the slot.
    const slot = document.getElementById("sidebar-slot");
    slot?.removeAttribute("id");
    ready = true;
    const timer = setTimeout(() => slot?.setAttribute("id", "sidebar-slot"), 0);
    return () => {
      clearTimeout(timer);
      slot?.setAttribute("id", "sidebar-slot");
    };
  });
</script>

{#if ready}{@render children()}{/if}
