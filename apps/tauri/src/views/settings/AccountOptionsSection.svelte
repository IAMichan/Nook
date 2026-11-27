<script lang="ts">
  // Per-account options in Settings › Agents (`AccountOptionsSection` on the Mac, CH-98):
  // enable/disable switch, plus a folded "Advanced" section for custom program path, extra CLI
  // arguments, per-account environment variables (plain or keychain-backed secrets), and custom models.
  import { open as openDialog } from "@tauri-apps/plugin-dialog";
  import { agentApi, type AccountVariable, type AgentProfile } from "../../lib/agents";
  import { clashingHomeVariable, splitLines } from "../../lib/account-options";
  import { tr } from "../../lib/i18n.svelte";
  import Ico from "../../components/ui/Ico.svelte";
  import SheetPart from "../../components/ui/SheetPart.svelte";
  import Fold from "./Fold.svelte";
  import SettingNote from "./SettingNote.svelte";
  import SettingToggle from "./SettingToggle.svelte";

  interface VariableRow {
    id: number;
    name: string;
    value: string;
    sensitive: boolean;
    hasStoredValue: boolean;
  }

  let {
    profile,
    detectedExecutable = null,
    commandName,
    onchange,
  }: {
    profile: AgentProfile;
    detectedExecutable?: string | null;
    commandName: string;
    onchange?: () => void | Promise<void>;
  } = $props();

  let loadedId = $state<string | null>(null);
  let enabled = $state(true);
  let advancedOpen = $state(false);
  let program = $state("");
  let argumentsText = $state("");
  let modelsText = $state("");
  let rows = $state<VariableRow[]>([]);
  let nextRowId = 1;
  let error = $state<string | null>(null);
  let argTimer: ReturnType<typeof setTimeout> | null = null;
  let modelTimer: ReturnType<typeof setTimeout> | null = null;

  function hydrate(p: AgentProfile) {
    loadedId = p.id;
    enabled = p.enabled !== false;
    program = p.executablePath ?? "";
    argumentsText = (p.extraArguments ?? []).join("\n");
    modelsText = (p.customModels ?? []).join("\n");
    const stored = new Set(p.storedSecretVariables ?? []);
    rows = (p.variables ?? []).map((v) => ({
      id: nextRowId++,
      name: v.name,
      value: v.sensitive ? "" : v.value,
      sensitive: v.sensitive,
      hasStoredValue: v.sensitive && stored.has(v.name),
    }));
  }

  $effect(() => {
    const p = profile;
    enabled = p.enabled !== false;
    if (loadedId !== p.id) {
      hydrate(p);
    }
  });

  const clash = $derived(
    clashingHomeVariable(
      profile,
      rows.map((r) => r.name),
    ),
  );

  async function toggleEnabled(next: boolean) {
    enabled = next;
    error = null;
    try {
      await agentApi.setProfileEnabled(profile.id, next);
      await onchange?.();
    } catch (e) {
      enabled = !next;
      error = String(e);
    }
  }

  async function saveProgram() {
    if (loadedId !== profile.id) return;
    error = null;
    try {
      await agentApi.setProfileExecutablePath(profile.id, program);
      await onchange?.();
    } catch (e) {
      error = String(e);
    }
  }

  async function chooseProgram() {
    error = null;
    try {
      const picked = await openDialog({ directory: false, multiple: false });
      if (typeof picked === "string") {
        program = picked;
        await saveProgram();
      }
    } catch (e) {
      error = String(e);
    }
  }

  async function flushArguments() {
    if (argTimer) {
      clearTimeout(argTimer);
      argTimer = null;
    }
    if (loadedId !== profile.id) return;
    error = null;
    try {
      await agentApi.setProfileExtraArguments(profile.id, splitLines(argumentsText));
      await onchange?.();
    } catch (e) {
      error = String(e);
    }
  }

  function onArgumentsInput() {
    if (argTimer) clearTimeout(argTimer);
    argTimer = setTimeout(() => {
      argTimer = null;
      flushArguments();
    }, 250);
  }

  async function flushModels() {
    if (modelTimer) {
      clearTimeout(modelTimer);
      modelTimer = null;
    }
    if (loadedId !== profile.id) return;
    error = null;
    try {
      await agentApi.setProfileCustomModels(profile.id, splitLines(modelsText));
      await onchange?.();
    } catch (e) {
      error = String(e);
    }
  }

  function onModelsInput() {
    if (modelTimer) clearTimeout(modelTimer);
    modelTimer = setTimeout(() => {
      modelTimer = null;
      flushModels();
    }, 250);
  }

  function addRow() {
    rows = [...rows, { id: nextRowId++, name: "", value: "", sensitive: false, hasStoredValue: false }];
  }

  async function removeRow(id: number) {
    rows = rows.filter((r) => r.id !== id);
    await saveVariables();
  }

  async function saveVariables() {
    if (loadedId !== profile.id) return;
    error = null;
    const payload: AccountVariable[] = rows
      .filter((r) => r.name.trim().length > 0)
      .map((r) => ({ name: r.name.trim(), value: r.value, sensitive: r.sensitive }));
    try {
      await agentApi.setProfileVariables(profile.id, payload);
      // A typed secret now lives in the keychain; show the stored placeholder instead of the cleartext value.
      rows = rows.map((r) =>
        r.sensitive && r.value.length > 0 ? { ...r, value: "", hasStoredValue: true } : r,
      );
      await onchange?.();
    } catch (e) {
      error = String(e);
    }
  }
