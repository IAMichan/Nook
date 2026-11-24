<script lang="ts">
  // People across every chat app (`ChatPeople`, `ChatPeopleView` on the Mac): everyone you have a private chat with,
  // deduplicated across apps, searchable by name, app, handle or your own notes, with a detail card for their chats,
  // birthday and personal note. Notes and birthdays share the same `person_note` store as `ChatInfo` and Today.
  import { invoke } from "@tauri-apps/api/core";
  import { listen } from "@tauri-apps/api/event";
  import {
    aggregatePeople,
    appName,
    chatApps,
    clockOrDay,
    formatBirthday,
    isBirthdayToday,
    searchPeople,
    type ChatEntry,
    type ChatPerson,
    type PersonNoteData,
  } from "../../lib/chats-list";
  import { tr } from "../../lib/i18n.svelte";
  import CountBadge from "../../components/ui/CountBadge.svelte";
  import Ico from "../../components/ui/Ico.svelte";
  import IconButton from "../../components/ui/IconButton.svelte";
  import ListEmptyNote from "../../components/ui/ListEmptyNote.svelte";
  import SearchField from "../../components/ui/SearchField.svelte";
  import ServiceIcon from "../connectors/ServiceIcon.svelte";
  import ChatFace from "./ChatFace.svelte";

  let { entries, now, onopenchat }: {
    entries: ChatEntry[];
    now: Date;
    onopenchat: (entry: ChatEntry) => void;
  } = $props();

  let query = $state("");
  let selectedId = $state<string | null>(null);
  let notes = $state<Record<string, PersonNoteData>>({});

  const people = $derived(aggregatePeople(entries));
  const filtered = $derived(searchPeople(people, query, notes));

  /** Picks the chat key that holds this person's note/birthday (or their newest chat when none exists yet). */
  function noteKeyOf(person: ChatPerson): string {
    for (const c of person.chats) {
      const n = notes[c.key];
      if (n && (n.note.trim() || n.birthday)) return c.key;
    }
    return person.primaryChat.key;
  }

  function noteOf(person: ChatPerson): PersonNoteData {
    return notes[noteKeyOf(person)] ?? { note: "", birthday: null };
  }

  async function loadNotes(keys: string[]) {
    const unique = [...new Set(keys)];
    if (!unique.length) return;
    const loaded = await Promise.all(
      unique.map(async (key) => {
        try {
          const data = await invoke<PersonNoteData>("person_note", { key });
          return [key, data] as const;
        } catch {
          return null;
        }
      }),
    );
    const next = { ...notes };
    for (const pair of loaded) {
      if (pair) next[pair[0]] = pair[1];
    }
    notes = next;
  }

  // Fetch person notes whenever the set of private chat keys changes or another view updates them.
  const chatKeys = $derived(people.flatMap((p) => p.chats.map((c) => c.key)));
  const chatKeysSignature = $derived(chatKeys.join("\n"));
  $effect(() => {
    void chatKeysSignature;
    loadNotes(chatKeys);
  });
  $effect(() => {
    const off = listen("person-notes", () => loadNotes(chatKeys));
    return () => { off.then((f) => f()); };
  });

  const birthdaysToday = $derived(people.filter((p) => isBirthdayToday(noteOf(p).birthday, now)));
  const selected = $derived(
    (selectedId ? people.find((p) => p.id === selectedId) : null) ?? filtered[0] ?? null,
  );

  // Local editing buffers for the currently selected person's note and birthday.
  let editKey = $state<string | null>(null);
  let draftNote = $state("");
  let draftBirthday = $state("");
  let saved = $state(false);
  let saveTimer: ReturnType<typeof setTimeout> | null = null;

  $effect(() => {
    const person = selected;
    if (!person) {
      editKey = null;
      draftNote = "";
      draftBirthday = "";
      return;
    }
    const key = noteKeyOf(person);
    const data = notes[key] ?? { note: "", birthday: null };
    if (key !== editKey) {
      editKey = key;
      draftNote = data.note;
      draftBirthday = data.birthday ? `2024-${data.birthday}` : "";
      saved = false;
    }
  });

  async function persist(key: string, note: string, birthdayInput: string) {
    const birthday = birthdayInput ? birthdayInput.slice(5) : null;
    notes = { ...notes, [key]: { note, birthday } };
    try {
      await invoke("person_note_set", { key, note, birthday });
      saved = true;
    } catch {
      // Kept locally until next attempt.
    }
  }

  function scheduleSave() {
    if (!editKey) return;
    saved = false;
    const key = editKey;
    const note = draftNote;
    const birthday = draftBirthday;
    if (saveTimer) clearTimeout(saveTimer);
    saveTimer = setTimeout(() => {
      saveTimer = null;
      persist(key, note, birthday);
    }, 450);
  }

  function flushSave() {
    if (!editKey) return;
    if (saveTimer) {
      clearTimeout(saveTimer);
      saveTimer = null;
    }
    persist(editKey, draftNote, draftBirthday);
  }

  function clearBirthday() {
    if (!editKey) return;
    draftBirthday = "";
    flushSave();
  }
