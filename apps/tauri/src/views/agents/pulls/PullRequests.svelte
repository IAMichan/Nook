<script lang="ts">
  // The pull requests of your GitHub accounts (`PullRequestsPanel` on the Mac): the ones you wrote, the ones waiting
  // for your review, and the others in the organizations and repositories you watch (Settings › Accounts &
  // koppelingen). Open ones by default; the Filters dropdown also shows closed and merged ones. A click opens the pull
  // request here, where it can be read in full and merged.
  import { api } from "../../../lib/api";
  import { connectorsApi, type AccountPullRequests, type PullRequestItem } from "../../../lib/connectors";
  import { pullRequests } from "../../../lib/pulls.svelte";
  import { apply, authors, defaultFilter, isActive, isEmpty, itemId, stateNames, unreadable } from "../../../lib/pulls";
  import { nook } from "../../../lib/state.svelte";
  import { ago } from "../time";
  import FilterMenu from "./FilterMenu.svelte";
  import PullGlyph from "./PullGlyph.svelte";
  import PullRequestView from "./PullRequestView.svelte";

  /// The pull request shown in full, with the account it is listed under.
  let opened = $state<{ account: string; item: PullRequestItem } | null>(null);
  /// Search and filters; kept while a pull request is open, so going back shows the same list.
  let filter = $state(defaultFilter());
  let now = $state(Date.now());
  let signIn = $state<{ busy: boolean; error: string | null }>({ busy: false, error: null });
  let search = $state<HTMLInputElement | null>(null);

  const watching = $derived(nook.settings?.watchedPullRequests ?? []);
  const accounts = $derived(pullRequests.accounts);
  const shown = $derived(accounts.map((a) => apply(filter, a)));
  const missing = $derived(unreadable(accounts, watching));

  // The last list shows at once; a stale one refreshes in the background, and again every minute while open.
  $effect(() => {
    pullRequests.refresh();
    const timer = setInterval(() => {
      now = Date.now();
      pullRequests.refresh();
    }, 60_000);
    return () => clearInterval(timer);
  });

  // A changed watch list refreshes at once.
  let lastWatching: string | null = null;
  $effect(() => {
    const key = watching.join(",");
    if (lastWatching !== null && key !== lastWatching) pullRequests.refresh(true);
    lastWatching = key;
  });

  function openSettings() {
    localStorage.setItem("settings.section", "accounts");
    api.showMain("settings");
  }

  async function useCli(account: string) {
    signIn = { busy: true, error: null };
    try {
      await connectorsApi.githubCli(account);
      signIn = { busy: false, error: null };
      pullRequests.refresh(true);
    } catch (e) {
      signIn = { busy: false, error: String(e) };
    }
  }

  function keys(e: KeyboardEvent) {
    // Ctrl+F (⌘F) jumps to the search field.
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "f" && !opened && search) {
      e.preventDefault();
      search.focus();
    }
  }

  const visible = (a: AccountPullRequests) => !isActive(filter) || !isEmpty(a) || !!a.error;
</script>

<svelte:window onkeydown={keys} />

