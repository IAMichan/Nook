<script lang="ts">
  // Who a chat is with (`ChatsInfoSheet`), from its face or name in the header: the picture, the name, the app and
  // account, a group's members, and what can be done with the chat (the same steps as its "…" menu). For every app.
  import { appName, type Bubble, type ChatEntry } from "../../lib/chats-list";
  import { chatsApi, type ChatProfile, type CommonGroup } from "../../lib/connectors";
  import { duration, ME, noticeText } from "../../lib/chat-notice";
  import { save as saveDialog } from "@tauri-apps/plugin-dialog";
  import { canCallChat, type CallKind } from "../../lib/chats-call";
  import { activeCall } from "../../lib/chats-call.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import Ico from "../../components/ui/Ico.svelte";
  import CallIcon from "./CallIcon.svelte";
  import ChatFace from "./ChatFace.svelte";
  import { chatMenu } from "./chat-actions.svelte";
  import { invoke } from "@tauri-apps/api/core";

  let { entry, people, profile, bubbles = [], onopenchat, anchor, onclose, onclosechat }: {
    entry: ChatEntry;
    people: string[];
    /** What the chat's app says about the chat itself. */
    profile?: ChatProfile;
    /** The chat's messages, for exporting it. */
    bubbles?: Bubble[];
    onopenchat?: (key: string) => void;
    anchor: DOMRect;
    onclose: () => void;
    onclosechat: () => void;
  } = $props();

  const app = $derived(appName(entry.app));
  const handle = $derived(entry.isGroup ? "" : profile?.phone ?? (profile?.username ?? ""));
  const subtitle = $derived([handle, entry.account ? `${app} \u00b7 ${entry.account}` : app].filter(Boolean).join(" \u00b7 "));
  const admins = $derived(profile?.admins ?? []);
  const adminNames = $derived(new Set(admins.filter((a) => a !== ME)));
  // Admins first, then the rest, each by name (`ChatInfoButton.sorted`).
  const sortedPeople = $derived([...people].sort((a, b) => Number(adminNames.has(b)) - Number(adminNames.has(a)) || a.localeCompare(b)));
  const facts = $derived([
    [tr("Gebruikersnaam", "Username"), profile?.username],
    [tr("Telefoon", "Phone"), profile?.phone],
    [tr("E-mail", "Email"), profile?.email],
  ].filter((f): f is [string, string] => !!f[1]));
  const rules = $derived([
    profile?.bot ? tr("Bot", "Bot") : "",
    profile?.disappearAfter ? tr("Berichten verdwijnen na {time}", "Messages disappear after {time}", { time: duration(profile.disappearAfter) }) : "",
  ].filter(Boolean));

  // The groups you share with this person (`ChatCommonGroups`), from every chat of the same app.
  let groups = $state<CommonGroup[]>([]);
  let allGroups = $state(false);
  const GROUPS_SHOWN = 3;
  $effect(() => {
    if (entry.isGroup) return;
    chatsApi.commonGroups(entry.key).then((g) => (groups = g)).catch(() => {});
  });

  // Every message as "date Who: text", in a text file (`exportChat`); lines about the group read as themselves.
  async function exportChat() {
    onclose();
    const safe = entry.name.replace(/[\\/:*?"<>|]/g, "-");
    const path = await saveDialog({ defaultPath: `${safe}.txt`, filters: [{ name: "Text", extensions: ["txt"] }] }).catch(() => null);
    if (!path) return;
    const when = (iso: string) => new Date(iso).toLocaleString();
    const lines = bubbles.map((m) => {
      const notice = noticeText(m);
      if (notice) return `${when(m.date)} ${notice}`;
      const who = m.fromMe ? tr("Jij", "You") : m.sender || entry.name;
      const body = m.deleted ? tr("Dit bericht is verwijderd", "This message was deleted") : m.text || (m.media.kind !== "none" ? (m.media.name ?? m.media.kind) : "");
      return `${when(m.date)} ${who}: ${body}`;
    });
    await chatsApi.exportChat(path.toLowerCase().endsWith(".txt") ? path : `${path}.txt`, `${entry.name} \u00b7 ${app}\n\n${lines.join("\n")}\n`).catch(() => {});
  }
  const canCall = $derived(canCallChat(entry.app, entry.isGroup));
  const rows = $derived(chatMenu(entry, onclosechat).flat());

  // What you keep about this person (`ChatPersonNotes`): a note and a birthday, which Today shows on the day.
  let note = $state("");
  let birthday = $state("");
  $effect(() => {
    if (entry.isGroup) return;
    invoke<{ note: string; birthday: string | null }>("person_note", { key: entry.key })
      .then((n) => { note = n.note; birthday = n.birthday ? `2024-${n.birthday}` : ""; })
      .catch(() => {});
  });
  function savePerson() {
    invoke("person_note_set", { key: entry.key, note, birthday: birthday ? birthday.slice(5) : null }).catch(() => {});
  }

  function startCall(kind: CallKind) {
    onclose();
    activeCall.start(entry, kind);
  }

  $effect(() => {
    const esc = (e: KeyboardEvent) => { if (e.key === "Escape") { e.stopPropagation(); onclose(); } };
    window.addEventListener("keydown", esc, true);
    return () => window.removeEventListener("keydown", esc, true);
  });
</script>

<!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
<div class="scrim" onclick={onclose}>
  <div class="panel" role="dialog" aria-label={entry.name} tabindex="-1" style:top="{anchor.bottom + 6}px" style:left="{Math.max(12, anchor.left)}px" onclick={(e) => e.stopPropagation()}>
    <div class="identity">
      <ChatFace id={entry.id} app={entry.app} name={entry.name} size={72} />
      <strong>{entry.name}</strong>
      <span class="sub">{subtitle}</span>
    </div>
    <div class="tiles">
      {#if canCall}
        <button class="tile" title={tr("Bel in {app}", "Call in {app}", { app })} onclick={() => startCall("voice")}>
          <CallIcon name="phone" size={16} />
          <span>{tr("Bel", "Call")}</span>
        </button>
        <button class="tile" title={tr("Bel in {app}", "Call in {app}", { app })} onclick={() => startCall("video")}>
          <CallIcon name="video" size={16} />
          <span>{tr("Video", "Video")}</span>
        </button>
      {/if}
      <button class="tile" title={tr("Open {app}", "Open {app}", { app })} onclick={() => { onclose(); activeCall.openApp(entry.app); }}>
        <Ico name="external-link" size={16} />
        <span>{app}</span>
      </button>
    </div>
    {#if profile?.about && entry.isGroup}
      <div class="section">
        <span class="label">{tr("Beschrijving", "Description")}</span>
        <div class="card text"><p>{profile.about}</p></div>
      </div>
    {/if}
    {#if rules.length}
      <div class="rules">{#each rules as r (r)}<span>{r}</span>{/each}</div>
    {/if}
    {#if entry.isGroup && people.length}
      <div class="section">
        <span class="label">{tr("Leden", "Members")} &middot; {people.length + 1}</span>
        <div class="card members">
          <span class="member">{tr("Jij", "You")}{#if admins.includes(ME)}<em>{tr("Beheerder", "Admin")}</em>{/if}</span>
          {#each sortedPeople as p (p)}<span class="member"><ChatFace id={p} app={entry.app} name={p} size={20} badge={false} />{p}{#if adminNames.has(p)}<em>{tr("Beheerder", "Admin")}</em>{/if}</span>{/each}
        </div>
      </div>
    {/if}
    {#if !entry.isGroup}
      <div class="section">
        <span class="label">{tr("Over {name}", "About {name}", { name: entry.name })}</span>
        <div class="card person">
          {#if profile?.about}<p class="bio">{profile.about}</p>{/if}
          {#each facts as [label, value] (label)}<div class="fact"><span>{label}</span><b>{value}</b></div>{/each}
          <label class="field"><span>{tr("Verjaardag", "Birthday")}</span><input type="date" bind:value={birthday} onchange={savePerson} aria-label={tr("Verjaardag", "Birthday")} /></label>
          <textarea rows="2" bind:value={note} onblur={savePerson} placeholder={tr("Een notitie voor jezelf", "A note for yourself")} aria-label={tr("Notitie", "Note")}></textarea>
        </div>
      </div>
    {/if}
    {#if groups.length}
      <div class="section">
        <span class="label">{tr("{n} gemeenschappelijke groepen", "{n} groups in common", { n: groups.length })}</span>
        <div class="card">
          {#each allGroups ? groups : groups.slice(0, GROUPS_SHOWN) as g (g.key)}
            <button class="row group" onclick={() => { onclose(); onopenchat?.(g.key); }}>
              <ChatFace id={g.key} app={g.app} name={g.name} size={30} badge={false} />
              <span class="gtext"><strong>{g.name}</strong><small>{g.members.join(", ")}</small></span>
              <Ico name="chevron-right" size={12} />
            </button>
          {/each}
          {#if groups.length > GROUPS_SHOWN}
            <button class="row" onclick={() => (allGroups = !allGroups)}>
              <Ico name={allGroups ? "chevron-up" : "chevron-down"} size={14} /><span>{allGroups ? tr("Toon minder", "Show less") : tr("Alles tonen", "Show all")}</span>
            </button>
          {/if}
        </div>
      </div>
    {/if}
    <div class="card">
      {#each rows as r (r.label)}
        <button class="row" class:danger={r.destructive} onclick={() => { r.onselect?.(); onclose(); }}>
          {#if r.icon}<Ico name={r.icon} size={14} />{/if}<span>{r.label}</span>
        </button>
      {/each}
      {#if bubbles.length}
        <button class="row" onclick={exportChat}><Ico name="download" size={14} /><span>{tr("Exporteer chat", "Export chat")}</span></button>
      {/if}
      <!-- No chat app lets another app block or report someone: that stays in the app. -->
      {#if !entry.isGroup}
        <button class="row danger" onclick={() => { onclose(); activeCall.openApp(entry.app); }}><Ico name="hand" size={14} /><span>{tr("Blokkeer of rapporteer in {app}", "Block or report in {app}", { app })}</span></button>
      {/if}
    </div>
  </div>
</div>

<style>
  .scrim { position: fixed; inset: 0; z-index: 50; }
  .panel { position: fixed; width: 340px; max-height: min(600px, 80vh); overflow-y: auto; display: flex; flex-direction: column; gap: var(--space-12); padding: var(--space-12); box-sizing: border-box; background: var(--menu); border: 1px solid var(--line2); border-radius: var(--radius-panel); box-shadow: var(--shadow-popover); }
  .identity { display: flex; flex-direction: column; align-items: center; gap: var(--space-6); text-align: center; padding-top: var(--space-4); }
  .identity strong { font: var(--text-heading); color: var(--paper); user-select: text; }
  .sub { font: var(--text-detail); color: var(--text3); user-select: text; }
  .tiles { display: flex; gap: var(--space-8); }
  .tile { flex: 1; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: var(--space-4); padding: var(--space-8) var(--space-6); border: 0; border-radius: var(--radius-card); background: var(--smoke); color: var(--paper); font: var(--text-caption); }
  .tile:hover:not(:disabled) { background: var(--row-hover); }
  .section { display: flex; flex-direction: column; gap: var(--space-6); }
  .label { font: var(--text-label); color: var(--text2); }
  .card { display: flex; flex-direction: column; border-radius: var(--radius-card); background: var(--smoke); overflow: hidden; }
  .members { max-height: 180px; overflow-y: auto; padding: var(--space-4) 0; }
  .member { display: flex; align-items: center; gap: var(--space-8); padding: var(--space-4) var(--space-12); font: var(--text-control); font-weight: 400; color: var(--text-strong); }
  .row { display: flex; align-items: center; gap: var(--space-8); padding: var(--space-8) var(--space-12); border: 0; border-radius: 0; background: transparent; text-align: left; font: var(--text-control); font-weight: 400; color: var(--paper); }
  .row + .row { border-top: 1px solid var(--separator); }
  .row:hover:not(:disabled) { background: var(--row-hover); border-color: var(--separator); }
  .row.danger { color: var(--coral); }
  .text { padding: var(--space-8) var(--space-12); }
  .text p, .bio { margin: 0; font: var(--text-body); color: var(--paper); user-select: text; white-space: pre-wrap; }
  .rules { display: flex; flex-direction: column; gap: var(--space-4); font: var(--text-detail); color: var(--text2); }
  .member em { margin-left: auto; font-style: normal; font: var(--text-caption); color: var(--mint); }
  .fact { display: flex; flex-direction: column; gap: var(--space-2); }
  .fact span { font: var(--text-caption); color: var(--text3); }
  .fact b { font: var(--text-control); font-weight: 400; color: var(--paper); user-select: text; }
  .row.group { gap: var(--space-12); }
  .gtext { display: flex; flex-direction: column; flex: 1; min-width: 0; }
  .gtext strong { font: var(--text-control); color: var(--paper); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .gtext small { font: var(--text-caption); color: var(--text3); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .person { padding: var(--space-8) var(--space-12); gap: var(--space-8); }
  .field { display: flex; align-items: center; justify-content: space-between; gap: var(--space-8); font: var(--text-control); font-weight: 400; color: var(--paper); }
  .field input { width: auto; }
  .person textarea { resize: vertical; min-height: 40px; font: var(--text-detail); }
</style>
