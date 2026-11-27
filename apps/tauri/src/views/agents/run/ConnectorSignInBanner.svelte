<script lang="ts">
  // Above a session's composer: MCP connectors the agent has but cannot use until you sign in (`ConnectorSignInBanner`, AG-31).
  // One connector gets its own "Sign in"; several share a dropdown menu. Hiding dismisses these connectors across sessions
  // (the session menu still lists them via `ConnectorSignInGroup`).
  import Dropdown from "../../../components/ui/Dropdown.svelte";
  import Ico from "../../../components/ui/Ico.svelte";
  import { tr } from "../../../lib/i18n.svelte";
  import { serviceIconUrl } from "../../../lib/service-icons";
  import { workspaceApi, type ConnectorSignIn } from "../../../lib/workspace/api";
  import { BANNER_LOGO_LIMIT, shownConnectors, waitingConnector } from "../../../lib/workspace/connector-sign-in";
  import { workspace } from "../../../lib/workspace/store.svelte";

  let {
    runId,
    connectors,
    dismissed,
  }: {
    runId: string;
    connectors: ConnectorSignIn[];
    dismissed: string[];
  } = $props();

  let icons = $state<Record<string, string | null>>({});

  let shown = $derived(shownConnectors(connectors, dismissed));
  let waiting = $derived(waitingConnector(shown));
  let logos = $derived(shown.slice(0, BANNER_LOGO_LIMIT));

  $effect(() => {
    for (const item of shown) {
      const domain = item.iconDomain;
      if (!domain || domain in icons) continue;
      icons = { ...icons, [domain]: null };
      void serviceIconUrl(domain).then((url) => {
        icons = { ...icons, [domain]: url };
      });
    }
  });

  function subtitle(): string {
    if (waiting) {
      return tr("Wacht op {name}…", "Waiting for {name}…", { name: waiting.title });
    }
    if (shown.length === 1) {
      return tr("{name} werkt pas als je inlogt.", "{name} works once you sign in.", { name: shown[0].title });
    }
    return tr("{count} connectors werken pas als je inlogt.", "{count} connectors work once you sign in.", { count: shown.length });
  }

  function signIn(name: string) {
    void workspace.act(() => workspaceApi.signInConnector(runId, name));
  }

  function hideAll() {
    const names = shown.map((c) => c.name);
    if (!names.length) return;
    void workspace.act(() => workspaceApi.hideConnectorSignIns(runId, names));
  }
</script>

