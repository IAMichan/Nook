<script lang="ts">
  // Settings › Coding agents › Usage & costs › Tokens (`TokenSettingsSection` on macOS — AG-32):
  // Nook's own savings (idle compaction before prompt cache expiry, context-size auto-compaction) and per-agent
  // suggestions read from each coding agent's own local files without modifying them.
  import { openUrl } from "@tauri-apps/plugin-opener";
  import Ico from "../../components/ui/Ico.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import { workspaceApi } from "../../lib/workspace/api";
  import { workspace } from "../../lib/workspace/store.svelte";
  import {
    DEFAULT_AUTO_COMPACT_TOKENS,
    SIZE_COMPACTION_CHOICES,
    isAdviceApplied,
    providerDisplayName,
    tokenSavingsApi,
    tuningAdviceDetail,
    tuningKindTitle,
    type AppliedTuning,
    type TuningAdvice,
  } from "../../lib/workspace/token-savings";
  import AgentMark from "../companion/ui/AgentMark.svelte";
  import InfoLabel from "./InfoLabel.svelte";
  import SettingNote from "./SettingNote.svelte";
  import SettingsSection from "./SettingsSection.svelte";

  let rows = $state<TuningAdvice[]>([]);
  let applied = $state<AppliedTuning>({ claudePlugins: [], claudeNoConnectors: false });
  let home = $state("");
  let scanning = $state(false);
  let scanned = $state(false);
  let copiedId = $state<string | null>(null);

  async function scan() {
    if (scanning) return;
    scanning = true;
    try {
      const snap = await tokenSavingsApi.scanTuning();
      rows = snap.rows;
      applied = snap.applied;
      home = snap.home;
      scanned = true;
    } catch {
      scanned = true;
    } finally {
      scanning = false;
    }
  }

  $effect(() => {
    if (!scanned && !scanning) {
      void scan();
    }
  });

  async function setIdleCompaction(on: boolean) {
    const current = workspace.settings;
    if (!current) return;
    await workspaceApi.saveSettings({ ...$state.snapshot(current), idleCompaction: on }).catch(() => {});
  }

  async function setAutoCompactTokens(tokens: number) {
    const current = workspace.settings;
    if (!current) return;
    await workspaceApi.saveSettings({ ...$state.snapshot(current), autoCompactTokens: tokens }).catch(() => {});
  }

  async function toggleApplied(item: TuningAdvice, on: boolean) {
    try {
      applied = await tokenSavingsApi.setTuning($state.snapshot(item), on);
    } catch {
      // keep previous state on failure
    }
  }

  async function copySnippet(item: TuningAdvice) {
    if (!item.snippet) return;
    try {
      await navigator.clipboard.writeText(item.snippet);
      copiedId = item.id;
      setTimeout(() => {
        if (copiedId === item.id) copiedId = null;
      }, 1500);
    } catch {
      // clipboard unavailable
    }
  }

  async function openLocation(item: TuningAdvice) {
    if (item.location.startsWith("https://")) {
      try {
        await openUrl(item.location);
      } catch {
        window.open(item.location, "_blank", "noopener,noreferrer");
      }
    } else {
      await tokenSavingsApi.revealPath(item.location).catch(() => {});
    }
  }

  const idleCompactionOn = $derived(workspace.settings?.idleCompaction ?? true);
  const autoCompactValue = $derived(workspace.settings?.autoCompactTokens ?? DEFAULT_AUTO_COMPACT_TOKENS);
</script>

