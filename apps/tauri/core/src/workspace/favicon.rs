//! Finds a project's own icon in its folder (`ProjectFavicon` on the Mac): a favicon or app icon at a well-known place,
//! else the icon an `index.html` (or a root route) links, else one in a web app of a monorepo (`apps/*/public`,
//! `apps/*/web/public`), else one in a site folder of its own, else an app's `AppIcon` picture. The session list shows
//! it as the project's badge; without one the badge is the project's initials. Reads a few files, never more than a
//! bounded walk.

use std::collections::VecDeque;
use std::io::Read;
use std::path::{Path, PathBuf};

/// The places looked at first, in order.
pub const CANDIDATES: &[&str] = &[
    "favicon.svg",
    "favicon.ico",
    "favicon.png",
    "public/favicon.svg",
    "public/favicon.ico",
    "public/favicon.png",
    "app/favicon.ico",
    "app/favicon.png",
    "app/icon.svg",
    "app/icon.png",
    "app/icon.ico",
    "src/favicon.ico",
    "src/favicon.svg",
    "src/app/favicon.ico",
    "src/app/icon.svg",
    "src/app/icon.png",
    // Phoenix (`priv/static`) and SvelteKit or Hugo (`static`) serve their public files from here.
    "priv/static/favicon.svg",
    "priv/static/favicon.ico",
    "priv/static/favicon.png",
    "static/favicon.svg",
    "static/favicon.ico",
    "static/favicon.png",
    "assets/icon.svg",
    "assets/icon.png",
    "assets/logo.svg",
    "assets/logo.png",
    ".idea/icon.svg",
];

/// Files that may link the icon (`<link rel="icon" href="…">`, or `rel: "icon", href: "…"` in a route).
const SOURCES: &[&str] =
    &["index.html", "public/index.html", "app/routes/__root.tsx", "src/routes/__root.tsx", "app/root.tsx", "src/root.tsx", "src/index.html"];
/// Folders of a monorepo whose packages may hold the web app with the favicon.
const WORKSPACES: &[&str] = &["apps", "packages", "web", "site", "website"];
/// Folders inside a monorepo package that hold its web app.
const WEB_FOLDERS: &[&str] = &["web", "app", "site", "frontend", "client", "www"];
/// Folders never walked into while looking for an `AppIcon`.
const SKIPPED: &[&str] =
    &["node_modules", ".git", ".build", "build", "dist", "DerivedData", "Pods", ".next", "vendor", "Vendor", "target", ".scratch"];

/// The repository's name, lowercased: the folder's own name, and for a worktree (`…/worktrees/<repo>/<branch>`) also
/// the repository's folder above it.
fn repository_names(base: &Path) -> Vec<String> {
    let parts: Vec<String> = base.components().map(|c| c.as_os_str().to_string_lossy().into_owned()).collect();
    let mut names = vec![parts.last().cloned().unwrap_or_default().to_lowercase()];
    if parts.len() >= 3 && parts[parts.len() - 3] == "worktrees" {
        names.push(parts[parts.len() - 2].to_lowercase());
    }
    names
}

/// Whether a package is named after the repository (`infaris` in `infaris-monorepo`); short names never match.
fn matches(package: &str, names: &[String]) -> bool {
    let package = package.to_lowercase();
    package.chars().count() >= 3 && names.iter().any(|n| n.contains(&package))
}

fn sorted_children(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(dir)
        .map(|e| e.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).filter(|n| !n.starts_with('.')).collect())
        .unwrap_or_default();
    names.sort();
    names
}

/// The icon file of the project at `root`, or `None`.
pub fn find(root: &str) -> Option<PathBuf> {
    let base = Path::new(root);
    let existing = |relative: &str| -> Option<PathBuf> {
        let path = base.join(relative);
        path.is_file().then_some(path)
    };
    if let Some(hit) = CANDIDATES.iter().find_map(|c| existing(c)) {
        return Some(hit);
    }
    for source in SOURCES {
        let Some(text) = read_head(&base.join(source)) else { continue };
        let Some(href) = icon_href(&text) else { continue };
        let clean = href.trim_start_matches('/');
        if let Some(hit) = [format!("public/{clean}"), clean.to_string()].iter().find_map(|c| existing(c)) {
            return Some(hit);
        }
    }
    // A monorepo: the package named after the repository first, then the others by name; in each, the package itself
    // or its web app (`apps/infaris/web/public/favicon.ico`).
    let names = repository_names(base);
    for folder in WORKSPACES {
        let mut packages = sorted_children(&base.join(folder));
        packages.sort_by_key(|p| !matches(p, &names));
        for package in packages {
            for sub in std::iter::once(String::new()).chain(WEB_FOLDERS.iter().map(|w| format!("{w}/"))) {
                let prefix = format!("{folder}/{package}/{sub}");
                if let Some(hit) = CANDIDATES.iter().find_map(|c| existing(&format!("{prefix}{c}"))) {
                    return Some(hit);
                }
            }
        }
    }
    // A repository of several sites side by side (`bettr-finance/favicon.svg`): its own folders, the same way.
    let mut folders: Vec<String> =
        sorted_children(base).into_iter().filter(|f| !SKIPPED.contains(&f.as_str()) && !WORKSPACES.contains(&f.as_str())).collect();
    folders.sort_by_key(|f| !matches(f, &names));
    for folder in folders {
        if let Some(hit) = CANDIDATES.iter().find_map(|c| existing(&format!("{folder}/{c}"))) {
            return Some(hit);
        }
    }
    app_icon(base, 4, 400)
}

