<script lang="ts">
  // Who a chat is with (`ChatsAvatar`): their picture from the chat's app, else their initials in their own color on a
  // soft circle of it, with the app the chat is in as a small badge on the corner. The same for every chat app.
  import { appName, chatApps, faceInitials, personTint } from "../../lib/chats-list";
  import { avatars } from "../../lib/whatsapp.svelte";
  import ServiceIcon from "../connectors/ServiceIcon.svelte";

  let { id, app, name, size = 40, badge = true }: { id: string; app: string; name: string; size?: number; badge?: boolean } = $props();

  // Only WhatsApp gives pictures on Windows so far; the other apps keep their initials.
  $effect(() => {
    if (app === "whatsapp") avatars.want(id);
  });
  const photo = $derived(app === "whatsapp" ? avatars.photos[id] : undefined);
  const tint = $derived(personTint(name ?? ""));
  const mark = $derived(Math.round(size * 0.42));
</script>

<span class="face" style:width="{size}px" style:height="{size}px" aria-hidden="true">
  {#if photo}
    <img src={photo} alt="" />
  {:else}
    <span class="initials" style:color={tint} style:background="color-mix(in srgb, {tint} 16%, transparent)" style:font-size="{Math.round(size * 0.36)}px">{faceInitials(name)}</span>
  {/if}
  {#if badge}
    <span class="badge"><ServiceIcon domain={chatApps[app]?.domain} title={appName(app)} size={mark} /></span>
  {/if}
</span>

<style>
  .face { position: relative; flex: none; display: inline-block; }
  img, .initials { width: 100%; height: 100%; border-radius: 50%; display: grid; place-items: center; object-fit: cover; }
  .initials { font-family: var(--rounded, var(--font)); font-weight: 600; }
  /* The app's mark on the corner, cut out of the row by a ring of the page's color. */
  .badge { position: absolute; right: calc(-1 * var(--space-4)); bottom: calc(-1 * var(--space-2)); display: inline-flex; padding: 1px; border-radius: 50%; background: var(--canvas); }
  .badge :global(.tile) { border-radius: 50% !important; }
</style>
