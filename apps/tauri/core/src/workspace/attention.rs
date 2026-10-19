//! Wat een sessie van jou vraagt, in één woord (`AgentAttention.swift`): voor de stipjes, de telefoon en meldingen.

use chrono::{DateTime, Utc};

use super::models::RunStatus;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum AgentAttention {
    /// Een tool of commando wacht op jouw toestemming.
    Approval,
    /// De agent stelde een vraag en wacht op je antwoord.
    Input,
    Failed,
    /// Gestopt door een gebruikslimiet; het gaat verder bij de reset, of als jij verdergaat.
    Limited,
    Working,
    /// Klaar sinds je laatst keek.
    Ready,
    Idle,
    /// Afgerond, gesnoozed of gestopt: uit de weg.
    Finished,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct AttentionInput {
    pub status: Option<RunStatus>,
    pub pending_approvals: usize,
    pub pending_questions: usize,
    pub limited_at: Option<DateTime<Utc>>,
    /// Klaar nadat je hem voor het laatst opende.
    pub unseen: bool,
    /// Door jou afgerond, of gesnoozed.
    pub settled: bool,
}

impl AgentAttention {
    /// Iets dat alleen jij kunt vrijgeven.
    pub fn needs_you(self) -> bool {
        matches!(self, Self::Approval | Self::Input)
    }

    /// Toestemming gaat voor een vraag, die voor al het andere. Wat op jou wacht wint van `settled`: het wordt nooit
    /// verborgen.
    pub fn resolve(input: &AttentionInput) -> Self {
        let status = input.status.unwrap_or(RunStatus::Completed);
        if input.pending_approvals > 0 || status == RunStatus::WaitingApproval {
            return Self::Approval;
        }
        if input.pending_questions > 0 && status.is_active() {
            return Self::Input;
        }
        if input.settled && !status.is_active() {
            return Self::Finished;
        }
        match status {
            RunStatus::Preparing | RunStatus::Running => Self::Working,
            RunStatus::WaitingApproval => Self::Approval,
            RunStatus::Failed if input.limited_at.is_some() => Self::Limited,
            RunStatus::Failed => Self::Failed,
            RunStatus::Completed if input.unseen => Self::Ready,
            RunStatus::Completed => Self::Idle,
            RunStatus::Stopped => Self::Finished,
        }
    }

    /// Het woord in het companion-protocol.
    pub fn raw(self) -> &'static str {
        match self {
            Self::Approval => "approval",
            Self::Input => "input",
            Self::Failed => "failed",
            Self::Limited => "limited",
            Self::Working => "working",
            Self::Ready => "ready",
            Self::Idle => "idle",
            Self::Finished => "finished",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn with(status: RunStatus) -> AttentionInput {
        AttentionInput { status: Some(status), ..Default::default() }
    }

    #[test]
    fn approval_beats_question_beats_the_rest() {
        let mut input = with(RunStatus::Running);
        input.pending_approvals = 1;
        input.pending_questions = 1;
        assert_eq!(AgentAttention::resolve(&input), AgentAttention::Approval);
        input.pending_approvals = 0;
        assert_eq!(AgentAttention::resolve(&input), AgentAttention::Input);
        input.pending_questions = 0;
        assert_eq!(AgentAttention::resolve(&input), AgentAttention::Working);
        assert_eq!(AgentAttention::resolve(&with(RunStatus::WaitingApproval)), AgentAttention::Approval);
    }

    #[test]
    fn a_question_of_a_finished_turn_does_not_wait_for_you() {
        let mut input = with(RunStatus::Completed);
        input.pending_questions = 1;
        assert_eq!(AgentAttention::resolve(&input), AgentAttention::Idle);
    }

    #[test]
    fn finished_states() {
        let mut failed = with(RunStatus::Failed);
        assert_eq!(AgentAttention::resolve(&failed), AgentAttention::Failed);
        failed.limited_at = Some(Utc::now());
        assert_eq!(AgentAttention::resolve(&failed), AgentAttention::Limited);
        let mut done = with(RunStatus::Completed);
        done.unseen = true;
        assert_eq!(AgentAttention::resolve(&done), AgentAttention::Ready);
        done.settled = true;
        assert_eq!(AgentAttention::resolve(&done), AgentAttention::Finished);
        assert_eq!(AgentAttention::resolve(&with(RunStatus::Stopped)), AgentAttention::Finished);
        // Wat op je wacht wint van afgerond.
        let mut waiting = with(RunStatus::Running);
        waiting.settled = true;
        waiting.pending_approvals = 1;
        assert!(AgentAttention::resolve(&waiting).needs_you());
        assert_eq!(AgentAttention::Limited.raw(), "limited");
    }
}