</script>

<section class="list" aria-label={tr("Mensen", "People")}>
  <header class="list-head" data-tauri-drag-region>
    <span class="list-title" data-tauri-drag-region>{tr("Mensen", "People")}</span>
    <span class="spacer" data-tauri-drag-region></span>
    {#if people.length}<span class="total">{people.length}</span>{/if}
  </header>

  <div class="search">
    <SearchField bind:value={query} placeholder={tr("Zoek mensen of notities", "Search people or notes")} />
  </div>

  {#if birthdaysToday.length && !query.trim()}
    <div class="birthday-banner">
      <span class="banner-label"><Ico name="calendar" size={12} stroke={2.2} />{tr("Vandaag jarig", "Birthday today")}</span>
      <div class="banner-chips">
        {#each birthdaysToday as b (b.id)}
          <button type="button" class="banner-chip" onclick={() => (selectedId = b.id)}>{b.name}</button>
        {/each}
      </div>
    </div>
  {/if}

  <div class="rows">
    {#each filtered as person, i (person.id)}
      {@const data = noteOf(person)}
      {@const bdayToday = isBirthdayToday(data.birthday, now)}
      {@const bdayText = formatBirthday(data.birthday)}
      {@const isSelected = selected?.id === person.id}
      {#if i > 0}<div class="separator" aria-hidden="true"></div>{/if}
      <button type="button" class="person-row" class:selected={isSelected} aria-current={isSelected ? "true" : undefined} onclick={() => (selectedId = person.id)}>
        <ChatFace id={person.primaryChat.id} app={person.primaryChat.app} name={person.name} size={40} badge={person.apps.length === 1} />
        <span class="what">
          <span class="top">
            <span class="name">{person.name}</span>
            <span class="when">{clockOrDay(person.last, now)}</span>
          </span>
          <span class="meta">
            <span class="app-icons">
              {#each person.apps as a (a)}
                <span class="app-icon" title={appName(a)}><ServiceIcon domain={chatApps[a]?.domain ?? null} title={appName(a)} size={13} /></span>
              {/each}
            </span>
            {#if bdayText}
              <span class="bday-pill" class:today={bdayToday}><Ico name="calendar" size={10} stroke={2.2} />{bdayToday ? tr("Vandaag jarig", "Birthday today") : bdayText}</span>
            {/if}
            <span class="spacer"></span>
            {#if person.unread > 0}<CountBadge count={person.unread} />{/if}
          </span>
          {#if data.note.trim()}
            <span class="note-preview">{data.note.trim()}</span>
          {/if}
        </span>
      </button>
    {:else}
      <div class="list-empty">
        <ListEmptyNote text={query.trim() ? tr("Geen mensen gevonden", "No people found") : tr("Nog geen contacten uit je chats.", "No people from your chats yet.")} />
      </div>
    {/each}
  </div>
</section>

<section class="detail">
  {#if selected}
    {@const data = noteOf(selected)}
    {@const bdayToday = isBirthdayToday(data.birthday, now)}
    {@const bdayText = formatBirthday(data.birthday)}
    <div class="card-scroll">
      <header class="person-head" data-tauri-drag-region>
        <ChatFace id={selected.primaryChat.id} app={selected.primaryChat.app} name={selected.name} size={64} badge={false} />
        <div class="person-title">
          <h2>{selected.name}</h2>
          <div class="person-sub">
            {#if selected.handle}<span>{selected.handle}</span>{/if}
            {#if selected.handle && selected.last}<span aria-hidden="true">·</span>{/if}
            {#if selected.last}<span>{tr("Laatste bericht {time}", "Last message {time}", { time: clockOrDay(selected.last, now) })}</span>{/if}
          </div>
          {#if bdayText}
            <span class="bday-pill large" class:today={bdayToday}>
              <Ico name="calendar" size={12} stroke={2.2} />
              {bdayToday ? tr("Vandaag jarig", "Birthday today") : bdayText}
            </span>
          {/if}
        </div>
      </header>

      <div class="section">
        <span class="section-title">{tr("Chats", "Chats")}</span>
        <div class="card">
          {#each selected.chats as chat (chat.key)}
            <button type="button" class="chat-jump" onclick={() => onopenchat(chat)}>
              <span class="jump-icon"><ServiceIcon domain={chatApps[chat.app]?.domain ?? null} title={appName(chat.app)} size={18} /></span>
              <span class="jump-what">
                <span class="jump-top">
                  <span class="jump-app">{appName(chat.app)}{#if chat.account} · {chat.account}{/if}</span>
                  <span class="when">{clockOrDay(chat.last, now)}</span>
                </span>
                <span class="jump-preview">{chat.preview || tr("Open chat", "Open chat")}</span>
              </span>
              {#if chat.unread > 0}<CountBadge count={chat.unread} />{/if}
              <span class="jump-arrow"><Ico name="chevron-right" size={14} stroke={2.2} /></span>
            </button>
          {/each}
        </div>
      </div>

      <div class="section">
        <div class="section-head">
          <span class="section-title">{tr("Over {name}", "About {name}", { name: selected.name })}</span>
          {#if saved}<span class="saved">{tr("Opgeslagen", "Saved")}</span>{/if}
        </div>
        <div class="card form">
          <label class="field">
            <span class="field-label"><Ico name="calendar" size={14} stroke={2} />{tr("Verjaardag", "Birthday")}</span>
            <span class="date-controls">
              <input type="date" bind:value={draftBirthday} onchange={flushSave} aria-label={tr("Verjaardag", "Birthday")} />
              {#if draftBirthday}
                <IconButton title={tr("Wis verjaardag", "Clear birthday")} size={22} onclick={clearBirthday}><Ico name="x" size={12} stroke={2.4} /></IconButton>
              {/if}
            </span>
          </label>
          <div class="note-block">
            <label class="field-label" for="person-note-field"><Ico name="notebook-pen" size={14} stroke={2} />{tr("Notitie", "Note")}</label>
            <textarea
              id="person-note-field"
              rows="4"
              bind:value={draftNote}
              oninput={scheduleSave}
              onblur={flushSave}
              placeholder={tr("Een notitie voor jezelf", "A note for yourself")}
              aria-label={tr("Notitie", "Note")}
            ></textarea>
          </div>
        </div>
      </div>
    </div>
  {:else}
    <div class="placeholder" data-tauri-drag-region>
      <span class="placeholder-icon"><Ico name="users" size={30} stroke={1.4} /></span>
      <span class="placeholder-title">{tr("Kies iemand", "Pick a person")}</span>
      <span class="placeholder-detail">{tr("Bekijk hun chats, verjaardag en je eigen notitie.", "See their chats, birthday and your own note.")}</span>
    </div>
  {/if}
</section>

<style>
  .list { flex: none; width: 334px; min-height: 0; display: flex; flex-direction: column; gap: var(--space-8); padding: 0 var(--space-4) 0 var(--space-8); border-right: 1px solid var(--border); box-sizing: border-box; }
  .list-head { display: flex; align-items: center; gap: var(--space-6); height: 30px; padding: 11px var(--space-8) 0 var(--space-12); flex: none; }
  .list-title { font: var(--text-title); color: var(--paper); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .total { font: var(--text-caption); font-variant-numeric: tabular-nums; color: var(--text3); }
  .spacer { flex: 1; }
  .search { padding: 0 var(--space-4); flex: none; }
  .search :global(.search) { background: var(--field); border-color: transparent; }

  .birthday-banner { flex: none; display: flex; flex-direction: column; gap: var(--space-6); margin: 0 var(--space-4); padding: var(--space-8) var(--space-12); border-radius: var(--radius-card); background: color-mix(in srgb, var(--amber) 12%, transparent); border: 1px solid color-mix(in srgb, var(--amber) 28%, transparent); }
  .banner-label { display: inline-flex; align-items: center; gap: var(--space-6); font: var(--text-label); color: var(--amber); }
  .banner-chips { display: flex; flex-wrap: wrap; gap: var(--space-4); }
  .banner-chip { padding: var(--space-2) var(--space-8); border: 0; border-radius: var(--radius-chip); background: var(--surface); color: var(--paper); font: var(--text-caption); font-weight: 600; }
  .banner-chip:hover:not(:disabled) { background: var(--row-hover); border: 0; }

  .rows { flex: 1; min-height: 0; overflow-y: auto; display: flex; flex-direction: column; gap: var(--space-2); padding-bottom: var(--space-12); }
  .separator { height: 1px; margin: var(--space-2) var(--space-12); background: var(--separator); flex: none; }
  .person-row { display: flex; align-items: flex-start; gap: var(--space-8); width: 100%; padding: var(--space-8) var(--space-12); border: 0; border-radius: var(--radius-card); background: transparent; text-align: left; color: inherit; }
  .person-row:hover:not(:disabled) { background: var(--row-hover); border: 0; }
  .person-row.selected, .person-row.selected:hover:not(:disabled) { background: var(--row-selected); }
  .what { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: var(--space-4); }
  .top { display: flex; align-items: baseline; gap: var(--space-6); min-width: 0; }
  .name { flex: 1; min-width: 0; font: var(--text-emphasis); line-height: 1.3; color: var(--paper); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .when { flex: none; font: var(--text-caption); font-variant-numeric: tabular-nums; color: var(--text3); }
  .meta { display: flex; align-items: center; gap: var(--space-6); min-width: 0; }
  .app-icons { display: inline-flex; align-items: center; gap: var(--space-4); flex: none; }
  .app-icon { display: inline-flex; }
  .bday-pill { display: inline-flex; align-items: center; gap: var(--space-4); padding: var(--space-2) var(--space-6); border-radius: var(--radius-chip); background: var(--smoke); color: var(--text2); font: var(--text-caption); white-space: nowrap; }
  .bday-pill.today { background: color-mix(in srgb, var(--amber) 18%, transparent); color: var(--amber); font-weight: 600; }
  .bday-pill.large { align-self: flex-start; margin-top: var(--space-4); padding: var(--space-4) var(--space-8); }
  .note-preview { font: var(--text-detail); color: var(--text3); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .list-empty { padding-top: var(--space-16); text-align: center; }

  .detail { flex: 1; min-width: 0; min-height: 0; padding-left: var(--space-16); padding-right: var(--space-16); display: flex; flex-direction: column; }
  .card-scroll { flex: 1; min-height: 0; overflow-y: auto; display: flex; flex-direction: column; gap: var(--space-20); padding: var(--space-20) 0 var(--space-24); max-width: 600px; width: 100%; }
  .person-head { display: flex; align-items: center; gap: var(--space-16); }
  .person-title { min-width: 0; flex: 1; display: flex; flex-direction: column; gap: var(--space-4); }
  .person-title h2 { margin: 0; font: var(--text-heading); color: var(--paper); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; user-select: text; }
  .person-sub { display: flex; flex-wrap: wrap; align-items: center; gap: var(--space-6); font: var(--text-detail); color: var(--text3); user-select: text; }

  .section { display: flex; flex-direction: column; gap: var(--space-8); }
  .section-head { display: flex; align-items: center; justify-content: space-between; gap: var(--space-8); }
  .section-title { font: var(--text-label); color: var(--text2); }
  .saved { font: var(--text-caption); color: var(--mint); }
  .card { display: flex; flex-direction: column; border-radius: var(--radius-card); background: var(--surface); border: 1px solid var(--hairline); overflow: hidden; }

  .chat-jump { display: flex; align-items: center; gap: var(--space-12); width: 100%; padding: var(--space-12); border: 0; border-radius: 0; background: transparent; text-align: left; color: inherit; }
  .chat-jump + .chat-jump { border-top: 1px solid var(--separator); }
  .chat-jump:hover:not(:disabled) { background: var(--row-hover); border-color: var(--separator); }
  .jump-icon { flex: none; display: inline-flex; }
  .jump-what { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: var(--space-2); }
  .jump-top { display: flex; align-items: baseline; justify-content: space-between; gap: var(--space-8); }
  .jump-app { font: var(--text-emphasis); color: var(--paper); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .jump-preview { font: var(--text-detail); color: var(--text2); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .jump-arrow { flex: none; display: inline-flex; color: var(--text3); }

  .form { padding: var(--space-12); gap: var(--space-12); }
  .field { display: flex; align-items: center; justify-content: space-between; gap: var(--space-12); }
  .field-label { display: inline-flex; align-items: center; gap: var(--space-6); font: var(--text-control); color: var(--text-strong); }
  .date-controls { display: inline-flex; align-items: center; gap: var(--space-6); }
  .date-controls input { width: auto; }
  .note-block { display: flex; flex-direction: column; gap: var(--space-6); padding-top: var(--space-8); border-top: 1px solid var(--separator); }
  .note-block textarea { width: 100%; box-sizing: border-box; resize: vertical; min-height: 88px; font: var(--text-body); }

  .placeholder { height: 100%; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: var(--space-6); text-align: center; }
  .placeholder-icon { color: var(--text-muted); }
  .placeholder-title { font: var(--text-body); color: var(--text2); }
  .placeholder-detail { font: var(--text-detail); color: var(--text3); }
</style>
