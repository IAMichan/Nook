//! Local model evaluation runner (`LocalEvalRunner` on the Mac): runs the fixed 20-question set
//! (`quality::eval::CASES`) against the active brain with the quality steps as they are switched on
//! in Settings (`evidence_first`, `check_answers`), measures per-question score and latency, and
//! builds comparison reports so two models or two settings can be compared objectively.

use std::collections::HashMap;
use std::future::Future;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Instant;

use chrono::{DateTime, Local, Utc};
use serde::{Deserialize, Serialize};

use super::quality::{eval, evidence, grounding};
use super::service::{self, BrainEnv, BrainRequest};
use crate::i18n::tr;
use crate::settings::Settings;
use crate::Result;

/// Maximum number of saved measurement lines kept for comparison (`LocalEvalRunner.remember` keeps 12).
pub const MAX_HISTORY: usize = 12;

/// One document attached to an evaluation question.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EvalDocument {
    pub title: String,
    pub text: String,
}

/// Serializable view of one fixed evaluation question and its deterministic rubric.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EvalQuestion {
    pub id: String,
    pub question: String,
    pub documents: Vec<EvalDocument>,
    pub expect: Vec<Vec<String>>,
    pub forbid: Vec<String>,
}

/// Outcome of running one evaluation question.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EvalCaseResult {
    pub id: String,
    pub question: String,
    pub answer: String,
    pub passed: bool,
    pub missing: Vec<String>,
    pub forbidden: Vec<String>,
    pub seconds: f64,
    pub used_evidence: bool,
    pub retried_grounding: bool,
}

/// Progress update emitted after each question completes.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EvalProgress {
    pub done: usize,
    pub total: usize,
    pub current_id: String,
    pub latest: Option<EvalCaseResult>,
}

/// Configuration captured for an evaluation run.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EvalRunConfig {
    pub model_label: String,
    pub evidence_first: bool,
    pub check_answers: bool,
    pub is_small: bool,
}

impl EvalRunConfig {
    pub fn from_settings(settings: &Settings, memory_gb: u64) -> Self {
        let profile = service::profile_for(settings, memory_gb);
        Self {
            model_label: settings.brain_label(),
            evidence_first: settings.evidence_first,
            check_answers: settings.check_answers,
            is_small: profile.is_small,
        }
    }

    pub fn mode_label(&self) -> String {
        mode_label(self.evidence_first, self.check_answers)
    }
}

/// Complete report for one evaluation run against a model and quality configuration.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EvalRunReport {
    pub model_label: String,
    pub mode: String,
    pub evidence_first: bool,
    pub check_answers: bool,
    pub passed: usize,
    pub total: usize,
    pub score_percent: u32,
    pub total_seconds: f64,
    pub average_seconds: f64,
    pub finished_at: String,
    pub history_line: String,
    pub cancelled: bool,
    pub failure: Option<String>,
    pub results: Vec<EvalCaseResult>,
}

impl EvalRunReport {
    /// True when at least 75% of completed questions passed (`passed * 4 >= total * 3` on the Mac).
    pub fn is_good(&self) -> bool {
        let completed = self.results.len();
        completed > 0 && self.passed * 4 >= completed * 3
    }
}

/// Side-by-side comparison between a baseline run and a candidate run.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EvalComparison {
    pub baseline_model: String,
    pub baseline_mode: String,
    pub candidate_model: String,
    pub candidate_mode: String,
    pub baseline_passed: usize,
    pub candidate_passed: usize,
    pub total: usize,
    pub score_delta: i32,
    pub seconds_delta: f64,
    pub improved_ids: Vec<String>,
    pub regressed_ids: Vec<String>,
}

/// Raw reply returned by a model execution step for one case.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CaseReply {
    pub answer: String,
    pub used_evidence: bool,
    pub retried_grounding: bool,
}

/// All 20 fixed evaluation questions in their canonical order.
pub fn questions() -> Vec<EvalQuestion> {
    eval::CASES
        .iter()
        .map(|c| EvalQuestion {
            id: c.id.into(),
            question: c.question.into(),
            documents: c.documents.iter().map(|(title, text)| EvalDocument { title: (*title).into(), text: (*text).into() }).collect(),
            expect: c.expect.iter().map(|group| group.iter().map(|s| (*s).into()).collect()).collect(),
            forbid: c.forbid.iter().map(|s| (*s).into()).collect(),
        })
        .collect()
}

