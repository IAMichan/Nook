<script lang="ts">
  // The sources this Nook may use, as the Mac's `ScopeMenu`: "Automatic: all relevant sources", then "Only these
  // sources" (a tick on each source turns the Nook into only those) and "Never use" (the screen, the web and the
  // clipboard left out). The question can say it too ("only my calendar and mail", "not my screen").
  import { brainApi, type SourceChoice, type SourceScope } from "../lib/brain";
  import { sourceDomain } from "../lib/sources";
  import { nook } from "../lib/state.svelte";
  import { tr } from "../lib/i18n.svelte";
  import ServiceIcon from "../views/connectors/ServiceIcon.svelte";
  import Ico from "./ui/Ico.svelte";
  import Dropdown from "./ui/Dropdown.svelte";

  let choices = $state<SourceChoice[]>([]);
  const scope = $derived<SourceScope>(nook.active?.scope ?? { mode: "automatic", included: [], excluded: [], focus: [] });
  const restricted = $derived(scope.mode === "only" || scope.excluded.length > 0);
  const label = $derived(
    scope.mode === "only" ? tr("Alleen {n}", "Only {n}", { n: scope.included.length }) : scope.excluded.length ? tr("Zonder {n}", "Without {n}", { n: scope.excluded.length }) : tr("Alle bronnen", "All sources"),
  );
  /** What "Never use" offers: what Nook reads besides the sources you connected. */
  const NEVER = ["screen", "web", "clipboard"];
  const only = $derived(choices.filter((c) => c.id !== "screen" && c.id !== "clipboard"));
  const never = $derived(NEVER.map((id) => choices.find((c) => c.id === id) ?? { id, title: id === "screen" ? tr("Scherm", "Screen") : id === "web" ? tr("Web", "Web") : tr("Klembord", "Clipboard"), private: false }));

  function sourceSymbol(id: string): string {
    switch (id) {
      case "calendar":
      case "icalfeeds":
        return "calendar";
      case "mail":
        return "mail";
      case "web":
      case "browser":
      case "browser_extension":
        return "globe";
      case "screen":
        return "monitor";
      case "clipboard":
        return "clipboard-list";
      case "notes":
      case "bear":
        return "notebook-pen";
      case "reminders":
      case "things":
      case "loops":
        return "list-checks";
      case "contacts":
        return "users";
      case "files":
        return "folder";
      case "memory":
        return "brain";
      case "messages":
        return "message-circle";
      case "callnotes":
        return "audio-waveform";
      case "terminal":
        return "terminal";
      case "agents":
        return "bot";
      case "system":
        return "laptop";
      default:
        return "layers";
    }
  }

  async function opened() {
    choices = await brainApi.sourceChoices();
  }

  async function set(next: SourceScope | null) {
    if (next && next.mode === "only" && next.included.length === 0) next = { ...next, mode: "automatic" };
    const id = await nook.ensureActive();
    await brainApi.setScope(id, next);
    await nook.load(id);
  }

  const isOnly = (id: string) => scope.mode === "only" && scope.included.includes(id);
  function toggleOnly(id: string) {
    if (isOnly(id)) set({ ...scope, included: scope.included.filter((i) => i !== id) });
    else set({ ...scope, mode: "only", included: [...(scope.mode === "only" ? scope.included : []), id], excluded: scope.excluded.filter((e) => e !== id) });
  }
  function toggleNever(id: string) {
    if (scope.excluded.includes(id)) set({ ...scope, excluded: scope.excluded.filter((e) => e !== id) });
    else set({ ...scope, excluded: [...scope.excluded, id], included: scope.included.filter((i) => i !== id) });
  }
</script>

<Dropdown width={288} onopen={opened} label={tr("Bronnen", "Sources")}>
  {#snippet trigger({ toggle, open })}
    <button class="composer-pill" class:restricted onclick={toggle} aria-expanded={open} title={tr("Welke bronnen deze Nook mag gebruiken", "Which sources this Nook may use")}>
      <Ico name="list-filter" size={15} /><span>{label}</span><Ico name="chevron-down" size={10} stroke={2.5} />
    </button>
  {/snippet}
  {#snippet children({ close })}
    <!-- A system menu's rows on the Mac (`ScopeMenu`): a tick column, the source icon, the name; grey section headings. -->
    <div class="scope">
      <button class="item" onclick={() => { set(null); close(); }}>
        <span class="tick">{#if !restricted}<Ico name="check" size={13} stroke={2.4} />{/if}</span>
        <span class="mark"><Ico name="sparkles" size={14} /></span>
        <span class="name">{tr("Automatisch: alle relevante bronnen", "Automatic: all relevant sources")}</span>
      </button>
      <div class="sep"></div>
      <div class="heading">{tr("Alleen deze bronnen", "Only these sources")}</div>
      {#each only as c (c.id)}
        {@const domain = sourceDomain(c.id)}
        <button class="item" disabled={c.private} onclick={() => toggleOnly(c.id)}
          title={c.private ? tr("Alleen op dit apparaat: een externe AI krijgt deze bron niet", "Only on this device: an external AI does not get this source") : undefined}>
          <span class="tick">{#if isOnly(c.id)}<Ico name="check" size={13} stroke={2.4} />{/if}</span>
          <span class="mark">
            {#if domain}<ServiceIcon {domain} title={c.title} size={15} />{:else}<Ico name={sourceSymbol(c.id)} size={14} />{/if}
          </span>
          <span class="name">{c.title}</span>
          {#if c.private}<span class="lock" aria-hidden="true"><Ico name="lock" size={12} /></span>{/if}
        </button>
      {/each}
      <div class="sep"></div>
      <div class="heading">{tr("Nooit gebruiken", "Never use")}</div>
      {#each never as c (c.id)}
        <button class="item" onclick={() => toggleNever(c.id)}>
          <span class="tick">{#if scope.excluded.includes(c.id)}<Ico name="check" size={13} stroke={2.4} />{/if}</span>
          <span class="mark"><Ico name={sourceSymbol(c.id)} size={14} /></span>
          <span class="name">{c.title}</span>
        </button>
      {/each}
    </div>
  {/snippet}
</Dropdown>

<style>
  .restricted { color: var(--iris); }
  .scope { display: flex; flex-direction: column; padding: var(--space-2) 0; }
  .heading { padding: var(--space-6) var(--space-8) var(--space-2) calc(var(--space-6) + 16px + var(--space-6)); font: var(--text-label); color: var(--text3); }
  .item { display: flex; align-items: center; gap: var(--space-6); min-height: 26px; margin: 0; padding: var(--space-4) var(--space-8) var(--space-4) var(--space-6); border: 0; border-radius: var(--radius-chip); background: transparent; font: var(--text-control); font-weight: 400; color: var(--paper); text-align: left; }
  .item:hover:not(:disabled) { background: var(--smoke); }
  .item:disabled { color: var(--text3); cursor: default; }
  .name { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .tick { display: inline-flex; width: 16px; flex: none; justify-content: center; color: var(--paper); }
  .mark { display: inline-flex; width: 16px; height: 16px; flex: none; align-items: center; justify-content: center; color: var(--text2); }
  .item:hover:not(:disabled) .mark { color: var(--paper); }
  .item:disabled .mark { opacity: 0.5; }
  .lock { display: inline-flex; flex: none; color: var(--text3); }
  .sep { height: 1px; margin: var(--space-4) var(--space-8); background: var(--line2); }
</style>
