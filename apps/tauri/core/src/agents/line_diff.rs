//! Een eenvoudige regeldiff (langste gemeenschappelijke deelrij). Genoeg voor wijzigingen van agents en de preview van
//! een instellingenbestand; heel grote stukken worden "alles weg, alles erbij". Zoals `LineDiff` op de Mac.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Op {
    Same(String),
    Add(String),
    Remove(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DiffKind {
    Add,
    Remove,
    Context,
}

/// Eén regel van een getoonde diff.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DiffLine {
    pub kind: DiffKind,
    pub text: String,
}

impl DiffLine {
    pub fn context(text: impl Into<String>) -> Self {
        Self { kind: DiffKind::Context, text: text.into() }
    }
}

/// Regels van een tekst; een laatste lege regel (na de slotnewline) telt niet.
pub fn lines(text: &str) -> Vec<String> {
    if text.is_empty() {
        return vec![];
    }
    let mut result: Vec<String> = text.split('\n').map(str::to_string).collect();
    if result.last().is_some_and(|l| l.is_empty()) {
        result.pop();
    }
    result
}

pub fn diff(old: &[String], new: &[String]) -> Vec<Op> {
    // Eerst het gemeenschappelijke begin en eind, zodat er voor de LCS weinig overblijft.
    let mut prefix = 0;
    while prefix < old.len() && prefix < new.len() && old[prefix] == new[prefix] {
        prefix += 1;
    }
    let mut suffix = 0;
    while suffix < old.len() - prefix && suffix < new.len() - prefix && old[old.len() - 1 - suffix] == new[new.len() - 1 - suffix] {
        suffix += 1;
    }
    let a = &old[prefix..old.len() - suffix];
    let b = &new[prefix..new.len() - suffix];
    let mut ops: Vec<Op> = old[..prefix].iter().cloned().map(Op::Same).collect();
    if a.len() * b.len() > 250_000 {
        ops.extend(a.iter().cloned().map(Op::Remove));
        ops.extend(b.iter().cloned().map(Op::Add));
    } else {
        ops.extend(middle(a, b));
    }
    ops.extend(old[old.len() - suffix..].iter().cloned().map(Op::Same));
    ops
}

fn middle(a: &[String], b: &[String]) -> Vec<Op> {
    let (n, m) = (a.len(), b.len());
    if n == 0 {
        return b.iter().cloned().map(Op::Add).collect();
    }
    if m == 0 {
        return a.iter().cloned().map(Op::Remove).collect();
    }
    let mut table = vec![vec![0u32; m + 1]; n + 1];
    for i in (0..n).rev() {
        for j in (0..m).rev() {
            table[i][j] = if a[i] == b[j] { table[i + 1][j + 1] + 1 } else { table[i + 1][j].max(table[i][j + 1]) };
        }
    }
    let mut ops = Vec::with_capacity(n + m);
    let (mut i, mut j) = (0, 0);
    while i < n && j < m {
        if a[i] == b[j] {
            ops.push(Op::Same(a[i].clone()));
            i += 1;
            j += 1;
        } else if table[i + 1][j] >= table[i][j + 1] {
            ops.push(Op::Remove(a[i].clone()));
            i += 1;
        } else {
            ops.push(Op::Add(b[j].clone()));
            j += 1;
        }
    }
    ops.extend(a[i..].iter().cloned().map(Op::Remove));
    ops.extend(b[j..].iter().cloned().map(Op::Add));
    ops
}

/// (toegevoegd, weggehaald)
pub fn counts(ops: &[Op]) -> (usize, usize) {
    ops.iter().fold((0, 0), |(a, r), op| match op {
        Op::Add(_) => (a + 1, r),
        Op::Remove(_) => (a, r + 1),
        Op::Same(_) => (a, r),
    })
}

fn prefix_chars(text: &str, width: usize) -> String {
    text.chars().take(width).collect()
}

/// Alleen de gewijzigde regels met wat context eromheen, klaar om te tonen.
pub fn display(ops: &[Op], context: usize, limit: usize, width: usize) -> Vec<DiffLine> {
    let mut keep = std::collections::BTreeSet::new();
    for (index, op) in ops.iter().enumerate() {
        if matches!(op, Op::Same(_)) {
            continue;
        }
        let lo = index.saturating_sub(context);
        let hi = (index + context).min(ops.len() - 1);
        keep.extend(lo..=hi);
    }
    let mut result = Vec::new();
    let mut last: Option<usize> = None;
    for index in keep {
        if let Some(l) = last {
            if index > l + 1 {
                result.push(DiffLine::context("  …"));
            }
        }
        last = Some(index);
        result.push(match &ops[index] {
            Op::Same(t) => DiffLine { kind: DiffKind::Context, text: format!("  {}", prefix_chars(t, width)) },
            Op::Add(t) => DiffLine { kind: DiffKind::Add, text: format!("+ {}", prefix_chars(t, width)) },
            Op::Remove(t) => DiffLine { kind: DiffKind::Remove, text: format!("- {}", prefix_chars(t, width)) },
        });
        if result.len() >= limit {
            result.push(DiffLine::context("  …"));
            break;
        }
    }
    result
}

/// Kort: diff van twee teksten, met (regels, toegevoegd, weggehaald).
pub fn text_diff(old: &str, new: &str, context: usize, limit: usize, width: usize) -> (Vec<DiffLine>, usize, usize) {
    let ops = diff(&lines(old), &lines(new));
    let (added, removed) = counts(&ops);
    (display(&ops, context, limit, width), added, removed)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v(items: &[&str]) -> Vec<String> {
        items.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn finds_changed_lines() {
        let ops = diff(&v(&["a", "b", "c"]), &v(&["a", "x", "c"]));
        assert_eq!(ops, vec![Op::Same("a".into()), Op::Remove("b".into()), Op::Add("x".into()), Op::Same("c".into())]);
        assert_eq!(counts(&ops), (1, 1));
    }

    #[test]
    fn lines_drop_trailing_newline() {
        assert_eq!(lines("a\nb\n"), v(&["a", "b"]));
        assert!(lines("").is_empty());
    }

    #[test]
    fn display_keeps_context_and_gaps() {
        let old: Vec<String> = (0..10).map(|i| i.to_string()).collect();
        let mut new = old.clone();
        new[1] = "x".into();
        new[8] = "y".into();
        let shown = display(&diff(&old, &new), 1, 40, 110);
        assert!(shown.iter().any(|l| l.text == "  …"));
        assert_eq!(shown.iter().filter(|l| l.kind == DiffKind::Add).count(), 2);
    }

    #[test]
    fn huge_chunks_fall_back() {
        let old: Vec<String> = (0..600).map(|i| format!("a{i}")).collect();
        let new: Vec<String> = (0..600).map(|i| format!("b{i}")).collect();
        assert_eq!(counts(&diff(&old, &new)), (600, 600));
    }
}