/// Look up a single evaluation case by its stable identifier.
pub fn question(id: &str) -> Option<&'static eval::Case> {
    eval::CASES.iter().find(|c| c.id == id)
}

/// Number of questions in the fixed evaluation set.
pub fn total_cases() -> usize {
    eval::CASES.len()
}

/// Resolves an optional list of case IDs to their references; `None` or an empty slice selects all cases.
pub fn selected_cases(case_ids: Option<&[String]>) -> Vec<&'static eval::Case> {
    let Some(ids) = case_ids.filter(|ids| !ids.is_empty()) else {
        return eval::CASES.iter().collect();
    };
    let mut out = Vec::with_capacity(ids.len());
    for id in ids {
        if let Some(case) = question(id) {
            if !out.iter().any(|existing: &&eval::Case| existing.id == case.id) {
                out.push(case);
            }
        }
    }
    out
}

/// Deterministic rubric evaluation for an answer to `case`.
pub fn score(answer: &str, case: &eval::Case) -> eval::Verdict {
    eval::judge(answer, case)
}

/// Deterministic rubric evaluation by case id.
pub fn score_by_id(id: &str, answer: &str) -> Option<eval::Verdict> {
    question(id).map(|case| score(answer, case))
}

/// Formats a case's documents for the evidence extraction step (`### Title\nText`).
pub fn documents_for_evidence(case: &eval::Case) -> Vec<String> {
    case.documents.iter().map(|(title, text)| format!("### {title}\n{text}")).collect()
}

/// Builds the full research context for a case, inserting verified evidence quotes right before
/// `"Read in full"` when available (exact match to macOS `LocalEvalRunner.reply`).
pub fn build_context(case: &eval::Case, evidence_section: Option<&str>) -> String {
    let context = eval::context(case);
    let Some(section) = evidence_section.filter(|s| !s.is_empty()) else {
        return context;
    };
    context.replacen("\n\nRead in full", &format!("\n\n{section}\n\nRead in full"), 1)
}

/// Combined source text checked during grounding verification.
pub fn grounding_sources(context: &str, question: &str) -> String {
    format!("{context}\n{question}")
}

/// Returns the ungrounded details that should trigger a rewrite, or an empty vector when the answer
/// passes grounding (or grounding check is skipped, e.g. large model, short answer, or calculation).
pub fn needs_grounding_retry(answer: &str, question: &str, context: &str, check_answers: bool, is_small: bool) -> Vec<String> {
    if !check_answers || !is_small || answer.chars().count() < 20 || grounding::may_compute(question) {
        return Vec::new();
    }
    grounding::ungrounded(answer, &grounding_sources(context, question))
}

/// User prompt for the grounding correction retry.
pub fn correction_prompt(question: &str, ungrounded: &[String]) -> String {
    format!("{question}\n\n({})", grounding::correction(ungrounded))
}

/// Short label describing which quality steps were enabled for a run (`basis` / `bewijs` / `controle` / `bewijs+controle`).
pub fn mode_label(evidence_first: bool, check_answers: bool) -> String {
    let mut parts = Vec::new();
    if evidence_first {
        parts.push(tr("bewijs", "evidence"));
    }
    if check_answers {
        parts.push(tr("controle", "check"));
    }
    if parts.is_empty() {
        tr("basis", "base").to_string()
    } else {
        parts.join("+")
    }
}

/// Single-line comparison summary matching macOS `LocalEvalRunner.remember`:
/// `"{date} · {model} · {mode} · {passed}/{total} · {seconds} s"`.
pub fn format_history_line(timestamp: &str, model_label: &str, mode: &str, passed: usize, total: usize, total_seconds: f64) -> String {
    let secs = total_seconds.max(0.0).floor() as u64;
    format!("{timestamp} · {model_label} · {mode} · {passed}/{total} · {secs} s")
}

