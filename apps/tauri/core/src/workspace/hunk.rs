//! Unified diff hunk parsing and single-hunk patch generation (`HunkPatch` on macOS, AG-103):
//! splits a file's unified diff into structured hunks and builds a clean, self-contained patch for one hunk so it can
//! be staged (`git apply --cached --unidiff-zero`) or discarded (`git apply --reverse --unidiff-zero`) without touching
//! the rest of the file.

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::i18n::tr;
use crate::workspace::git::Git;

/// Action to apply to a single diff hunk.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum HunkAction {
    /// Stage the hunk into the git index (`git apply --cached`).
    Stage,
    /// Revert the hunk from the working tree (`git apply --reverse`).
    Discard,
}

/// One structured hunk of a unified diff, starting with its `@@ ... @@` header line.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiffHunk {
    pub index: usize,
    pub header: String,
    pub old_start: usize,
    pub old_count: usize,
    pub new_start: usize,
    pub new_count: usize,
    pub section: String,
    pub lines: Vec<String>,
    pub added: usize,
    pub removed: usize,
}

/// A single file's unified diff split into its file header and structured hunks.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HunkPatch {
    /// File-level header lines (`diff --git`, `index`, `---`, `+++`, mode headers).
    pub header: Vec<String>,
    /// Hunks in file order.
    pub hunks: Vec<DiffHunk>,
}

impl HunkPatch {
    /// Parses the unified diff of one file. If the input contains multiple files, only the first file is parsed.
    /// Binary or mode-only diffs produce zero hunks.
    pub fn parse(diff: &str) -> Self {
        let normalized = diff.replace("\r\n", "\n");
        let mut lines: Vec<&str> = normalized.split('\n').collect();
        if lines.last() == Some(&"") {
            lines.pop();
        }

        let mut header: Vec<String> = Vec::new();
        let mut raw_hunks: Vec<Vec<String>> = Vec::new();
        let mut current: Option<Vec<String>> = None;
        let mut seen_file = false;

        for line in lines {
            if line.starts_with("diff --git ") {
                if seen_file {
                    break;
                }
                seen_file = true;
            }
            if line.starts_with("@@") {
                if let Some(h) = current.take() {
                    raw_hunks.push(h);
                }
                current = Some(vec![line.to_string()]);
            } else if let Some(ref mut h) = current {
                h.push(line.to_string());
            } else {
                header.push(line.to_string());
            }
        }
        if let Some(h) = current {
            raw_hunks.push(h);
        }

        let hunks = raw_hunks
            .into_iter()
            .enumerate()
            .map(|(index, lines)| {
                let hunk_header = lines.first().cloned().unwrap_or_default();
                let (old_start, old_count, new_start, new_count, section) = parse_hunk_header(&hunk_header);
                let mut added = 0;
                let mut removed = 0;
                for l in lines.iter().skip(1) {
                    if l.starts_with('+') && !l.starts_with("+++") {
                        added += 1;
                    } else if l.starts_with('-') && !l.starts_with("---") {
                        removed += 1;
                    }
                }
                DiffHunk {
                    index,
                    header: hunk_header,
                    old_start,
                    old_count,
                    new_start,
                    new_count,
                    section,
                    lines,
                    added,
                    removed,
                }
            })
            .collect();

        Self { header, hunks }
    }

    pub fn count(&self) -> usize {
        self.hunks.len()
    }

    /// Builds a clean applyable single-hunk unified patch (file header + hunk lines + trailing newline).
    pub fn build_hunk_patch(&self, index: usize) -> Option<String> {
        let hunk = self.hunks.get(index)?;
        if self.header.is_empty() {
            return None;
        }
        let mut out = Vec::with_capacity(self.header.len() + hunk.lines.len());
        out.extend(self.header.iter().cloned());
        out.extend(hunk.lines.iter().cloned());
        Some(format!("{}\n", out.join("\n")))
    }

    /// Arguments for `git apply` for a given `HunkAction` and temporary patch file path.
    pub fn git_apply_args(action: HunkAction, patch_path: &str) -> Vec<String> {
        match action {
            HunkAction::Stage => vec![
                "apply".into(),
                "--cached".into(),
                "--unidiff-zero".into(),
                "--whitespace=nowarn".into(),
                patch_path.into(),
            ],
            HunkAction::Discard => vec![
                "apply".into(),
                "--reverse".into(),
                "--unidiff-zero".into(),
                "--whitespace=nowarn".into(),
                patch_path.into(),
            ],
        }
    }
}

/// Convenience helper: builds an applyable single-hunk unified patch from a raw file diff and 0-based hunk index.
pub fn build_hunk_patch(diff: &str, hunk_index: usize) -> Option<String> {
    HunkPatch::parse(diff).build_hunk_patch(hunk_index)
}

