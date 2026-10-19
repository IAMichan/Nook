<script lang="ts">
  // Welke accounts deze chat mag gebruiken ("GitHub · Werk"), alleen bij diensten met meer dan één account.
  import { connectorsApi, connectorEvents, type ChatService } from "../../lib/connectors";

  // Een nieuwe chat heeft nog geen id: `ensure` maakt hem aan zodra je iets kiest.
  let { nookId, ensure }: { nookId: string | null; ensure?: () => Promise<string> } = $props();
  let services = $state<ChatService[]>([]);

  async function load() {
    services = await connectorsApi.chatAccounts(nookId ?? "").catch(() => []);
  }

  $effect(() => {
    load();
    const un = connectorEvents.onChanged(load);
    return () => {
      un.then((f) => f());
    };
  });

  async function toggle(id: string, allowed: boolean) {
    const excluded = services.flatMap((s) => s.accounts).filter((a) => (a.id === id ? !allowed : !a.allowed)).map((a) => a.id);
    const target = nookId ?? (await ensure?.());
    if (!target) return;
    await connectorsApi.setChatAccounts(target, excluded);
    await load();
  }
</script>

{#if services.length}
  <div class="accounts">
    {#each services as s (s.service)}
      {#each s.accounts as a (a.id)}
        <label title="Mag deze chat {a.title} gebruiken?">
          <input type="checkbox" checked={a.allowed} onchange={(e) => toggle(a.id, e.currentTarget.checked)} />
          {a.title}
        </label>
      {/each}
    {/each}
  </div>
{/if}

<style>
  .accounts { display: flex; flex-wrap: wrap; gap: 10px; font-size: 11px; color: var(--text3); }
  label { display: inline-flex; gap: 5px; align-items: center; }
</style>
