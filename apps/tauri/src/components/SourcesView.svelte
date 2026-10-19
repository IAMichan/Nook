<script lang="ts">
  // Wat Nook voor een antwoord gebruikte: één rustige regel ("3 bronnen gebruikt") die openklapt met per bron of hij
  // doorzocht is, niets vond of faalde, en de genummerde bronnen. Klapt vanzelf open als een bron niet gelezen kon worden.
  import { openUrl } from "@tauri-apps/plugin-opener";
  import { outcomeLabel, type RetrievalStep } from "../lib/brain";
  import type { ChatMessage, SourceReference } from "../lib/types";

  let { message, live = false }: { message: ChatMessage; live?: boolean } = $props();

  interface Group {
    title: string;
    status: "found" | "empty" | "failed" | "running" | "context";
    detail: string;
    queries: string[];
    references: SourceReference[];
  }

  const groups = $derived.by(() => {
    const result: Group[] = [];
    const get = (title: string) => {
      let g = result.find((x) => x.title === title);
      if (!g) {
        g = { title, status: "context", detail: "", queries: [], references: [] };
        result.push(g);
      }
      return g;
    };
    const byTitle = new Map<string, RetrievalStep[]>();
    for (const step of message.retrieval ?? []) byTitle.set(step.sourceTitle, [...(byTitle.get(step.sourceTitle) ?? []), step]);
    for (const [title, steps] of byTitle) {
      const g = get(title);
      g.queries = steps.map((s) => s.query).filter(Boolean);
      const failed = steps.find((s) => s.outcome.kind === "failed");
      if (steps.some((s) => s.outcome.kind === "running")) g.status = "running";
      else if (!steps.some((s) => s.outcome.kind === "found") && failed) {
        g.status = "failed";
        g.detail = outcomeLabel(failed.outcome);
      } else if (steps.every((s) => s.outcome.kind === "empty")) g.status = "empty";
      else g.status = "found";
      if (g.status === "found") g.detail = steps.map((s) => outcomeLabel(s.outcome)).find((t) => t.startsWith("doorzocht")) ?? "";
    }
    for (const ref of message.references ?? []) get(titleOf(ref)).references.push(ref);
    for (const source of [...(message.sources ?? []), ...(message.contextSources ?? [])]) get(source);
    return result;
  });

  function titleOf(ref: SourceReference): string {
    const step = (message.retrieval ?? []).find((s) => s.sourceId === ref.sourceId);
    return step?.sourceTitle ?? ref.sourceId ?? "Bron";
  }

  const failed = $derived(groups.filter((g) => g.status === "failed").length);
  const used = $derived(groups.filter((g) => g.status === "found" || g.status === "context").length);
  let expanded = $state(false);
  $effect(() => {
    if (failed > 0) expanded = true;
  });

  const summary = $derived(
    live || groups.some((g) => g.status === "running")
      ? `Bezig met ${groups.filter((g) => g.status === "running").map((g) => g.title).join(", ") || "zoeken"}…`
      : [used ? `${used} ${used === 1 ? "bron" : "bronnen"} gebruikt` : "", failed ? `${failed} niet te lezen` : ""].filter(Boolean).join(" · ") || "Bronnen",
  );
  const icon: Record<Group["status"], string> = { found: "✓", empty: "∅", failed: "!", running: "…", context: "·" };

  function open(ref: SourceReference) {
    if (ref.url && /^(https:|file:|message:)/.test(ref.url)) openUrl(ref.url);
  }
</script>

{#if groups.length}
  <div class="sources">
    <button class="toggle" class:warn={failed > 0} onclick={() => (expanded = !expanded)}>
      {summary} {message.scopeLabel ? `· ${message.scopeLabel}` : ""} <span class="chev">{expanded ? "▴" : "▾"}</span>
    </button>
    {#if expanded}
      <ul>
        {#each groups as g (g.title)}
          <li class={g.status}>
            <span class="icon">{icon[g.status]}</span>
            <span class="name">{g.title}</span>
            <span class="faint">
              {#if g.status === "empty"}niets gevonden{:else if g.status === "failed"}{g.detail}{:else if g.status === "context"}in de context{:else if g.status === "running"}bezig…{:else}{g.detail}{/if}
              {#if g.queries.length} · “{g.queries.join("”, “")}”{/if}
            </span>
            {#if g.references.length}
              <ol>
                {#each g.references as ref (ref.number)}
                  <li value={ref.number}>
                    {#if ref.url}<a href={ref.url} onclick={(e) => { e.preventDefault(); open(ref); }}>{ref.title}</a>{:else}{ref.title}{/if}
                    {#if ref.detail}<span class="faint"> — {ref.detail}</span>{/if}
                  </li>
                {/each}
              </ol>
            {/if}
          </li>
        {/each}
      </ul>
    {/if}
  </div>
{/if}

<style>
  .sources { margin: 2px 0 6px; font-size: 12px; }
  .toggle { background: none; border: none; padding: 2px 0; color: var(--text2); font-size: 12px; }
  .toggle:hover { background: none; color: var(--paper); }
  .toggle.warn { color: var(--amber); }
  .chev { font-size: 10px; }
  ul { list-style: none; margin: 4px 0 0; padding: 6px 10px; border-left: 2px solid var(--line2); display: flex; flex-direction: column; gap: 4px; }
  li .icon { display: inline-block; width: 14px; color: var(--text3); }
  li.found .icon { color: var(--mint); }
  li.failed .icon, li.failed .faint { color: var(--amber); }
  .name { color: var(--paper); margin-right: 6px; }
  ol { margin: 3px 0 0 14px; padding-left: 16px; color: var(--text2); }
</style>
