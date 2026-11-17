<script lang="ts">
  import { tr } from "../lib/i18n.svelte";
  // Eén bericht: boven het antwoord wat er opgezocht is, dan het antwoord zelf (Markdown met bronlabels), grafieken,
  // mailconcepten, het plan, meldingen en vervolgknoppen. Bij een fout de knop die hem oplost.
  import { openUrl } from "@tauri-apps/plugin-opener";
  import { api } from "../lib/api";
  import { brainApi, type Recovery } from "../lib/brain";
  import { citationReferences, claimFromTextBefore, isOpenableUrl, withoutSourceList } from "../lib/citations";
  import { answerCitation } from "../lib/markdown";
  import { serviceIconUrl } from "../lib/service-icons";
  import { visibleNotices } from "../lib/sources";
  import { nook } from "../lib/state.svelte";
  import { toast } from "../lib/toast.svelte";
  import type { ChatMessage, SourceReference } from "../lib/types";
  import ScheduledRunMarker from "./ScheduledRunMarker.svelte";
  import TaskChecklist from "./TaskChecklist.svelte";
  import WorkingIndicator from "./WorkingIndicator.svelte";
  import { errorKind } from "../lib/working";
  import ChartView from "./ChartView.svelte";
  import CitationPreview from "./CitationPreview.svelte";
  import MailDraftView from "./MailDraftView.svelte";
  import MarkdownBody from "./MarkdownBody.svelte";
  import PlanCard from "./PlanCard.svelte";
  import SourcesView from "./SourcesView.svelte";

  let { message, nookId, last = false }: { message: ChatMessage; nookId: string; last?: boolean } = $props();
  const text = $derived(message.streaming ? (nook.streaming[message.id] ?? message.text ?? "") : message.text);
  const citation = $derived(message.fromUser || !message.references?.length ? undefined : answerCitation(message.references));
  const notices = $derived(message.streaming ? [] : visibleNotices(message));
  let enlargedImages = $state<Record<string, boolean>>({});
  let markdownEl = $state<HTMLDivElement | null>(null);

  type PillPreview = {
    references: SourceReference[];
    claim: string;
    anchor: { left: number; top: number; right: number; bottom: number };
    pinned: boolean;
    pill: HTMLElement;
  };
  let preview = $state<PillPreview | null>(null);
  let onPill = false;
  let onPopover = false;
  let showTimer: ReturnType<typeof setTimeout> | undefined;
  let hideTimer: ReturnType<typeof setTimeout> | undefined;

  function clearClaimHighlight() {
    if (typeof CSS !== "undefined" && "highlights" in CSS) {
      CSS.highlights.delete("nook-claim");
    }
  }

  function closePreview() {
    clearTimeout(showTimer);
    clearTimeout(hideTimer);
    preview = null;
    clearClaimHighlight();
  }

  function scheduleClose() {
    clearTimeout(hideTimer);
    hideTimer = setTimeout(() => {
      if (!onPill && !onPopover && preview && !preview.pinned) {
        closePreview();
      }
    }, 200);
  }

  /** Extracts the sentence before `pill` within its block element and highlights it via CSS Custom Highlight API. */
  function extractAndHighlightClaim(pill: HTMLElement, highlight: boolean): string {
    const block = pill.closest("p, li, td, th, blockquote, h1, h2, h3, h4, h5, h6") ?? markdownEl;
    if (!block) return "";
    let chunks: { node: Text; text: string }[] = [];
    const walk = (root: Node): boolean => {
      for (const child of root.childNodes) {
        if (child === pill) return true;
        if (child instanceof HTMLElement && (child.classList.contains("cite-pill") || child.tagName === "BR")) {
          chunks = [];
          continue;
        }
        if (child.nodeType === Node.TEXT_NODE) {
          const val = child.textContent ?? "";
          if (val) chunks.push({ node: child as Text, text: val });
        } else if (child.hasChildNodes()) {
          if (walk(child)) return true;
        }
      }
      return false;
    };
    walk(block);
    const segment = chunks.map((c) => c.text).join("");
    const claim = claimFromTextBefore(segment);
    if (highlight && claim && typeof CSS !== "undefined" && "highlights" in CSS && typeof Highlight !== "undefined") {
      const idx = segment.lastIndexOf(claim);
      if (idx >= 0) {
        const endIdx = idx + claim.length;
        const range = document.createRange();
        let pos = 0;
        let started = false;
        for (const chunk of chunks) {
          const nextPos = pos + chunk.text.length;
          if (!started && idx < nextPos) {
            range.setStart(chunk.node, Math.max(0, idx - pos));
            started = true;
          }
          if (started && endIdx <= nextPos) {
            range.setEnd(chunk.node, Math.max(0, endIdx - pos));
            break;
          }
          pos = nextPos;
        }
        if (started) CSS.highlights.set("nook-claim", new Highlight(range));
      }
    }
    return claim;
  }

  function pillReferences(pill: HTMLElement): SourceReference[] {
    const nums = (pill.dataset.cites ?? "")
      .split(",")
      .map((s) => Number(s.trim()))
      .filter((n) => Number.isInteger(n) && n > 0);
    return citationReferences(nums, message.references);
  }

  $effect(() => {
    void text;
    void citation;
    closePreview();
    if (!markdownEl) return;
    let alive = true;
    for (const span of markdownEl.querySelectorAll<HTMLElement>(".cite-pill .cite-ico[data-icon-domain]")) {
      const domain = span.dataset.iconDomain;
      if (!domain) continue;
      serviceIconUrl(domain).then((src) => {
        if (!alive || !src) return;
        const img = document.createElement("img");
        img.src = src;
        img.alt = "";
        img.className = "cite-img";
        img.onerror = () => img.remove();
        span.replaceChildren(img);
      });
    }
    const cleanups: (() => void)[] = [];
    for (const pill of markdownEl.querySelectorAll<HTMLElement>(".cite-pill")) {
      const enter = () => {
        onPill = true;
        clearTimeout(showTimer);
        clearTimeout(hideTimer);
        const cited = pillReferences(pill);
        if (!cited.length) return;
        const claim = extractAndHighlightClaim(pill, true);
        if (preview?.pinned) return;
        const rect = pill.getBoundingClientRect();
        const anchor = { left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom };
        const delay = preview ? 0 : 250;
        showTimer = setTimeout(() => {
          if (!alive) return;
          preview = { references: cited, claim, anchor, pinned: false, pill };
        }, delay);
      };
      const leave = () => {
        onPill = false;
        clearTimeout(showTimer);
        if (!preview?.pinned) {
          clearClaimHighlight();
          scheduleClose();
        }
      };
      pill.addEventListener("mouseenter", enter);
      pill.addEventListener("mouseleave", leave);
      pill.addEventListener("focus", enter);
      pill.addEventListener("blur", leave);
      cleanups.push(() => {
        pill.removeEventListener("mouseenter", enter);
        pill.removeEventListener("mouseleave", leave);
        pill.removeEventListener("focus", enter);
        pill.removeEventListener("blur", leave);
      });
    }
    return () => {
      alive = false;
      clearTimeout(showTimer);
      clearTimeout(hideTimer);
      clearClaimHighlight();
      for (const fn of cleanups) fn();
    };
  });

  $effect(() => {
    if (!preview?.pinned) return;
    const onDocClick = (e: MouseEvent) => {
      const t = e.target as HTMLElement | null;
      if (t?.closest(".citation-popover") || t?.closest(".cite-pill") === preview?.pill) return;
      closePreview();
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") closePreview();
    };
    window.addEventListener("mousedown", onDocClick);
    window.addEventListener("keydown", onKey);
    return () => {
      window.removeEventListener("mousedown", onDocClick);
      window.removeEventListener("keydown", onKey);
    };
  });

  function toggleImage(src: string) {
    enlargedImages[src] = !enlargedImages[src];
  }

  // The error card: what happened in plain words, by the fix it offers; the raw message behind Details.
  const failure = $derived(errorKind(message.recovery));
  let showDetails = $state(false);
  const explanation = $derived(
    failure.kind === "chooseModel"
      ? tr("Er is geen model beschikbaar. Kies er een en probeer het daarna opnieuw.", "No model is available. Choose one, then try again.")
      : failure.kind === "server"
        ? tr("{name} reageert niet. Open het programma en probeer het opnieuw.", "{name} is not responding. Open it and try again.", { name: failure.name })
        : failure.kind === "credentials"
          ? tr("De sleutel of inlog is geweigerd. Controleer die en probeer het opnieuw.", "The key or login was rejected. Check it and try again.")
          : tr("Er ging iets mis bij het maken van het antwoord. Probeer het opnieuw.", "Something went wrong while making the answer. Try again."),
  );

  let copied = $state(false);
  async function copyAnswer() {
    try {
      await navigator.clipboard.writeText(withoutSourceList(text));
      copied = true;
      setTimeout(() => (copied = false), 1500);
    } catch { /* The clipboard can be busy; the button simply stays. */ }
  }

  function click(e: MouseEvent) {
    const target = e.target as HTMLElement;
    const pill = target.closest(".cite-pill") as HTMLElement | null;
    if (pill) {
      e.preventDefault();
      const cited = pillReferences(pill);
      if (!cited.length) return;
      if (cited.length === 1 && cited[0].url && isOpenableUrl(cited[0].url)) {
        openUrl(cited[0].url);
        closePreview();
        return;
      }
      if (preview?.pinned && preview.pill === pill) {
        closePreview();
        return;
      }
      const claim = extractAndHighlightClaim(pill, true);
      const rect = pill.getBoundingClientRect();
      preview = {
        references: cited,
        claim,
        anchor: { left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom },
        pinned: true,
        pill,
      };
      return;
    }
  }

  function recoveryTitle(r: Recovery): string {
    switch (r.kind) {
      case "chooseModel": return tr("Kies een model", "Choose a model");
      case "openLocalServer": return starting ? tr("{name} starten…", "Starting {name}…", { name: r.name }) : tr("Start {name} en probeer opnieuw", "Start {name} and retry", { name: r.name });
      case "reconnectBrain":
      case "reconnectConnection": return tr("Opnieuw koppelen", "Reconnect");
      default: return tr("Instellingen", "Settings");
    }
  }

  // A local brain that is installed but not running is started by Nook itself, and the question asked again. Only
  // when it is not installed does the button lead to the download page.
  let starting = $state(false);
  async function startLocal(name: string) {
    if (starting) return;
    starting = true;
    try {
      const outcome = await api.startLocalBrain(name);
      if (outcome === "notInstalled") {
        openUrl(name === "Ollama" ? "https://ollama.com/download" : "https://lmstudio.ai");
        return;
      }
      if (outcome === "noAnswer") return void toast.warning(tr("{name} start niet", "{name} does not start", { name }), tr("Hij is gestart maar antwoordt nog niet. Probeer het zo nog eens.", "It started but is not answering yet. Try again in a moment."));
      await brainApi.retryLast(nookId);
    } catch (e) {
      toast.error(tr("{name} kon niet starten", "{name} could not start", { name }), e);
    } finally {
      starting = false;
    }
  }

  function recover(r: Recovery) {
    if (r.kind === "openLocalServer") return void startLocal(r.name);
    localStorage.setItem("settings.section", r.kind === "reconnectConnection" ? "connections" : "brain");
    api.showMain("settings");
    window.dispatchEvent(new CustomEvent("nook-navigate", { detail: "settings" }));
  }
