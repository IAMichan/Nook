<script lang="ts">
  // One session as the iPhone app opens it (`SessionDetailView`): "folder / title ⌄" opening what you can do with it, the
  // conversation (live with a computer that keeps a connection, else asked every few seconds), "Working for 12s"
  // floating over its end, what waits on you in the composer's place (deny with a reason in its own field), and the
  // composer, which offers Steer now or After this turn while the agent works.
  import { onDestroy, untrack } from "svelte";
  import {
    applyTimeline, canStop, companion, followsLive, has, may, writingWaits, Feature,
    type ClientView, type DigestItem, type SessionDigest, type TimelineEntry,
  } from "../../lib/companion";
  import { renderMarkdown } from "../../lib/markdown";
  import { tr } from "../../lib/i18n.svelte";
  import { haptic } from "../../lib/haptics";
  import { duration } from "../../lib/transcript";
  import NavBar from "./ui/NavBar.svelte";
  import Ico from "../../components/ui/Ico.svelte";
  import PulseDot from "../../components/ui/PulseDot.svelte";
  import DecisionButton from "./ui/DecisionButton.svelte";
  import SessionComposer from "./ui/SessionComposer.svelte";
  import ComposerPill from "./ui/ComposerPill.svelte";
  import EmptyState from "../../components/ui/EmptyState.svelte";
  import Menu, { type MenuItem } from "../../components/ui/Menu.svelte";
  import Dialog from "../../components/ui/Dialog.svelte";
  import ConversationScroll from "./ConversationScroll.svelte";
  import TranscriptView from "./TranscriptView.svelte";
  import ChangesView from "./ChangesView.svelte";
  import FilesView from "./FilesView.svelte";
  import SnoozePicker from "./SnoozePicker.svelte";
  import TerminalsView from "./TerminalsView.svelte";
  import PhotoButton from "./ui/PhotoButton.svelte";
  import ImageTray from "./ui/ImageTray.svelte";
  import PullRequests from "./PullRequests.svelte";
  import Sheet from "../../components/ui/Sheet.svelte";
  import { withReviewComment } from "../../lib/patch";
  import { activeMac, cacheFor, kept, recordTimeline, saveSoon } from "../../lib/companion-cache";
  import OfflineStrip from "./ui/OfflineStrip.svelte";
  import OfflineNote from "./ui/OfflineNote.svelte";
  import SessionPrompt from "./SessionPrompt.svelte";
  import QuestionFlow from "./QuestionFlow.svelte";
  import { HEADER_MENU } from "../../lib/companion-sessions";
  import { sessionMenu } from "./session-menu";

  let { view, id, fallback, onback, onopen, act, took }: {
    view: ClientView;
    id: string;
    /** An older session the live list does not hold (from `history`), shown until a message moves it back. */
    fallback?: SessionDigest;
    onback: () => void;
    /** Another session to open (a fork of this one). */
    onopen?: (id: string) => void;
    act: (f: () => Promise<ClientView>) => Promise<void>;
    took: (v: ClientView) => void;
  } = $props();

  const session = $derived(view.sessions.find((s) => s.id === id) ?? fallback ?? null);
  const hasTimeline = $derived(has(view, Feature.timeline));
  const live = $derived(followsLive(view, Feature.liveTimeline));
  const canOperate = $derived(may(view, "operate"));
  const canApprove = $derived(may(view, "approve"));
  const working = $derived(session?.attention === "working");
  const steerable = $derived(has(view, Feature.steer) && session?.canSteer === true);
  const item = $derived(session?.items[0] ?? null);

  // The conversation as the phone kept it (`companion-cache.ts`), until the computer answers.
  let entries = $state<TimelineEntry[]>(untrack(() => kept(cacheFor(activeMac(view))?.timelines ?? [], id) ?? []));
  const offline = $derived(view.phase === "offline");
  $effect(() => {
    const mac = activeMac(view);
    const cache = cacheFor(mac);
    if (!cache || offline || !loaded || !entries.length) return;
    if (recordTimeline(cache, id, entries, Date.now() / 1000)) saveSoon(mac);
  });
  let loaded = $state(false);
  let message = $state("");
  let reason = $state("");
  let answer = $state("");
  let sending = $state(false);
  let steer = $state(readSteer());
  let menu = $state<DOMRect | null>(null);
  let steerMenu = $state<DOMRect | null>(null);
  let dialog = $state<null | { kind: "stop" | "end" | "archive" } | { kind: "rename"; name: string }>(null);
  let now = $state(Date.now() / 1000);
  let titleEl = $state<HTMLButtonElement | null>(null);
  let sub = $state<null | "changes" | "pulls" | "files" | "terminals">(null);
  let images = $state<string[]>([]);
  let picking = $state(false);
  // Earlier entries asked for page by page, kept beside the live conversation so an update never drops them.
  let earlier = $state<TimelineEntry[]>([]);
  let atStart = $state(false);
  let loadingEarlier = $state(false);
  const fullTranscript = $derived(has(view, Feature.fullTranscript));
  const shown = $derived([...earlier.filter((e) => !entries.some((x) => x.id === e.id)), ...entries]);
  async function loadEarlier() {
    const oldest = shown[0];
    if (!oldest || loadingEarlier) return;
    loadingEarlier = true;
    const r = await companion.call({ op: "timeline", session: id, item: oldest.id });
    loadingEarlier = false;
    const page = r.response?.timeline ?? [];
    if (!page.length) atStart = true;
    earlier = [...page, ...earlier];
  }
  async function readWhole(entry: TimelineEntry) {
    const r = await companion.call({ op: "entry", session: id, item: entry.id });
    const text = r.response?.entryText;
    if (!text) return took(r.view);
    const swap = (list: TimelineEntry[]) => list.map((e) => (e.id === entry.id ? { ...e, text, clipped: false } : e));
    entries = swap(entries);
    earlier = swap(earlier);
  }
  const canPicture = $derived(has(view, Feature.images));
  const tooLarge = () => took({ ...view, notice: tr("Die foto kon niet klein genoeg worden gemaakt.", "That picture could not be made small enough.") });
  let moreMenu = $state<DOMRect | null>(null);
  const showChanges = $derived(has(view, Feature.diff) && may(view, "read") && session?.canSend !== false);
  const showPulls = $derived(has(view, Feature.pullRequests) && may(view, "read"));
  // Files and terminals need the right to operate, and only for sessions Nook runs on this Mac.
  const showWorkspace = $derived(has(view, Feature.workspace) && may(view, "operate") && session?.canSend !== false);

  function readSteer(): boolean {
    try { return localStorage.getItem("companion.steer") === "1"; } catch { return false; }
  }
  function setSteer(on: boolean) {
    steer = on;
    try { localStorage.setItem("companion.steer", on ? "1" : "0"); } catch { /* remembered for this visit */ }
  }

  // The conversation: watched live (the computer sends what changes), or asked every three seconds.
  async function watch() {
    const r = await companion.call(live ? { op: "watch", session: id } : { op: "timeline", session: id });
    if (r.response?.timeline) entries = applyTimeline(entries, r.response.timeline, r.response.timelineAfter) ?? r.response.timeline;
    loaded = true;
  }
  $effect(() => {
    if (!hasTimeline) return;
    void id;
    untrack(watch);
    if (live) {
      const un = companion.onLive((r) => {
        if (!r.timeline || r.timelineSession !== id) return;
        const next = applyTimeline(entries, r.timeline, r.timelineAfter);
        if (next) entries = next;
        else untrack(watch);
      });
      return () => un.then((f) => f());
    }
    const timer = setInterval(() => document.visibilityState === "visible" && watch(), 3000);
    return () => clearInterval(timer);
  });
  onDestroy(() => {
    if (untrack(() => live)) companion.call({ op: "watch" });
  });
  $effect(() => {
    if (!working) return;
    const timer = setInterval(() => (now = Date.now() / 1000), 1000);
    return () => clearInterval(timer);
  });
  const queued = $derived((view.outbox ?? []).filter((q) => q.op === "send" && q.session === id));
  const turnStart = $derived([...entries].reverse().find((e) => e.kind === "user")?.date ?? null);

  async function send(text: string) {
    if (!session || sending) return;
    sending = true;
    haptic();
    const steering = steerable && steer;
    const r = await companion.call({ op: "send", session: session.id, text, steer: steering || undefined, turn: steering ? session.turn : undefined, images: images.length ? images.map((jpeg) => ({ jpeg })) : undefined });
    sending = false;
    took(r.view);
    if (r.response) {
      message = "";
      images = [];
      haptic("success");
      if (!live) watch();
    }
  }

  function decide(target: DigestItem, allow: boolean) {
    if (!session) return;
    haptic(allow ? "success" : "warning");
    act(() => companion.decide(session.id, target.id, allow));
  }
  // "Always allow" and every question at once (`agentsTab`).
  const agentsTab = $derived(has(view, Feature.agentsTab));
  async function allowAlways(target: DigestItem) {
    if (!session) return;
    haptic("success");
    const r = await companion.call({ op: "decide", session: session.id, item: target.id, allow: true, decision: "always" });
    took(r.view);
  }
  async function answerAll(answers: Record<string, string[]>) {
    if (!session || !item) return;
    const r = await companion.call({ op: "answer", session: session.id, item: item.id, answers });
    took(r.view);
  }
  const flow = $derived(agentsTab && item?.kind === "question" && !!item.questions?.length
    && (item.questions.length > 1 || item.questions[0].multiSelect) ? item.questions : null);
  let prompt = $state<"rename" | "delete" | "end" | null>(null);
  let controlsMenu = $state<DOMRect | null>(null);
  const controls = $derived(session?.controls ?? null);
  const controlActions = $derived(["setMode", "setEffort", "setModel"].filter((a) => actions.has(a)));
  const controlsWord = $derived.by(() => {
    if (!controls) return "";
    const parts: string[] = [];
    if (controls.mode === "plan") parts.push(tr("Plan", "Plan"));
    const effort = controls.effort ? controls.efforts?.find((e) => e.id === controls.effort)?.name : undefined;
    if (effort) parts.push(effort);
    if (!parts.length) { const m = controls.models?.find((x) => x.id === (controls.model ?? ""))?.name; if (m) parts.push(m); }
    return parts.length ? parts.join(" · ") : tr("Opties", "Options");
  });
  const controlSections = $derived.by<MenuItem[][]>(() => {
    if (!controls) return [];
    return [
      actions.has("setMode") && controls.mode ? [
        { label: tr("Agent", "Agent"), checked: controls.mode === "agent", onselect: () => manage("setMode", "agent") },
        { label: tr("Plan", "Plan"), checked: controls.mode === "plan", onselect: () => manage("setMode", "plan") },
      ] : [],
      actions.has("setEffort") ? (controls.efforts ?? []).map((e) => ({ label: e.name, detail: e.id ? undefined : tr("Inspanning", "Effort"), checked: e.id === (controls.effort ?? ""), onselect: () => manage("setEffort", e.id) })) : [],
      actions.has("setModel") ? (controls.models ?? []).map((m) => ({ label: m.name, checked: m.id === (controls.model ?? ""), onselect: () => manage("setModel", m.id) })) : [],
    ];
  });
  function denyWithReason(text: string) {
    if (!session || !item) return;
    reason = "";
    haptic("warning");
    act(() => companion.deny(session.id, item.id, text));
  }
  function answerWith(text: string) {
    if (!session || !item) return;
    answer = "";
    haptic("success");
    act(() => companion.answer(session.id, item.id, text));
  }

  async function stop() {
    if (!session) return;
    const r = await companion.call({ op: "stop", session: session.id, turn: session.turn });
    took(r.view);
  }
  async function manage(action: string, text?: string) {
    if (!session) return;
    haptic();
    const r = await companion.call({ op: "manage", session: session.id, item: action, text });
    took(r.view);
    if (r.response && (action === "archive" || action === "end" || action === "delete" || action === "deleteWithWorktree")) onback();
    return r.response;
  }

  const actions = $derived(new Set(session && has(view, Feature.manage) && canOperate ? (session.actions ?? []) : []));
  const canStopIt = $derived(!!session && canOperate && session.canSend !== false && canStop(session.attention));
  const menuSections = $derived.by<MenuItem[][]>(() => {
    if (!session) return [];
    // The Mac's header menu, in its order (`HEADER_MENU`), on a computer with the Agents tab.
    if (agentsTab) {
      return [
        canStopIt ? [{ label: tr("Stop", "Stop"), icon: "circle-stop", destructive: true, onselect: () => (dialog = { kind: "stop" }) }] : [],
        ...sessionMenu(HEADER_MENU, session, [...actions], {
          run: (action) => void manage(action),
          ask: (kind) => (prompt = kind),
          pickTime: () => (picking = true),
          fork: async () => { const created = (await manage("fork"))?.created; if (created) onopen?.(created); },
        }),
      ];
    }
    const snooze: MenuItem[] = actions.has("unsnooze")
      ? [{ label: tr("Snooze opheffen", "Cancel snooze"), icon: "alarm-clock", onselect: () => manage("unsnooze") }]
      : [
          ...(actions.has("snoozeHour") ? [{ label: tr("Een uur", "One hour"), icon: "clock", onselect: () => manage("snoozeHour") }] : []),
          ...(actions.has("snoozeEvening") ? [{ label: tr("Vanavond", "This evening"), icon: "clock", onselect: () => manage("snoozeEvening") }] : []),
          ...(actions.has("snoozeTomorrow") ? [{ label: tr("Morgenochtend", "Tomorrow morning"), icon: "clock", onselect: () => manage("snoozeTomorrow") }] : []),
          ...(actions.has("snoozeLimitReset") && session.limitResetsAt ? [{ label: tr("Tot de limiet reset", "Until the limit resets"), icon: "gauge", onselect: () => manage("snoozeLimitReset") }] : []),
          ...(actions.has("snoozeUntil") ? [{ label: tr("Kies een moment…", "Pick a time…"), icon: "calendar-clock", onselect: () => (picking = true) }] : []),
        ];
    return [
      [
        ...(canStopIt ? [{ label: tr("Stop", "Stop"), icon: "circle-stop", destructive: true, onselect: () => (dialog = { kind: "stop" }) }] : []),
        ...(actions.has("end") ? [{ label: tr("Beëindig sessie", "End session"), icon: "circle-x", destructive: true, onselect: () => (dialog = { kind: "end" }) }] : []),
      ],
      snooze,
      [
        ...(actions.has("mainThreadOn") ? [{ label: tr("Hoofdthread maken", "Make main thread"), icon: "git-branch", onselect: () => manage("mainThreadOn") }] : []),
        ...(actions.has("mainThreadOff") ? [{ label: tr("Hoofdthread uitzetten", "Stop main thread"), icon: "git-branch", onselect: () => manage("mainThreadOff") }] : []),
        ...(actions.has("rename") ? [{ label: tr("Hernoem", "Rename"), icon: "pencil", onselect: () => (dialog = { kind: "rename", name: session.title }) }] : []),
      ],
      actions.has("archive") ? [{ label: tr("Archiveer", "Archive"), icon: "archive", destructive: true, onselect: () => (dialog = { kind: "archive" }) }] : [],
    ];
  });
  const hasMenu = $derived(menuSections.some((s) => s.length));
