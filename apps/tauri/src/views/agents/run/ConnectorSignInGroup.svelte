<script lang="ts">
  // Connectors waiting for sign-in inside the session menu (`ConnectorSignInGroup` on the Mac, AG-31).
  // Up to three show directly; more fold into a single expandable row with an in-place scrolling list.
  import Ico from "../../../components/ui/Ico.svelte";
  import { tr } from "../../../lib/i18n.svelte";
  import { serviceIconUrl } from "../../../lib/service-icons";
  import { workspaceApi, type ConnectorSignIn } from "../../../lib/workspace/api";
  import { MENU_INLINE_LIMIT } from "../../../lib/workspace/connector-sign-in";
  import { workspace } from "../../../lib/workspace/store.svelte";

  let {
    runId,
    connectors,
    onselect,
  }: {
    runId: string;
    connectors: ConnectorSignIn[];
    onselect?: () => void;
  } = $props();

  let expanded = $state(false);
  let icons = $state<Record<string, string | null>>({});

  $effect(() => {
    for (const item of connectors) {
      const domain = item.iconDomain;
      if (!domain || domain in icons) continue;
      icons = { ...icons, [domain]: null };
      void serviceIconUrl(domain).then((url) => {
        icons = { ...icons, [domain]: url };
      });
    }
  });

  function signIn(name: string) {
    onselect?.();
    void workspace.act(() => workspaceApi.signInConnector(runId, name));
  }
</script>

{#if connectors.length > 0}
  <div class="group-sep" role="separator"></div>
  {#if connectors.length <= MENU_INLINE_LIMIT}
    <div class="group-head">{tr("Connectors", "Connectors")}</div>
    {#each connectors as connector (connector.name)}
      {@const src = connector.iconDomain ? icons[connector.iconDomain] : null}
      <button
        type="button"
        class="row"
        disabled={connector.waiting}
        title={connector.waiting
          ? tr("De inlogpagina staat open in je browser. Nook kijkt mee tot de connector verbonden is.", "The sign-in page is open in your browser. Nook checks until the connector is connected.")
          : undefined}
        onclick={() => signIn(connector.name)}
      >
        <span class="ico" aria-hidden="true">
          {#if src && !connector.waiting}
            <img {src} alt="" width="14" height="14" />
          {:else}
            <Ico name={connector.waiting ? "hourglass" : "plug"} size={14} stroke={2} />
          {/if}
        </span>
        <span class="label">
          {connector.waiting
            ? tr("Wacht op {name}…", "Waiting for {name}…", { name: connector.title })
            : connector.title}
        </span>
        {#if !connector.waiting}
          <span class="trailing">{tr("Inloggen", "Sign in")}</span>
        {/if}
      </button>
    {/each}
  {:else}
    <button
      type="button"
      class="row"
      aria-expanded={expanded}
      onclick={(e) => {
        e.stopPropagation();
        expanded = !expanded;
      }}
    >
      <span class="ico" aria-hidden="true"><Ico name="plug" size={14} stroke={2} /></span>
      <span class="label">{tr("Connectors", "Connectors")}</span>
      <span class="trailing">{connectors.length}</span>
      <span class="chev" class:open={expanded} aria-hidden="true"><Ico name="chevron-right" size={12} stroke={2.4} /></span>
    </button>
    {#if expanded}
      <div class="scroll-list">
        {#each connectors as connector (connector.name)}
          {@const src = connector.iconDomain ? icons[connector.iconDomain] : null}
          <button
            type="button"
            class="row"
            disabled={connector.waiting}
            title={connector.waiting
              ? tr("De inlogpagina staat open in je browser. Nook kijkt mee tot de connector verbonden is.", "The sign-in page is open in your browser. Nook checks until the connector is connected.")
              : undefined}
            onclick={() => signIn(connector.name)}
          >
            <span class="ico" aria-hidden="true">
              {#if src && !connector.waiting}
                <img {src} alt="" width="14" height="14" />
              {:else}
                <Ico name={connector.waiting ? "hourglass" : "plug"} size={14} stroke={2} />
              {/if}
            </span>
            <span class="label">
              {connector.waiting
                ? tr("Wacht op {name}…", "Waiting for {name}…", { name: connector.title })
                : connector.title}
            </span>
            {#if !connector.waiting}
              <span class="trailing">{tr("Inloggen", "Sign in")}</span>
            {/if}
          </button>
        {/each}
      </div>
    {/if}
  {/if}
{/if}

<style>
  .group-sep {
    height: 1px;
    margin: var(--space-4) var(--space-8);
    background: var(--line);
  }
  .group-head {
    padding: var(--space-4) var(--space-8) var(--space-2);
    font: var(--text-label);
    color: var(--text3);
  }
  .scroll-list {
    max-height: 186px;
    overflow-y: auto;
    padding-left: var(--space-8);
  }
  .row {
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
  .row:hover:not(:disabled) {
    background: var(--smoke);
  }
  .row:disabled {
    opacity: 0.6;
    cursor: default;
  }
  .ico {
    display: inline-grid;
    place-items: center;
    width: 15px;
    height: 15px;
    flex: none;
    color: var(--text2);
  }
  .ico img {
    display: block;
    width: 14px;
    height: 14px;
    border-radius: var(--radius-chat-join);
    object-fit: contain;
  }
  .label {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .trailing {
    font: var(--text-detail);
    color: var(--text3);
    white-space: nowrap;
    flex: none;
  }
  .chev {
    display: inline-flex;
    color: var(--text3);
    flex: none;
    transition: transform 0.12s ease;
  }
  .chev.open {
    transform: rotate(90deg);
  }
</style>
