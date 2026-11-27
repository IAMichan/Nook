//! The `$` list of a session composer (`SkillIndex` and `SkillPlaces` on the Mac): the skills on disk that the session's
//! agent reads. Only the front matter of each file is read (bounded), never the body, so a huge or hostile SKILL.md
//! cannot cost memory or leak into the interface.

use std::collections::{BTreeMap, HashSet};
use std::io::Read;
use std::path::{Path, PathBuf};

use serde::Serialize;

use super::models::RunProvider;

const MAX_FILE_BYTES: u64 = 64 * 1024;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Skill {
    pub name: String,
    pub description: String,
    pub path: String,
    /// The root it came from, such as ".claude/skills".
    pub source: String,
}

/// The skills folder an agent reads, user-wide and per project (`SkillPlaces.root`).
fn places(provider: RunProvider) -> (&'static str, &'static str) {
    match provider {
        RunProvider::Claude => (".claude/skills", ".claude/skills"),
        // `~/.codex/skills` is the older place; current Codex reads the shared `.agents/skills`.
        RunProvider::Codex => (".agents/skills", ".agents/skills"),
        RunProvider::Gemini => (".gemini/skills", ".gemini/skills"),
        RunProvider::Antigravity => (".gemini/config/skills", ".agents/skills"),
        RunProvider::Opencode => (".config/opencode/skills", ".opencode/skills"),
        RunProvider::Cursor => (".cursor/skills", ".cursor/skills"),
        // Grok Build also reads Claude Code's skills; it documents no project folder of its own.
        RunProvider::Grok => (".grok/skills", ".claude/skills"),
        // Custom ACP agents read shared `.agents/skills`.
        RunProvider::Acp => (".agents/skills", ".agents/skills"),
    }
}

/// The folder whose project skills a session gets: where it works, or, once its worktree is gone, the project itself.
pub fn project_folder(working_directory: &str, project_path: &str) -> Option<PathBuf> {
    [working_directory, project_path].into_iter().filter(|f| !f.is_empty()).map(PathBuf::from).find(|p| p.is_dir())
}

/// The roots to scan, each once: the agent's own project folder and the shared project ones before every user one, so
/// a project skill beats a user skill of the same name.
pub fn roots(provider: RunProvider, home: &Path, project: Option<&Path>) -> Vec<PathBuf> {
    let (user, own_project) = places(provider);
    let mut shared = Vec::new();
    if let Some(p) = project {
        shared.push(p.join(".claude/skills"));
        shared.push(p.join(".agents/skills"));
    }
    shared.push(home.join(".claude/skills"));
    shared.push(home.join(".agents/skills"));
    shared.push(home.join(".codex/skills"));
    let mut ordered = Vec::new();
    if let Some(p) = project {
        ordered.push(p.join(own_project));
        ordered.extend(shared.iter().filter(|r| r.starts_with(p)).cloned());
    }
    ordered.push(home.join(user));
    ordered.extend(shared);
    let mut seen = HashSet::new();
    ordered.into_iter().filter(|r| seen.insert(r.clone())).collect()
}

/// The skills under `roots`: a folder with a SKILL.md, or a loose .md file; the first root to name one wins.
pub fn scan(roots: &[PathBuf]) -> Vec<Skill> {
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for root in roots {
        let label = format!(
            "{}/{}",
            root.parent().and_then(Path::file_name).map(|n| n.to_string_lossy().into_owned()).unwrap_or_default(),
            root.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
        );
        let Ok(entries) = std::fs::read_dir(root) else { continue };
        let mut names: Vec<String> = entries.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect();
        names.sort();
        for entry in names.into_iter().filter(|n| !n.starts_with('.')) {
            let path = root.join(&entry);
            let (file, fallback) = if path.is_dir() {
                (path.join("SKILL.md"), entry.clone())
            } else if entry.to_lowercase().ends_with(".md") && entry.to_uppercase() != "README.MD" {
                (path.clone(), entry[..entry.len() - 3].to_string())
            } else {
                continue;
            };
            let Some(head) = read_head(&file) else { continue };
            let meta = front_matter(&head);
            let name = clean(meta.get("name")).unwrap_or(fallback);
            if !seen.insert(name.to_lowercase()) {
                continue;
            }
            out.push(Skill {
                name,
                description: clean(meta.get("description")).unwrap_or_default(),
                path: file.to_string_lossy().into_owned(),
                source: label.clone(),
            });
        }
    }
    out.sort_by_key(|s| s.name.to_lowercase());
    out
}