<SettingsSection title={tr("Wat Nook doet", "What Nook does")}>
  <label class="row">
    <InfoLabel
      label={tr("Lange sessies samenvatten voordat hun cache verloopt", "Summarize long sessions before their cache expires")}
      info={tr(
        "Een sessie van meer dan 200.000 tokens die stilligt, wordt vlak voor het verlopen van de promptcache van de agent samengevat (/compact). Je volgende bericht leest dan een korte samenvatting in plaats van de hele geschiedenis opnieuw tegen het volle tarief. Nu alleen Claude Code: de andere agents melden niet hoe lang hun cache leeft.",
        "An idle session over 200,000 tokens is summarized (/compact) shortly before the agent's prompt cache expires. Your next message then reads a short summary instead of the whole history again at the full price. Claude Code only for now: the other agents do not report how long their cache lives.",
      )}
    />
    <input
      type="checkbox"
      role="switch"
      checked={idleCompactionOn}
      onchange={(e) => setIdleCompaction(e.currentTarget.checked)}
    />
  </label>

  <label class="row">
    <InfoLabel
      label={tr("Een sessie samenvatten zodra de context groter is dan", "Summarize a session once its context passes")}
      info={tr(
        "Als een beurt eindigt en de context van de sessie boven deze grootte ligt, vat de agent het gesprek samen (/compact). Elk bericht leest de hele context opnieuw, dus een sessie die blijft groeien kost per bericht een veelvoud. Werkt voor elke agent met /compact.",
        "When a turn ends and the session's context is over this size, the agent summarizes the conversation (/compact). Every message rereads the whole context, so a session that keeps growing costs several times more per message. Works for every agent that has /compact.",
      )}
    />
    <select
      value={String(autoCompactValue)}
      onchange={(e) => setAutoCompactTokens(Number(e.currentTarget.value))}
    >
      {#each SIZE_COMPACTION_CHOICES as tokens (tokens)}
        <option value={String(tokens)}>
          {tokens === 0
            ? tr("Uit", "Off")
            : tr("{n}K tokens", "{n}K tokens", { n: Math.round(tokens / 1000) })}
        </option>
      {/each}
    </select>
  </label>

  <div class="note-row">
    <SettingNote
      text={tr(
        "In de sessies die Nook start, zet het de tool search van Claude Code aan (tenzij je die zelf hebt ingesteld) en krijgen agents de uitleg van Nook één keer. De voorstellen hieronder kijken naar je eigen instellingen van elke agent.",
        "In the sessions it starts, Nook turns on Claude Code's tool search (unless you set it yourself) and gives agents its own instructions once. The suggestions below look at your own setup of each agent.",
      )}
    />
  </div>
</SettingsSection>

<SettingsSection
  title={tr("Je agents", "Your agents")}
  info={tr(
    "Wat bij elk verzoek van een agent meegaat zonder gebruikt te worden, gelezen uit zijn eigen bestanden (bij Claude Code ook uit de transcripts van de laatste 30 dagen). Nook verandert daar niets aan: kopieer een instelling naar je bestand, of laat hem gelden voor de sessies die Nook start.",
    "What goes with every request of an agent without being used, read from its own files (Claude Code also from its transcripts of the last 30 days). Nook changes none of them: copy a setting into your file, or apply it to the sessions Nook starts.",
  )}
>
  {#if scanning && !scanned}
    <div class="note-row">
      <SettingNote text={tr("Je agents worden nagekeken…", "Checking your agents…")} />
    </div>
  {:else if rows.length === 0}
    <div class="note-row">
      <SettingNote text={tr("Geen voorstellen in de bestanden die Nook kan lezen.", "No suggestions in the files Nook can read.")} />
    </div>
  {:else}
    {#each rows as item (item.id)}
      {@const isPage = item.location.startsWith("https://")}
      {@const on = isAdviceApplied(applied, item)}
      <div class="advice-row">
        <div class="advice-head">
          <AgentMark agent={providerDisplayName(item.provider)} size={16} />
          <span class="advice-title">{providerDisplayName(item.provider)} · {tuningKindTitle(item.kind)}</span>
        </div>
        <p class="advice-detail">{tuningAdviceDetail(item, home)}</p>
        {#if item.snippet}
          <pre class="advice-snippet"><code>{item.snippet}</code></pre>
        {/if}
        <div class="advice-actions">
          {#if item.appliesInNook}
            <label class="apply-toggle">
              <input
                type="checkbox"
                role="switch"
                checked={on}
                onchange={(e) => toggleApplied(item, e.currentTarget.checked)}
              />
              <InfoLabel
                label={tr("Gebruiken in sessies die Nook start", "Use in sessions Nook starts")}
                info={tr(
                  "Nook geeft dit aan Claude Code mee als het een sessie start, zonder je eigen instellingen te veranderen. Het geldt vanaf de volgende sessie.",
                  "Nook passes this to Claude Code when it starts a session, without changing your own settings. It applies from the next session.",
                )}
              />
            </label>
          {/if}
          <span class="spacer"></span>
          {#if item.snippet}
            <button type="button" class="ghost-btn" onclick={() => copySnippet(item)}>
              <Ico name={copiedId === item.id ? "check" : "copy"} size={12} />
              <span>{copiedId === item.id ? tr("Gekopieerd", "Copied") : tr("Kopieer", "Copy")}</span>
            </button>
          {/if}
          <button type="button" class="ghost-btn" onclick={() => openLocation(item)}>
            <Ico name={isPage ? "arrow-up-right" : "folder-open"} size={12} />
            <span>{isPage ? tr("Pagina openen", "Open page") : tr("Bestand tonen", "Show file")}</span>
          </button>
        </div>
      </div>
    {/each}
  {/if}

  <div class="note-row">
    <SettingNote
      text={tr(
        "Nook leest Claude Code, Codex, Gemini CLI, OpenCode, Cursor en Antigravity uit hun bestanden in je thuismap; een bestand dat het niet kan lezen, slaat het over. Grok en de ACP-agents die je toevoegde hebben geen bestand dat Nook kent, dus die worden niet nagekeken.",
        "Nook reads Claude Code, Codex, Gemini CLI, OpenCode, Cursor and Antigravity from their files in your home folder; a file it cannot read is skipped. Grok and the ACP agents you added keep no file Nook knows, so they are not checked.",
      )}
    />
  </div>

  <div class="recheck-row">
    <span class="spacer"></span>
    <button type="button" class="ghost-btn" disabled={scanning} onclick={scan}>
      {scanning ? tr("Je agents worden nagekeken…", "Checking your agents…") : tr("Opnieuw nakijken", "Check again")}
    </button>
  </div>
</SettingsSection>

<style>
  .note-row {
    padding: var(--space-10) var(--space-14);
  }
  .advice-row {
    display: flex;
    flex-direction: column;
    gap: var(--space-8);
    padding: var(--space-12) var(--space-14);
  }
  .advice-head {
    display: flex;
    align-items: center;
    gap: var(--space-8);
  }
  .advice-title {
    font: var(--text-strong);
    color: var(--text);
  }
  .advice-detail {
    margin: 0;
    font: var(--text-detail);
    color: var(--text2);
    white-space: pre-line;
    line-height: 1.45;
  }
  .advice-snippet {
    margin: 0;
    padding: var(--space-8) var(--space-10);
    border-radius: var(--radius-chip);
    background: var(--surface2);
    border: 1px solid var(--border);
    font: var(--text-code);
    color: var(--text);
    overflow-x: auto;
    max-height: 12rem;
    user-select: text;
    white-space: pre-wrap;
    word-break: break-word;
  }
  .advice-actions {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: var(--space-8);
  }
  .apply-toggle {
    display: inline-flex;
    align-items: center;
    gap: var(--space-8);
    font: var(--text-detail);
    color: var(--text);
    cursor: pointer;
  }
  .recheck-row {
    display: flex;
    align-items: center;
    padding: var(--space-8) var(--space-14) var(--space-10);
  }
  .spacer {
    flex: 1;
  }
  .ghost-btn {
    display: inline-flex;
    align-items: center;
    gap: var(--space-6);
    padding: var(--space-4) var(--space-10);
    border-radius: var(--radius-chip);
    border: 1px solid var(--border);
    background: var(--surface);
    color: var(--text);
    font: var(--text-detail);
    cursor: pointer;
  }
  .ghost-btn:hover:not(:disabled) {
    background: var(--surface-hover);
  }
  .ghost-btn:disabled {
    opacity: 0.55;
    cursor: default;
  }
</style>