</script>

<div class="options-root">
  <SheetPart title={tr("Status", "Status")} embedded>
    <SettingToggle
      title={tr("Dit account gebruiken", "Use this account")}
      detail={tr(
        "Uit: Nook laat dit account weg uit alle lijsten en uit Auto, en bewaart de login en instellingen.",
        "Off: Nook leaves this account out of every list and of Auto, and keeps its login and settings.",
      )}
      checked={enabled}
      onchange={toggleEnabled}
    />
  </SheetPart>

  <SheetPart title={tr("Geavanceerd", "Advanced")} embedded>
    <Fold title={tr("Programma, argumenten, variabelen, modellen", "Program, arguments, variables, models")} bind:open={advancedOpen}>
      <div class="advanced-body">
        <div class="field-block">
          <span class="field-label">{tr("Programma", "Program")}</span>
          <div class="program-row">
            <input
              type="text"
              class="mono-input"
              placeholder={detectedExecutable || commandName}
              bind:value={program}
              onblur={saveProgram}
              onkeydown={(e) => e.key === "Enter" && saveProgram()}
            />
            <button type="button" class="small" onclick={chooseProgram}>{tr("Kies…", "Choose…")}</button>
          </div>
          <SettingNote
            text={tr(
              "Het {command}-programma dat dit account start in plaats van dat wat Nook vond. Leeg laten voor dat van Nook.",
              "The {command} program this account starts instead of the one Nook found. Leave empty for Nook's.",
              { command: commandName },
            )}
          />
        </div>

        <div class="field-block">
          <span class="field-label">{tr("Extra argumenten", "Extra arguments")}</span>
          <textarea
            class="lines"
            rows="3"
            bind:value={argumentsText}
            oninput={onArgumentsInput}
            onblur={flushArguments}
          ></textarea>
          <SettingNote
            text={tr(
              "Eén argument per regel, toegevoegd aan elke start van de agent met dit account.",
              "One argument per line, added to every start of the agent under this account.",
            )}
          />
        </div>

        <div class="field-block">
          <span class="field-label">{tr("Omgevingsvariabelen", "Environment variables")}</span>
          <div class="vars">
            {#each rows as row (row.id)}
              <div class="var-row">
                <input
                  type="text"
                  class="mono-input var-name"
                  placeholder={tr("NAAM", "NAME")}
                  bind:value={row.name}
                  onkeydown={(e) => e.key === "Enter" && saveVariables()}
                />
                {#if row.sensitive}
                  <input
                    type="password"
                    class="var-value"
                    placeholder={row.hasStoredValue ? tr("Bewaard in Sleutelhanger", "Stored in Keychain") : tr("Waarde", "Value")}
                    bind:value={row.value}
                    onkeydown={(e) => e.key === "Enter" && saveVariables()}
                  />
                {:else}
                  <input
                    type="text"
                    class="mono-input var-value"
                    placeholder={tr("Waarde", "Value")}
                    bind:value={row.value}
                    onkeydown={(e) => e.key === "Enter" && saveVariables()}
                  />
                {/if}
                <button
                  type="button"
                  class="icon-btn"
                  class:secret-on={row.sensitive}
                  aria-pressed={row.sensitive}
                  title={tr("Geheim: bewaar de waarde in de Sleutelhanger", "Secret: keep the value in the Keychain")}
                  aria-label={tr("Geheim: bewaar de waarde in de Sleutelhanger", "Secret: keep the value in the Keychain")}
                  onclick={() => (row.sensitive = !row.sensitive)}
                >
                  <Ico name="key-round" size={14} />
                </button>
                <button
                  type="button"
                  class="icon-btn"
                  title={tr("Variabele verwijderen", "Remove variable")}
                  aria-label={tr("Variabele verwijderen", "Remove variable")}
                  onclick={() => removeRow(row.id)}
                >
                  <Ico name="circle-minus" size={14} />
                </button>
              </div>
            {/each}
            <div class="var-actions">
              <button type="button" class="small add-var" onclick={addRow}>
                <Ico name="plus" size={13} />
                {tr("Variabele toevoegen", "Add variable")}
              </button>
              <span class="grow"></span>
              <button type="button" class="small" onclick={saveVariables}>{tr("Bewaar", "Save")}</button>
            </div>
            {#if clash}
              <SettingNote
                tone="error"
                text={tr(
                  "{name} wordt door Nook gezet voor de map van dit account en kan niet worden vervangen.",
                  "{name} is set by Nook for this account's folder and cannot be replaced.",
                  { name: clash },
                )}
              />
            {/if}
          </div>
          <SettingNote
            text={tr(
              "Gezet bij elke start met dit account. Markeer een waarde als geheim (sleutelicoon) om haar in de Sleutelhanger te bewaren.",
              "Set for every start under this account. Mark a value as secret (key icon) to keep it in the Keychain.",
            )}
          />
        </div>

        <div class="field-block">
          <span class="field-label">{tr("Eigen modellen", "Custom models")}</span>
          <textarea
            class="lines"
            rows="3"
            bind:value={modelsText}
            oninput={onModelsInput}
            onblur={flushModels}
          ></textarea>
          <SettingNote
            text={tr(
              "Eén modelnaam per regel, toegevoegd aan de modelmenu's van dit account.",
              "One model name per line, added to this account's model menus.",
            )}
          />
        </div>
      </div>
    </Fold>
  </SheetPart>

  {#if error}
    <SettingNote tone="error" text={error} />
  {/if}
</div>

<style>
  .options-root {
    display: flex;
    flex-direction: column;
    gap: var(--space-16);
    padding-top: var(--space-8);
    border-top: 1px solid var(--separator);
  }
  .advanced-body {
    display: flex;
    flex-direction: column;
    gap: var(--space-16);
    padding: var(--space-12) 0 var(--space-4);
  }
  .field-block {
    display: flex;
    flex-direction: column;
    gap: var(--space-6);
  }
  .field-label {
    font: var(--text-emphasis);
    color: var(--paper);
  }
  .program-row {
    display: flex;
    align-items: center;
    gap: var(--space-8);
  }
  .program-row input {
    flex: 1;
    min-width: 0;
  }
  .mono-input {
    font: var(--text-code);
  }
  .lines {
    width: 100%;
    min-height: 64px;
    resize: vertical;
    padding: var(--space-6) var(--space-8);
    border: 1px solid var(--separator);
    border-radius: var(--radius-control);
    background: var(--smoke);
    color: var(--paper);
    font: var(--text-code);
    box-sizing: border-box;
  }
  .vars {
    display: flex;
    flex-direction: column;
    gap: var(--space-8);
  }
  .var-row {
    display: flex;
    align-items: center;
    gap: var(--space-6);
  }
  .var-name {
    width: 160px;
    flex: none;
  }
  .var-value {
    flex: 1;
    min-width: 0;
  }
  .var-actions {
    display: flex;
    align-items: center;
    gap: var(--space-8);
  }
  .add-var {
    display: inline-flex;
    align-items: center;
    gap: var(--space-4);
  }
  .grow {
    flex: 1;
  }
  .small {
    font: var(--text-detail);
  }
  .icon-btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 28px;
    height: 28px;
    flex: none;
    padding: 0;
    border: 1px solid var(--separator);
    border-radius: var(--radius-control);
    background: transparent;
    color: var(--text2);
  }
  .icon-btn:hover {
    background: var(--smoke);
    color: var(--paper);
  }
  .icon-btn.secret-on {
    background: var(--iris);
    border-color: var(--iris);
    color: var(--on-iris);
  }
</style>