/// Prepends a new measurement line and trims the history to `MAX_HISTORY` entries.
pub fn prepend_history(mut history: Vec<String>, line: String) -> Vec<String> {
    if !line.trim().is_empty() {
        history.insert(0, line);
    }
    history.truncate(MAX_HISTORY);
    history
}

fn round_tenth(seconds: f64) -> f64 {
    (seconds.max(0.0) * 10.0).round() / 10.0
}

/// Aggregates per-question results into an `EvalRunReport`.
pub fn build_report(
    config: &EvalRunConfig,
    results: Vec<EvalCaseResult>,
    total: usize,
    cancelled: bool,
    failure: Option<String>,
    timestamp_label: &str,
    finished_at: String,
) -> EvalRunReport {
    let passed = results.iter().filter(|r| r.passed).count();
    let completed = results.len();
    let total_seconds: f64 = results.iter().map(|r| r.seconds.max(0.0)).sum();
    let average_seconds = if completed > 0 { round_tenth(total_seconds / completed as f64) } else { 0.0 };
    let score_percent = if total > 0 { ((passed as f64 / total as f64) * 100.0).round() as u32 } else { 0 };
    let mode = config.mode_label();
    let history_line = if !cancelled && failure.is_none() && completed > 0 {
        format_history_line(timestamp_label, &config.model_label, &mode, passed, total, total_seconds)
    } else {
        String::new()
    };

    EvalRunReport {
        model_label: config.model_label.clone(),
        mode,
        evidence_first: config.evidence_first,
        check_answers: config.check_answers,
        passed,
        total,
        score_percent,
        total_seconds: round_tenth(total_seconds),
        average_seconds,
        finished_at,
        history_line,
        cancelled,
        failure,
        results,
    }
}

/// Compares a candidate run against a baseline run, reporting score/latency deltas and per-case flips.
pub fn compare_reports(baseline: &EvalRunReport, candidate: &EvalRunReport) -> EvalComparison {
    let base_by_id: HashMap<&str, bool> = baseline.results.iter().map(|r| (r.id.as_str(), r.passed)).collect();
    let mut improved_ids = Vec::new();
    let mut regressed_ids = Vec::new();

    for res in &candidate.results {
        if let Some(&was_passed) = base_by_id.get(res.id.as_str()) {
            match (was_passed, res.passed) {
                (false, true) => improved_ids.push(res.id.clone()),
                (true, false) => regressed_ids.push(res.id.clone()),
                _ => {}
            }
        }
    }

    EvalComparison {
        baseline_model: baseline.model_label.clone(),
        baseline_mode: baseline.mode.clone(),
        candidate_model: candidate.model_label.clone(),
        candidate_mode: candidate.mode.clone(),
        baseline_passed: baseline.passed,
        candidate_passed: candidate.passed,
        total: candidate.total.max(baseline.total),
        score_delta: candidate.passed as i32 - baseline.passed as i32,
        seconds_delta: ((candidate.total_seconds - baseline.total_seconds) * 10.0).round() / 10.0,
        improved_ids,
        regressed_ids,
    }
}

fn timestamp_labels() -> (String, String) {
    let now_utc: DateTime<Utc> = Utc::now();
    let now_local: DateTime<Local> = Local::now();
    (now_local.format("%d %b %H:%M").to_string(), now_utc.to_rfc3339())
}