/// The `href` of the first icon link in an HTML page or a route file; only a file in the project.
pub fn icon_href(text: &str) -> Option<String> {
    let patterns = [
        r#"(?i)<link\b(?=[^>]*\brel=["'](?:icon|shortcut icon)["'])[^>]*\bhref=["']([^"'?]+)"#,
        r#"(?i)<link\b[^>]*\bhref=["']([^"'?]+)["'][^>]*\brel=["'](?:icon|shortcut icon)["']"#,
        r#"(?i)\brel\s*:\s*["'](?:icon|shortcut icon)["'][^{}]*?\bhref\s*:\s*["']([^"'?]+)"#,
    ];
    for pattern in patterns {
        let Ok(re) = fancy_regex::Regex::new(pattern) else { continue };
        let Ok(Some(caps)) = re.captures(text) else { continue };
        let Some(href) = caps.get(1).map(|m| m.as_str()) else { continue };
        if href.contains("://") || href.starts_with("data:") || href.starts_with("//") {
            continue;
        }
        return Some(href.to_string());
    }
    None
}

/// An app's icon within `max_depth` levels, nearest first: the biggest picture of up to 2 MB in an `AppIcon.appiconset`.
/// (`AppIcon.icns`, a Mac app's, is no picture a window here can draw.)
fn app_icon(base: &Path, max_depth: usize, budget: usize) -> Option<PathBuf> {
    let mut queue = VecDeque::from([(base.to_path_buf(), 0usize)]);
    let mut visited = 0;
    while let Some((folder, depth)) = queue.pop_front() {
        if visited >= budget {
            break;
        }
        visited += 1;
        let mut entries: Vec<PathBuf> = std::fs::read_dir(&folder).map(|e| e.flatten().map(|e| e.path()).collect()).unwrap_or_default();
        entries.sort();
        for path in entries {
            let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
            if name == "AppIcon.appiconset" || name == "AppIcon.icon" {
                let best = std::fs::read_dir(&path)
                    .map(|e| e.flatten().map(|e| e.path()).collect::<Vec<_>>())
                    .unwrap_or_default()
                    .into_iter()
                    .filter(|p| p.extension().is_some_and(|x| x.eq_ignore_ascii_case("png")))
                    .filter_map(|p| std::fs::metadata(&p).ok().map(|m| (p, m.len())))
                    .filter(|(_, size)| *size <= 2 * 1024 * 1024)
                    .max_by_key(|(_, size)| *size);
                if let Some((p, _)) = best {
                    return Some(p);
                }
                continue;
            }
            if depth < max_depth && !name.starts_with('.') && !SKIPPED.contains(&name.as_str()) && path.is_dir() {
                queue.push_back((path, depth + 1));
            }
        }
    }
    None
}

/// The head of a page holds its links; a big file is not read whole.
fn read_head(path: &Path) -> Option<String> {
    let mut buffer = vec![0u8; 64 * 1024];
    let n = std::fs::File::open(path).ok()?.read(&mut buffer).ok()?;
    buffer.truncate(n);
    Some(String::from_utf8_lossy(&buffer).into_owned())
}

/// The icon as a `data:` address the window can draw (no file access from the page), when it is a picture of at most
/// 512 KB.
pub fn data_url(path: &Path) -> Option<String> {
    use base64::Engine;
    let mime = match path.extension()?.to_string_lossy().to_lowercase().as_str() {
        "svg" => "image/svg+xml",
        "png" => "image/png",
        "ico" => "image/x-icon",
        _ => return None,
    };
    let bytes = std::fs::read(path).ok().filter(|b| b.len() <= 512 * 1024)?;
    Some(format!("data:{mime};base64,{}", base64::engine::general_purpose::STANDARD.encode(bytes)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn project(files: &[&str]) -> PathBuf {
        let root = std::env::temp_dir().join(format!("nook-favicon-{}", uuid::Uuid::new_v4())).join("infaris-monorepo");
        for f in files {
            let p = root.join(f);
            std::fs::create_dir_all(p.parent().unwrap()).unwrap();
            std::fs::write(&p, "x").unwrap();
        }
        std::fs::create_dir_all(&root).unwrap();
        root
    }

    #[test]
    fn looks_in_the_known_places_then_the_monorepo() {
        let r = project(&["static/favicon.png", "public/favicon.svg"]);
        assert!(find(&r.to_string_lossy()).unwrap().ends_with("public/favicon.svg"));
        let r = project(&["apps/admin/public/favicon.ico", "apps/infaris/web/public/favicon.ico"]);
        assert!(find(&r.to_string_lossy()).unwrap().ends_with("apps/infaris/web/public/favicon.ico"), "the package named after the repo");
        let r = project(&["README.md"]);
        assert_eq!(find(&r.to_string_lossy()), None);
    }

    #[test]
    fn reads_the_icon_link() {
        assert_eq!(icon_href(r#"<link rel="icon" href="/img/i.png">"#).as_deref(), Some("/img/i.png"));
        assert_eq!(icon_href(r#"<link href="fav.svg" rel="shortcut icon">"#).as_deref(), Some("fav.svg"));
        assert_eq!(icon_href(r#"{ rel: "icon", href: "/f.ico" }"#).as_deref(), Some("/f.ico"));
        assert_eq!(icon_href(r#"<link rel="icon" href="https://x.com/f.ico">"#), None);
    }
}
