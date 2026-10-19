// De staat van de agents in de interface (Svelte 5 runes). De waarheid staat in Rust; dit volgt de events.
import { agentApi, agentEvents, type AgentApproval, type AgentSession, type HistoryResult, type Overview, type QuestionRequest } from "./agents";
import { playSound } from "./sound";
import { nook } from "./state.svelte";

class AgentsStore {
  overview = $state<Overview | null>(null);
  history = $state<HistoryResult | null>(null);
  /// Het kaartje "klaar / mislukt / wacht op je" in de balk.
  attention = $state<AgentSession | null>(null);
  /// Een korte bevestiging na een antwoord vanuit Nook ("Toegestaan").
  confirmation = $state<string | null>(null);
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
      this.attention = s;
    });
    agentEvents.onUsage(() => this.refresh());
    agentEvents.onHistory((h) => (this.history = h));
  }

  play(kind: "attention" | "done" | "error") {
    if (this.sounds && nook.settings?.sounds) playSound(kind);
  }

  confirm(message: string) {
    this.confirmation = message;
    setTimeout(() => {
      if (this.confirmation === message) this.confirmation = null;
    }, 1800);
  }

  async refresh() {
    // Een reeks events wordt één keer ophalen.
    if (this.refreshing) return this.refreshing;
    this.refreshing = (async () => {
      try {
        this.overview = await agentApi.overview();
      } catch (e) {
        this.error = String(e);
      } finally {
        this.refreshing = null;
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

  select(id: string | null) {
    this.selectedId = id;
    if (id) {
      localStorage.setItem("agents.selected", id);
      agentApi.visit(id);
    } else {
      localStorage.removeItem("agents.selected");
    }
  }

  approvalFor(sessionKey: string): AgentApproval | undefined {
    return this.approvals.find((a) => a.sessionKey === sessionKey);
  }

  questionFor(sessionKey: string): QuestionRequest | undefined {
    return this.questions.find((q) => q.sessionKey === sessionKey);
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
