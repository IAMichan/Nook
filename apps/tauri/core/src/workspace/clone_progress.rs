//! How far a `git clone --progress` is, from its stderr (the Mac's `GitCloneProgress`): the stage, the percentage and
//! git's own words after the count, for the clone notices in the main window's top right corner (`CloneNoticeStack`).

use serde::Serialize;

use crate::i18n::tr;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Stage {
    /// The server counts and compresses what it sends.
    Counting,
    Receiving,
    Resolving,
    /// Writing out the files of the default branch.
    Checkout,
}

impl Stage {
    pub fn title(self) -> &'static str {
        match self {
            Stage::Counting => tr("Objecten tellen", "Counting objects"),
            Stage::Receiving => tr("Objecten ontvangen", "Receiving objects"),
            Stage::Resolving => tr("Delta's verwerken", "Resolving deltas"),
            Stage::Checkout => tr("Bestanden uitchecken", "Checking out files"),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CloneProgress {
    pub stage: Stage,
    /// 0–100; none when git gave no percentage for the stage.
    pub percent: Option<u8>,
    /// Git's own words after the count ("12.40 MiB | 3.10 MiB/s").
    pub detail: Option<String>,
}

const STAGES: [(&str, Stage); 7] = [
    ("remote: Enumerating objects", Stage::Counting),
    ("remote: Counting objects", Stage::Counting),
    ("remote: Compressing objects", Stage::Counting),
    ("Receiving objects", Stage::Receiving),
    ("Resolving deltas", Stage::Resolving),
    ("Updating files", Stage::Checkout),
    ("Checking out files", Stage::Checkout),
];

impl CloneProgress {
    /// The notice's line: "Receiving objects · 42% · 12.40 MiB | 3.10 MiB/s".
    pub fn summary(&self) -> String {
        let mut parts = vec![self.stage.title().to_string()];
        if let Some(p) = self.percent {
            parts.push(format!("{p}%"));
        }
        if let Some(d) = &self.detail {
            parts.push(d.clone());
        }
        parts.join(" · ")
    }

    /// One line of git's stderr; none when it is not a progress line (a warning, "Cloning into …", an error).
    pub fn parse(line: &str) -> Option<CloneProgress> {
        let text = line.trim();
        let (prefix, stage) = STAGES.iter().find(|(prefix, _)| text.starts_with(prefix))?;
        let after = &text[prefix.len()..];
        let Some(colon) = after.find(':') else { return Some(CloneProgress { stage: *stage, percent: None, detail: None }) };
        let rest = after[colon + 1..].trim_start();
        // "42% (420/1000), 12.40 MiB | 3.10 MiB/s" or "100% (1000/1000), 24.00 MiB | 3.10 MiB/s, done."
        let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
        let after_digits = &rest[digits.len()..];
        if digits.is_empty() || digits.len() > 3 || !after_digits.starts_with('%') {
            return Some(CloneProgress { stage: *stage, percent: None, detail: None });
        }
        let percent = digits.parse::<u16>().ok().map(|p| p.min(100) as u8);
        let mut tail = after_digits[1..].trim_start();
        if tail.starts_with('(') {
            tail = tail.find(')').map(|i| &tail[i + 1..]).unwrap_or("");
        }
        let mut detail = tail.trim().trim_start_matches(',').trim().to_string();
        for suffix in [", done.", "done."] {
            if let Some(cut) = detail.strip_suffix(suffix) {
                detail = cut.trim().to_string();
            }
        }
        let detail = detail.trim_end_matches(',').trim().to_string();
        Some(CloneProgress { stage: *stage, percent, detail: (!detail.is_empty()).then_some(detail) })
    }
}

/// "owner/repo" of a clone address (https, ssh or scp style), without ".git".
pub fn display_name(url: &str) -> String {
    let mut text = url.trim().trim_end_matches('/').to_string();
    if let Some(cut) = text.strip_suffix(".git") {
        text = cut.to_string();
    }
    if let Some(i) = text.find("://") {
        text = text[i + 3..].to_string();
        text = text.find('/').map(|i| text[i + 1..].to_string()).unwrap_or(text);
    } else if let Some(i) = text.find(':') {
        text = text[i + 1..].to_string();
    }
    let parts: Vec<&str> = text.split('/').filter(|p| !p.is_empty()).collect();
    if parts.is_empty() {
        return url.to_string();
    }
    parts[parts.len().saturating_sub(2)..].join("/")
}

/// Cuts a stream of stderr into lines on `\r` and `\n`, keeping a line that is not finished for the next chunk.
#[derive(Default)]
pub struct Lines {
    pending: String,
}

impl Lines {
    pub fn feed(&mut self, text: &str) -> Vec<String> {
        let mut lines = vec![];
        let mut current = std::mem::take(&mut self.pending);
        for c in text.chars() {
            if c == '\r' || c == '\n' {
                if !current.is_empty() {
                    lines.push(std::mem::take(&mut current));
                }
            } else {
                current.push(c);
            }
        }
        self.pending = current;
        lines
    }
}

/// The lines that say why a clone failed: everything that is not progress or "Cloning into", the last few.
pub fn failure(stderr: &str) -> Option<String> {
    let mut lines = Lines::default();
    let all = lines.feed(&format!("{stderr}\n"));
    let reasons: Vec<&str> = all
        .iter()
        .map(|l| l.trim())
        .filter(|l| !l.is_empty() && CloneProgress::parse(l).is_none() && !l.starts_with("Cloning into"))
        .collect();
    (!reasons.is_empty()).then(|| reasons[reasons.len().saturating_sub(4)..].join("\n"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_gits_progress_lines() {
        crate::i18n::set_language("en");
        let p = CloneProgress::parse("Receiving objects:  42% (420/1000), 12.40 MiB | 3.10 MiB/s").unwrap();
        assert_eq!(p.stage, Stage::Receiving);
        assert_eq!(p.percent, Some(42));
        assert_eq!(p.detail.as_deref(), Some("12.40 MiB | 3.10 MiB/s"));
        assert_eq!(p.summary(), "Receiving objects · 42% · 12.40 MiB | 3.10 MiB/s");
        let done = CloneProgress::parse("Resolving deltas: 100% (900/900), done.").unwrap();
        assert_eq!((done.stage, done.percent, done.detail), (Stage::Resolving, Some(100), None));
        let remote = CloneProgress::parse("remote: Counting objects:  10% (1/10)").unwrap();
        assert_eq!(remote.stage, Stage::Counting);
        assert!(CloneProgress::parse("Cloning into 'nook'...").is_none());
        assert!(CloneProgress::parse("fatal: repository not found").is_none());
    }

    #[test]
    fn names_the_repository() {
        assert_eq!(display_name("https://github.com/owner/repo.git"), "owner/repo");
        assert_eq!(display_name("git@github.com:owner/repo.git"), "owner/repo");
        assert_eq!(display_name("https://gitlab.com/group/sub/repo/"), "sub/repo");
    }

    #[test]
    fn cuts_stderr_into_lines_across_chunks() {
        let mut lines = Lines::default();
        assert_eq!(lines.feed("Receiving objects:  1%\rReceiving obj"), vec!["Receiving objects:  1%"]);
        assert_eq!(lines.feed("ects:  2%\r\n"), vec!["Receiving objects:  2%"]);
        assert_eq!(failure("Cloning into 'x'...\nfatal: repository not found\n").as_deref(), Some("fatal: repository not found"));
    }
}
