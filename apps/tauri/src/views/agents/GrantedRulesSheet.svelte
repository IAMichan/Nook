<script lang="ts">
  // Granted permission rules per project (AG-45) and searchable approval audit log (AG-42), matching the Mac's
  // `GrantedRules` (`PermissionScope.swift`) and `ApprovalAudit` / `AuditLogSection.swift`.
  import { agentApi, type ApprovalAuditEntry, type GrantedRuleEntry } from "../../lib/agents";
  import { agents } from "../../lib/agents.svelte";
  import { ask } from "../../lib/confirm.svelte";
  import { locale, tr } from "../../lib/i18n.svelte";
  import { toast } from "../../lib/toast.svelte";
  import { workspace } from "../../lib/workspace/store.svelte";
  import Ico from "../../components/ui/Ico.svelte";
  import { ago, folderName } from "./time";

  let {
    project = null,
    initialTab = "rules",
    onclose,
  }: {
    project?: string | null;
    initialTab?: "rules" | "audit";
    onclose: () => void;
  } = $props();

  type Tab = "rules" | "audit";
  let tabOverride = $state<Tab | null>(null);
  let projectOverride = $state<string | null>(null);
  const tab = $derived<Tab>(tabOverride ?? initialTab);
  const projectFilter = $derived<string>(projectOverride ?? (project ?? ""));
  let ruleQuery = $state("");
  let auditQuery = $state("");
  let decisionFilter = $state<string>("");

  let rules = $state<GrantedRuleEntry[]>([]);
  let audit = $state<ApprovalAuditEntry[]>([]);
  let loading = $state(false);
  let error = $state<string | null>(null);
  let busyId = $state<string | null>(null);

  function knownProjects(): string[] {
    const set = new Set<string>();
    if (project) set.add(project);
    for (const s of agents.sessions) if (s.cwd) set.add(s.cwd);
    for (const r of workspace.runs) if (r.projectPath) set.add(r.projectPath);
    for (const p of agents.history?.sessions ?? []) if (p.cwd) set.add(p.cwd);
    return [...set];
  }

  async function refresh() {
    loading = true;
    error = null;
    try {
      const [r, a] = await Promise.all([
        agentApi.grantedRules(projectFilter || null, knownProjects()),
        agentApi.approvalAudit(auditQuery.trim() || null, 300),
      ]);
      rules = r;
      audit = a;
    } catch (e) {
      error = String(e);
    } finally {
      loading = false;
    }
  }

  $effect(() => {
    // Re-fetch when projectFilter or auditQuery changes.
    void projectFilter;
    void auditQuery;
    void refresh();
  });

  const filteredRules = $derived.by(() => {
    const q = ruleQuery.trim().toLowerCase();
    if (!q) return rules;
    return rules.filter(
      (r) =>
        r.rule.toLowerCase().includes(q) ||
        r.projectName.toLowerCase().includes(q) ||
        r.project.toLowerCase().includes(q) ||
        r.agent.toLowerCase().includes(q) ||
        r.reachLabel.toLowerCase().includes(q),
    );
  });

  interface RuleGroup {
    project: string;
    label: string;
    entries: GrantedRuleEntry[];
  }

  const ruleGroups = $derived.by<RuleGroup[]>(() => {
    const map = new Map<string, GrantedRuleEntry[]>();
    for (const entry of filteredRules) {
      const list = map.get(entry.project) ?? [];
      list.push(entry);
      map.set(entry.project, list);
    }
    return [...map.entries()].map(([proj, entries]) => ({
      project: proj,
      label: proj ? (entries[0]?.projectName || folderName(proj)) : tr("Alle projecten (gebruiker)", "All projects (user)"),
      entries,
    }));
  });

  const filteredAudit = $derived.by(() => {
    if (!decisionFilter) return audit;
    return audit.filter((a) => a.decision === decisionFilter);
  });

  function reachText(r: GrantedRuleEntry): string {
    switch (r.reach) {
      case "project": return tr("dit project", "this project");
      case "sharedProject": return tr("gedeeld in project", "shared in project");
      case "user": return tr("alle projecten", "all projects");
      case "session": return tr("deze sessie", "this session");
      default: return r.reachLabel || tr("door de agent bepaald", "agent decides");
    }
  }

  function fileHint(path: string): string {
    if (!path) return "";
    const parts = path.split(/[\\/]/);
    if (parts.length >= 2 && parts[parts.length - 2] === ".claude") {
      return `.claude/${parts[parts.length - 1]}`;
    }
    return parts[parts.length - 1] || path;
  }

  function decisionLabel(decision: string): string {
    switch (decision) {
      case "allow": return tr("Toegestaan", "Allowed");
      case "always": return tr("Altijd", "Always");
      case "deny": return tr("Geweigerd", "Denied");
      case "terminal": return tr("Terminal", "Terminal");
      case "expired": return tr("Verlopen", "Expired");
      default: return decision;
    }
  }

  function decisionTone(decision: string): string {
    switch (decision) {
      case "allow": return "mint";
      case "always": return "blue";
      case "deny": return "coral";
      case "terminal": return "amber";
      default: return "muted";
    }
  }

  function sourceLabel(source?: string | null): string {
    switch (source) {
      case "app": return tr("App", "App");
      case "notification": return tr("Melding", "Notification");
      case "phone": return tr("Telefoon", "Phone");
      default: return "";
    }
  }

  function exactTime(iso: string): string {
    const d = new Date(iso);
    if (Number.isNaN(d.getTime())) return iso;
    return d.toLocaleString(locale(), { dateStyle: "short", timeStyle: "medium" });
  }

  async function revokeOne(entry: GrantedRuleEntry) {
    busyId = entry.id;
    error = null;
    try {
      await agentApi.revokeRule(entry.project, entry.rule, entry.file || null);
      toast.success(tr("Regel ingetrokken", "Rule revoked"));
      await refresh();
    } catch (e) {
      error = String(e);
    } finally {
      busyId = null;
    }
  }

  async function revokeProject(group: RuleGroup) {
    if (!group.project) return;
    const ok = await ask({
      question: tr("Alle regels voor {project} intrekken?", "Revoke all rules for {project}?", { project: group.label }),
      detail: tr("Agents vragen daarna weer toestemming voordat ze deze acties uitvoeren.", "Agents will ask for permission again before running these actions."),
      confirmTitle: tr("Alles intrekken", "Revoke all"),
    });
    if (!ok) return;
    busyId = `project:${group.project}`;
    error = null;
    try {
      const count = await agentApi.revokeProjectRules(group.project);
      toast.success(tr("{n} regels ingetrokken", "{n} rules revoked", { n: count }));
      await refresh();
    } catch (e) {
      error = String(e);
    } finally {
      busyId = null;
    }
  }

  async function clearAudit() {
    const ok = await ask({
      question: tr("Geschiedenis van goedkeuringen wissen?", "Clear approval log?"),
      detail: tr("Opgeslagen regels blijven behouden.", "Granted rules are not affected."),
      confirmTitle: tr("Wissen", "Clear"),
    });
    if (!ok) return;
    error = null;
    try {
      await agentApi.clearApprovalAudit();
      toast.success(tr("Geschiedenis gewist", "Approval log cleared"));
      await refresh();
    } catch (e) {
      error = String(e);
    }
  }

  function keys(e: KeyboardEvent) {
    if (e.key === "Escape") {
      e.preventDefault();
      onclose();
    }
  }
