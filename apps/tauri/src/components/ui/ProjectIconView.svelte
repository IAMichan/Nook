<script lang="ts">
  // A project's icon wherever projects are listed (`ProjectIconView`): its emoji, its monogram on a tint, or its image;
  // without one, its initials on the tint picked from `name` (or the folder symbol when there is no name either).
  import { convertFileSrc } from "@tauri-apps/api/core";
  import { defaultProjectIcon, tintColor, type ProjectIcon } from "../../lib/project-icon";
  import Ico from "./Ico.svelte";
  let { icon, name, size = 15 }: { icon?: ProjectIcon | null; name?: string; size?: number } = $props();
  const shown = $derived(icon ?? (name ? defaultProjectIcon(name) : null));
  const radius = $derived(`calc(var(--radius-chip) * ${size / 24})`);
  let broken = $state(false);
</script>

{#if shown?.kind === "emoji"}
  <span class="icon" style:width="{size}px" style:height="{size}px" style:font-size="{size * 0.9}px" aria-hidden="true">{shown.emoji}</span>
{:else if shown?.kind === "monogram"}
  <span class="icon mono" style:width="{size}px" style:height="{size}px" style:border-radius={radius} style:--tint={tintColor(shown.tint)}
    style:font-size="{size * (shown.letters.length > 1 ? 0.56 : 0.66)}px" aria-hidden="true">{shown.letters}</span>
{:else if shown?.kind === "image" && !broken}
  <img class="icon" src={convertFileSrc(shown.path)} alt="" width={size} height={size} style:border-radius={radius} onerror={() => (broken = true)} />
{:else}
  <span class="icon folder" style:width="{size}px" style:height="{size}px" aria-hidden="true"><Ico name="folder" size={Math.round(size * 0.9)} /></span>
{/if}

<style>
  .icon { display: inline-flex; align-items: center; justify-content: center; flex: none; line-height: 1; object-fit: contain; }
  .mono { color: var(--tint); background: color-mix(in srgb, var(--tint) 22%, transparent); font-weight: 700; font-family: var(--font); }
  .folder { color: var(--text2); }
</style>
