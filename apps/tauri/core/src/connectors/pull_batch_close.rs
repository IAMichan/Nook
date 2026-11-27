//! Closing several pull requests in one go (`PullRequestBatchClose` on the Mac): the selection bar's Close in the pull
//! request list, with an optional comment that says why. They go one after the other; one that fails is reported with
//! its reason and the rest still go. With a comment, the comment goes first and a pull request whose comment the forge
//! refused is left open, so none closes without the words you wrote for it. The forge calls come in as closures, so tests
//! use it without a network.

use std::future::Future;

use serde::Serialize;

/// More than this in one go is no longer something the user can check at a glance.
pub const LIMIT: usize = 30;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", content = "reason", rename_all = "camelCase")]
pub enum Outcome {
    Closed,
    /// The comment was refused; the pull request stays open.
    CommentFailed(String),
    Failed(String),
}

impl Outcome {
    pub fn closed(&self) -> bool {
        matches!(self, Outcome::Closed)
    }
}

/// The comment as it is sent, or None when there is none worth sending.
pub fn comment(text: Option<&str>) -> Option<String> {
    let clean = text.unwrap_or_default().trim();
    (!clean.is_empty()).then(|| clean.to_string())
}

/// Runs `targets` in order: `post` (only with a comment), then `close`. Never stops at a failure.
pub async fn run<T, P, PF, C, CF>(targets: Vec<T>, comment_text: Option<&str>, mut post: P, mut close: C) -> Vec<(T, Outcome)>
where
    P: FnMut(&T, String) -> PF,
    PF: Future<Output = Result<(), String>>,
    C: FnMut(&T) -> CF,
    CF: Future<Output = Result<(), String>>,
{
    let comment = comment(comment_text);
    let mut outcomes = Vec::with_capacity(targets.len());
    for target in targets {
        if let Some(text) = &comment {
            if let Err(reason) = post(&target, text.clone()).await {
                outcomes.push((target, Outcome::CommentFailed(reason)));
                continue;
            }
        }
        let outcome = match close(&target).await {
            Ok(()) => Outcome::Closed,
            Err(reason) => Outcome::Failed(reason),
        };
        outcomes.push((target, outcome));
    }
    outcomes
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Failure {
    /// "owner/name#12" (or another name).
    pub name: String,
    pub reason: String,
    /// Only the comment was refused: the pull request is still open.
    pub comment_only: bool,
}

/// What the result says: how many closed of how many, and each one that did not with its reason.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Report {
    pub closed: usize,
    pub total: usize,
    pub failures: Vec<Failure>,
}

impl Report {
    pub fn all_closed(&self) -> bool {
        self.failures.is_empty()
    }
}

pub fn report<T>(outcomes: &[(T, Outcome)], name: impl Fn(&T) -> String) -> Report {
    let failures = outcomes
        .iter()
        .filter_map(|(target, outcome)| match outcome {
            Outcome::Closed => None,
            Outcome::CommentFailed(reason) => Some(Failure { name: name(target), reason: reason.clone(), comment_only: true }),
            Outcome::Failed(reason) => Some(Failure { name: name(target), reason: reason.clone(), comment_only: false }),
        })
        .collect();
    Report { closed: outcomes.iter().filter(|(_, o)| o.closed()).count(), total: outcomes.len(), failures }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    #[test]
    fn comment_is_trimmed_or_none() {
        assert_eq!(comment(Some("  why \n")), Some("why".into()));
        assert_eq!(comment(Some("   ")), None);
        assert_eq!(comment(None), None);
    }

    #[tokio::test]
    async fn closes_all_and_never_stops_at_a_failure() {
        let calls = RefCell::new(Vec::new());
        let outcomes = run(
            vec![1, 2, 3],
            None,
            |_, _| async { Ok(()) },
            |n: &i32| {
                calls.borrow_mut().push(*n);
                let n = *n;
                async move {
                    if n == 2 {
                        Err("gone".to_string())
                    } else {
                        Ok(())
                    }
                }
            },
        )
        .await;
        assert_eq!(*calls.borrow(), vec![1, 2, 3]);
        let report = report(&outcomes, |n| format!("#{n}"));
        assert_eq!(report.closed, 2);
        assert_eq!(report.total, 3);
        assert_eq!(report.failures, vec![Failure { name: "#2".into(), reason: "gone".into(), comment_only: false }]);
        assert!(!report.all_closed());
    }

    #[tokio::test]
    async fn a_refused_comment_leaves_the_pull_request_open() {
        let closed = RefCell::new(Vec::new());
        let outcomes = run(
            vec![1, 2],
            Some("Superseded"),
            |n: &i32, text| {
                assert_eq!(text, "Superseded");
                let n = *n;
                async move {
                    if n == 1 {
                        Err("locked".to_string())
                    } else {
                        Ok(())
                    }
                }
            },
            |n: &i32| {
                closed.borrow_mut().push(*n);
                async { Ok(()) }
            },
        )
        .await;
        assert_eq!(*closed.borrow(), vec![2]);
        assert_eq!(outcomes[0].1, Outcome::CommentFailed("locked".into()));
        assert!(report(&outcomes, |n| format!("#{n}")).failures[0].comment_only);
    }
}
