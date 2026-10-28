<script lang="ts">
  // Chats: every linked app in one place, as on the Mac. WhatsApp's chats open as a card to answer in; the other linked
  // apps (calendar, mail, GitHub, ...) show what Nook sees in them. A chip per app filters the list.
  import { openUrl } from "@tauri-apps/plugin-opener";
  import { api } from "../lib/api";
  import { connectorEvents, connectorsApi, type ConnectorInfo, type Overview, type PullRequestItem, type WhatsAppConversation, type WhatsAppView } from "../lib/connectors";
  import { tr } from "../lib/i18n.svelte";
  import { itemId, laneCounts, triage } from "../lib/pulls";
  import { pullRequests } from "../lib/pulls.svelte";
  import { time } from "../lib/whatsapp";
  import { whatsapp } from "../lib/whatsapp.svelte";
  import PullRequestView from "./agents/pulls/PullRequestView.svelte";
  import Avatar from "./connectors/Avatar.svelte";
  import GitHubPanel from "./connectors/GitHubPanel.svelte";
  import ServiceIcon from "./connectors/ServiceIcon.svelte";
  import WhatsAppCard from "./connectors/WhatsAppCard.svelte";

  let { onnook }: { onnook: (nookId: string) => void } = $props();

  const WHATSAPP = "whatsapp";
  const GITHUB = "github";

  let overview = $state<Overview | null>(null);
  let wa = $state<WhatsAppView | null>(null);
  let chats = $state<WhatsAppConversation[]>([]);
  let filter = $state<string>("all");
  let failed = $state(false);
  /// The pull request open beside the GitHub dashboard, with the account it is listed under.
  let gh = $state<{ account: string; item: PullRequestItem } | null>(null);

  async function load() {
    try {
      const [o, w] = await Promise.all([connectorsApi.overview(), connectorsApi.whatsapp().catch(() => null)]);
      overview = o;
      wa = w;
      chats = w && w.link.kind === "connected" ? await connectorsApi.whatsappChatList().catch(() => []) : [];
      failed = false;
    } catch {
      failed = true;
    }
  }

  // Reading, muting, hiding or answering a chat changes its unread mark: redraw at once, not at the next poll.
  $effect(() => {
    whatsapp.version;
    load();
  });

  $effect(() => {
    load();
    const a = connectorEvents.onChanged(load);
    const b = connectorEvents.onWhatsApp(load);
    const timer = setInterval(load, 30_000);
    return () => {
      a.then((f) => f());
      b.then((f) => f());
      clearInterval(timer);
    };
  });

  // Apps folded shut with the arrow, so a long WhatsApp list does not push the calendar off screen. Remembered between visits.
  const FOLDED_KEY = "chats.folded";
  function loadFolded(): string[] {
    try {
      const v = JSON.parse(localStorage.getItem(FOLDED_KEY) ?? "[]");
      return Array.isArray(v) ? v.filter((x) => typeof x === "string") : [];
    } catch {
      return [];
    }
  }
  let folded = $state<string[]>(loadFolded());
  function fold(id: string) {
    folded = folded.includes(id) ? folded.filter((x) => x !== id) : [...folded, id];
    try {
      localStorage.setItem(FOLDED_KEY, JSON.stringify(folded));
    } catch {
      // The choice only lasts until the window closes.
    }
  }

  const domainOf = (id: string) => overview?.services.find((s) => s.id === id)?.domain ?? null;
  // The linked apps with something to show; WhatsApp has its own section.
  const apps = $derived((overview?.connectors ?? []).filter((c) => c.configured && c.on && c.id !== WHATSAPP));
  const whatsappOn = $derived(!!wa?.settings.enabled);
  const sorted = $derived([...chats].sort((a, b) => b.lastActivity.localeCompare(a.lastActivity)));

  // What waits on you in GitHub (reviews asked, CI to fix) counts on its chip, not the number of rows in the status.
  const githubCount = $derived.by(() => {
    const counts = laneCounts(triage(pullRequests.accounts));
    return counts.review + counts.fix;
  });

  type Chip = { id: string; title: string; domain: string | null; count: number };
  const chips = $derived<Chip[]>([
    ...(whatsappOn ? [{ id: WHATSAPP, title: "WhatsApp", domain: "whatsapp.com", count: wa?.unread ?? 0 }] : []),
    ...apps.map((c) => ({ id: c.id, title: c.title, domain: domainOf(c.id), count: c.id === GITHUB ? githubCount : c.status.items.length })),
  ]);
  const shown = $derived(chips.filter((c) => filter === "all" || c.id === filter));

  const last = (c: WhatsAppConversation) => c.messages[c.messages.length - 1];
  const at = (c: WhatsAppConversation) => (last(c) ? time(last(c).date) : c.messages.length ? "" : time(c.lastActivity));

  // A chat Nook has no messages of yet (it only knows it from the phone) is fetched first, so its card has something to show.
  async function openChat(c: WhatsAppConversation) {
    gh = null;
    if (!c.messages.length) await connectorsApi.whatsappCardLoad(c.id).catch(() => {});
    whatsapp.show(c.id);
  }
  function preview(c: WhatsAppConversation): string {
    const m = last(c);
    if (!m) return "";
    const text = m.text || (m.media.kind !== "none" ? `[${m.media.kind}]` : "");
    return c.isGroup && !m.fromMe && m.senderName ? `${m.senderName}: ${text}` : m.fromMe ? `${tr("Jij", "You")}: ${text}` : text;
  }

  function openPull(account: string, item: PullRequestItem) {
    whatsapp.dismiss();
    gh = { account, item };
  }

  function item(info: ConnectorInfo, url: string | null) {
    if (url) openUrl(url).catch(() => {});
    else api.showMain("settings");
  }

  function settings() {
    try {
      localStorage.setItem("settings.section", "accounts");
    } catch {
      // The window opens on its last section instead.
    }
    api.showMain("settings");
  }
