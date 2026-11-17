<script lang="ts">
  // A chat's face (`InboxAvatar`): its initials on a circle in the person's tint, and its app's badge at the corner.
  import { appColor, initials, personTint } from "../../../lib/companion";
  import { picture } from "../../../lib/avatars.svelte";
  let { name, app = "", size = 40, badge = true, id }: { name: string; app?: string; size?: number; badge?: boolean; id?: string } = $props();
  const photo = $derived(id ? picture(id) : null);
  const icon = $derived(app ? picture(`app:${app}`) : null);
  const tint = $derived(personTint(name));
</script>

<span class="avatar" style:width="{size}px" style:height="{size}px">
  {#if photo}<img class="photo" src={photo} alt="" />{:else}<span class="face" style:background="color-mix(in srgb, {tint} 16%, transparent)" style:color={tint} style:font-size="{size * 0.36}px">{initials(name)}</span>{/if}
  {#if badge && app}
    <!-- As the Mac's `ChatsAvatar`: the app's real icon (else its mark in its color) in a ring of the canvas, so every
         chat says which app it is in. The icon is drawn a little larger, so its own transparent margin does not shrink it. -->
    <span class="ring" style:width="{size * 0.42}px" style:height="{size * 0.42}px">
      {#if icon}<img class="appicon" src={icon} alt="" style:width="{size * 0.42 * 1.15}px" style:height="{size * 0.42 * 1.15}px" />
      {:else}<span class="badge" style:background={appColor(app)}></span>{/if}
    </span>
  {/if}
</span>

<style>
  .avatar { position: relative; display: inline-flex; flex: none; }
  .face { width: 100%; height: 100%; border-radius: 50%; display: flex; align-items: center; justify-content: center; font-weight: 600; font-family: var(--font); }
  .photo { width: 100%; height: 100%; border-radius: 50%; object-fit: cover; box-shadow: inset 0 0 0 0.5px var(--hairline); }
  .ring { position: absolute; right: -4px; bottom: -2px; display: flex; align-items: center; justify-content: center; border-radius: 50%; box-shadow: 0 0 0 1px var(--canvas); background: var(--canvas); }
  .appicon { flex: none; }
  .badge { width: 100%; height: 100%; border-radius: 50%; }
</style>
