<script lang="ts">
  // The session's active goal (`/goal`, AG-67, matching macOS `GoalStrip`): target icon, goal text, inline edit & clear.
  import Ico from "../../../components/ui/Ico.svelte";
  import { tr } from "../../../lib/i18n.svelte";
  import { workspaceApi } from "../../../lib/workspace/api";
  import { workspace } from "../../../lib/workspace/store.svelte";

  let { runId, goal }: { runId: string; goal: string } = $props();

  let editing = $state(false);
  let draft = $state("");
  let busy = $state(false);
  let input = $state<HTMLInputElement>();

  function startEdit() {
    draft = goal;
    editing = true;
    requestAnimationFrame(() => {
      input?.focus();
      input?.select();
    });
  }

  function cancelEdit() {
    editing = false;
    draft = "";
  }

  async function applyGoal(next: string | null) {
    if (busy) return;
    busy = true;
    try {
      await workspace.act(async () => {
        try {
          await workspaceApi.setGoal(runId, next);
        } catch {
          // Fallback if `workspace_set_goal` is not yet registered in `lib.rs`: `/goal` is handled in `workspace_send`.
          await workspaceApi.send(runId, next ? `/goal ${next}` : "/goal clear");
        }
      });
    } finally {
      busy = false;
    }
  }

  async function saveEdit() {
    const clean = draft.trim();
    editing = false;
    if (clean === goal) return;
    await applyGoal(clean || null);
  }

  async function clearGoal() {
    editing = false;
    await applyGoal(null);
  }

  function keydown(e: KeyboardEvent) {
    if (e.key === "Enter") {
      e.preventDefault();
      void saveEdit();
    } else if (e.key === "Escape") {
      e.preventDefault();
      cancelEdit();
    }
  }
</script>

<div class="goal-strip" role="region" aria-label={tr("Doel", "Goal")}>
  <span class="ico"><Ico name="target" size={14} stroke={2} /></span>
  <span class="label">{tr("Doel", "Goal")}</span>
  {#if editing}
    <input
      bind:this={input}
      class="edit-input"
      type="text"
      bind:value={draft}
      placeholder={tr("Beschrijf het doel van deze sessie…", "Describe this session's goal…")}
      disabled={busy}
      onkeydown={keydown}
    />
    <button
      type="button"
      class="act"
      disabled={busy}
      title={tr("Doel opslaan", "Save goal")}
      aria-label={tr("Doel opslaan", "Save goal")}
      onclick={saveEdit}
    ><Ico name="check" size={12} stroke={2.4} /></button>
    <button
      type="button"
      class="act"
      disabled={busy}
      title={tr("Annuleer", "Cancel")}
      aria-label={tr("Annuleer", "Cancel")}
      onclick={cancelEdit}
    ><Ico name="x" size={12} stroke={2.4} /></button>
  {:else}
    <span class="objective" title={goal} ondblclick={startEdit} role="button" tabindex="-1">{goal}</span>
    <button
      type="button"
      class="act"
      disabled={busy}
      title={tr("Doel bewerken", "Edit goal")}
      aria-label={tr("Doel bewerken", "Edit goal")}
      onclick={startEdit}
    ><Ico name="pencil" size={12} stroke={2} /></button>
    <button
      type="button"
      class="act"
      disabled={busy}
      title={tr("Doel wissen", "Clear goal")}
      aria-label={tr("Doel wissen", "Clear goal")}
      onclick={clearGoal}
    ><Ico name="x" size={12} stroke={2.4} /></button>
  {/if}
</div>

<style>
  .goal-strip {
    display: flex;
    align-items: center;
    gap: var(--space-8);
    padding: var(--space-6) var(--space-12);
    border: 1px solid var(--line2);
    border-radius: var(--radius-card);
    background: var(--surface);
    font: var(--text-detail);
    color: var(--text2);
    min-width: 0;
  }
  .ico {
    display: inline-flex;
    flex: none;
    color: var(--text2);
  }
  .label {
    flex: none;
    color: var(--text3);
  }
  .objective {
    flex: 1;
    min-width: 0;
    color: var(--paper);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .edit-input {
    flex: 1;
    min-width: 0;
    padding: var(--space-2) var(--space-6);
    border: 1px solid var(--field-stroke);
    border-radius: var(--radius-chip);
    background: var(--field);
    color: var(--paper);
    font: var(--text-detail);
  }
  .edit-input:focus {
    outline: none;
    border-color: color-mix(in srgb, var(--iris) 35%, var(--field-stroke));
  }
  .act {
    display: grid;
    place-items: center;
    width: 22px;
    height: 22px;
    flex: none;
    padding: 0;
    margin: 0;
    border: 0;
    border-radius: var(--radius-chip);
    background: transparent;
    color: var(--text3);
    cursor: pointer;
  }
  .act:hover:not(:disabled) {
    background: var(--smoke);
    color: var(--paper);
  }
  .act:disabled {
    opacity: 0.4;
    cursor: default;
  }
</style>