</script>

<svelte:window onkeydown={keys} />

<div class="backdrop" role="presentation" onclick={onclose}>
  <div class="sheet" role="dialog" aria-modal="true" aria-label={tr("Toestemmingen", "Permissions")} tabindex="-1" onclick={(e) => e.stopPropagation()} onkeydown={() => {}}>
    <header>
      <span class="head-ico"><Ico name="shield-check" size={18} /></span>
      <h2>{tr("Toestemmingen", "Permissions")}</h2>
      <span class="spacer"></span>
      <div class="segments" role="tablist">
        <button role="tab" aria-selected={tab === "rules"} class:on={tab === "rules"} onclick={() => (tabOverride = "rules")}>
          {tr("Opgeslagen regels", "Granted rules")}{#if rules.length}<span class="pill-count">{rules.length}</span>{/if}
        </button>
        <button role="tab" aria-selected={tab === "audit"} class:on={tab === "audit"} onclick={() => (tabOverride = "audit")}>
          {tr("Geschiedenis", "Approval log")}{#if audit.length}<span class="pill-count">{audit.length}</span>{/if}
        </button>
      </div>
      <button class="icon" disabled={loading} onclick={refresh} title={tr("Vernieuwen", "Refresh")} aria-label={tr("Vernieuwen", "Refresh")}>
        <span class:spin={loading}><Ico name="refresh-cw" size={15} /></span>
      </button>
      <button class="icon" onclick={onclose} title={tr("Sluit", "Close")} aria-label={tr("Sluit", "Close")}>
        <Ico name="x" size={16} />
      </button>
    </header>

    {#if error}<p class="err">{error}</p>{/if}

    <div class="body">
      {#if tab === "rules"}
        <div class="toolbar">
          <label class="search">
            <Ico name="search" size={14} />
            <input bind:value={ruleQuery} placeholder={tr("Filter regels of projecten…", "Filter rules or projects…")} aria-label={tr("Filter regels of projecten…", "Filter rules or projects…")} />
            {#if ruleQuery}
              <button class="clear-x" onclick={() => (ruleQuery = "")} aria-label={tr("Wissen", "Clear")}><Ico name="x" size={13} /></button>
            {/if}
          </label>
          {#if project}
            <div class="scope-switch">
              <button class="chip" class:on={projectFilter === project} onclick={() => (projectOverride = project)}>
                {folderName(project)}
              </button>
              <button class="chip" class:on={projectFilter === ""} onclick={() => (projectOverride = "")}>
                {tr("Alle projecten", "All projects")}
              </button>
            </div>
          {/if}
        </div>

        <div class="scroll">
          {#if ruleGroups.length === 0}
            <div class="empty">
              <span class="empty-ico"><Ico name="shield" size={24} /></span>
              <strong>{tr("Nog geen opgeslagen regels", "No granted rules yet")}</strong>
              <p>{tr("Wanneer je bij een toestemmingsvraag op \"Altijd\" klikt, verschijnt de regel hier per project en kun je hem op elk moment weer intrekken.", "When you choose \"Always\" on an approval request, the rule appears here by project so you can revoke it anytime.")}</p>
            </div>
          {:else}
            {#each ruleGroups as group (group.project || "__user__")}
              <section class="group">
                <div class="group-head">
                  <div class="group-title">
                    <Ico name="folder" size={14} />
                    <strong>{group.label}</strong>
                    <span class="count">{group.entries.length}</span>
                  </div>
                  {#if group.project}
                    <span class="group-path" title={group.project}>{group.project}</span>
                    <button
                      class="ghost danger-btn"
                      disabled={busyId === `project:${group.project}`}
                      onclick={() => revokeProject(group)}
                    >
                      <Ico name="trash-2" size={13} />
                      {tr("Alles intrekken", "Revoke all")}
                    </button>
                  {/if}
                </div>
                <div class="rows">
                  {#each group.entries as entry (entry.id)}
                    <div class="rule-row">
                      <div class="rule-main">
                        <code class="rule-code">{entry.rule}</code>
                        <div class="rule-meta">
                          <span class="tag">{reachText(entry)}</span>
                          {#if entry.agent}<span>{entry.agent}</span>{/if}
                          {#if entry.file}<span class="file-hint" title={entry.file}>{fileHint(entry.file)}</span>{/if}
                          {#if entry.grantedAt}<span title={exactTime(entry.grantedAt)}>{ago(entry.grantedAt)}</span>{/if}
                        </div>
                      </div>
                      <button
                        class="ghost danger-btn"
                        disabled={busyId === entry.id}
                        onclick={() => revokeOne(entry)}
                      >
                        {tr("Intrekken", "Revoke")}
                      </button>
                    </div>
                  {/each}
                </div>
              </section>
            {/each}
          {/if}
        </div>
      {:else}
        <div class="toolbar">
          <label class="search">
            <Ico name="search" size={14} />
            <input bind:value={auditQuery} placeholder={tr("Zoek op agent, project, commando of beslissing…", "Search by agent, project, command, or decision…")} aria-label={tr("Zoek in geschiedenis", "Search approval log")} />
            {#if auditQuery}
              <button class="clear-x" onclick={() => (auditQuery = "")} aria-label={tr("Wissen", "Clear")}><Ico name="x" size={13} /></button>
            {/if}
          </label>
          <button class="ghost danger-btn" disabled={!audit.length} onclick={clearAudit}>
            <Ico name="trash-2" size={13} />
            {tr("Wissen", "Clear")}
          </button>
        </div>

        <div class="filter-bar">
          {#each [
            ["", tr("Alles", "All")],
            ["allow", tr("Toegestaan", "Allowed")],
            ["always", tr("Altijd", "Always")],
            ["deny", tr("Geweigerd", "Denied")],
            ["terminal", tr("Terminal", "Terminal")],
            ["expired", tr("Verlopen", "Expired")],
          ] as [val, label] (val)}
            <button class="chip" class:on={decisionFilter === val} onclick={() => (decisionFilter = val)}>{label}</button>
          {/each}
        </div>

        <div class="scroll">
          {#if filteredAudit.length === 0}
            <div class="empty">
              <span class="empty-ico"><Ico name="history" size={24} /></span>
              <strong>{tr("Nog geen beslissingen gelogd", "No approval decisions logged yet")}</strong>
              <p>{tr("Elke goedkeuring, weigering of \"Altijd\"-keuze die je in Nook maakt wordt hier bewaard.", "Every allow, deny, or \"Always\" decision you make in Nook is recorded here.")}</p>
            </div>
          {:else}
            <div class="rows audit-list">
              {#each filteredAudit as item (item.id)}
                <div class="audit-row">
                  <div class="audit-top">
                    <span class="badge {decisionTone(item.decision)}">{decisionLabel(item.decision)}</span>
                    {#if item.danger}
                      <span class="danger-flag" title={tr("Risicovol commando", "High-risk command")}>
                        <Ico name="triangle-alert" size={12} />
                        {tr("Risico", "Risk")}
                      </span>
                    {/if}
                    <span class="audit-agent">{item.agent}</span>
                    {#if item.project}<span class="sep">·</span><span class="audit-proj">{item.project}</span>{/if}
                    {#if item.tool}<span class="sep">·</span><span class="audit-tool">{item.tool}</span>{/if}
                    <span class="spacer"></span>
                    {#if sourceLabel(item.source)}<span class="tag">{sourceLabel(item.source)}</span>{/if}
                    <span class="audit-time" title={exactTime(item.timestamp)}>{ago(item.timestamp)}</span>
                  </div>
                  {#if item.summary}
                    <code class="audit-summary">{item.summary}</code>
                  {/if}
                  {#if item.scope}
                    <span class="audit-scope">{item.scope}</span>
                  {/if}
                </div>
              {/each}
            </div>
          {/if}
        </div>
      {/if}
    </div>
  </div>
</div>

<style>
  .backdrop { position: fixed; inset: 0; z-index: 80; display: grid; place-items: center; padding: var(--space-24); background: color-mix(in srgb, var(--canvas) 55%, transparent); }
  .sheet {
    display: flex; flex-direction: column; width: min(760px, 100%); height: min(600px, 100%); min-height: 0;
    background: var(--surface); border: 1px solid var(--line2); border-radius: var(--radius-sheet); box-shadow: var(--shadow-popover); overflow: hidden;
  }
  header { display: flex; align-items: center; gap: var(--space-8); padding: var(--space-12) var(--space-24); border-bottom: 1px solid var(--line); flex: none; }
  .head-ico { display: inline-flex; color: var(--text2); }
  h2 { margin: 0; font: var(--text-heading); color: var(--paper); }
  .spacer { flex: 1; }
  .segments { display: inline-flex; gap: var(--space-2); padding: var(--space-2); margin-right: var(--space-8); border: 1px solid var(--line2); border-radius: var(--radius-control); background: var(--graphite); }
  .segments button { display: inline-flex; align-items: center; gap: var(--space-6); height: 26px; margin: 0; padding: 0 var(--space-12); border: 0; border-radius: var(--radius-chip); background: transparent; font: var(--text-control); font-weight: 400; color: var(--text2); }
  .segments button:hover { color: var(--paper); background: transparent; }
  .segments button.on { background: var(--smoke); color: var(--paper); font-weight: 600; }
  .pill-count { font: var(--text-caption); color: var(--text3); font-variant-numeric: tabular-nums; }
  .segments button.on .pill-count { color: var(--text2); }
  .icon { display: grid; place-items: center; width: 28px; height: 28px; padding: 0; margin: 0; border: 0; border-radius: var(--radius-control); background: transparent; color: var(--text2); }
  .icon:hover:not(:disabled) { background: var(--smoke); color: var(--paper); }
  .spin { display: inline-flex; animation: turn 0.9s linear infinite; }
  @keyframes turn { to { transform: rotate(360deg); } }
  .err { margin: 0; padding: var(--space-8) var(--space-24); font: var(--text-detail); color: var(--coral); background: color-mix(in srgb, var(--coral) 10%, transparent); border-bottom: 1px solid var(--line); }
  .body { flex: 1; min-height: 0; display: flex; flex-direction: column; gap: var(--space-12); padding: var(--space-16) var(--space-24); }
  .toolbar { display: flex; align-items: center; gap: var(--space-8); flex-wrap: wrap; flex: none; }
  .search { flex: 1; min-width: 180px; display: flex; align-items: center; gap: var(--space-8); height: 32px; padding: 0 var(--space-12); border: 1px solid var(--line2); border-radius: var(--radius-control); background: var(--graphite); color: var(--text3); }
  .search input { flex: 1; min-width: 0; height: 100%; border: 0; padding: 0; background: transparent; box-shadow: none; outline: none; font: var(--text-body); color: var(--paper); }
  .search input::placeholder { color: var(--text3); }
  .clear-x { display: grid; place-items: center; width: 20px; height: 20px; padding: 0; border: 0; border-radius: var(--radius-chip); background: transparent; color: var(--text3); }
  .clear-x:hover { color: var(--paper); background: var(--smoke); }
  .scope-switch, .filter-bar { display: flex; align-items: center; gap: var(--space-4); flex-wrap: wrap; flex: none; }
  .chip { height: 26px; padding: 0 var(--space-12); border: 1px solid var(--line2); border-radius: 999px; background: transparent; font: var(--text-detail); color: var(--text2); }
  .chip:hover { color: var(--paper); background: var(--row-hover); }
  .chip.on { background: var(--smoke); border-color: var(--line2); color: var(--paper); font-weight: 500; }
  .scroll { flex: 1; min-height: 0; overflow-y: auto; display: flex; flex-direction: column; gap: var(--space-16); }
  .empty { flex: 1; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: var(--space-8); padding: var(--space-32); text-align: center; color: var(--text2); }
  .empty-ico { display: grid; place-items: center; width: 44px; height: 44px; border-radius: var(--radius-panel); background: var(--graphite); color: var(--text3); }
  .empty strong { font: var(--text-emphasis); color: var(--paper); }
  .empty p { margin: 0; max-width: 420px; font: var(--text-body); color: var(--text3); }
  .group { display: flex; flex-direction: column; gap: var(--space-8); }
  .group-head { display: flex; align-items: center; gap: var(--space-8); flex-wrap: wrap; }
  .group-title { display: inline-flex; align-items: center; gap: var(--space-6); color: var(--paper); font: var(--text-emphasis); }
  .count { font: var(--text-detail); color: var(--text3); font-variant-numeric: tabular-nums; }
  .group-path { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font: var(--text-caption); color: var(--text3); }
  .rows { display: flex; flex-direction: column; border: 1px solid var(--line); border-radius: var(--radius-card); background: var(--graphite); overflow: hidden; }
  .rule-row { display: flex; align-items: center; gap: var(--space-12); padding: var(--space-12) var(--space-16); border-top: 1px solid var(--line); }
  .rule-row:first-child { border-top: 0; }
  .rule-main { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: var(--space-4); }
  .rule-code { font: var(--text-code); color: var(--paper); word-break: break-all; }
  .rule-meta { display: flex; align-items: center; gap: var(--space-8); flex-wrap: wrap; font: var(--text-caption); color: var(--text3); }
  .file-hint { font-family: var(--mono); }
  .tag { display: inline-flex; align-items: center; padding: 0 var(--space-6); height: 18px; border-radius: var(--radius-chip); background: var(--smoke); font: var(--text-caption); color: var(--text2); }
  .danger-btn { display: inline-flex; align-items: center; gap: var(--space-4); color: var(--coral); font: var(--text-control); flex: none; }
  .danger-btn:hover:not(:disabled) { background: color-mix(in srgb, var(--coral) 14%, transparent); color: var(--coral); }
  .audit-row { display: flex; flex-direction: column; gap: var(--space-6); padding: var(--space-12) var(--space-16); border-top: 1px solid var(--line); }
  .audit-row:first-child { border-top: 0; }
  .audit-top { display: flex; align-items: center; gap: var(--space-6); flex-wrap: wrap; font: var(--text-detail); color: var(--text2); }
  .badge { display: inline-flex; align-items: center; height: 20px; padding: 0 var(--space-8); border-radius: 999px; font: var(--text-label); }
  .badge.mint { color: var(--mint); background: color-mix(in srgb, var(--mint) 14%, transparent); }
  .badge.blue { color: var(--blue); background: color-mix(in srgb, var(--blue) 14%, transparent); }
  .badge.coral { color: var(--coral); background: color-mix(in srgb, var(--coral) 14%, transparent); }
  .badge.amber { color: var(--amber); background: color-mix(in srgb, var(--amber) 14%, transparent); }
  .badge.muted { color: var(--text3); background: var(--smoke); }
  .danger-flag { display: inline-flex; align-items: center; gap: var(--space-4); color: var(--coral); font: var(--text-label); }
  .audit-agent { color: var(--paper); font-weight: 500; }
  .audit-proj, .audit-tool, .sep { color: var(--text3); }
  .audit-time { font: var(--text-caption); color: var(--text3); font-variant-numeric: tabular-nums; }
  .audit-summary { font: var(--text-code); color: var(--text2); white-space: pre-wrap; word-break: break-word; }
  .audit-scope { font: var(--text-caption); color: var(--text3); }
</style>
