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
  {#if badge && app && icon}
    <img class="appicon" src={icon} alt="" style:width="{size * 0.46}px" style:height="{size * 0.46}px" />
  {:else if badge && app}
    <span class="badge" style:width="{size * 0.42}px" style:height="{size * 0.42}px" style:background={appColor(app)}></span>
  {/if}
</span>

<style>
  .avatar { position: relative; display: inline-flex; flex: none; }
  .face { width: 100%; height: 100%; border-radius: 50%; display: flex; align-items: center; justify-content: center; font-weight: 600; font-family: var(--font); }
  .photo { width: 100%; height: 100%; border-radius: 50%; object-fit: cover; box-shadow: inset 0 0 0 0.5px var(--hairline); }
  .appicon { position: absolute; right: -4px; bottom: -2px; border-radius: 22%; }
  .badge { position: absolute; right: -4px; bottom: -2px; border-radius: 50%; box-shadow: 0 0 0 1px var(--canvas); }
</style>