</script>

<div class="msg" class:user={message.fromUser} class:error={message.isError}>
  {#if message.fromUser && message.scheduled}
    <ScheduledRunMarker text={message.text} date={message.date} />
  {:else if message.fromUser}
    {#each message.images as src (src)}
      {@const label = enlargedImages[src] ? tr("Verkleinen", "Shrink") : tr("Vergroten", "Enlarge")}
      <button
        type="button"
        class="pic-btn"
        aria-pressed={!!enlargedImages[src]}
        aria-label={label}
        title={label}
        onclick={() => toggleImage(src)}
      >
        <img class="pic" class:enlarged={!!enlargedImages[src]} {src} alt="" />
      </button>
    {/each}
    {#if message.attachment}<div class="file">📄 {message.attachment}</div>{/if}
    <div class="bubble">{message.text}</div>
  {:else}
    <SourcesView {message} live={message.streaming} onRetry={last ? () => brainApi.retryLast(nookId) : undefined} />
    {#if message.tasks?.length}<TaskChecklist steps={message.tasks} live={message.streaming} />{/if}
    {#if message.isError && !message.streaming}
      <div class="error-card">
        <div class="error-head">
          <span class="mark">!</span>
          <div>
            <div class="error-title">{tr("Nook kan nu niet antwoorden", "Nook can't answer right now")}</div>
            <div class="error-detail">{explanation}</div>
          </div>
        </div>
        <div class="error-actions">
          <div class="offers">
            {#if message.recovery}<button class="primary" disabled={starting} onclick={() => recover(message.recovery!)}>{recoveryTitle(message.recovery)}</button>{/if}
            {#if last}<button class="ghost" onclick={() => brainApi.retryLast(nookId)}>{tr("Probeer opnieuw", "Try again")}</button>{/if}
          </div>
          <button class="ghost details" onclick={() => (showDetails = !showDetails)}>{showDetails ? tr("Verberg details", "Hide details") : tr("Details", "Details")}</button>
          {#if showDetails}<pre class="raw">{message.text}</pre>{/if}
        </div>
      </div>
    {:else if message.streaming && !text}
      <WorkingIndicator status={message.status} since={message.date} />
    {:else if text}
      <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
      <div class="answer-body" bind:this={markdownEl} onclick={click}>
        <MarkdownBody text={withoutSourceList(text)} {citation} />
      </div>
      {#if !message.streaming && !message.isError}
        <div class="tools"><button class="ghost" onclick={copyAnswer} title={tr("Antwoord kopiëren", "Copy answer")} aria-label={tr("Antwoord kopiëren", "Copy answer")}>{copied ? tr("✓ Gekopieerd", "✓ Copied") : tr("Kopieer", "Copy")}</button></div>
      {/if}
    {/if}
    {#each message.charts ?? [] as chart (chart.id)}<ChartView {chart} />{/each}
    {#each message.mails ?? [] as draft (draft.id)}<MailDraftView {draft} {nookId} />{/each}
    {#if message.actions.length}
      <PlanCard {nookId} {message} {last} />
    {/if}
    {#if notices.length}
      <div class="notices">
        {#each notices as notice (notice)}<div class="notice"><span class="mark">!</span><span>{notice}</span></div>{/each}
      </div>
    {/if}
    {#if message.streaming && text && message.status}
      <WorkingIndicator status={message.status} since={message.date} />
    {/if}
    {#if !message.isError && message.recovery}
      <div class="offers">
        {#if message.recovery}<button class:primary={message.recovery.kind === "openLocalServer"} disabled={starting} onclick={() => recover(message.recovery!)}>{recoveryTitle(message.recovery)}</button>{/if}
      </div>
    {/if}
    {#if message.offers.length && !message.streaming}
      <div class="offers">
        {#each message.offers as offer (offer)}
          <button onclick={() => nook.ask(offer)}>{offer}</button>
        {/each}
      </div>
    {/if}
  {/if}
</div>

{#if preview}
  <CitationPreview
    references={preview.references}
    claim={preview.claim}
    anchor={preview.anchor}
    edge="bottom"
    onhover={(inside) => {
      onPopover = inside;
      if (inside) clearTimeout(hideTimer);
      else scheduleClose();
    }}
    onopen={closePreview}
  />
{/if}

<style>
  .msg { padding: 14px 0; max-width: 100%; line-height: 1.7; overflow-wrap: anywhere; }
  .msg.user { display: flex; flex-direction: column; align-items: flex-end; }
  .bubble { background: var(--smoke); border-radius: 14px 14px 4px 14px; padding: 12px 16px; max-width: 85%; white-space: pre-wrap; user-select: text; }
  .pic-btn { background: none; border: none; padding: 0; margin: 0 0 4px; display: inline-flex; max-width: 100%; border-radius: 10px; }
  .pic { display: block; max-width: 180px; max-height: 140px; border-radius: 10px; cursor: zoom-in; transition: max-width 0.2s ease, max-height 0.2s ease; }
  .pic.enlarged { width: auto; height: auto; min-width: min(100%, 240px); max-width: min(100%, 520px); max-height: 420px; object-fit: contain; cursor: zoom-out; }
  .file { font-size: 12px; color: var(--text2); margin-bottom: 4px; }
  .error :global(.markdown) { color: var(--coral); }
  .error-card { margin-top: 4px; padding: 14px; border-radius: var(--radius-sheet); background: color-mix(in srgb, var(--coral) 7%, transparent); }
  .error-head { display: flex; gap: 10px; align-items: flex-start; }
  .error-head .mark { color: var(--coral); font-weight: 600; width: 16px; text-align: center; }
  .error-title { font-weight: 600; }
  .error-detail { color: var(--text2); font: var(--text-detail); }
  .error-actions { padding-left: 26px; }
  .details { font: var(--text-detail); color: var(--text3); padding: 4px 0; margin-top: 6px; }
  .raw { font: var(--text-label); color: var(--text3); white-space: pre-wrap; user-select: text; margin: 6px 0 0; padding: 10px; border-radius: var(--radius-control); background: var(--well, var(--smoke)); }
  .refs { margin: 8px 0 0; padding-left: 20px; font-size: 12px; color: var(--text2); }
  .notices { display: flex; flex-direction: column; gap: 8px; margin-top: 8px; padding: 8px 10px; border-radius: 12px; background: color-mix(in srgb, var(--amber) 6%, transparent); border: 1px solid color-mix(in srgb, var(--amber) 18%, transparent); }
  .notice { display: flex; gap: 8px; align-items: flex-start; font-size: 12px; color: var(--text2); user-select: text; }
  .mark { flex: none; width: 14px; height: 14px; margin-top: 1px; border-radius: 50%; background: var(--amber); color: var(--ink); font-size: 10px; font-weight: 700; display: grid; place-items: center; }
  .tools { display: flex; gap: 4px; margin-top: 2px; opacity: 0; transition: opacity 0.15s; }
  .msg:hover .tools, .tools:focus-within { opacity: 1; }
  .tools button { font-size: 11px; padding: 2px 8px; color: var(--text3); }
  .tools button:hover { color: var(--paper); }
  .offers { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 8px; }
  .offers button { font-size: 12px; padding: 4px 10px; border-radius: 999px; }
</style>
