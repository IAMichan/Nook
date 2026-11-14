<script lang="ts">
  // Eén sessie: wat er op je wacht (goedkeuren of antwoorden), het laatste antwoord, een bericht sturen en stoppen.
  import { attentionColor, attentionWord, canStop, companion, type ClientView, type SessionDigest } from "../../lib/companion";
  import { tr } from "../../lib/i18n.svelte";

  let { session, onback, act }: { session: SessionDigest | null; onback: () => void; act: (f: () => Promise<ClientView>) => Promise<void> } = $props();
  let message = $state("");
  let answers = $state<Record<string, string>>({});
  let confirmStop = $state(false);

  function send() {
    if (!session) return;
    const text = message.trim();
    if (!text) return;
    message = "";
    act(() => companion.send(session.id, text));
  }

  function answer(item: string, text: string) {
    if (!session || !text.trim()) return;
    answers[item] = "";
    act(() => companion.answer(session.id, item, text.trim()));
  }
</script>

<div class="detail">
  <header>
    <button class="ghost back" onclick={onback} aria-label={tr("Terug", "Back")}>‹</button>
    <h2>{session?.title ?? tr("Sessie", "Session")}</h2>
  </header>
  {#if !session}
    <p class="faint pad">{tr("Deze sessie is er niet meer.", "This session no longer exists.")}</p>
  {:else}
    <div class="body">
      <section>
        <div class="state" style="color:{attentionColor(session.attention)}">● {attentionWord(session.attention)}</div>
        <div class="faint small">{session.agent} · {session.folder}{session.branch ? ` · ${session.branch}` : ""}</div>
      </section>

      {#each session.items as item (item.id)}
        <section class="item">
          <h3>{item.kind === "approval" ? tr("Toestemming", "Permission") : tr("Vraag", "Question")}</h3>
          <p>{item.title}</p>
          {#if item.detail}<p class="faint small">{item.detail}</p>{/if}
          {#if item.kind === "approval"}
            <div class="buttons">
              <button class="danger" onclick={() => act(() => companion.decide(session.id, item.id, false))}>{tr("Weiger", "Deny")}</button>
              {#if item.canAllow}
                <button class="primary" onclick={() => act(() => companion.decide(session.id, item.id, true))}>{tr("Sta toe", "Allow")}</button>
              {/if}
            </div>
            {#if !item.canAllow}<p class="warn small">{tr("Dit is riskant of onbekend: toestaan kan alleen op je computer.", "This is risky or unknown: you can only allow it on your computer.")}</p>{/if}
          {:else if item.canAllow}
            <div class="options">
              {#each item.options as option (option)}
                <button onclick={() => answer(item.id, option)}>{option}</button>
              {/each}
            </div>
            <div class="own">
              <input placeholder={tr("Eigen antwoord", "Your own answer")} bind:value={answers[item.id]} onkeydown={(e) => e.key === "Enter" && answer(item.id, answers[item.id] ?? "")} />
              <button disabled={!answers[item.id]?.trim()} onclick={() => answer(item.id, answers[item.id] ?? "")}>{tr("Stuur", "Send")}</button>
            </div>
          {:else}
            <p class="warn small">{tr("Meerdere vragen tegelijk: beantwoord ze op je computer.", "Several questions at once: answer them on your computer.")}</p>
          {/if}
        </section>
      {/each}

      {#if session.excerpt}
        <section>
          <h3>{tr("Laatste antwoord", "Latest reply")}</h3>
          <p class="excerpt">{session.excerpt}</p>
        </section>
      {/if}

      <section>
        <h3>{tr("Stuur een bericht", "Send a message")}</h3>
        <textarea rows="3" placeholder={tr("Bericht aan de agent", "Message to the agent")} bind:value={message}></textarea>
        <button class="primary send" disabled={!message.trim()} onclick={send}>{tr("Verstuur", "Send")}</button>
      </section>

      {#if canStop(session.attention)}
        <section>
          {#if confirmStop}
            <p>{tr("De sessie stoppen?", "Stop the session?")}</p>
            <div class="buttons">
              <button onclick={() => (confirmStop = false)}>{tr("Annuleer", "Cancel")}</button>
              <button class="danger" onclick={() => { confirmStop = false; act(() => companion.stop(session.id)); }}>{tr("Stop de sessie", "Stop the session")}</button>
            </div>
          {:else}
            <button class="danger wide" onclick={() => (confirmStop = true)}>{tr("Stop", "Stop")}</button>
          {/if}
        </section>
      {/if}
    </div>
  {/if}
</div>

<style>
  .detail { display: flex; flex-direction: column; height: 100%; min-height: 0; }
  header { display: flex; align-items: center; gap: 4px; padding: 8px 12px 8px 4px; border-bottom: 1px solid var(--line); }
  header h2 { margin: 0; font-size: 16px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .back { min-width: 44px; min-height: 44px; font-size: 26px; line-height: 1; }
  .body { flex: 1; overflow-y: auto; padding: 8px 16px 24px; }
  section { padding: 12px 0; border-bottom: 1px solid var(--line); display: flex; flex-direction: column; gap: 8px; }
  section:last-child { border-bottom: none; }
  h3 { margin: 0; font-size: 12px; color: var(--text2); text-transform: uppercase; letter-spacing: 0.04em; }
  p { margin: 0; line-height: 1.45; user-select: text; }
  .small { font-size: 12px; }
  .state { font-weight: 600; }
  .warn { color: var(--amber); }
  .buttons { display: flex; gap: 8px; }
  .buttons button { flex: 1; min-height: 46px; }
  .options { display: flex; flex-direction: column; gap: 6px; }
  .options button { min-height: 44px; text-align: left; }
  .own { display: flex; gap: 8px; }
  .own input { flex: 1; min-width: 0; min-height: 44px; }
  .own button { min-height: 44px; }
  textarea { resize: none; min-height: 72px; }
  .send, .wide { min-height: 46px; }
  .excerpt { white-space: pre-wrap; font-size: 13px; color: var(--text2); }
  .pad { padding: 16px; }
</style>
