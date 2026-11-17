<script lang="ts">
  // A session that needs you, as a card at the top of the Agents list (`SessionNotice`): what it asks, and Deny / Allow
  // right there, or Answer, which opens it.
  import { attentionTint, companion, may, type ClientView, type SessionDigest } from "../../../lib/companion";
  import { tr } from "../../../lib/i18n.svelte";
  import AgentMark from "../../../components/ui/AgentMark.svelte";
  import StatusPill from "../../../components/ui/StatusPill.svelte";
  import DecisionButton from "./DecisionButton.svelte";
  import Ico from "../../../components/ui/Ico.svelte";
  import { haptic } from "../../../lib/haptics";
  let { view, session, onopen, act }: { view: ClientView; session: SessionDigest; onopen: () => void; act: (f: () => Promise<ClientView>) => Promise<void> } = $props();
  const item = $derived(session.items[0]);
  const state = $derived(item?.kind === "approval" ? "approval" : item?.kind === "question" ? "input" : session.attention);
  const tint = $derived(attentionTint(state));
</script>

<div class="notice" style:border-color="color-mix(in srgb, {tint} 35%, transparent)" style:background-image="linear-gradient(color-mix(in srgb, {tint} 10%, transparent), transparent 60%)">
  <button class="top press" onclick={onopen}>
    <AgentMark agent={session.agent} size={16} />
    <span class="title">{session.title}</span>
    <StatusPill attention={state} />
  </button>
  {#if item}
    <p class="ask">{item.title}</p>
    {#if item.detail}<code class="detail">{item.detail}</code>{/if}
    <div class="actions">
      {#if !may(view, "approve")}
        <span class="note" style:color="var(--text2)"><Ico name="lock" size={12} />{tr("Goedkeuren staat uit voor deze iPhone in Nook op je Mac.", "Approving is turned off for this phone in Nook on your Mac.")}</span>
      {:else if item.kind === "approval" && item.canAllow}
        <DecisionButton kind="deny" label={tr("Weiger", "Deny")} onclick={() => { haptic("warning"); act(() => companion.decide(session.id, item.id, false)); }} />
        <DecisionButton kind="allow" label={tr("Sta toe", "Allow")} onclick={() => { haptic("success"); act(() => companion.decide(session.id, item.id, true)); }} />
      {:else if item.kind === "approval"}
        <button class="ghost press" onclick={() => { haptic("warning"); act(() => companion.decide(session.id, item.id, false)); }}>{tr("Weiger", "Deny")}</button>
        <span class="note"><Ico name="lock" size={12} />{tr("Alleen op je Mac: dit is riskant of onbekend.", "Only on your Mac: this one is risky or unknown.")}</span>
      {:else}
        <button class="answer press" onclick={onopen}>{tr("Antwoord", "Answer")}</button>
      {/if}
      {#if session.items.length > 1}<span class="sp"></span><span class="more">{tr("en nog {n}", "and {n} more", { n: session.items.length - 1 })}</span>{/if}
    </div>
  {:else if session.excerpt}
    <p class="excerpt">{session.excerpt}</p>
  {/if}
</div>

<style>
  .notice { display: flex; flex-direction: column; gap: 12px; padding: 16px; border-radius: 12px; border: 1px solid; background-color: var(--surface); }
  .top { display: flex; align-items: center; gap: 8px; text-align: left; }
  .title { flex: 1; min-width: 0; font: var(--pt-label); color: var(--text2); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .ask { margin: 0; font: var(--pt-strong); color: var(--paper); display: -webkit-box; -webkit-line-clamp: 4; line-clamp: 4; -webkit-box-orient: vertical; overflow: hidden; }
  .detail { font: var(--pt-code); color: var(--text2); padding: 8px; background: var(--well); border: 0.5px solid var(--hairline); border-radius: 8px; display: -webkit-box; -webkit-line-clamp: 2; line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
  .actions { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
  .note { display: flex; align-items: baseline; gap: 6px; font: var(--pt-detail); color: var(--amber); flex: 1; min-width: 160px; }
  .ghost { height: 44px; padding: 0 16px; border-radius: 999px; color: var(--coral) !important; font: 600 16px var(--font) !important; }
  .answer { height: 44px; padding: 0 18px; border-radius: 999px; background: var(--paper) !important; color: var(--ink) !important; font: 600 16px var(--font) !important; }
  .sp { flex: 1; }
  .more { font: var(--pt-caption); color: var(--text3); }
  .excerpt { margin: 0; font: var(--pt-detail); color: var(--text2); display: -webkit-box; -webkit-line-clamp: 3; line-clamp: 3; -webkit-box-orient: vertical; overflow: hidden; }
</style>