</script>

<div class="chats" class:split={!!whatsapp.chat || !!gh}>
  {#if failed && !overview}
    <p class="faint note">{tr("De gekoppelde apps konden niet worden geladen.", "The linked apps could not be loaded.")}</p>
  {:else if !overview}
    <p class="faint note">{tr("Laden…", "Loading…")}</p>
  {:else if !chips.length}
    <div class="none">
      <p>{tr("Nog geen apps gekoppeld.", "No apps linked yet.")}</p>
      <p class="faint">{tr("Koppel WhatsApp, je agenda, mail of GitHub, dan zie je ze hier bij elkaar.", "Link WhatsApp, your calendar, mail or GitHub and you will see them here together.")}</p>
      <button onclick={settings}>{tr("Apps koppelen", "Link apps")}</button>
    </div>
  {:else}
    <div class="pane">
    <div class="chips" role="tablist">
      <button class="chip" class:on={filter === "all"} onclick={() => (filter = "all")}>{tr("Alles", "All")}</button>
      {#each chips as c (c.id)}
        <button class="chip" class:on={filter === c.id} onclick={() => (filter = c.id)}>
          <ServiceIcon domain={c.domain} title={c.title} size={14} />
          {c.title}
          {#if c.count}<span class="count">{c.count}</span>{/if}
        </button>
      {/each}
    </div>

    <div class="list">
      {#each shown as c (c.id)}
        <section>
          <h4>
            <button class="fold" aria-expanded={!folded.includes(c.id)} onclick={() => fold(c.id)}>
              <svg class="arrow" class:open={!folded.includes(c.id)} width="10" height="10" viewBox="0 0 10 10" aria-hidden="true"><path d="M3 1.5 7 5 3 8.5" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" /></svg>
              <ServiceIcon domain={c.domain} title={c.title} size={16} />
              <span class="name">{c.title}</span>
              {#if folded.includes(c.id) && c.count}<span class="count">{c.count}</span>{/if}
            </button>
          </h4>
          {#if folded.includes(c.id)}
            <!-- Folded: only the header shows. -->
          {:else if c.id === WHATSAPP}
            {#if wa && wa.link.kind !== "connected"}
              <p class="faint note">{wa.statusLine}</p>
              <button class="small" onclick={settings}>{tr("Naar instellingen", "Open settings")}</button>
            {:else if !sorted.length}
              <p class="faint note">{tr("Nog geen gesprekken. Zodra er berichten binnenkomen staan ze hier.", "No chats yet. They show up here as messages arrive.")}</p>
            {/if}
            {#each sorted.slice(0, 200) as chat (chat.id)}
              <button class="row" class:active={whatsapp.chat === chat.id} onclick={() => openChat(chat)}>
                <Avatar chat={chat.id} name={chat.name} size={28} />
                <span class="what">
                  <span class="line"><span class="title">{chat.name}</span><span class="when faint">{at(chat)}</span></span>
                  <span class="sub faint">{preview(chat)}</span>
                </span>
                {#if chat.unread}<span class="count">{chat.unread}</span>{/if}
              </button>
            {/each}
          {:else if c.id === GITHUB}
            <GitHubPanel active={gh ? `${gh.account} ${itemId(gh.item)}` : null} onopen={openPull} />
          {:else}
            {@const info = apps.find((a) => a.id === c.id)}
            {#if info}
              {#if info.status.headline}<p class="faint note">{info.status.headline}</p>{/if}
              {#each info.status.items.slice(0, 12) as it (it.id)}
                <button class="row" onclick={() => item(info, it.url)}>
                  <span class="dot {it.tone === 'good' ? 'unread' : it.tone === 'attention' ? 'waiting' : it.tone === 'bad' ? 'error' : 'idle'}"></span>
                  <span class="what">
                    <span class="line"><span class="title">{it.title}</span></span>
                    {#if it.subtitle}<span class="sub faint">{it.subtitle}</span>{/if}
                  </span>
                </button>
              {:else}
                <p class="faint note">{info.status.detail || tr("Niets nieuws.", "Nothing new.")}</p>
              {/each}
            {/if}
          {/if}
        </section>
      {/each}
    </div>
    </div>
    {#if gh}
      <div class="detail pr">
        {#key `${gh.account} ${itemId(gh.item)}`}
          <PullRequestView accountId={gh.account} item={gh.item} onback={() => (gh = null)} />
        {/key}
      </div>
    {:else if whatsapp.chat}
      <div class="detail"><WhatsAppCard inline {onnook} /></div>
    {/if}
  {/if}
</div>

<style>
  .chats { height: 100%; display: flex; min-height: 0; }
  /* The list of every chat, and beside it the open chat, so all your groups stay in view and scroll on their own. */
  .pane { flex: 1; min-width: 0; display: flex; flex-direction: column; min-height: 0; }
  .split .pane { flex: none; width: 300px; border-right: 1px solid var(--line); }
  .detail { flex: 1; min-width: 0; min-height: 0; }
  .detail.pr { padding: 12px; box-sizing: border-box; }
  .row.active { background: var(--smoke); border-color: var(--line2); }
  .split .chips { padding: 4px 10px 8px; }
  .split .list { padding: 0 6px 12px; }
  .chips { display: flex; flex-wrap: wrap; gap: 6px; padding: 4px 16px 8px; }
  .chip { display: inline-flex; align-items: center; gap: 6px; font-size: 12px; padding: 4px 10px; border-radius: 999px; background: var(--smoke); color: var(--text2); border: 1px solid var(--line); }
  .chip.on { color: var(--paper); border-color: color-mix(in srgb, var(--iris) 55%, var(--line)); }
  .count { min-width: 16px; height: 16px; padding: 0 4px; box-sizing: border-box; border-radius: 999px; background: var(--iris); color: #fff; font-size: 10px; font-weight: 700; line-height: 16px; text-align: center; }
  .list { flex: 1; min-height: 0; overflow-y: auto; padding: 0 12px 12px; }
  h4 { margin: 10px 0 6px; font-size: 11px; letter-spacing: 0.06em; text-transform: uppercase; color: var(--text3); }
  .fold { display: flex; align-items: center; gap: 8px; width: 100%; padding: 4px; border: 0; background: transparent; color: inherit; font: inherit; letter-spacing: inherit; text-transform: inherit; text-align: left; cursor: pointer; }
  .fold:hover { color: var(--text2); }
  .fold .name { flex: 1; min-width: 0; }
  .arrow { flex: none; transition: transform 0.12s ease; }
  .arrow.open { transform: rotate(90deg); }
  .note { margin: 4px 4px 8px; font-size: 11px; line-height: 1.5; }
  .row { display: flex; align-items: center; gap: 10px; width: 100%; text-align: left; padding: 8px; margin-bottom: 2px; border: 1px solid transparent; border-radius: var(--radius-control); background: transparent; }
  .row:hover { background: var(--row-hover); }
  .what { min-width: 0; flex: 1; display: grid; gap: 2px; }
  .line { display: flex; align-items: baseline; gap: 8px; }
  .title { min-width: 0; flex: 1; font-size: 12px; font-weight: 500; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .when { flex: none; font-size: 10px; }
  .sub { font-size: 11px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .dot.idle { background: var(--text3); width: 5px; height: 5px; margin: 1px; }
  .none { padding: 24px 20px; text-align: center; }
  .none p { margin: 0 0 8px; font-size: 12px; line-height: 1.5; }
  .small { font-size: 11px; padding: 4px 10px; }
</style>
