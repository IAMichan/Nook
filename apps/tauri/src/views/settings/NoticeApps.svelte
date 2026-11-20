<script lang="ts">
  // Settings › Notifications › Notifications per app (`NoticeRulesSettings`, part apps, on the Mac): one switch per
  // agent, kept in `noticeRules.apps` as "agents:<name>" and read by `notice_decide` for every agent notice. Chat apps
  // follow once the chats ask `notice_decide` too.
  import { nook } from "../../lib/state.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import { agentNames } from "../../lib/agents";
  import AgentMark from "../companion/ui/AgentMark.svelte";
  import Ico from "../../components/ui/Ico.svelte";

  const s = $derived(nook.settings!);
  const rules = $derived(s.noticeRules ?? { styles: {}, apps: {}, quietHours: null, quietWhileWatching: false });
  let query = $state("");
  const agents = $derived(Object.values(agentNames).filter((n) => !query.trim() || n.toLowerCase().includes(query.trim().toLowerCase())));
  const key = (name: string) => `agents:${name.trim().toLowerCase()}`;
  const isOn = (name: string) => rules.apps[key(name)] ?? true;
  const onCount = $derived(Object.values(agentNames).filter(isOn).length);

  function set(name: string, on: boolean) {
    const apps = { ...rules.apps };
    if (on) delete apps[key(name)];
    else apps[key(name)] = false;
    nook.saveSettings({ noticeRules: { ...rules, apps } });
  }
  import SnoozeOptions from "./SnoozeOptions.svelte";
</script>

<div class="group">
  <label class="row search"><Ico name="search" size={13} /><input placeholder={tr("Zoek apps", "Search apps")} aria-label={tr("Zoek apps", "Search apps")} bind:value={query} /></label>
</div>

<h3>{tr("Agents", "Agents")} · {tr("{on} van {all} aan", "{on} of {all} on", { on: onCount, all: Object.keys(agentNames).length })}</h3>
<p class="section-info">{tr("Een agent die uit staat, is stil; de tab Agents toont hem nog, en zijn toestemmingsvragen bereiken je nog steeds.", "An agent switched off is silent; the Agents tab still shows it, and its permission requests still reach you.")}</p>
<div class="group">
  {#each agents as name (name)}
    <label class="row agent">
      <span class="name"><AgentMark agent={name} size={18} />{name}</span>
      <input type="checkbox" role="switch" checked={isOn(name)} onchange={(e) => set(name, e.currentTarget.checked)} />
    </label>
  {:else}
    <p class="note">{tr("Niets gevonden.", "Nothing found.")}</p>
  {/each}
</div>


<SnoozeOptions />

<style>
  .search { flex-wrap: nowrap; justify-content: flex-start; gap: var(--space-6); color: var(--text3); }
  .search input { flex: 1; min-width: 0; padding: 0; border: none; background: none; box-shadow: none; outline: none; color: var(--paper); font: var(--text-body); }
  .agent { flex-wrap: nowrap; }
  .name { display: inline-flex; align-items: center; gap: var(--space-8); }
</style>