{#if shown.length > 0}
  <div class="banner" role="region" aria-label={tr("Connectors wachten op je login", "Connectors need you to sign in")}>
    <div class="lead">
      <span class="logos" aria-hidden="true">
        {#each logos as connector (connector.name)}
          {@const src = connector.iconDomain ? icons[connector.iconDomain] : null}
          <span class="logo" title={connector.title}>
            {#if src}
              <img {src} alt="" width="16" height="16" />
            {:else}
              <span class="fallback"><Ico name="plug" size={14} stroke={2} /></span>
            {/if}
          </span>
        {/each}
      </span>
      <div class="copy">
        <span class="title">{tr("Connectors wachten op je login", "Connectors need you to sign in")}</span>
        <span class="detail">{subtitle()}</span>
      </div>
    </div>

    <div class="actions">
      {#if shown.length === 1}
        <button
          type="button"
          class="sign-in"
          disabled={shown[0].waiting}
          onclick={() => signIn(shown[0].name)}
        >{tr("Inloggen", "Sign in")}</button>
      {:else}
        <Dropdown width={224} label={tr("Inloggen", "Sign in")}>
          {#snippet trigger({ toggle, open })}
            <button
              type="button"
              class="sign-in menu-btn"
              class:lit={open}
              aria-expanded={open}
              onclick={toggle}
            >
              <span>{tr("Inloggen", "Sign in")}</span>
              <Ico name="chevron-down" size={11} stroke={2.5} />
            </button>
          {/snippet}
          {#snippet children({ close })}
            {#each shown as connector (connector.name)}
              {@const src = connector.iconDomain ? icons[connector.iconDomain] : null}
              <button
                type="button"
                class="menu-row"
                disabled={connector.waiting}
                title={connector.waiting
                  ? tr("De inlogpagina staat open in je browser. Nook kijkt mee tot de connector verbonden is.", "The sign-in page is open in your browser. Nook checks until the connector is connected.")
                  : undefined}
                onclick={() => {
                  close();
                  signIn(connector.name);
                }}
              >
                <span class="row-ico" aria-hidden="true">
                  {#if src}
                    <img {src} alt="" width="14" height="14" />
                  {:else}
                    <Ico name={connector.waiting ? "hourglass" : "plug"} size={14} stroke={2} />
                  {/if}
                </span>
                <span class="row-name">
                  {connector.waiting
                    ? tr("Wacht op {name}…", "Waiting for {name}…", { name: connector.title })
                    : connector.title}
                </span>
              </button>
            {/each}
          {/snippet}
        </Dropdown>
      {/if}

      <button
        type="button"
        class="hide-btn"
        title={tr("Niet meer tonen voor deze connectors. Je vindt ze nog in het menu van de sessie.", "Stop showing these connectors here. The session menu still lists them.")}
        aria-label={tr("Niet meer tonen voor deze connectors. Je vindt ze nog in het menu van de sessie.", "Stop showing these connectors here. The session menu still lists them.")}
        onclick={hideAll}
      ><Ico name="x" size={12} stroke={2.4} /></button>
    </div>
  </div>
{/if}

<style>
  .banner {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: var(--space-12);
    flex-wrap: wrap;
    padding: var(--space-8) var(--space-12);
    border: 1px solid var(--field-stroke);
    border-radius: var(--radius-panel);
    background: var(--surface);
    min-width: 0;
  }
  .lead {
    display: flex;
    align-items: center;
    gap: var(--space-10);
    min-width: 0;
    flex: 1 1 200px;
  }
  .logos {
    display: inline-flex;
    align-items: center;
    gap: var(--space-4);
    flex: none;
  }
  .logo {
    display: inline-grid;
    place-items: center;
    width: 16px;
    height: 16px;
    border-radius: var(--radius-chat-join);
    overflow: hidden;
  }
  .logo img {
    display: block;
    width: 16px;
    height: 16px;
    object-fit: contain;
  }
  .fallback {
    display: inline-flex;
    color: var(--amber);
  }
  .copy {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    min-width: 0;
  }
  .title {
    font: var(--text-emphasis);
    color: var(--text2);
  }
  .detail {
    font: var(--text-detail);
    color: var(--text3);
  }
  .actions {
    display: inline-flex;
    align-items: center;
    gap: var(--space-6);
    flex: none;
  }
  .sign-in {
    display: inline-flex;
    align-items: center;
    gap: var(--space-4);
    height: 30px;
    padding: 0 var(--space-10);
    margin: 0;
    border: 0;
    border-radius: var(--radius-control);
    background: transparent;
    color: var(--text2);
    font: var(--text-emphasis);
    cursor: pointer;
    white-space: nowrap;
  }
  .sign-in:hover:not(:disabled),
  .sign-in.lit {
    background: var(--smoke);
    color: var(--paper);
  }
  .sign-in:disabled {
    opacity: 0.45;
    cursor: default;
  }
  .hide-btn {
    display: grid;
    place-items: center;
    width: 22px;
    height: 22px;
    padding: 0;
    margin: 0;
    border: 0;
    border-radius: var(--radius-chip);
    background: transparent;
    color: var(--text3);
    cursor: pointer;
  }
  .hide-btn:hover {
    background: var(--smoke);
    color: var(--paper);
  }
  .menu-row {
    display: flex;
    align-items: center;
    gap: var(--space-8);
    width: 100%;
    min-height: 30px;
    margin: 0;
    padding: var(--space-6) var(--space-8);
    border: 0;
    border-radius: var(--radius-chip);
    background: transparent;
    color: var(--paper);
    font: var(--text-body);
    text-align: left;
    cursor: pointer;
  }
  .menu-row:hover:not(:disabled) {
    background: var(--smoke);
  }
  .menu-row:disabled {
    opacity: 0.55;
    cursor: default;
  }
  .row-ico {
    display: inline-grid;
    place-items: center;
    width: 15px;
    height: 15px;
    flex: none;
    color: var(--text2);
  }
  .row-ico img {
    display: block;
    width: 14px;
    height: 14px;
    border-radius: var(--radius-chat-join);
    object-fit: contain;
  }
  .row-name {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
</style>
