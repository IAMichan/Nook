//! The files of a project for the composer's `@` list (`FileMentions` on the Mac): a bounded walk that skips build
//! output and dependencies, ranked by how well the path matches what you typed. And where a pasted or dropped picture
//! is kept, so the agent can read it from a path.

use std::path::{Path, PathBuf};

/// Folders never walked into.
const SKIPPED: &[&str] = &[
    "node_modules",
    ".git",
    ".build",
    "build",
    "dist",
    "DerivedData",
    "Pods",
    ".next",
    "vendor",
    "target",
    ".scratch",
    ".venv",
    "__pycache__",
    ".gradle",
    ".idea",
    ".svelte-kit",
    "coverage",
];
/// At most this many entries are looked at, so a huge folder answers quickly.
const BUDGET: usize = 40_000;

/// Every file (and folder) below `root`, relative, with `/` between parts; folders end in `/`.
pub fn list(root: &Path) -> Vec<String> {
    let mut out = vec![];
    let mut stack = vec![PathBuf::new()];
    let mut seen = 0;
    while let Some(rel) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(root.join(&rel)) else { continue };
        let mut entries: Vec<_> = entries.flatten().collect();
        entries.sort_by_key(|e| e.file_name());
        for entry in entries {
            seen += 1;
            if seen > BUDGET {
                return out;
            }
            let name = entry.file_name().to_string_lossy().into_owned();
            let path = rel.join(&name);
            let text = path.to_string_lossy().replace('\\', "/");
            let is_dir = entry.file_type().is_ok_and(|t| t.is_dir());
            if is_dir {
                if SKIPPED.contains(&name.as_str()) || name.starts_with('.') {
                    continue;
                }
                out.push(format!("{text}/"));
                stack.push(path);
            } else {
                out.push(text);
            }
        }
    }
    out
}

/// How well `path` matches `query` (higher is better); `None` when its letters are not all in it in order. The file
/// name counts more than the folders, an exact start of the name most.
pub fn score(path: &str, query: &str) -> Option<i64> {
    let q = query.to_lowercase();
    if q.is_empty() {
        return Some(-(path.len() as i64));
    }
    let lower = path.to_lowercase();
    let name = lower.trim_end_matches('/').rsplit('/').next().unwrap_or("").to_string();
    let mut chars = lower.chars();
    if !q.chars().all(|c| chars.any(|p| p == c)) {
        return None;
    }
    let mut s = 0i64;
    if name.starts_with(&q) {
        s += 1000;
    } else if name.contains(&q) {
        s += 600;
    } else if lower.contains(&q) {
        s += 300;
    }
    Some(s - path.len() as i64)
}

/// The best `limit` matches of `query` among `files`.
pub fn search(files: &[String], query: &str, limit: usize) -> Vec<String> {
    let mut ranked: Vec<(i64, &String)> = files.iter().filter_map(|f| score(f, query).map(|s| (s, f))).collect();
    ranked.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(b.1)));
    ranked.into_iter().take(limit).map(|(_, f)| f.clone()).collect()
}

/// Where pasted and dropped pictures are kept for the agents to read (`~/.nook/attachments`).
pub fn pictures() -> PathBuf {
    crate::paths::dot_nook().join("attachments")
}

/// Keeps a picture's bytes under a new name and gives its path.
pub fn save_picture(bytes: &[u8], extension: &str) -> std::io::Result<PathBuf> {
    save_picture_named(bytes, extension, None)
}

/// Keeps a picture's bytes under a requested stem (when given) or a timestamped name, and gives its path.
pub fn save_picture_named(bytes: &[u8], extension: &str, name: Option<&str>) -> std::io::Result<PathBuf> {
    let ext: String = extension.chars().filter(|c| c.is_ascii_alphanumeric()).take(5).collect::<String>().to_lowercase();
    let ext = if ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(&ext.as_str()) { ext } else { "png".into() };
    let dir = pictures();
    std::fs::create_dir_all(&dir)?;
    let stem: String = name
        .unwrap_or("")
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '_' { c } else { '-' })
        .take(64)
        .collect::<String>()
        .trim_matches('-')
        .to_string();
    let file_name = if !stem.is_empty() {
        let preferred = format!("{stem}.{ext}");
        if !dir.join(&preferred).exists() {
            preferred
        } else {
            format!("{stem}-{}.{ext}", &uuid::Uuid::new_v4().simple().to_string()[..6])
        }
    } else {
        format!("{}-{}.{ext}", chrono::Local::now().format("%Y%m%d-%H%M%S"), &uuid::Uuid::new_v4().simple().to_string()[..6])
    };
    let path = dir.join(file_name);
    std::fs::write(&path, bytes)?;
    Ok(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn walks_the_project_and_ranks_by_name() {
        let root = std::env::temp_dir().join(format!("nook-files-{}", uuid::Uuid::new_v4()));
        for f in ["src/Login.swift", "src/app/login_view.rs", "node_modules/x/login.js", "README.md"] {
            let p = root.join(f);
            std::fs::create_dir_all(p.parent().unwrap()).unwrap();
            std::fs::write(p, "").unwrap();
        }
        let files = list(&root);
        assert!(files.contains(&"src/Login.swift".to_string()) && files.contains(&"src/".to_string()));
        assert!(!files.iter().any(|f| f.contains("node_modules")));
        assert_eq!(search(&files, "login", 2), vec!["src/Login.swift", "src/app/login_view.rs"]);
        assert!(search(&files, "zzz", 5).is_empty());
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn sanitizes_named_picture_stems() {
        let stem = format!("pdf-test-{}", &uuid::Uuid::new_v4().simple().to_string()[..8]);
        let path = save_picture_named(b"png", "png", Some(&format!("../{stem} "))).unwrap();
        let name = path.file_name().unwrap().to_string_lossy().to_string();
        assert_eq!(name, format!("{stem}.png"));
        let second = save_picture_named(b"png", "png", Some(&stem)).unwrap();
        let second_name = second.file_name().unwrap().to_string_lossy().to_string();
        assert!(second_name.starts_with(&format!("{stem}-")) && second_name.ends_with(".png"));
        let _ = std::fs::remove_file(path);
        let _ = std::fs::remove_file(second);
    }
}