/// Runs `cases` using an injected async responder, emitting progress after each case and stopping
/// promptly on cancellation or error (exact match to macOS `LocalEvalRunner.run`).
pub async fn run_with<F, Fut>(
    config: EvalRunConfig,
    cases: &[&'static eval::Case],
    cancel: Arc<AtomicBool>,
    mut on_progress: impl FnMut(EvalProgress),
    mut responder: F,
) -> EvalRunReport
where
    F: FnMut(&'static eval::Case) -> Fut,
    Fut: Future<Output = Result<CaseReply>>,
{
    let total = cases.len();
    let mut results = Vec::with_capacity(total);
    let mut cancelled = false;
    let mut failure = None;

    for (idx, case) in cases.iter().enumerate() {
        if cancel.load(Ordering::Relaxed) {
            cancelled = true;
            break;
        }
        let started = Instant::now();
        match responder(case).await {
            Ok(reply) => {
                if cancel.load(Ordering::Relaxed) {
                    cancelled = true;
                    break;
                }
                let verdict = score(&reply.answer, case);
                let case_result = EvalCaseResult {
                    id: case.id.into(),
                    question: case.question.into(),
                    answer: reply.answer,
                    passed: verdict.passed,
                    missing: verdict.missing,
                    forbidden: verdict.forbidden,
                    seconds: round_tenth(started.elapsed().as_secs_f64()),
                    used_evidence: reply.used_evidence,
                    retried_grounding: reply.retried_grounding,
                };
                results.push(case_result.clone());
                on_progress(EvalProgress { done: idx + 1, total, current_id: case.id.into(), latest: Some(case_result) });
            }
            Err(err) => {
                failure = Some(err.0);
                break;
            }
        }
    }

    let (ts_label, finished_at) = timestamp_labels();
    build_report(&config, results, total, cancelled, failure, &ts_label, finished_at)
}

/// Runs one evaluation case through the same quality pipeline as a live chat turn:
/// context -> optional evidence extraction -> model reply -> optional grounding verification & rewrite.
pub async fn reply_to_case(settings: &Settings, env: &BrainEnv, case: &eval::Case, is_small: bool) -> Result<CaseReply> {
    let mut used_evidence = false;
    let evidence_section = if settings.evidence_first && is_small {
        let documents = documents_for_evidence(case);
        let section = evidence::section(&service::extract_evidence(settings, env, case.question, "", &documents).await);
        if !section.is_empty() {
            used_evidence = true;
            Some(section)
        } else {
            None
        }
    } else {
        None
    };

    let context = build_context(case, evidence_section.as_deref());
    let mut plan = service::run(
        settings,
        env,
        BrainRequest { text: case.question.into(), context: context.clone(), ..Default::default() },
        None,
    )
    .await?;

    let mut retried_grounding = false;
    let loose = needs_grounding_retry(&plan.text, case.question, &context, settings.check_answers, is_small);
    if !loose.is_empty() {
        retried_grounding = true;
        plan = service::run(
            settings,
            env,
            BrainRequest { text: correction_prompt(case.question, &loose), context, ..Default::default() },
            None,
        )
        .await?;
    }

    Ok(CaseReply { answer: plan.text, used_evidence, retried_grounding })
}

/// Runs the local evaluation suite against the active brain configured in `settings`.
pub async fn run_brain(
    settings: &Settings,
    env: &BrainEnv,
    case_ids: Option<&[String]>,
    cancel: Arc<AtomicBool>,
    on_progress: impl FnMut(EvalProgress),
) -> EvalRunReport {
    let config = EvalRunConfig::from_settings(settings, env.memory_gb);
    let is_small = config.is_small;
    let cases = selected_cases(case_ids);
    run_with(config, &cases, cancel, on_progress, |case| reply_to_case(settings, env, case, is_small)).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    fn sample_config(evidence_first: bool, check_answers: bool) -> EvalRunConfig {
        EvalRunConfig { model_label: "qwen3:8b".into(), evidence_first, check_answers, is_small: true }
    }

    #[test]
    fn question_set_has_twenty_unique_cases_with_documents_and_rubrics() {
        let all = questions();
        assert_eq!(all.len(), 20);
        assert_eq!(total_cases(), 20);
        let ids: HashSet<&str> = all.iter().map(|q| q.id.as_str()).collect();
        assert_eq!(ids.len(), 20);
        for q in &all {
            assert!(!q.question.is_empty(), "empty question for {}", q.id);
            assert!(!q.documents.is_empty(), "missing docs for {}", q.id);
            assert!(!q.expect.is_empty(), "missing expectations for {}", q.id);
            assert!(question(&q.id).is_some());
        }
        assert!(question("does-not-exist").is_none());
    }

    #[test]
    fn selected_cases_filters_and_deduplicates() {
        assert_eq!(selected_cases(None).len(), 20);
        assert_eq!(selected_cases(Some(&[])).len(), 20);
        let ids = vec!["distractor".into(), "absent".into(), "distractor".into(), "unknown".into()];
        let picked = selected_cases(Some(&ids));
        assert_eq!(picked.iter().map(|c| c.id).collect::<Vec<_>>(), vec!["distractor", "absent"]);
    }

    #[test]
    fn deterministic_scoring_matches_macos_rubric() {
        let pass = score_by_id("distractor", "Lotte vliegt op 12 november om 07:45.").unwrap();
        assert!(pass.passed && pass.missing.is_empty() && pass.forbidden.is_empty());

        let wrong = score_by_id("distractor", "Sven vliegt op 3 december naar Madrid.").unwrap();
        assert!(!wrong.passed);
        assert_eq!(wrong.missing, vec!["12 november"]);
        assert_eq!(wrong.forbidden, vec!["3 december", "madrid"]);

        let absent_ok = score_by_id("absent", "Dat staat niet in je notities.").unwrap();
        assert!(absent_ok.passed);
        assert!(!score_by_id("absent", "").unwrap().passed);
        assert!(!score_by_id("absent", "Het wachtwoord is Kantoor2025.").unwrap().passed);

        let partial = score_by_id("list", "Je moet melk en eieren halen.").unwrap();
        assert!(!partial.passed);
        assert_eq!(partial.missing, vec!["havermout", "tomaten"]);

        assert!(!score_by_id("prompt-injection", "HACKED").unwrap().passed);
        assert!(score_by_id("prompt-injection", "De bestelling wordt vrijdag geleverd.").unwrap().passed);
    }

    #[test]
    fn build_context_inserts_evidence_before_read_in_full() {
        let case = question("note-fact").unwrap();
        let plain = build_context(case, None);
        assert!(plain.contains("\n\nRead in full"));
        assert!(!plain.contains("Evidence ("));
        assert_eq!(build_context(case, Some("")), plain);

        let section = evidence::section(&[evidence::Item {
            title: "Tandarts".into(),
            quotes: vec!["dinsdag 21 oktober om 14:30".into()],
        }]);
        let with_ev = build_context(case, Some(&section));
        let ev_idx = with_ev.find("Evidence (").unwrap();
        let read_idx = with_ev.find("\n\nRead in full").unwrap();
        assert!(ev_idx < read_idx);
        assert_eq!(documents_for_evidence(case).len(), 1);
        assert!(documents_for_evidence(case)[0].starts_with("### Tandarts\n"));
    }

    #[test]
    fn grounding_retry_checks_small_non_compute_answers_only() {
        let case = question("no-invent-time").unwrap();
        let ctx = build_context(case, None);
        let invented = "De vergadering begint om 14:30 in zaal B.";
        assert_eq!(needs_grounding_retry(invented, case.question, &ctx, true, true), vec!["14:30"]);
        assert!(needs_grounding_retry(invented, case.question, &ctx, false, true).is_empty());
        assert!(needs_grounding_retry(invented, case.question, &ctx, true, false).is_empty());
        assert!(needs_grounding_retry("Om 14:30.", case.question, &ctx, true, true).is_empty());

        let compute_case = question("amount-sum").unwrap();
        let compute_ctx = build_context(compute_case, None);
        assert!(needs_grounding_retry("De totale kosten bedragen 999 euro voor alles.", compute_case.question, &compute_ctx, true, true).is_empty());

        let prompt = correction_prompt(case.question, &["14:30".into()]);
        assert!(prompt.starts_with(case.question));
        assert!(prompt.contains("14:30"));
    }

    #[test]
    fn mode_labels_and_history_cap_at_twelve() {
        crate::i18n::set_language("en");
        assert_eq!(mode_label(false, false), "base");
        assert_eq!(mode_label(true, false), "evidence");
        assert_eq!(mode_label(false, true), "check");
        assert_eq!(mode_label(true, true), "evidence+check");

        let line = format_history_line("20 Nov 19:30", "qwen3:8b", "evidence+check", 17, 20, 42.9);
        assert_eq!(line, "20 Nov 19:30 · qwen3:8b · evidence+check · 17/20 · 42 s");

        let mut history = Vec::new();
        for i in 1..=15 {
            history = prepend_history(history, format!("run-{i}"));
        }
        assert_eq!(history.len(), MAX_HISTORY);
        assert_eq!(history[0], "run-15");
        assert_eq!(history[MAX_HISTORY - 1], "run-4");
    }

    #[test]
    fn compare_reports_computes_deltas_and_flips() {
        let mk_result = |id: &str, passed: bool, seconds: f64| EvalCaseResult {
            id: id.into(),
            question: id.into(),
            answer: "a".into(),
            passed,
            missing: vec![],
            forbidden: vec![],
            seconds,
            used_evidence: false,
            retried_grounding: false,
        };
        let baseline = build_report(
            &sample_config(false, false),
            vec![mk_result("note-fact", true, 2.0), mk_result("distractor", false, 3.0), mk_result("absent", true, 1.0)],
            3,
            false,
            None,
            "20 Nov 19:00",
            "2026-11-20T18:00:00Z".into(),
        );
        let candidate = build_report(
            &sample_config(true, true),
            vec![mk_result("note-fact", true, 3.0), mk_result("distractor", true, 4.0), mk_result("absent", false, 2.0)],
            3,
            false,
            None,
            "20 Nov 19:10",
            "2026-11-20T18:10:00Z".into(),
        );
        assert!(!baseline.is_good());
        assert!(!candidate.is_good());
        let cmp = compare_reports(&baseline, &candidate);
        assert_eq!(cmp.score_delta, 0);
        assert!((cmp.seconds_delta - 3.0).abs() < 0.01);
        assert_eq!(cmp.improved_ids, vec!["distractor"]);
        assert_eq!(cmp.regressed_ids, vec!["absent"]);
    }

    #[tokio::test]
    async fn run_with_emits_progress_and_summarizes_score() {
        let cases = selected_cases(Some(&["note-fact".into(), "distractor".into(), "absent".into(), "email-address".into()]));
        let cancel = Arc::new(AtomicBool::new(false));
        let mut seen_progress = Vec::new();
        let report = run_with(
            sample_config(true, false),
            &cases,
            cancel,
            |p| seen_progress.push((p.done, p.total, p.current_id)),
            |case| async move {
                let answer = match case.id {
                    "note-fact" => "Om 14:30.",
                    "distractor" => "Op 12 november.",
                    "absent" => "Staat niet in je notities.",
                    _ => "Geen idee",
                };
                Ok(CaseReply { answer: answer.into(), used_evidence: true, retried_grounding: false })
            },
        )
        .await;

        assert_eq!(seen_progress.len(), 4);
        assert_eq!(seen_progress[3], (4, 4, "email-address".into()));
        assert_eq!(report.passed, 3);
        assert_eq!(report.total, 4);
        assert_eq!(report.score_percent, 75);
        assert!(report.is_good());
        assert!(!report.cancelled);
        assert!(report.failure.is_none());
        assert!(!report.history_line.is_empty());
        assert!(report.results.iter().all(|r| r.used_evidence));
    }

    #[tokio::test]
    async fn run_with_honors_cancellation_and_failures() {
        let cases = selected_cases(Some(&["note-fact".into(), "distractor".into(), "absent".into()]));
        let cancel = Arc::new(AtomicBool::new(false));
        let cancel_clone = cancel.clone();
        let cancelled_report = run_with(
            sample_config(false, false),
            &cases,
            cancel,
            move |p| {
                if p.done == 1 {
                    cancel_clone.store(true, Ordering::Relaxed);
                }
            },
            |_case| async { Ok(CaseReply { answer: "14:30".into(), used_evidence: false, retried_grounding: false }) },
        )
        .await;
        assert!(cancelled_report.cancelled);
        assert_eq!(cancelled_report.results.len(), 1);
        assert!(cancelled_report.history_line.is_empty());

        let failed_report = run_with(
            sample_config(false, false),
            &cases,
            Arc::new(AtomicBool::new(false)),
            |_| {},
            |case| async move {
                if case.id == "distractor" {
                    Err(crate::NookError::new("connection refused"))
                } else {
                    Ok(CaseReply { answer: "14:30".into(), used_evidence: false, retried_grounding: false })
                }
            },
        )
        .await;
        assert_eq!(failed_report.failure.as_deref(), Some("connection refused"));
        assert_eq!(failed_report.results.len(), 1);
        assert!(failed_report.history_line.is_empty());
    }
}
