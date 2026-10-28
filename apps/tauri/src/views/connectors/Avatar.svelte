<script lang="ts">
  // A chat's round picture: its profile photo once WhatsApp gave one, else the initials.
  import { avatars } from "../../lib/whatsapp.svelte";
  import { initials } from "../../lib/whatsapp";

  let { chat, name, size = 28 }: { chat: string; name: string; size?: number } = $props();

  $effect(() => {
    avatars.want(chat);
  });

  const photo = $derived(avatars.photos[chat]);
</script>

<span class="avatar" style="width:{size}px;height:{size}px;font-size:{Math.round(size * 0.4)}px">
  {#if photo}<img src={photo} alt="" />{:else}{initials(name)}{/if}
</span>

<style>
  .avatar { flex: none; display: grid; place-items: center; overflow: hidden; border-radius: 50%; background: var(--smoke); color: var(--text2); font-weight: 600; }
  img { width: 100%; height: 100%; object-fit: cover; display: block; }
</style>
