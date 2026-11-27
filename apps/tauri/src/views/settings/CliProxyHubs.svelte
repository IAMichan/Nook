<script lang="ts">
  // CLIProxyAPI hubs as a source of limits (`CLIProxyHubViews.swift` on the Mac):
  // lists each hub with its pooled accounts, availability state, and observed limit windows;
  // in editable mode (Settings › Coding agents › Usage & costs) also lets you add and remove hubs.
  import {
    agentApi,
    agentNames,
    formatCompactDuration,
    formatUpcomingTime,
    type CliProxyHubSnapshot,
    type CliProxyProblem,
  } from "../../lib/agents";
  import { cliproxyAccountState, cliproxyProblemText, cliproxyWindowLimits } from "../../lib/cliproxy";
  import { tr } from "../../lib/i18n.svelte";
  import { paceForLimit, timeElapsed, usageTone, usedOf, type LimitDisplay } from "../../lib/workspace/limit-pool";
  import ConfirmedButton from "../../components/ui/ConfirmedButton.svelte";
  import Ico from "../../components/ui/Ico.svelte";
  import { tip } from "../../components/ui/tip";
  import AgentMark from "../companion/ui/AgentMark.svelte";
  import SettingNote from "./SettingNote.svelte";

  let {
    hubs = [],
    editable = false,
    now,
    onchanged,
  }: {
    hubs: CliProxyHubSnapshot[];
    editable?: boolean;
    now: Date;
    onchanged?: () => void;
  } = $props();

  let label = $state("");
  let address = $state("");
  let key = $state("");
  let problem = $state<CliProxyProblem | null>(null);
  let adding = $state(false);

  async function addHub() {
    if (adding || !address.trim() || !key.trim()) return;
    adding = true;
    problem = null;
    try {
      const res = await agentApi.cliproxyAdd(label, address, key);
      if (res.problem) {
        problem = res.problem;
        return;
      }
      label = "";
      address = "";
      key = "";
      onchanged?.();
    } catch {
      problem = "unreachable";
    } finally {
      adding = false;
    }
  }

  async function removeHub(id: string) {
    await agentApi.cliproxyRemove(id).catch(() => {});
    onchanged?.();
  }

  function resetText(limit: LimitDisplay): string | null {
    if (!limit.resetsAt) return null;
    const secs = (limit.resetsAt.getTime() - now.getTime()) / 1000;
    return `↻ ${secs > 0 ? formatCompactDuration(secs) : tr("nu", "now")}`;
  }

  function rowHelp(limit: LimitDisplay): string {
    const used = usedOf(limit.used);
    const lines = [tr("{label}: {used}% gebruikt", "{label}: {used}% used", { label: limit.label, used })];
    if (limit.resetsAt && limit.resetsAt > now) {
      const secs = (limit.resetsAt.getTime() - now.getTime()) / 1000;
      lines.push(
        tr("Reset over {d} · {at}", "Resets in {d} · {at}", {
          d: formatCompactDuration(secs),
          at: formatUpcomingTime(limit.resetsAt, now),
        }),
      );
    }
    const elapsed = timeElapsed(limit, now);
    if (elapsed !== null) {
      lines.push(tr("Venster voor {n}% verstreken", "Window {n}% elapsed", { n: elapsed }));
    }
    const pace = paceForLimit(limit, now);
    if (pace === "ahead") lines.push(tr("Voor op tempo", "Ahead of pace"));
    else if (pace === "on") lines.push(tr("Op tempo", "On pace"));
    else if (pace === "under") lines.push(tr("Onder tempo", "Under pace"));
    return lines.join("\n");
  }
</script>

