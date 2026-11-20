import { invoke } from "@tauri-apps/api/core";
// De staat van de agents in de interface (Svelte 5 runes). De waarheid staat in Rust; dit volgt de events.
import { agentApi, agentEvents, type AgentApproval, type AgentSession, type HistoryResult, type Overview, type QuestionRequest } from "./agents";
import { playSound } from "./sound";
import { nook } from "./state.svelte";
import { toast } from "./toast.svelte";

class AgentsStore {
  overview = $state<Overview | null>(null);
  history = $state<HistoryResult | null>(null);
  /// Het kaartje "klaar / mislukt / wacht op je" in de balk.
  attention = $state<AgentSession | null>(null);
  /// Welke sessie rechts in de tab Agents open staat.
  selectedId = $state<string | null>(localStorage.getItem("agents.selected"));
  error = $state<string | null>(null);
  /// Alleen de balk speelt geluiden, zodat je ze niet dubbel hoort.
  sounds = false;
  private started = false;
  private refreshing: Promise<void> | null = null;

  approvals = $derived(this.overview?.approvals ?? []);
  questions = $derived(this.overview?.questions ?? []);
  sessions = $derived(this.overview?.sessions ?? []);
  pending = $derived(this.approvals.length + this.questions.length);

  async start() {
    if (this.started) return;
    this.started = true;
    await this.refresh();
    agentEvents.onChanged(() => this.refresh());
    // Een nieuwe vraag zet zijn sessie rechts in de tab Agents, zodat je hem meteen ziet.
    agentEvents.onApproval((a) => {
      this.selectedId = a.sessionKey;
      this.refresh();
      this.play("attention");
    });
    agentEvents.onApprovalGone((g) => {
      this.refresh();
      if (g.message) this.confirm(g.message);
    });
    agentEvents.onQuestion((q) => {
      this.selectedId = q.sessionKey;
      this.refresh();
      this.play("attention");
    });
    agentEvents.onQuestionGone((g) => {
      this.refresh();
      if (g.message) this.confirm(g.message);
    });
    agentEvents.onAttention((s) => {
      this.play(s.status === "done" ? "done" : s.status === "failed" ? "error" : "attention");
      // The bar's card or line only when Settings › Notifications says so (`notice_decide`: not as a system
      // notification, not off, not in quiet hours or while Nook keeps quiet).
      invoke<string>("notice_decide", { source: "agents", appName: s.name ?? "", urgent: false })
        .catch(() => (nook.settings?.agentNotice === "system" ? "system" : "card"))
        .then((d) => {
          if (d === "card" || d === "strip") this.attention = s;
        });
    });
    agentEvents.onUsage(() => this.refresh());
    agentEvents.onHistory((h) => (this.history = h));
  }

  play(kind: "attention" | "done" | "error") {
    if (this.sounds && nook.settings?.sounds) playSound(kind);
  }

  /// A short confirmation ("Toegestaan", "Worktree verwijderd") in this window's toast.
  confirm(message: string) {
    toast.success(message);
  }

  /// A burst of events becomes one fetch. An event during a fetch asks for one more afterwards, because the fetch that
  /// is running may have read the state before that change.
  private again = false;

  async refresh(): Promise<void> {
    if (this.refreshing) {
      this.again = true;
      return this.refreshing;
    }
    this.refreshing = (async () => {
      try {
        this.overview = await agentApi.overview();
      } catch (e) {
        this.error = String(e);
      } finally {
        this.refreshing = null;
        if (this.again) {
          this.again = false;
          void this.refresh();
        }
      }
    })();
    return this.refreshing;
  }

  async loadHistory(force = false) {
    try {
      this.history = await agentApi.history(force);
    } catch (e) {
      this.error = String(e);
    }
  }

  /// What you opened, for back and forward in the sidebar's head (the Mac's `AgentsHistory`): the open item is
  /// `trail[at]`; opening another drops what was ahead of it.
  trail = $state<(string | null)[]>([localStorage.getItem("agents.selected")]);
  at = $state(0);
  get canBack() { return this.at > 0; }
  get canForward() { return this.at < this.trail.length - 1; }

  back() {
    if (!this.canBack) return;
    this.at -= 1;
    this.select(this.trail[this.at], false);
  }

  forward() {
    if (!this.canForward) return;
    this.at += 1;
    this.select(this.trail[this.at], false);
  }

  select(id: string | null, record = true) {
    if (record && id !== this.trail[this.at]) {
      this.trail = [...this.trail.slice(0, this.at + 1), id].slice(-50);
      this.at = this.trail.length - 1;
    }
    this.selectedId = id;
    if (id) {
      localStorage.setItem("agents.selected", id);
      agentApi.visit(id);
    } else {
      localStorage.removeItem("agents.selected");
    }
  }

  /// Telt als gezien: wat de sessie afmaakte is niet meer nieuw.
  visit(id: string) {
    agentApi.visit(id).catch(() => {});
  }

  approvalFor(sessionKey: string): AgentApproval | undefined {
    return this.approvals.find((a) => a.sessionKey === sessionKey);
  }

  questionFor(sessionKey: string): QuestionRequest | undefined {
    return this.questions.find((q) => q.sessionKey === sessionKey);
  }

  /// Deny and tell the agent why; a bridge request (no agent behind it) takes a plain Deny.
  async denyWithReason(a: AgentApproval, reason: string) {
    try {
      await agentApi.deny(a.id, reason);
    } catch (e) {
      this.error = String(e);
    }
    await this.refresh();
  }

  async decide(a: AgentApproval, decision: "allow" | "always" | "deny" | "terminal") {
    try {
      if (decision === "terminal") await agentApi.decideInTerminal(a.id);
      else await agentApi.decide(a.id, decision);
    } catch (e) {
      this.error = String(e);
    }
    await this.refresh();
  }
}

export const agents = new AgentsStore();
