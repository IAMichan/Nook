<script lang="ts">
  // Settings › Agents › Updates (`AgentUpdatesSection` on the Mac): each agent's program, its version and the newest
  // one, and Update, which runs the installer that put it there (npm, pnpm, Bun, Volta, Scoop, mise, Homebrew or the
  // agent's own updater) after you confirm. Running sessions keep the version they started with.
  import { ask } from "../../lib/confirm.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import { toast } from "../../lib/toast.svelte";
  import { updatesApi, type AgentUpdateRow } from "../../lib/workspace/agent-updates";
  import { isActive } from "../../lib/workspace/api";
  import { workspace } from "../../lib/workspace/store.svelte";
  import AgentMark from "../companion/ui/AgentMark.svelte";

  let rows = $state<AgentUpdateRow[]>([]);
  let checking = $state(false);
  let updating = $state<Set<string>>(new Set());

  async function load(latest: boolean) {
    checking = latest;
    try {
      rows = await updatesApi.list(latest);
    } catch (e) {
      toast.error(tr("Zoeken naar updates mislukt", "Checking for updates failed"), e);
    } finally {
      checking = false;
    }
  }
  $effect(() => { load(true); });

  const outdated = $derived(rows.filter((r) => r.outdated && r.command));

  function how(r: AgentUpdateRow): string {
    if (!r.command) return tr("Nook kan niet zien wat {agent} installeerde. Werk het bij zoals je het installeerde.", "Nook cannot tell what installed {agent}. Update it the way you installed it.", { agent: r.name });
    if (r.installer === "self") return tr("Geïnstalleerd met het eigen installatieprogramma van {agent}: Nook draait de eigen updater.", "Installed with {agent}'s own installer: Nook runs its own updater.", { agent: r.name });
    return tr("Geïnstalleerd met {installer}: Nook draait de updateopdracht daarvan.", "Installed with {installer}: Nook runs its update command.", { installer: r.installer });
  }

  async function update(list: AgentUpdateRow[]) {
    if (!list.length) return;
    const running = workspace.runs.filter((r) => isActive(r.status) && list.some((x) => x.kind === r.provider)).length;
    const yes = await ask({
      question: list.length === 1 ? tr("{agent} bijwerken?", "Update {agent}?", { agent: list[0].name }) : tr("{count} agents bijwerken?", "Update {count} agents?", { count: list.length }),
      detail: [
        list.map((r) => r.command).join("\n"),
        running ? tr("Er lopen {count} sessies van deze agents. Ze houden de versie waarmee ze begonnen tot ze stoppen.", "{count} sessions of these agents are running. They keep the version they started with until they end.", { count: running }) : "",
      ].filter(Boolean).join("\n\n"),
      confirmTitle: tr("Bijwerken", "Update"),
    });
    if (!yes) return;
    for (const r of list) {
      updating = new Set([...updating, r.kind]);
      try {
        await updatesApi.update(r.kind);
      } catch (e) {
        toast.error(tr("Bijwerken mislukt", "Update failed"), `${r.name}: ${e}`);
      } finally {
        updating = new Set([...updating].filter((k) => k !== r.kind));
      }
    }
    await load(true);
  }

  export async function updateAgent(kind: string) {
    if (!rows.length) await load(true);
    const row = rows.find((r) => r.kind === kind);
    if (row) await update([row]);
  }
</script>

<div class="section-head">
  <h3>{tr("Updates", "Updates")}</h3>
  <span class="spacer"></span>
  {#if outdated.length > 1}<button class="small" onclick={() => update(outdated)}>{tr("Alles bijwerken ({count})", "Update all ({count})", { count: outdated.length })}</button>{/if}
  <button class="small" disabled={checking} onclick={() => load(true)}>{checking ? tr("Controleren…", "Checking…") : tr("Zoek naar updates", "Check for updates")}</button>
</div>
<p class="section-info">{tr("Het programma van elke agent, de versie en de nieuwste. Bijwerken draait het installatieprogramma dat het neerzette (npm, pnpm, Bun, Volta, Scoop, mise of de eigen updater van de agent), nadat je het bevestigt. Lopende sessies houden de versie waarmee ze begonnen.", "Each agent's program, its version and the newest one. Update runs the installer that put it there (npm, pnpm, Bun, Volta, Scoop, mise, or the agent's own updater) after you confirm. Running sessions keep the version they started with.")}</p>
<div class="group">
  {#each rows as r (r.kind)}
    <div class="row">
      <AgentMark agent={r.name} size={22} />
      <div class="body">
        <span class="name">{r.name}{#if r.installed}<span class="ver">{r.installed}</span>{/if}</span>
        <span class="detail">
          {#if r.outdated && r.latest}{tr("Update beschikbaar: {version}", "Update available: {version}", { version: r.latest })} · {:else if r.latest}{tr("Bijgewerkt", "Up to date")} · {/if}{how(r)}
        </span>
      </div>
      {#if r.outdated && r.command}
        <button class="small primary" disabled={updating.has(r.kind)} onclick={() => update([r])}>{updating.has(r.kind) ? tr("Bijwerken…", "Updating…") : tr("Bijwerken", "Update")}</button>
      {/if}
    </div>
  {:else}
    <div class="empty"><strong>{tr("Geen agentprogramma's gevonden", "No agent programs found")}</strong><span>{tr("Zodra een agent is geïnstalleerd, staat zijn programma hier met de versie.", "Once an agent is installed, its program shows here with its version.")}</span></div>
  {/each}
</div>

<style>
  .section-head { display: flex; align-items: center; gap: var(--space-8); }
  .spacer { flex: 1; }
  .row { display: flex; align-items: center; gap: var(--space-12); padding: var(--space-8) var(--space-12); }
  .row + .row { border-top: 1px solid var(--line); }
  .body { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: var(--space-2); }
  .name { font: var(--text-body); color: var(--paper); display: flex; gap: var(--space-8); align-items: baseline; }
  .ver { font: var(--text-detail); color: var(--text3); font-variant-numeric: tabular-nums; }
  .detail { font: var(--text-detail); color: var(--text3); }
  .empty { display: flex; flex-direction: column; gap: var(--space-4); padding: var(--space-12); font: var(--text-body); color: var(--text2); }
  .empty span { font: var(--text-detail); color: var(--text3); }
</style>