<div class="hubs-wrap">
  {#if hubs.length === 0 && editable}
    <div class="block-pad">
      <SettingNote
        text={tr(
          "Nog geen hub. Voeg er een toe met het adres en de beheersleutel (remote-management.secret-key) uit de config van de hub.",
          "No hub yet. Add one with its address and the management key (remote-management.secret-key) from the hub's config.",
        )}
      />
    </div>
  {:else}
    {#each hubs as snap (snap.hub.id)}
      <div class="hub-block">
        <div class="hub-head">
          <span class="hub-ico" aria-hidden="true"><Ico name="layers" size={16} /></span>
          <div class="hub-meta">
            <div class="hub-name">{snap.name}</div>
            <div class="hub-url">{snap.hub.url}</div>
          </div>
          <span class="spacer"></span>
          {#if editable}
            <span use:tip={tr("Hub verwijderen", "Remove hub")}>
              <ConfirmedButton
                class="icon-danger"
                confirmTitle={tr("Hub verwijderen", "Remove hub")}
                question={tr("“{name}” verwijderen?", "Remove “{name}”?", { name: snap.name })}
                detail={tr(
                  "De beheersleutel verdwijnt uit de sleutelhanger. De hub zelf blijft zoals hij is.",
                  "The management key is removed from the keychain. The hub itself stays as it is.",
                )}
                onconfirm={() => removeHub(snap.hub.id)}
              >
                <Ico name="trash-2" size={14} />
              </ConfirmedButton>
            </span>
          {/if}
        </div>

        {#if snap.problem}
          <SettingNote tone="warning" text={cliproxyProblemText(snap.problem)} />
        {/if}

        {#if snap.readAt}
          {#if snap.accounts.length === 0}
            <p class="faint-line">{tr("Deze hub heeft nog geen accounts.", "This hub has no accounts yet.")}</p>
          {:else}
            <div class="acct-list">
              {#each snap.accounts as acc (acc.id)}
                {@const st = cliproxyAccountState(acc, now)}
                {@const limits = cliproxyWindowLimits(acc.windows, now)}
                <div class="hub-acct">
                  <div class="hub-acct-head">
                    {#if acc.agentKind}
                      <AgentMark agent={agentNames[acc.agentKind] ?? acc.agentKind} size={18} />
                    {:else}
                      <span class="acct-ico" aria-hidden="true"><Ico name="circle-user" size={18} /></span>
                    {/if}
                    <div class="hub-acct-meta">
                      <div class="hub-acct-name">{acc.name}</div>
                      <div class="hub-acct-sub">
                        <span class="state {st.tone}">{st.text}</span>
                        <span class="dot">·</span>
                        <span>
                          {tr("{ok} gelukt, {fail} mislukt", "{ok} succeeded, {fail} failed", {
                            ok: acc.succeeded,
                            fail: acc.failed,
                          })}
                        </span>
                      </div>
                    </div>
                  </div>

                  {#if limits.length === 0}
                    <p class="faint-line">
                      {tr(
                        "De hub heeft de limieten van dit account nog niet gezien. Ze verschijnen zodra er requests via de hub lopen.",
                        "The hub has not seen this account's limits yet. They show up once requests go through the hub.",
                      )}
                    </p>
                  {:else}
                    <div class="win-list">
                      {#each limits as limit, idx (`${acc.id}-${idx}-${limit.label}`)}
                        {@const used = usedOf(limit.used)}
                        {@const tone = usageTone(used)}
                        {@const elapsed = timeElapsed(limit, now)}
                        {@const right = resetText(limit)}
                        <div class="limit-row" use:tip={rowHelp(limit)}>
                          <div class="limit-top">
                            <span class="limit-label">{limit.label}</span>
                            <span class="spacer"></span>
                            <span class="limit-pct {tone}">{used}%</span>
                            {#if right}
                              <span class="limit-reset">{right}</span>
                            {/if}
                          </div>
                          <div class="bar-wrap" aria-hidden="true">
                            <div class="bar-track">
                              <div class="bar-fill {tone}" style:width="{used}%"></div>
                            </div>
                            {#if elapsed !== null}
                              <span class="bar-tick" style:left="clamp(3px, {elapsed}%, calc(100% - 3px))"></span>
                            {/if}
                          </div>
                        </div>
                      {/each}
                    </div>
                  {/if}
                </div>
              {/each}
            </div>
          {/if}
        {:else if !snap.problem}
          <div class="loading-row">
            <span class="spin"><Ico name="loader-circle" size={14} /></span>
            <span>{tr("Hub lezen…", "Reading hub…")}</span>
          </div>
        {/if}
      </div>
    {/each}
  {/if}

  {#if editable}
    <form
      class="add-form"
      onsubmit={(e) => {
        e.preventDefault();
        void addHub();
      }}
    >
      <input
        type="text"
        bind:value={label}
        placeholder={tr("Naam (optioneel)", "Name (optional)")}
        aria-label={tr("Naam (optioneel)", "Name (optional)")}
      />
      <input
        type="text"
        bind:value={address}
        placeholder={tr("Adres, bijvoorbeeld http://127.0.0.1:8317", "Address, for example http://127.0.0.1:8317")}
        aria-label={tr("Adres van de hub", "Hub address")}
      />
      <div class="key-row">
        <input
          type="password"
          bind:value={key}
          placeholder={tr("Beheersleutel", "Management key")}
          aria-label={tr("Beheersleutel", "Management key")}
        />
        <button type="submit" class="primary" disabled={adding || !address.trim() || !key.trim()}>
          {tr("Hub toevoegen", "Add hub")}
        </button>
      </div>
      {#if problem}
        <SettingNote tone="error" text={cliproxyProblemText(problem)} />
      {/if}
    </form>
  {/if}
</div>

<style>
  .hubs-wrap {
    display: flex;
    flex-direction: column;
  }
  .block-pad {
    padding: var(--row-pad-y) var(--row-pad-x);
  }
  .hub-block {
    display: flex;
    flex-direction: column;
    gap: var(--space-12);
    padding: var(--row-pad-y) var(--row-pad-x);
    border-bottom: 1px solid var(--separator);
  }
  .hub-block:last-child {
    border-bottom: 0;
  }
  .hub-head {
    display: flex;
    align-items: center;
    gap: var(--space-10);
  }
  .hub-ico,
  .acct-ico {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 22px;
    color: var(--text2);
    flex: none;
  }
  .hub-meta,
  .hub-acct-meta {
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
  }
  .hub-name {
    font: var(--text-emphasis);
    color: var(--paper);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .hub-url {
    font: var(--text-detail);
    color: var(--text2);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .spacer {
    flex: 1;
  }
  .hub-head :global(.icon-danger) {
    display: grid;
    place-items: center;
    width: 26px;
    height: 26px;
    padding: 0;
    border: 0;
    border-radius: var(--radius-control);
    background: transparent;
    color: var(--text2);
    cursor: pointer;
  }
  .hub-head :global(.icon-danger:hover) {
    background: var(--smoke);
    color: var(--coral);
  }
  .acct-list {
    display: flex;
    flex-direction: column;
    gap: var(--space-14);
  }
  .hub-acct {
    display: flex;
    flex-direction: column;
    gap: var(--space-8);
  }
  .hub-acct-head {
    display: flex;
    align-items: center;
    gap: var(--space-10);
  }
  .hub-acct-name {
    font: var(--text-body);
    color: var(--paper);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .hub-acct-sub {
    display: flex;
    align-items: center;
    gap: var(--space-6);
    font: var(--text-detail);
    color: var(--text2);
  }
  .state.ready {
    color: var(--mint);
  }
  .state.warning {
    color: var(--amber);
  }
  .state.muted {
    color: var(--text2);
  }
  .dot {
    color: var(--text3);
  }
  .faint-line {
    margin: 0;
    font: var(--text-detail);
    color: var(--text2);
  }
  .loading-row {
    display: flex;
    align-items: center;
    gap: var(--space-8);
    font: var(--text-detail);
    color: var(--text2);
  }
  .spin {
    display: inline-flex;
    animation: turn 0.9s linear infinite;
  }
  @keyframes turn {
    to {
      transform: rotate(360deg);
    }
  }
  .win-list {
    display: flex;
    flex-direction: column;
    gap: var(--space-8);
  }
  .limit-row {
    display: flex;
    flex-direction: column;
    gap: var(--space-4);
  }
  .limit-top {
    display: flex;
    align-items: baseline;
    gap: var(--space-8);
  }
  .limit-label {
    font: var(--text-detail);
    color: var(--text2);
  }
  .limit-pct {
    font: var(--text-detail);
    font-weight: 600;
    font-variant-numeric: tabular-nums;
    color: var(--text-strong);
  }
  .limit-pct.warning {
    color: var(--amber);
  }
  .limit-pct.error {
    color: var(--coral-soft);
  }
  .limit-reset {
    font: var(--text-caption);
    font-variant-numeric: tabular-nums;
    color: var(--text3);
    white-space: nowrap;
  }
  .bar-wrap {
    position: relative;
    height: 10px;
    display: flex;
    align-items: center;
  }
  .bar-track {
    width: 100%;
    height: 4px;
    border-radius: 999px;
    background: var(--smoke);
    overflow: hidden;
  }
  .bar-fill {
    height: 100%;
    border-radius: 999px;
    background: var(--text2);
    transition: width var(--motion-standard);
  }
  .bar-fill.warning {
    background: var(--amber);
  }
  .bar-fill.error {
    background: var(--coral);
  }
  .bar-tick {
    position: absolute;
    top: 0;
    bottom: 0;
    width: 2px;
    transform: translateX(-1px);
    border-radius: 999px;
    background: var(--paper);
  }
  .add-form {
    display: flex;
    flex-direction: column;
    gap: var(--space-8);
    padding: var(--row-pad-y) var(--row-pad-x);
    border-top: 1px solid var(--separator);
  }
  .add-form input {
    width: 100%;
    box-sizing: border-box;
    padding: var(--space-6) var(--space-10);
    border: 1px solid var(--line2);
    border-radius: var(--radius-control);
    background: var(--field);
    color: var(--paper);
    font: var(--text-body);
  }
  .key-row {
    display: flex;
    align-items: center;
    gap: var(--space-8);
  }
  .key-row input {
    flex: 1;
    min-width: 0;
  }
  .primary {
    flex: none;
    padding: var(--space-6) var(--space-14);
    border: 0;
    border-radius: var(--radius-control);
    background: var(--accent);
    color: var(--paper);
    font: var(--text-label);
    cursor: pointer;
  }
  .primary:disabled {
    opacity: 0.45;
    cursor: default;
  }
</style>
