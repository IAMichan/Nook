<script lang="ts">
  // Flat rounded square with a soft glyph (the Mac's `SettingsTile` in `SettingsStyle.swift`): the one icon style of
  // Settings — quiet graphite surface, strong icon, no gradient or border.
  import Ico from "../../components/ui/Ico.svelte";
  import { sectionTileIcon, type SettingsSectionId } from "../../lib/settings-pages";
  import { tileMetrics } from "../../lib/settings-ui";

  let {
    section,
    icon,
    size = 22,
  }: {
    /** Settings section whose tile icon is drawn. */
    section?: SettingsSectionId;
    /** Explicit Lucide icon name (overrides `section` for flows without a section of their own). */
    icon?: string;
    /** Square edge in pixels (22 default, 26 in `SettingsLinkRow`, 40/48 in setup sheets). */
    size?: number;
  } = $props();

  const iconName = $derived(icon ?? (section ? sectionTileIcon(section) : "settings"));
  const metrics = $derived(tileMetrics(size));
</script>

<span
  class="settings-tile"
  style:width="{metrics.size}px"
  style:height="{metrics.size}px"
  style:border-radius="var(--radius-{metrics.radiusToken})"
  aria-hidden="true"
>
  <Ico name={iconName} size={metrics.iconSize} stroke={1.75} />
</span>

<style>
  .settings-tile {
    display: grid;
    place-items: center;
    flex: none;
    background: var(--smoke);
    color: var(--text-strong);
  }
</style>
