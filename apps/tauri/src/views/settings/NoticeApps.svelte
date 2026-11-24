<script lang="ts">
  // Settings › Notifications › Notifications per app (`NoticeRulesSettings`, part apps, on the Mac): one switch per
  // agent, chat app and muted Think Along app, kept in `noticeRules.apps` as "<source>:<name>" and read by
  // `notice_decide` / `chats::notify`.
  import { nook } from "../../lib/state.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import { agentNames } from "../../lib/agents";
  import { services, type ServicePrefs } from "../../lib/services";
  import AgentMark from "../companion/ui/AgentMark.svelte";
  import ServiceIcon from "../connectors/ServiceIcon.svelte";
  import Ico from "../../components/ui/Ico.svelte";

  type NoticeSource = "agents" | "chats" | "suggestions";
  interface ChatAppEntry {
    key: string;
    name: string;
    domain: string;
    defaultOn: boolean;
  }

  const CHAT_APPS: ChatAppEntry[] = [
    { key: "whatsapp", name: "WhatsApp", domain: "whatsapp.com", defaultOn: true },
    { key: "telegram", name: "Telegram", domain: "telegram.org", defaultOn: false },
    { key: "signal", name: "Signal", domain: "signal.org", defaultOn: false },
    { key: "slack", name: "Slack", domain: "slack.com", defaultOn: false },
    { key: "teams", name: "Teams", domain: "teams.microsoft.com", defaultOn: false },
    { key: "discord", name: "Discord", domain: "discord.com", defaultOn: false },
    { key: "messenger", name: "Messenger", domain: "messenger.com", defaultOn: false },
    { key: "instagram", name: "Instagram", domain: "instagram.com", defaultOn: false },
    { key: "linkedin", name: "LinkedIn", domain: "linkedin.com", defaultOn: false },
    { key: "x", name: "X", domain: "x.com", defaultOn: false },
    { key: "google chat", name: "Google Chat", domain: "chat.google.com", defaultOn: false },
  ];

  const s = $derived(nook.settings!);
  const rules = $derived(
    (s.noticeRules ?? { styles: {}, apps: {}, quietHours: null, quietWhileWatching: false }) as typeof s.noticeRules & {
      suppressBots?: boolean;
      respectAppMute?: boolean;
    },
  );
  let prefs = $state<ServicePrefs | null>(null);
  let query = $state("");

  $effect(() => {
    services.prefs().then((p) => (prefs = p)).catch(() => {});
  });

  const suppressBots = $derived(rules.suppressBots ?? true);
  const respectAppMute = $derived(rules.respectAppMute ?? true);

  function setChatRule(patch: { suppressBots?: boolean; respectAppMute?: boolean }) {
    nook.saveSettings({
      noticeRules: {
        ...rules,
        ...patch,
      } as typeof s.noticeRules,
    });
  }

  const normalized = (name: string) => name.trim().toLowerCase();
  const appKey = (source: NoticeSource, id: string) => `${source}:${normalized(id)}`;
  const defaultOn = (source: NoticeSource, id: string) => (source === "chats" ? normalized(id) === "whatsapp" : true);
  const isOn = (source: NoticeSource, id: string) => {
    const stored = rules.apps[appKey(source, id)];
    if (stored !== undefined) return stored;
    if (source === "suggestions" && prefs?.thinkAlongMuted && Object.prototype.hasOwnProperty.call(prefs.thinkAlongMuted, id)) {
      return false;
    }
    return defaultOn(source, id);
  };

  const agentsOff = $derived((s.agentNotice ?? "detailed") === "off" || rules.styles.agents === "off");
  const chatsOff = $derived(rules.styles.chats === "off");
  const suggestionsOff = $derived(rules.styles.suggestions === "off");

  const allAgents = $derived(Object.values(agentNames));
  const q = $derived(query.trim().toLowerCase());
  const matches = (name: string) => !q || name.toLowerCase().includes(q);

  const agents = $derived(allAgents.filter(matches));
  const agentsOnCount = $derived(allAgents.filter((name) => isOn("agents", name)).length);

  const chatApps = $derived(CHAT_APPS.filter((app) => matches(app.name)));
  const chatsOnCount = $derived(CHAT_APPS.filter((app) => isOn("chats", app.key)).length);

  // Apps muted in Think Along (`prefs.thinkAlongMuted` and any `suggestions:*` entries in `noticeRules.apps`).
  const allSuggestionApps = $derived.by(() => {
    const map = new Map<string, string>();
    for (const [id, name] of Object.entries(prefs?.thinkAlongMuted ?? {})) {
      map.set(id, name || id);
    }
    for (const k of Object.keys(rules.apps)) {
      if (k.startsWith("suggestions:")) {
        const id = k.slice("suggestions:".length);
        if (id && !map.has(id)) map.set(id, id);
      }
    }
    return [...map.entries()]
      .map(([id, name]) => ({ id, name }))
      .sort((a, b) => a.name.localeCompare(b.name));
  });
  const suggestionApps = $derived(allSuggestionApps.filter((app) => matches(app.name)));
  const suggestionsOnCount = $derived(allSuggestionApps.filter((app) => isOn("suggestions", app.id)).length);

  const anyMatch = $derived(agents.length > 0 || chatApps.length > 0 || suggestionApps.length > 0);

  function setApp(source: NoticeSource, id: string, on: boolean) {
    const apps = { ...rules.apps };
    const k = appKey(source, id);
    if (on === defaultOn(source, id)) delete apps[k];
    else apps[k] = on;
    nook.saveSettings({ noticeRules: { ...rules, apps } });
  }

  async function setSuggestionApp(id: string, name: string, on: boolean) {
    setApp("suggestions", id, on);
    if (!prefs) return;
    const muted = { ...prefs.thinkAlongMuted };
    if (on) delete muted[id];
    else muted[id] = name;
    prefs = await services.savePrefs({ ...prefs, thinkAlongMuted: muted }).catch(() => prefs);
  }
