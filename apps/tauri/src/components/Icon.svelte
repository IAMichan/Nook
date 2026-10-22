<script lang="ts">
  let { name, size = 18 }: {
    name: "chat" | "agents" | "workspace" | "phone" | "settings" | "plus" | "search" | "sidebar" | "arrow" | "back" | "attach" | "mic" | "copy";
    size?: number;
  } = $props();
</script>

<svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
  {#if name === "chat"}<path d="M20 11.5a8 8 0 0 1-8 8H5l-3 2v-10a9 9 0 0 1 18 0Z" /><path d="M7 9h8M7 13h5" />
  {:else if name === "agents"}<rect x="4" y="6" width="16" height="14" rx="4" /><path d="M12 3v3M8 12h.01M16 12h.01M9 16h6M1 11v4M23 11v4" />
  {:else if name === "workspace"}<rect x="3" y="4" width="18" height="16" rx="3" /><path d="M3 9h18M9 9v11M6 6.5h.01M9 6.5h.01" />
  {:else if name === "phone"}<rect x="6" y="2" width="12" height="20" rx="3" /><path d="M10 18h4" />
  {:else if name === "settings"}<path d="m9 3-1 3-3 1-2 3 2 2v3l3 1 1 3h4l1-3 3-1 2-3-2-2V7l-3-1-1-3Z" /><circle cx="10.5" cy="11" r="3" />
  {:else if name === "plus"}<path d="M12 5v14M5 12h14" />
  {:else if name === "search"}<circle cx="10.5" cy="10.5" r="6.5" /><path d="m16 16 4 4" />
  {:else if name === "sidebar"}<rect x="3" y="4" width="18" height="16" rx="3" /><path d="M9 4v16" />
  {:else if name === "arrow"}<path d="M12 19V5m-6 6 6-6 6 6" />
  {:else if name === "back"}<path d="m14 6-6 6 6 6" />
  {:else if name === "attach"}<path d="m8 13 7-7a3 3 0 0 1 4 4L9 20a5 5 0 0 1-7-7L12 3" />
  {:else if name === "mic"}<rect x="9" y="2" width="6" height="12" rx="3" /><path d="M5 10v2a7 7 0 0 0 14 0v-2M12 19v3M8 22h8" />
  {:else if name === "copy"}<rect x="8" y="8" width="12" height="13" rx="2" /><path d="M16 8V5a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h3" />
  {/if}
</svg>