</script>

<div class="session">
{#if sub === "files" && session}
  <FilesView {view} session={session.id} onback={() => (sub = null)} {took} />
{:else if sub === "terminals" && session}
  <TerminalsView session={session.id} onback={() => (sub = null)} {took} />
{:else if sub === "changes" && session}
  <ChangesView session={session.id} onback={() => (sub = null)} {took} oncomment={(block) => { message = withReviewComment(message, block); sub = null; }} />
{:else}
  <NavBar onback={onback}>
    {#snippet trailing()}
      {#if showChanges}<button class="navbtn" aria-label={tr("Wijzigingen", "Changes")} onclick={() => { haptic(); sub = "changes"; }}><Ico name="diff" size={19} /></button>{/if}
      {#if showPulls || showWorkspace}<button class="navbtn" aria-label={tr("Bestanden, terminals en pull requests", "Files, terminals and pull requests")} onclick={(e) => (moreMenu = (e.currentTarget as HTMLElement).getBoundingClientRect())}><Ico name="circle-ellipsis" size={19} /></button>{/if}
    {/snippet}
    {#snippet center()}
      <button bind:this={titleEl} class="title" disabled={!hasMenu} onclick={() => titleEl && (menu = titleEl.getBoundingClientRect())}>
        {#if session}
          <span class="l1"><span class="folder">{session.folder} /</span> <span class="name">{session.title}</span>{#if hasMenu}<span class="chev"><Ico name="chevron-down" size={10} stroke={3} /></span>{/if}</span>
          <span class="l2">{session.agent}{session.branch ? ` · ${session.branch}` : ""}</span>
        {/if}
      </button>
    {/snippet}
  </NavBar>

  {#if !session}
    <EmptyState icon="inbox" title={tr("Deze sessie is er niet meer.", "This session is gone.")} text={tr("Hij is op je Mac gesloten of gearchiveerd.", "It was closed or archived on your Mac.")} />
  {:else}
    <div class="body">
      <ConversationScroll version={[entries.length, entries[entries.length - 1]?.text.length, session.attention, session.excerpt]} reserve={working ? 56 : 0}>
        {#if hasTimeline}
          {#if offline && !entries.length && !queued.length}
            <OfflineNote>{tr("Dit gesprek staat nog niet op deze telefoon. Het opent zodra je Mac verbonden is.", "This conversation is not kept on this phone yet. It opens once your Mac is connected.")}</OfflineNote>
          {:else if !loaded && !entries.length}
            <div class="loading breathe"><span style:width="90%"></span><span style:width="70%"></span><span style:width="80%"></span></div>
          {:else}
            {#if fullTranscript && shown.length && !atStart}
              <button class="earlier" onclick={loadEarlier} disabled={loadingEarlier}>{#if loadingEarlier}<span class="mini"></span>{:else}<Ico name="arrow-up" size={13} />{/if}{tr("Eerdere berichten", "Earlier messages")}</button>
            {/if}
            <TranscriptView entries={shown} {working} onwhole={fullTranscript ? readWhole : undefined} onreply={canOperate && session.canSend !== false ? (t) => (message = "> " + t.split("\n").slice(0, 4).join("\n> ") + "\n\n" + message) : undefined} />
          {/if}
        {:else if session.excerpt}
          <h3 class="section">{tr("Laatste antwoord", "Latest reply")}</h3>
          <div class="markdown reply">{@html renderMarkdown(session.excerpt)}</div>
        {/if}
        {#each queued as q (q.id)}
          <div class="queued"><div class="qbubble">{q.text}</div><span class="qnote"><Ico name="clock" size={11} />{tr("Nog niet verstuurd · wacht op je Mac", "Not sent yet · waiting for your Mac")}<button onclick={async () => took(await companion.discard(q.id))}>{tr("Niet versturen", "Don’t send")}</button></span></div>
        {/each}
        {#snippet floating()}
          {#if working}
            <div class="floating"><PulseDot size={7} />{turnStart ? tr("Werkt al {d}", "Working for {d}", { d: duration(Math.max(0, now - turnStart)) }) : tr("Aan het werk", "Working")}</div>
          {/if}
        {/snippet}
      </ConversationScroll>
    </div>

    {#if item}
      <div class="pending">
        <OfflineStrip {view} kind="answers" />
        <div class="card">
          <span class="kind"><Ico name={item.kind === "approval" ? "hand" : "message-circle-question"} size={12} stroke={2.4} />{item.kind === "approval" ? tr("Goedkeuring nodig", "Approval needed") : tr("Wacht op je antwoord", "Waiting for your answer")}</span>
          <p class="ask">{item.title}</p>
          {#if item.detail}<code class="detail">{item.detail}</code>{/if}
          {#if !canApprove}
            <span class="note muted"><Ico name="lock" size={12} />{tr("Goedkeuren staat uit voor deze iPhone in Nook op je Mac.", "Approving is turned off for this phone in Nook on your Mac.")}</span>
          {:else if item.kind === "approval"}
            <div class="decide">
              <DecisionButton kind="deny" label={tr("Weiger", "Deny")} onclick={() => decide(item, false)} />
              {#if item.canAllow}<DecisionButton kind="allow" label={tr("Sta toe", "Allow")} onclick={() => decide(item, true)} />{/if}
            </div>
            {#if agentsTab && item.canAllow && item.canAlways}
              <button class="always press" onclick={() => allowAlways(item)}><Ico name="badge-check" size={15} />{tr("Altijd toestaan", "Always allow")}</button>
            {/if}
            {#if !item.canAllow}<span class="note"><Ico name="lock" size={12} />{tr("Dit is riskant of onbekend: toestaan kan alleen op je Mac.", "This is risky or unknown: it can only be allowed on your Mac.")}</span>{/if}
            <SessionComposer bind:value={reason} placeholder={tr("Of weiger met een reden", "Or deny with a reason")} onsend={denyWithReason} />
          {:else if flow}
            <QuestionFlow questions={flow} onsend={answerAll} />
          {:else if item.canAllow}
            <div class="options">
              {#each item.options as option, i (option)}
                <button class="option press" onclick={() => answerWith(option)}>
                  <span class="key">{i < 9 ? i + 1 : "·"}</span>
                  <span class="otext"><span>{option}</span>{#if item.optionPreviews?.[i]}<pre>{item.optionPreviews[i]}</pre>{/if}</span>
                </button>
              {/each}
            </div>
            <SessionComposer bind:value={answer} placeholder={tr("Je eigen antwoord", "Your own answer")} onsend={answerWith} />
          {:else}
            <span class="note"><Ico name="laptop" size={12} />{tr("Meerdere vragen tegelijk: beantwoord ze op je Mac.", "Several questions at once: answer them on your Mac.")}</span>
          {/if}
        </div>
        {#if session.items.length > 1}<span class="morewait">{tr("Hierna wachten er nog {n}", "{n} more wait after this one", { n: session.items.length - 1 })}</span>{/if}
      </div>
    {:else}
      <div class="dock">
        {#if canOperate && session.canSend !== false}<OfflineStrip {view} />{/if}
        {#if !canOperate}
          <div class="fieldcard"><Ico name="lock" size={12} />{tr("Berichten sturen staat uit voor deze iPhone in Nook op je Mac.", "Sending messages is turned off for this phone in Nook on your Mac.")}</div>
        {:else if session.canSend === false}
          <div class="fieldcard"><Ico name="terminal" size={12} />{tr("Deze agent draait in een terminal op je Mac; beantwoord hem daar.", "This agent runs in a terminal on your Mac; answer it there.")}</div>
        {:else}
          {#if session.queued?.length}
            <div class="line">
              <span class="linehead">{tr("Wacht op deze beurt", "Waiting for this turn")}</span>
              {#each session.queued as q (q.id)}
                <div class="qrow"><Ico name="clock" size={11} /><span class="qtext">{q.text}</span>
                  {#if actions.has("unqueue")}<button class="qremove" aria-label={tr("Uit de wachtrij halen", "Remove from the queue")} onclick={() => manage("unqueue", q.id)}><Ico name="x" size={12} /></button>{/if}
                </div>
              {/each}
            </div>
          {/if}
          <ImageTray {images} onremove={(i) => (images = images.filter((_, j) => j !== i))} />
          <div class="withphoto">
          {#if canPicture}<PhotoButton count={images.length} onpick={(more) => (images = [...images, ...more])} ontoolarge={tooLarge} />{/if}
          <div class="grow">
        {#if steerable}
          <SessionComposer bind:value={message} placeholder={steer ? tr("Stuur de agent bij", "Steer the agent") : tr("Bericht voor na deze beurt", "Message for after this turn")} onsend={send} {sending} canSend={!offline || writingWaits(view)}
            onstop={canStopIt ? () => (dialog = { kind: "stop" }) : undefined}>
            {#snippet controls()}
              <ComposerPill label={steer ? tr("Nu bijsturen", "Steer now") : tr("Na deze beurt", "After this turn")} icon={steer ? "corner-down-right" : "list"} onclick={(e) => (steerMenu = (e.currentTarget as HTMLElement).getBoundingClientRect())} />
              {#if agentsTab && controlActions.length}<ComposerPill label={controlsWord} icon="cpu" onclick={(e) => (controlsMenu = (e.currentTarget as HTMLElement).getBoundingClientRect())} />{/if}
            {/snippet}
          </SessionComposer>
        {:else if agentsTab && controlActions.length}
          <SessionComposer bind:value={message} placeholder={tr("Bericht aan de agent", "Message to the agent")} onsend={send} {sending} canSend={!offline || writingWaits(view)}
            onstop={canStopIt ? () => (dialog = { kind: "stop" }) : undefined}>
            {#snippet controls()}
              <ComposerPill label={controlsWord} icon="cpu" onclick={(e) => (controlsMenu = (e.currentTarget as HTMLElement).getBoundingClientRect())} />
            {/snippet}
          </SessionComposer>
        {:else}
          <SessionComposer bind:value={message} placeholder={tr("Bericht aan de agent", "Message to the agent")} onsend={send} {sending} canSend={!offline || writingWaits(view)}
            onstop={canStopIt ? () => (dialog = { kind: "stop" }) : undefined} />
        {/if}
          </div>
          </div>
        {/if}
      </div>
    {/if}
  {/if}
{/if}
</div>

{#if sub === "pulls" && session}
  <Sheet onclose={() => (sub = null)}><PullRequests {view} session={session.id} {took} onclose={() => (sub = null)} onstarted={() => (sub = null)} /></Sheet>
{/if}
{#if picking && session}
  <Sheet onclose={() => (picking = false)}><SnoozePicker title={session.title} onclose={() => (picking = false)} onpick={(at) => manage("snoozeUntil", String(at))} /></Sheet>
{/if}
{#if moreMenu}
  <Menu anchor={moreMenu} onclose={() => (moreMenu = null)} sections={[[
    ...(showWorkspace ? [{ label: tr("Bestanden", "Files"), icon: "folder", onselect: () => (sub = "files") }, { label: tr("Terminals", "Terminals"), icon: "terminal", onselect: () => (sub = "terminals") }] : []),
    ...(showPulls ? [{ label: tr("Pull requests", "Pull requests"), icon: "git-pull-request", onselect: () => (sub = "pulls") }] : []),
  ]]} />
{/if}
{#if menu}<Menu sections={menuSections} anchor={menu} onclose={() => (menu = null)} />{/if}
{#if controlsMenu}<Menu title={tr("Modus, inspanning en model", "Mode, effort and model")} sections={controlSections} anchor={controlsMenu} onclose={() => (controlsMenu = null)} />{/if}
{#if prompt && session}
  <SessionPrompt kind={prompt} {session} onclose={() => (prompt = null)} onrun={(action, text) => void manage(action, text)} />
{/if}
{#if steerMenu}
  <Menu title={tr("Terwijl de agent werkt", "While the agent works")} anchor={steerMenu} onclose={() => (steerMenu = null)} sections={[[
    { label: tr("Nu bijsturen", "Steer now"), icon: "corner-down-right", checked: steer, onselect: () => setSteer(true) },
    { label: tr("Na deze beurt", "After this turn"), icon: "list", checked: !steer, onselect: () => setSteer(false) },
  ]]} />
{/if}
{#if dialog?.kind === "stop"}
  <Dialog title={tr("Deze sessie stoppen?", "Stop this session?")} onclose={() => (dialog = null)} buttons={[
    { label: tr("Stop de sessie", "Stop the session"), destructive: true, onselect: stop },
    { label: tr("Annuleer", "Cancel"), bold: true, onselect: () => {} },
  ]} />
{:else if dialog?.kind === "end"}
  <Dialog title={tr("Deze sessie beëindigen?", "End this session?")} message={tr("De agent bewaart het gesprek, dus je kunt het in Nook voortzetten.", "The agent saves its conversation, so you can continue it in Nook.")} onclose={() => (dialog = null)} buttons={[
    { label: tr("Beëindig sessie", "End session"), destructive: true, onselect: () => manage("end") },
    { label: tr("Annuleer", "Cancel"), bold: true, onselect: () => {} },
  ]} />
{:else if dialog?.kind === "archive"}
  <Dialog title={tr("Deze sessie archiveren?", "Archive this session?")} onclose={() => (dialog = null)} buttons={[
    { label: tr("Archiveer", "Archive"), destructive: true, onselect: () => manage("archive") },
    { label: tr("Annuleer", "Cancel"), bold: true, onselect: () => {} },
  ]} />
{:else if dialog?.kind === "rename"}
  {@const d = dialog}
  <Dialog title={tr("Hernoem", "Rename")} bind:field={d.name} placeholder={tr("Naam", "Name")} onclose={() => (dialog = null)} buttons={[
    { label: tr("Bewaar", "Save"), bold: true, onselect: () => d.name.trim() && manage("rename", d.name.trim()) },
    { label: tr("Annuleer", "Cancel"), onselect: () => {} },
  ]} />
{/if}

<style>
  .session { display: flex; flex-direction: column; height: 100%; min-height: 0; }
  .earlier { align-self: center; margin: 8px auto 4px; display: flex; align-items: center; gap: 6px; height: 32px; padding: 0 12px; border-radius: 8px; background: var(--smoke) !important; color: var(--text2) !important; font: var(--pt-label) !important; }
  .mini { width: 12px; height: 12px; border-radius: 50%; border: 2px solid var(--text3); border-top-color: transparent; animation: spin 0.8s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }
  .navbtn { width: 36px; height: 44px; display: inline-flex; align-items: center; justify-content: center; color: var(--paper) !important; }
  .title { max-width: 260px; display: flex; flex-direction: column; align-items: center; min-width: 0; opacity: 1 !important; }
  .l1 { display: flex; align-items: center; gap: 4px; max-width: 100%; font: var(--pt-strong); white-space: nowrap; }
  .folder { color: var(--text3); flex: none; }
  .name { color: var(--paper); overflow: hidden; text-overflow: ellipsis; }
  .chev { color: var(--text3); display: inline-flex; }
  .l2 { font: var(--pt-caption); color: var(--text3); max-width: 100%; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .body { flex: 1; min-height: 0; display: flex; flex-direction: column; }
  .loading { display: flex; flex-direction: column; gap: 8px; padding-top: 24px; }
  .loading span { height: 12px; border-radius: 999px; background: var(--smoke); }
  .section { margin: 16px 0 4px; font: var(--pt-label); color: var(--text3); }
  .reply { font: var(--pt-body); color: var(--text-strong); }
  .floating { display: inline-flex; align-items: center; gap: 6px; height: 40px; padding: 0 12px; border-radius: 999px; background: rgba(30, 30, 30, 0.72); backdrop-filter: blur(20px); -webkit-backdrop-filter: blur(20px); border: 1px solid rgba(255, 255, 255, 0.08); font: var(--pt-label); color: var(--text-strong); }
  .pending { padding: 0 16px 8px; display: flex; flex-direction: column; gap: 6px; animation: rise var(--reveal); }
  .card { display: flex; flex-direction: column; gap: 12px; padding: 16px; background: var(--surface); border: 1px solid rgba(240, 182, 90, 0.35); border-radius: 12px; max-height: 360px; overflow-y: auto; }
  .kind { text-transform: uppercase; display: flex; align-items: center; gap: 6px; font: var(--pt-caption); letter-spacing: 1.1px; color: var(--amber); }
  .ask { margin: 0; font: var(--pt-title); color: var(--paper); user-select: text; overflow-wrap: anywhere; }
  .detail { font: var(--pt-code); color: var(--text2); padding: 8px; background: var(--well); border-radius: 8px; white-space: pre-wrap; overflow-wrap: anywhere; }
  .decide { display: flex; gap: 8px; }
  .note { display: flex; align-items: baseline; gap: 6px; font: var(--pt-detail); color: var(--amber); }
  .note.muted { color: var(--text2); }
  .options { display: flex; flex-direction: column; gap: 8px; }
  .option { display: flex; align-items: baseline; gap: 8px; padding: 9px 12px; background: var(--field) !important; border: 1px solid rgba(255, 255, 255, 0.08) !important; border-radius: 10px; text-align: left; }
  .key { min-width: 22px; height: 22px; border-radius: 6px; background: var(--well); font: 600 12.57px var(--mono); color: var(--text2); display: inline-flex; align-items: center; justify-content: center; flex: none; }
  .otext { display: flex; flex-direction: column; gap: 6px; font: 600 14.86px var(--font); color: var(--paper); min-width: 0; }
  .otext pre { margin: 0 0 0 12px; font: var(--pt-code); font-size: 12px; color: var(--text2); white-space: pre; overflow-x: auto; max-height: 10lh; }
  .morewait { font: var(--pt-caption); color: var(--text3); text-align: center; }
  .dock { padding: 8px 12px; background: linear-gradient(transparent, var(--canvas) 30%); }
  .queued { display: flex; flex-direction: column; align-items: flex-end; gap: 4px; padding: 18px 0 2px 56px; opacity: 0.6; }
  .qbubble { background: var(--bubble); border-radius: 16px; padding: 12px; font: var(--pt-body); white-space: pre-wrap; overflow-wrap: anywhere; }
  .qnote { display: flex; align-items: center; gap: 4px; font: var(--pt-caption); color: var(--text3); }
  .qnote button { margin-left: 8px; color: var(--coral) !important; font: var(--pt-caption) !important; }
  .withphoto { display: flex; align-items: flex-end; gap: 6px; }
  .always { display: flex; align-items: center; justify-content: center; gap: 6px; min-height: 44px; border-radius: 10px; background: var(--smoke) !important; color: var(--paper) !important; font: var(--pt-label) !important; }
  .line { display: flex; flex-direction: column; gap: 4px; margin-bottom: 6px; }
  .linehead { font: var(--pt-caption); color: var(--text3); padding: 0 4px; }
  .qrow { display: flex; align-items: center; gap: 6px; padding-left: 10px; background: var(--field); border-radius: 8px; color: var(--text3); }
  .qtext { flex: 1; min-width: 0; font: var(--pt-detail); color: var(--text2); overflow: hidden; display: -webkit-box; -webkit-line-clamp: 2; line-clamp: 2; -webkit-box-orient: vertical; }
  .qremove { width: 44px; height: 36px; display: inline-flex; align-items: center; justify-content: center; color: var(--text2) !important; }
  .grow { flex: 1; min-width: 0; }
  .fieldcard { display: flex; align-items: baseline; gap: 6px; padding: 12px; background: var(--field); border-radius: 12px; font: var(--pt-detail); color: var(--text2); }
  @keyframes rise { from { transform: translateY(16px); opacity: 0; } }
</style>