</script>

<div class="group">
  <label class="row search">
    <Ico name="search" size={13} />
    <input placeholder={tr("Zoek apps", "Search apps")} aria-label={tr("Zoek apps", "Search apps")} bind:value={query} />
    {#if query}
      <button type="button" class="clear ghost" onclick={() => (query = "")} aria-label={tr("Wissen", "Clear")}>
        <Ico name="circle-x" size={14} />
      </button>
    {/if}
  </label>
  {#if q && !anyMatch}
    <p class="note">{tr("Niets gevonden.", "Nothing found.")}</p>
  {/if}
</div>

{#if agents.length > 0 || !q}
  <h3>{tr("Agents", "Agents")} · {tr("{on} van {all} aan", "{on} of {all} on", { on: agentsOnCount, all: allAgents.length })}</h3>
  <p class="section-info">{tr("Een agent die uit staat, is stil; de tab Agents toont hem nog, en zijn toestemmingsvragen bereiken je nog steeds.", "An agent switched off is silent; the Agents tab still shows it, and its permission requests still reach you.")}</p>
  <div class="group" class:dimmed={agentsOff}>
    {#each agents as name (name)}
      <label class="row app-row">
        <span class="name"><AgentMark agent={name} size={18} />{name}</span>
        <input type="checkbox" role="switch" disabled={agentsOff} checked={isOn("agents", name)} onchange={(e) => setApp("agents", name, e.currentTarget.checked)} />
      </label>
    {/each}
    {#if agentsOff}
      <p class="note">{tr("Meldingen voor agents staan op “Alleen in de lijst”. Pas dat aan bij Meldingen om deze schakelaars te gebruiken.", "Notifications for agents are set to “Only in the list”. Change that under Notifications to use these switches.")}</p>
    {/if}
  </div>
{/if}

{#if chatApps.length > 0 || !q}
  <h3>{tr("Chat-apps", "Chat apps")} · {tr("{on} van {all} aan", "{on} of {all} on", { on: chatsOnCount, all: CHAT_APPS.length })}</h3>
  <p class="section-info">{tr("Andere apps dan WhatsApp tonen al hun eigen meldingen, dus die staan eerst uit. Hun berichten staan altijd in Chats.", "Apps other than WhatsApp already show their own notifications, so they start off. Their messages are always in Chats.")}</p>
  <div class="group" class:dimmed={chatsOff}>
    {#each chatApps as app (app.key)}
      <label class="row app-row">
        <span class="name"><ServiceIcon domain={app.domain} title={app.name} size={20} />{app.name}</span>
        <input type="checkbox" role="switch" disabled={chatsOff} checked={isOn("chats", app.key)} onchange={(e) => setApp("chats", app.key, e.currentTarget.checked)} />
      </label>
    {/each}
    {#if chatsOff}
      <p class="note">{tr("Meldingen voor chatberichten staan op “Alleen in de lijst”. Pas dat aan bij Meldingen om deze schakelaars te gebruiken.", "Notifications for chat messages are set to “Only in the list”. Change that under Notifications to use these switches.")}</p>
    {/if}
  </div>

  {#if !q}
    <h3>{tr("Van wie", "From whom")}</h3>
    <p class="section-info">{tr("Wie bij chatberichten wel en geen melding geeft; het bericht zelf verschijnt altijd in Chats.", "Who triggers a chat notification and who stays quiet; the message itself always shows in Chats.")}</p>
    <div class="group" class:dimmed={chatsOff}>
      <label class="row">
        <span>
          {tr("Bots en automatische afzenders stil houden", "Keep bots and automated senders quiet")}<br />
          <small>{tr("Geen melding bij berichten van bots, nieuwsbrieven en no-reply-afzenders.", "No notification for messages from bots, newsletters and no-reply senders.")}</small>
        </span>
        <input
          type="checkbox"
          role="switch"
          disabled={chatsOff}
          checked={suppressBots}
          onchange={(e) => setChatRule({ suppressBots: e.currentTarget.checked })}
        />
      </label>
      <label class="row">
        <span>
          {tr("Gedempt in de eigen app ook in Nook stil houden", "Keep chats muted in their own app quiet in Nook too")}<br />
          <small>{tr("Als een gesprek of groep in WhatsApp, Telegram of Slack gedempt is, stoort Nook je er ook niet voor.", "If a chat or group is muted in WhatsApp, Telegram or Slack, Nook does not interrupt you for it either.")}</small>
        </span>
        <input
          type="checkbox"
          role="switch"
          disabled={chatsOff}
          checked={respectAppMute}
          onchange={(e) => setChatRule({ respectAppMute: e.currentTarget.checked })}
        />
      </label>
    </div>
  {/if}
{/if}

{#if suggestionApps.length > 0}
  <h3>{tr("Meedenken in apps", "Think Along in apps")} · {tr("{on} van {all} aan", "{on} of {all} on", { on: suggestionsOnCount, all: allSuggestionApps.length })}</h3>
  <p class="section-info">{tr("Apps waarin je bij een voorstel “Niet in deze app” koos. Staat een app uit, dan denkt Nook daar helemaal niet mee.", "Apps where you chose “Not in this app” on a suggestion. Switched off, Nook does not look along in that app at all.")}</p>
  <div class="group" class:dimmed={suggestionsOff}>
    {#each suggestionApps as app (app.id)}
      <label class="row app-row">
        <span class="name"><Ico name="monitor" size={16} />{app.name}</span>
        <input type="checkbox" role="switch" disabled={suggestionsOff} checked={isOn("suggestions", app.id)} onchange={(e) => setSuggestionApp(app.id, app.name, e.currentTarget.checked)} />
      </label>
    {/each}
    {#if suggestionsOff}
      <p class="note">{tr("Meldingen voor Meedenken staan op “Alleen in de lijst”. Pas dat aan bij Meldingen om deze schakelaars te gebruiken.", "Notifications for Think Along are set to “Only in the list”. Change that under Notifications to use these switches.")}</p>
    {/if}
  </div>
{/if}

<style>
  .search { flex-wrap: nowrap; justify-content: flex-start; gap: var(--space-6); color: var(--text3); }
  .search input { flex: 1; min-width: 0; padding: 0; border: none; background: none; box-shadow: none; outline: none; color: var(--paper); font: var(--text-body); }
  .clear { display: grid; place-items: center; padding: 0; border: 0; color: var(--text3); }
  .clear:hover { color: var(--paper); }
  .app-row { flex-wrap: nowrap; }
  .name { display: inline-flex; align-items: center; gap: var(--space-8); }
  .dimmed { opacity: 0.6; }
</style>