/// Applies one hunk of `diff` in `repo` (staging to index or discarding from working tree).
pub fn apply_hunk_to_repo(git: &Git, repo: &str, diff: &str, hunk_index: usize, action: HunkAction) -> Result<(), String> {
    let patch = build_hunk_patch(diff, hunk_index)
        .ok_or_else(|| tr("Deze wijziging kon niet worden gevonden in de diff.", "This hunk could not be found in the diff.").to_string())?;

    let temp_path = std::env::temp_dir().join(format!("nook-hunk-{}.patch", Uuid::new_v4()));
    std::fs::write(&temp_path, patch.as_bytes()).map_err(|e| e.to_string())?;
    let patch_str = temp_path.to_string_lossy().into_owned();
    let args = HunkPatch::git_apply_args(action, &patch_str);
    let arg_refs: Vec<&str> = args.iter().map(String::as_str).collect();
    let result = git.run(&arg_refs, repo).map(|_| ()).map_err(|e| e.0);
    let _ = std::fs::remove_file(&temp_path);
    result
}

/// Parses `@@ -old_start[,old_count] +new_start[,new_count] @@[ section]`.
fn parse_hunk_header(header: &str) -> (usize, usize, usize, usize, String) {
    let after_open = header.strip_prefix("@@").unwrap_or(header).trim_start();
    let (range_part, section) = match after_open.find("@@") {
        Some(pos) => (&after_open[..pos], after_open[pos + 2..].trim().to_string()),
        None => (after_open, String::new()),
    };

    let mut old_start = 1;
    let mut old_count = 1;
    let mut new_start = 1;
    let mut new_count = 1;

    for token in range_part.split_whitespace() {
        if let Some(rest) = token.strip_prefix('-') {
            let (s, c) = parse_range(rest);
            old_start = s;
            old_count = c;
        } else if let Some(rest) = token.strip_prefix('+') {
            let (s, c) = parse_range(rest);
            new_start = s;
            new_count = c;
        }
    }

    (old_start, old_count, new_start, new_count, section)
}