{#if opened}
  {#key `${opened.account} ${itemId(opened.item)}`}
    <PullRequestView accountId={opened.account} item={opened.item} onback={() => (opened = null)} />
  {/key}
{:else}
  <div class="pulls">
    <div class="head">
      <strong>Pull requests</strong>
      <span class="spacer"></span>
      {#if pullRequests.loading}<span class="faint small">Bezig…</span>{/if}
      <button class="ghost" title="Organisaties en repositories volgen" onclick={openSettings}>Volgen</button>
      <button class="ghost" title="Vernieuwen" disabled={pullRequests.loading} onclick={() => pullRequests.refresh(true)}>Vernieuwen</button>
    </div>

    {#if pullRequests.error && !accounts.length}<p class="err">{pullRequests.error}</p>{/if}

    {#if pullRequests.loaded && !pullRequests.available && !accounts.length}
      {@render empty("GitHub is nog niet gekoppeld", "Koppel je GitHub-account (of accounts) onder Instellingen › Accounts & koppelingen, dan zie je hier al je pull requests.", ["Koppel GitHub", openSettings])}
    {:else if pullRequests.loaded && accounts.every((a) => isEmpty(a) && !a.error)}
      {@render empty("Geen open pull requests", "Je hebt niets open staan en niemand wacht op jouw review.")}
    {:else if !pullRequests.loaded}
      <p class="faint small">Pull requests laden…</p>
    {:else}
      <div class="filters">
        <label class="search">
          <span class="faint" aria-hidden="true">⌕</span>
          <input bind:this={search} placeholder="Zoek op titel, repo, #nummer of @auteur" bind:value={filter.query} onkeydown={(e) => e.key === "Escape" && ((filter.query = ""), search?.blur())} />
          {#if filter.query}<button class="clear" aria-label="Wissen" onclick={() => (filter.query = "")}>✕</button>{/if}
        </label>
        <FilterMenu bind:filter authors={authors(accounts)} watching={watching.length > 0} />
      </div>
      {#if missing.length}
        <p class="note">⚠ GitHub kon {missing.join(", ")} niet doorzoeken. Controleer de naam, of dat een van je accounts er toegang toe heeft.</p>
      {/if}
      {#if shown.every((a) => isEmpty(a) && !a.error)}
        {#if isActive(filter)}
          {@render empty("Geen pull requests gevonden", "Niets past bij je zoekopdracht of filter.", ["Wis filter", () => (filter = defaultFilter())])}
        {:else}
          <!-- Only closed or merged pull requests: nothing open, but the Status filter shows them. -->
          {@render empty("Geen open pull requests", "Je hebt niets open staan en niemand wacht op jouw review.")}
        {/if}
      {:else}
        <div class="list">
          {#each shown.filter(visible) as account (account.id)}
            <section class="account">
              {#if accounts.length > 1}
                <div class="who faint">◉ <strong>{account.name}</strong>{#if account.login} @{account.login}{/if}</div>
              {/if}
              {#if account.error}
                {#if account.errorKind === "auth"}
                  <!-- The token was rejected: say so in plain words and offer the fix right here. -->
                  <div class="expired">
                    <strong>⚠ GitHub-login verlopen</strong>
                    <span class="muted small">GitHub weigerde je token (401). Het is verlopen of ingetrokken. Log opnieuw in met je GitHub CLI-login, of vernieuw het token in de instellingen.</span>
                    <span class="actions">
                      <button class="primary" disabled={signIn.busy} onclick={() => useCli(account.id)}>Log in met GitHub CLI</button>
                      <button class="ghost" onclick={openSettings}>Instellingen</button>
                    </span>
                    {#if signIn.error}<span class="err">{signIn.error}</span>{/if}
                  </div>
                {:else}
                  <p class="err">{account.error}</p>
                {/if}
              {/if}
              {#if account.reviews.length}
                <!-- Closed and merged ones no longer wait for you: those are the ones you reviewed. -->
                {@render group(filter.state === "open" ? `Wacht op jouw review (${account.reviews.length})` : `Voor jouw review (${account.reviews.length})`, account.reviews, account.id, true)}
              {/if}
              {#if account.mine.length}{@render group(`Van jou (${account.mine.length})`, account.mine, account.id, false)}{/if}
              {#if account.watched.length}{@render group(`Gevolgd (${account.watched.length})`, account.watched, account.id, true)}{/if}
            </section>
          {/each}
        </div>
      {/if}
    {/if}
  </div>
{/if}

{#snippet empty(title: string, detail: string, action?: [string, () => void])}
  <div class="empty">
    <strong>{title}</strong>
    <span class="muted small">{detail}</span>
    {#if action}<button class="primary" onclick={action[1]}>{action[0]}</button>{/if}
  </div>
{/snippet}

{#snippet group(title: string, items: PullRequestItem[], account: string, showAuthor: boolean)}
  <div class="group">
    <div class="title faint">{title}</div>
    {#each items as item (itemId(item))}
      <button class="row" title="Bekijk pull request" onclick={() => (opened = { account, item })}>
        <span class="mark">
          {#if item.state === "merged"}<span class="merged" title={stateNames.merged}><PullGlyph glyph="merged" size={13} /></span>
          {:else if item.state === "closed"}<span class="closed" title={stateNames.closed}><PullGlyph glyph="closed" size={13} /></span>
          {:else if item.ci === "passing"}<span class="pass">✓</span>
          {:else if item.ci === "failing"}<span class="fail">✕</span>
          {:else if item.ci === "pending"}<span class="dot waiting"></span>
          {:else}<span class="dot hollow"></span>{/if}
        </span>
        <span class="text">
          <span class="name">{item.title}</span>
          <span class="meta faint">{itemId(item)}{#if showAuthor && item.author} · @{item.author}{/if}{#if item.draft} · concept{/if}</span>
        </span>
        {#if item.updated}<span class="faint small">{ago(item.updated, now)}</span>{/if}
        <span class="chevron faint">›</span>
      </button>
    {/each}
  </div>
{/snippet}

<style>
  .pulls { display: flex; flex-direction: column; gap: 12px; height: 100%; min-height: 0; }
  .head { display: flex; align-items: center; gap: 6px; min-height: 30px; }
  .spacer { flex: 1; }
  .small { font-size: 12px; }
  .err { color: var(--coral); font-size: 12px; margin: 0; }
  .note { color: var(--coral); opacity: 0.85; font-size: 12px; margin: 0; }
  .filters { display: flex; gap: 6px; align-items: center; }
  .search { flex: 1; min-width: 0; display: flex; align-items: center; gap: 6px; height: 30px; padding: 0 10px; background: var(--field); border: 1px solid var(--line2); border-radius: 9px; }
  .search input { flex: 1; min-width: 0; border: none; background: none; padding: 0; font-size: 12.5px; }
  .clear { border: none; background: none; padding: 0 2px; color: var(--text3); font-size: 11px; }
  .empty { display: flex; flex-direction: column; align-items: flex-start; gap: 8px; padding-top: 8px; }
  .empty strong { font-size: 15px; }
  .list { overflow-y: auto; min-height: 0; flex: 1; display: flex; flex-direction: column; gap: 18px; }
  .account { display: flex; flex-direction: column; gap: 8px; }
  .who { font-size: 12.5px; }
  .group { display: flex; flex-direction: column; gap: 2px; }
  .title { font-size: 11.5px; font-weight: 600; padding-bottom: 3px; }
  .row { display: flex; align-items: center; gap: 10px; padding: 8px 10px; border: none; background: none; border-radius: 10px; text-align: left; }
  .row:hover { background: var(--smoke); }
  .row .chevron { opacity: 0; }
  .row:hover .chevron { opacity: 1; }
  .mark { width: 16px; display: grid; place-items: center; flex: none; }
  .pass { color: var(--mint); }
  .fail { color: var(--coral); }
  .merged { color: var(--violet); display: grid; }
  .closed { color: var(--coral); display: grid; }
  .dot.hollow { border: 1.2px solid var(--text3); }
  .text { display: flex; flex-direction: column; gap: 2px; min-width: 0; flex: 1; }
  .name { font-size: 13.5px; font-weight: 500; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .meta { font-size: 11.5px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .expired { display: flex; flex-direction: column; gap: 8px; padding: 14px; border-radius: var(--radius); background: rgba(255, 107, 107, 0.1); }
  .actions { display: flex; gap: 4px; }
</style>
