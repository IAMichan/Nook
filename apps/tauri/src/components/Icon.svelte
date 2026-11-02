<script lang="ts">
  let { name, size = 18 }: {
    name: "chat" | "agents" | "workspace" | "phone" | "settings" | "plus" | "search" | "sidebar" | "arrow" | "back" | "attach" | "mic" | "copy" | "lock" | "unlock" | "gamepad"
      | "home" | "memory" | "link" | "brain" | "pull" | "chart" | "globe" | "note" | "voice" | "check" | "calendar" | "message"
      | "code" | "sparkle" | "x" | "grip" | "tasks";
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
  {:else if name === "lock"}<rect x="5" y="11" width="14" height="10" rx="2.5" /><path d="M8 11V8a4 4 0 0 1 8 0v3" />
  {:else if name === "unlock"}<rect x="5" y="11" width="14" height="10" rx="2.5" /><path d="M8 11V8a4 4 0 0 1 7.5-1.9" />
  {:else if name === "gamepad"}<path d="M7 7h10a5 5 0 0 1 4.9 6l-.6 3a2.5 2.5 0 0 1-4.3 1.2L15 15H9l-2 2.2A2.5 2.5 0 0 1 2.7 16l-.6-3A5 5 0 0 1 7 7Z" /><path d="M7 10v4M5 12h4M15.5 11h.01M18 13h.01" />
  {:else if name === "home"}<path d="M4 11.5 12 5l8 6.5V19a2 2 0 0 1-2 2h-3.5v-5.5h-5V21H6a2 2 0 0 1-2-2Z" />
  {:else if name === "memory"}<path d="M12 4a5 5 0 0 0-5 5c0 1.7.8 3 2 4v3h6v-3c1.2-1 2-2.3 2-4a5 5 0 0 0-5-5Z" /><path d="M10 20h4" />
  {:else if name === "link"}<path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1" /><path d="M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1" />
  {:else if name === "brain"}<path d="M9 4a3 3 0 0 0-3 3 3 3 0 0 0-2 5 3 3 0 0 0 2 5 3 3 0 0 0 6 1V5a3 3 0 0 0-3-1Z" /><path d="M15 4a3 3 0 0 1 3 3 3 3 0 0 1 2 5 3 3 0 0 1-2 5 3 3 0 0 1-6 1" />
  {:else if name === "pull"}<circle cx="6" cy="6" r="2.5" /><circle cx="6" cy="18" r="2.5" /><circle cx="18" cy="18" r="2.5" /><path d="M6 8.5v7M18 15.5V10a3 3 0 0 0-3-3h-3m0 0 2-2m-2 2 2 2" />
  {:else if name === "chart"}<path d="M4 20h16M7 16v-4M12 16V7M17 16v-6" />
  {:else if name === "globe"}<circle cx="12" cy="12" r="8.5" /><path d="M3.5 12h17M12 3.5c2.5 2.5 3.5 5.5 3.5 8.5s-1 6-3.5 8.5c-2.5-2.5-3.5-5.5-3.5-8.5s1-6 3.5-8.5Z" />
  {:else if name === "note"}<path d="M6 3h9l4 4v12a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2Z" /><path d="M14 3v5h5M8 13h8M8 17h5" />
  {:else if name === "voice"}<path d="M4 10v4M8 7v10M12 4v16M16 8v8M20 11v2" />
  {:else if name === "check"}<path d="m5 12.5 4.5 4.5L19 7.5" />
  {:else if name === "calendar"}<rect x="3.5" y="5" width="17" height="15" rx="3" /><path d="M3.5 10h17M8 3v4M16 3v4" />
  {:else if name === "message"}<path d="M4 6.5A2.5 2.5 0 0 1 6.5 4h11A2.5 2.5 0 0 1 20 6.5v8a2.5 2.5 0 0 1-2.5 2.5H10l-4 3.5V17h0a2.5 2.5 0 0 1-2-2.5Z" />
  {:else if name === "code"}<path d="m8 8-4 4 4 4M16 8l4 4-4 4M13.5 5l-3 14" />
  {:else if name === "sparkle"}<path d="M12 3.5c.6 4.4 2.1 5.9 6.5 6.5-4.4.6-5.9 2.1-6.5 6.5-.6-4.4-2.1-5.9-6.5-6.5 4.4-.6 5.9-2.1 6.5-6.5ZM18.5 15.5c.3 1.9.9 2.6 2.5 3-1.6.3-2.2.9-2.5 2.5-.3-1.6-.9-2.2-2.5-2.5 1.6-.4 2.2-1.1 2.5-3Z" />
  {:else if name === "x"}<path d="M6.5 6.5l11 11M17.5 6.5l-11 11" />
  {:else if name === "grip"}<path d="M9 6h.01M15 6h.01M9 12h.01M15 12h.01M9 18h.01M15 18h.01" stroke-width="2.6" />
  {:else if name === "tasks"}<rect x="4" y="4" width="16" height="16" rx="4" /><path d="m8.5 12 2.5 2.5 4.5-5" />
  {/if}
</svg>