fn parse_range(spec: &str) -> (usize, usize) {
    match spec.split_once(',') {
        Some((s, c)) => (s.parse().unwrap_or(1), c.parse().unwrap_or(1)),
        None => (spec.parse().unwrap_or(1), 1),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MULTI_HUNK_DIFF: &str = "\
diff --git a/src/lib.rs b/src/lib.rs
index 1111111..2222222 100644
--- a/src/lib.rs
+++ b/src/lib.rs
@@ -1,4 +1,5 @@
 fn alpha() {
-    let a = 1;
+    let a = 10;
+    let b = 20;
 }
 fn keep() {}
@@ -20,3 +21,2 @@ fn gamma()
 fn gamma() {
-    old_call();
 }
";

    #[test]
    fn parses_multi_hunk_diff_and_metadata() {
        let parsed = HunkPatch::parse(MULTI_HUNK_DIFF);
        assert_eq!(parsed.header.len(), 4);
        assert_eq!(parsed.count(), 2);

        let h0 = &parsed.hunks[0];
        assert_eq!(h0.index, 0);
        assert_eq!((h0.old_start, h0.old_count), (1, 4));
        assert_eq!((h0.new_start, h0.new_count), (1, 5));
        assert_eq!(h0.added, 2);
        assert_eq!(h0.removed, 1);
        assert_eq!(h0.section, "");

        let h1 = &parsed.hunks[1];
        assert_eq!(h1.index, 1);
        assert_eq!((h1.old_start, h1.old_count), (20, 3));
        assert_eq!((h1.new_start, h1.new_count), (21, 2));
        assert_eq!(h1.added, 0);
        assert_eq!(h1.removed, 1);
        assert_eq!(h1.section, "fn gamma()");
    }

    #[test]
    fn builds_clean_single_hunk_patch() {
        let p0 = build_hunk_patch(MULTI_HUNK_DIFF, 0).expect("hunk 0");
        assert!(p0.starts_with("diff --git a/src/lib.rs b/src/lib.rs\n"));
        assert!(p0.contains("@@ -1,4 +1,5 @@"));
        assert!(p0.contains("+    let b = 20;"));
        assert!(!p0.contains("@@ -20,3 +21,2 @@"));
        assert!(p0.ends_with('\n'));

        let p1 = build_hunk_patch(MULTI_HUNK_DIFF, 1).expect("hunk 1");
        assert!(p1.starts_with("diff --git a/src/lib.rs b/src/lib.rs\n"));
        assert!(p1.contains("@@ -20,3 +21,2 @@ fn gamma()"));
        assert!(!p1.contains("@@ -1,4 +1,5 @@"));
        assert!(p1.ends_with('\n'));

        assert!(build_hunk_patch(MULTI_HUNK_DIFF, 2).is_none());
    }

    #[test]
    fn stops_at_second_file_in_multi_file_diff() {
        let two_files = format!(
            "{MULTI_HUNK_DIFF}\
diff --git a/src/other.rs b/src/other.rs
--- a/src/other.rs
+++ b/src/other.rs
@@ -1 +1 @@
-x
+y
"
        );
        let parsed = HunkPatch::parse(&two_files);
        assert_eq!(parsed.count(), 2);
        assert!(parsed.header[0].contains("src/lib.rs"));
    }

    #[test]
    fn handles_binary_diff_and_single_line_hunk_and_no_newline() {
        let binary = "diff --git a/img.png b/img.png\nBinary files a/img.png and b/img.png differ\n";
        let parsed_bin = HunkPatch::parse(binary);
        assert_eq!(parsed_bin.count(), 0);
        assert!(parsed_bin.build_hunk_patch(0).is_none());

        let single = "\
--- a/note.txt
+++ b/note.txt
@@ -1 +1 @@
-hello
\\ No newline at end of file
+world
\\ No newline at end of file
";
        let parsed = HunkPatch::parse(single);
        assert_eq!(parsed.count(), 1);
        assert_eq!((parsed.hunks[0].old_start, parsed.hunks[0].old_count), (1, 1));
        assert_eq!((parsed.hunks[0].new_start, parsed.hunks[0].new_count), (1, 1));
        let patch = parsed.build_hunk_patch(0).unwrap();
        assert!(patch.contains("\\ No newline at end of file"));
    }

    #[test]
    fn builds_expected_git_apply_arguments() {
        assert_eq!(
            HunkPatch::git_apply_args(HunkAction::Stage, "/tmp/a.patch"),
            vec!["apply", "--cached", "--unidiff-zero", "--whitespace=nowarn", "/tmp/a.patch"]
        );
        assert_eq!(
            HunkPatch::git_apply_args(HunkAction::Discard, "/tmp/a.patch"),
            vec!["apply", "--reverse", "--unidiff-zero", "--whitespace=nowarn", "/tmp/a.patch"]
        );
    }

    #[test]
    fn stages_and_discards_individual_hunks_in_real_git_repo() {
        let Some(git) = Git::locate() else {
            return;
        };
        let dir = std::env::temp_dir().join(format!("nook-hunk-test-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let repo = dir.to_string_lossy().into_owned();

        git.run(&["init"], &repo).unwrap();
        git.run(&["config", "user.email", "test@nook.local"], &repo).unwrap();
        git.run(&["config", "user.name", "Nook Test"], &repo).unwrap();

        let file_path = dir.join("sample.txt");
        let original = (1..=20).map(|n| format!("line {n}")).collect::<Vec<_>>().join("\n") + "\n";
        std::fs::write(&file_path, &original).unwrap();
        git.run(&["add", "sample.txt"], &repo).unwrap();
        git.run(&["commit", "-m", "initial"], &repo).unwrap();

        // Modify line 2 (hunk 0) and line 18 (hunk 1).
        let modified = original.replace("line 2\n", "line 2 edited\n").replace("line 18\n", "line 18 edited\n");
        std::fs::write(&file_path, &modified).unwrap();

        let diff = git.run(&["diff", "--", "sample.txt"], &repo).unwrap();
        assert_eq!(HunkPatch::parse(&diff).count(), 2);

        // Stage only hunk 0.
        apply_hunk_to_repo(&git, &repo, &diff, 0, HunkAction::Stage).unwrap();
        let staged = git.run(&["diff", "--cached", "--", "sample.txt"], &repo).unwrap();
        assert!(staged.contains("+line 2 edited"));
        assert!(!staged.contains("+line 18 edited"));

        // Discard remaining unstaged hunk (which is now hunk 0 in working-tree diff: line 18).
        let unstaged = git.run(&["diff", "--", "sample.txt"], &repo).unwrap();
        assert_eq!(HunkPatch::parse(&unstaged).count(), 1);
        apply_hunk_to_repo(&git, &repo, &unstaged, 0, HunkAction::Discard).unwrap();

        let after_discard = std::fs::read_to_string(&file_path).unwrap();
        assert!(after_discard.contains("line 2 edited\n"));
        assert!(after_discard.contains("line 18\n"));
        assert!(!after_discard.contains("line 18 edited"));

        let _ = std::fs::remove_dir_all(&dir);
    }
}