/// Prefix on the name, then a name that contains it, then a hit in the description.
pub fn filter(skills: &[Skill], query: &str, limit: usize) -> Vec<Skill> {
    let q = query.trim().trim_start_matches('$').to_lowercase();
    if q.is_empty() {
        return skills.iter().take(limit).cloned().collect();
    }
    let (mut prefix, mut contains, mut desc) = (Vec::new(), Vec::new(), Vec::new());
    for s in skills {
        let name = s.name.to_lowercase();
        if name.starts_with(&q) {
            prefix.push(s.clone());
        } else if name.contains(&q) {
            contains.push(s.clone());
        } else if s.description.to_lowercase().contains(&q) {
            desc.push(s.clone());
        }
    }
    prefix.into_iter().chain(contains).chain(desc).take(limit).collect()
}

fn read_head(file: &Path) -> Option<String> {
    let f = std::fs::File::open(file).ok()?;
    let mut bytes = Vec::new();
    f.take(MAX_FILE_BYTES).read_to_end(&mut bytes).ok()?;
    Some(String::from_utf8_lossy(&bytes).into_owned())
}

/// Flat `key: value` pairs between the first two `---` lines; indented lines continue the previous value. Without a
/// closing line the file has no usable front matter.
pub fn front_matter(text: &str) -> BTreeMap<String, String> {
    let text = text.replace("\r\n", "\n");
    let mut lines = text.split('\n');
    if lines.next().map(str::trim) != Some("---") {
        return BTreeMap::new();
    }
    let mut out: BTreeMap<String, String> = BTreeMap::new();
    let mut key: Option<String> = None;
    let mut closed = false;
    for line in lines {
        if line.trim() == "---" {
            closed = true;
            break;
        }
        if let Some(k) = &key {
            if line.starts_with(' ') || line.starts_with('\t') {
                let part = line.trim();
                if !part.is_empty() {
                    let v = out.entry(k.clone()).or_default();
                    if v.is_empty() {
                        *v = part.to_string();
                    } else {
                        v.push(' ');
                        v.push_str(part);
                    }
                }
                continue;
            }
        }
        let Some(colon) = line.find(':').filter(|_| !line.starts_with('#')) else {
            key = None;
            continue;
        };
        let k = line[..colon].trim().to_lowercase();
        let mut v = line[colon + 1..].trim().to_string();
        if [">", "|", ">-", "|-", ">+", "|+"].contains(&v.as_str()) {
            v.clear();
        }
        out.insert(k.clone(), v);
        key = Some(k);
    }
    if closed {
        out
    } else {
        BTreeMap::new()
    }
}

fn clean(value: Option<&String>) -> Option<String> {
    let mut v = value?.trim();
    if v.len() >= 2 && ((v.starts_with('"') && v.ends_with('"')) || (v.starts_with('\'') && v.ends_with('\''))) {
        v = &v[1..v.len() - 1];
    }
    let v = v.trim();
    (!v.is_empty()).then(|| v.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_front_matter_with_folded_values() {
        let m = front_matter("---\nname: \"review\"\ndescription: >\n  Reads a diff\n  and comments\n---\nbody: no");
        assert_eq!(clean(m.get("name")).as_deref(), Some("review"));
        assert_eq!(m.get("description").map(String::as_str), Some("Reads a diff and comments"));
        assert!(front_matter("---\nname: x\n").is_empty());
        assert!(front_matter("name: x").is_empty());
    }

    #[test]
    fn project_skills_win_and_filter_orders_hits() {
        let dir = std::env::temp_dir().join(format!("nook-skills-{}", uuid::Uuid::new_v4()));
        let home = dir.join("home");
        let project = dir.join("project");
        std::fs::create_dir_all(project.join(".claude/skills/deploy")).unwrap();
        std::fs::create_dir_all(home.join(".claude/skills/deploy")).unwrap();
        std::fs::create_dir_all(home.join(".agents/skills")).unwrap();
        std::fs::write(project.join(".claude/skills/deploy/SKILL.md"), "---\nname: deploy\ndescription: Project deploy\n---\n").unwrap();
        std::fs::write(home.join(".claude/skills/deploy/SKILL.md"), "---\nname: deploy\ndescription: User deploy\n---\n").unwrap();
        std::fs::write(home.join(".agents/skills/release-notes.md"), "---\ndescription: Writes notes to deploy\n---\n").unwrap();
        std::fs::write(home.join(".agents/skills/README.md"), "---\nname: readme\n---\n").unwrap();
        let roots = roots(RunProvider::Claude, &home, Some(&project));
        assert_eq!(roots[0], project.join(".claude/skills"));
        let skills = scan(&roots);
        assert_eq!(skills.len(), 2);
        assert_eq!(skills[0].description, "Project deploy");
        assert_eq!(skills[1].name, "release-notes");
        let hits = filter(&skills, "$dep", 8);
        assert_eq!(hits.iter().map(|s| s.name.as_str()).collect::<Vec<_>>(), vec!["deploy", "release-notes"]);
        std::fs::remove_dir_all(&dir).ok();
    }
}
