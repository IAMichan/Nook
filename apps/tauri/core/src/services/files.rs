//! Bestanden zoeken en lezen voor het brein: alleen in je eigen thuismap, nooit in verborgen mappen, sleutels of
//! wachtwoordexports (`FileText` en `FilesConnector` op de Mac). Het zoeken zelf gebruikt de index van het systeem
//! waar die er is (Windows Search, `locate`, Tracker); dit is de terugval en de regels eromheen.

use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::{Duration, Instant, SystemTime};

use regex::Regex;

use crate::{nook_err, Result};

/// Mappen in de thuismap die instellingen en sleutels bevatten, niet je documenten.
const PRIVATE_DIRS: [&str; 4] = ["Library", "AppData", "snap", "go"];

/// Alleen bestanden in je eigen thuismap, niet in verborgen mappen of in de mappen met app-gegevens.
pub fn is_allowed(path: &Path, home: &Path) -> bool {
    let Ok(home) = home.canonicalize() else { return false };
    let resolved = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
    let Ok(relative) = resolved.strip_prefix(&home) else { return false };
    let parts: Vec<String> = relative.components().map(|c| c.as_os_str().to_string_lossy().to_string()).collect();
    if parts.is_empty() || parts.iter().any(|p| p.starts_with('.')) {
        return false;
    }
    if PRIVATE_DIRS.iter().any(|d| parts[0].eq_ignore_ascii_case(d)) {
        return false;
    }
    !is_sensitive(&resolved)
}

/// Sleutels, certificaten, sleutelhangers en wachtwoordexports worden nooit gelezen, waar ze ook staan.
pub const SENSITIVE_EXTENSIONS: [&str; 23] = [
    "pem",
    "key",
    "p12",
    "pfx",
    "p8",
    "keychain",
    "keychain-db",
    "kdbx",
    "kdb",
    "1pux",
    "1pif",
    "agilekeychain",
    "opvault",
    "psafe3",
    "gpg",
    "asc",
    "ovpn",
    "mobileprovision",
    "cer",
    "der",
    "crt",
    "jks",
    "keystore",
];

pub fn is_sensitive(path: &Path) -> bool {
    let ext = extension(path);
    if SENSITIVE_EXTENSIONS.contains(&ext.as_str()) {
        return true;
    }
    let name = path.file_stem().map(|s| s.to_string_lossy().to_lowercase()).unwrap_or_default();
    let patterns = [
        "id_rsa",
        "id_ed25519",
        "id_ecdsa",
        "id_dsa",
        "credentials",
        "passwords",
        "wachtwoorden",
        "recovery-codes",
        "recovery codes",
        "seed phrase",
        "secret",
    ];
    patterns.iter().any(|p| name.contains(p)) && ["", "txt", "csv", "json", "md", "rtf"].contains(&ext.as_str())
}

/// Openen zou iets uitvoeren (programma's, scripts, installers) in plaats van het te tonen.
pub fn could_execute(path: &Path) -> bool {
    const RISKY: [&str; 34] = [
        "exe", "msi", "bat", "cmd", "com", "ps1", "vbs", "js", "jse", "wsf", "scr", "lnk", "url", "reg", "sh", "bash", "zsh", "run", "bin",
        "appimage", "deb", "rpm", "desktop", "jar", "py", "rb", "pl", "app", "command", "pkg", "dmg", "scpt", "workflow", "msix",
    ];
    if RISKY.contains(&extension(path).as_str()) {
        return true;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if let Ok(meta) = std::fs::metadata(path) {
            return meta.is_file() && meta.permissions().mode() & 0o111 != 0;
        }
    }
    false
}

fn extension(path: &Path) -> String {
    path.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default()
}

pub fn is_build_output(path: &str) -> bool {
    let path = path.replace('\\', "/");
    const PARTS: [&str; 16] = [
        "/node_modules/",
        "/dist/",
        "/build/",
        "/.build/",
        "/DerivedData/",
        "/Pods/",
        "/.git/",
        "/vendor/",
        "/.next/",
        "/.nuxt/",
        "/target/",
        "/coverage/",
        "/.cache/",
        "/__pycache__/",
        "/.venv/",
        "/venv/",
    ];
    PARTS.iter().any(|p| path.contains(p)) || path.ends_with(".map") || path.ends_with(".min.js")
}

/// Broncode, die bijna elk woord bevat maar zelden het antwoord is op een vraag over je eigen leven.
pub fn is_source_code(path: &str) -> bool {
    const CODE: [&str; 38] = [
        "swift", "js", "jsx", "ts", "tsx", "mjs", "cjs", "py", "go", "rs", "java", "kt", "c", "cc", "cpp", "h", "hpp", "m", "mm", "rb",
        "php", "cs", "css", "scss", "less", "vue", "svelte", "sh", "lock", "plist", "xcconfig", "pbxproj", "gradle", "toml", "ps1", "bat",
        "cmake", "mk",
    ];
    CODE.contains(&extension(Path::new(path)).as_str())
}

/// Treffers in de volgorde die het tonen waard is: eerst documenten, dan code; build-uitvoer valt weg.
pub fn rank_files(paths: &[String], code_first: bool) -> Vec<String> {
    let kept: Vec<&String> = paths.iter().filter(|p| !is_build_output(p)).collect();
    let (code, docs): (Vec<&String>, Vec<&String>) = kept.into_iter().partition(|p| is_source_code(p));
    let ordered = if code_first { code.into_iter().chain(docs) } else { docs.into_iter().chain(code) };
    ordered.cloned().collect()
}

/// Of de vraag over code gaat (dan code eerst).
pub fn is_code_query(query: &str) -> bool {
    static RX: OnceLock<Regex> = OnceLock::new();
    RX.get_or_init(|| {
        Regex::new(r"(?i)\b(code|func\w*|class|script|swift|python|javascript|typescript|rust|api|bug|repo)\b").expect("geldig")
    })
    .is_match(query)
}

/// De zoekwoorden van een vraag: kleine letters, hooguit zes, niet korter dan twee tekens.
pub fn words(query: &str) -> Vec<String> {
    query.to_lowercase().split_whitespace().filter(|w| w.chars().count() >= 2).take(6).map(String::from).collect()
}

/// `~/Documenten/x.txt` in plaats van het hele pad.
pub fn tilde(path: &Path, home: &Path) -> String {
    match path.strip_prefix(home) {
        Ok(rest) => format!("~{}{}", std::path::MAIN_SEPARATOR, rest.display()),
        Err(_) => path.display().to_string(),
    }
}

/// Een pad dat met `~` mag beginnen.
pub fn expand(raw: &str, home: &Path) -> PathBuf {
    let raw = raw.trim().trim_matches('"');
    if let Some(rest) = raw.strip_prefix("~/").or_else(|| raw.strip_prefix("~\\")) {
        home.join(rest)
    } else if raw == "~" {
        home.to_path_buf()
    } else {
        PathBuf::from(raw)
    }
}

const TEXT_EXTENSIONS: [&str; 30] = [
    "txt", "md", "markdown", "csv", "tsv", "json", "xml", "html", "htm", "log", "ini", "cfg", "conf", "yaml", "yml", "toml", "tex", "rst",
    "org", "srt", "vtt", "ics", "vcf", "eml", "rs", "py", "js", "ts", "swift", "sql",
];

/// De tekst van een document: platte tekst, Word (.docx) en OpenDocument (.odt). PDF leest de platformlaag
/// (`pdftotext` als dat er is).
pub fn read_text(path: &Path, limit: u64) -> Result<String> {
    let ext = extension(path);
    let text = match ext.as_str() {
        "docx" => zipped_xml(path, "word/document.xml", "w:p")?,
        "odt" => zipped_xml(path, "content.xml", "text:p")?,
        "html" | "htm" => {
            // Same limit as plain text: a saved mail archive can be huge, and the tags are stripped in memory.
            if std::fs::metadata(path)?.len() > limit {
                return Err(nook_err!("{} is te groot om te lezen.", name(path)));
            }
            strip_tags(&String::from_utf8_lossy(&std::fs::read(path)?))
        }
        _ => {
            let size = std::fs::metadata(path)?.len();
            if size > limit {
                return Err(nook_err!("{} is te groot om te lezen.", name(path)));
            }
            let bytes = std::fs::read(path)?;
            if !TEXT_EXTENSIONS.contains(&ext.as_str()) && bytes.iter().take(4096).any(|b| *b == 0) {
                return Err(nook_err!("Ik kan geen tekst lezen uit {}. Platte tekst, PDF, Word en OpenDocument werken.", name(path)));
            }
            String::from_utf8_lossy(&bytes).to_string()
        }
    };
    if text.trim().is_empty() {
        return Err(nook_err!("Ik kan geen tekst lezen uit {}. Platte tekst, PDF, Word en OpenDocument werken.", name(path)));
    }
    Ok(text)
}

fn name(path: &Path) -> String {
    path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default()
}

/// De tekst uit de XML in een zip (Word, OpenDocument): elke alinea een regel.
fn zipped_xml(path: &Path, entry: &str, paragraph: &str) -> Result<String> {
    let file = std::fs::File::open(path)?;
    let mut archive = zip::ZipArchive::new(file).map_err(|e| nook_err!("{} is geen geldig document: {e}", name(path)))?;
    let mut xml = String::new();
    archive.by_name(entry).map_err(|_| nook_err!("{} heeft geen tekst.", name(path)))?.take(50_000_000).read_to_string(&mut xml)?;
    let xml = xml.replace(&format!("</{paragraph}>"), "\n").replace("<w:tab/>", "\t").replace("<w:br/>", "\n");
    Ok(strip_tags(&xml))
}

/// Tags weg en de gewone entiteiten terug.
pub fn strip_tags(html: &str) -> String {
    static SCRIPT: OnceLock<Regex> = OnceLock::new();
    static TAG: OnceLock<Regex> = OnceLock::new();
    let text = SCRIPT.get_or_init(|| Regex::new(r"(?is)<(script|style)[^>]*>.*?</(script|style)>").expect("geldig")).replace_all(html, "");
    let text = TAG.get_or_init(|| Regex::new(r"<[^>]+>").expect("geldig")).replace_all(&text, "");
    text.replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&apos;", "'")
        .replace("&#39;", "'")
        .replace("&nbsp;", " ")
}

/// Grenzen van het zoeken zonder index.
#[derive(Debug, Clone, Copy)]
pub struct WalkLimits {
    pub max_depth: usize,
    pub max_entries: usize,
    pub max_hits: usize,
    pub time: Duration,
    /// Zo veel kleine tekstbestanden mogen op inhoud doorzocht worden.
    pub content_files: usize,
}

impl Default for WalkLimits {
    fn default() -> Self {
        Self { max_depth: 7, max_entries: 60_000, max_hits: 40, time: Duration::from_millis(2500), content_files: 600 }
    }
}

/// Zoeken in de thuismap zonder index: eerst op naam (alle woorden in de bestandsnaam), dan in kleine tekstbestanden.
pub fn walk_search(home: &Path, query: &str, limits: WalkLimits) -> Vec<PathBuf> {
    let wanted = words(query);
    if wanted.is_empty() {
        return vec![];
    }
    let started = Instant::now();
    let mut by_name: Vec<(usize, PathBuf)> = Vec::new();
    let mut by_content = Vec::new();
    let mut content_budget = limits.content_files;
    let mut seen = 0;
    let mut stack = vec![(home.to_path_buf(), 0usize)];
    while let Some((dir, depth)) = stack.pop() {
        if started.elapsed() > limits.time || seen > limits.max_entries {
            break;
        }
        let Ok(entries) = std::fs::read_dir(&dir) else { continue };
        for entry in entries.flatten() {
            seen += 1;
            let path = entry.path();
            let file_name = entry.file_name().to_string_lossy().to_lowercase();
            if file_name.starts_with('.') || (depth == 0 && PRIVATE_DIRS.iter().any(|d| d.eq_ignore_ascii_case(&file_name))) {
                continue;
            }
            let Ok(kind) = entry.file_type() else { continue };
            if kind.is_symlink() {
                continue;
            }
            if kind.is_dir() {
                if depth < limits.max_depth && !is_build_output(&format!("/{file_name}/")) {
                    stack.push((path, depth + 1));
                }
                continue;
            }
            if is_sensitive(&path) {
                continue;
            }
            let hits = wanted.iter().filter(|w| file_name.contains(w.as_str())).count();
            if hits == wanted.len() || (wanted.len() > 2 && hits * 3 >= wanted.len() * 2) {
                by_name.push((hits, path));
            } else if content_budget > 0
                && TEXT_EXTENSIONS.contains(&extension(&path).as_str())
                && !is_source_code(&path.to_string_lossy())
                && entry.metadata().map(|m| m.len() < 256 * 1024).unwrap_or(false)
            {
                content_budget -= 1;
                if let Ok(text) = std::fs::read_to_string(&path) {
                    let lower = text.to_lowercase();
                    if wanted.iter().all(|w| lower.contains(w.as_str())) {
                        by_content.push(path);
                    }
                }
            }
            if by_name.len() >= limits.max_hits {
                break;
            }
        }
    }
    by_name.sort_by_key(|b| std::cmp::Reverse(b.0));
    let mut out: Vec<PathBuf> = by_name.into_iter().map(|(_, p)| p).collect();
    out.extend(by_content);
    out.truncate(limits.max_hits);
    out
}

/// De nieuwste bestanden uit een lijst, op wijzigingsdatum.
pub fn newest(paths: Vec<PathBuf>, count: usize) -> Vec<PathBuf> {
    let mut dated: Vec<(SystemTime, PathBuf)> =
        paths.into_iter().filter_map(|p| std::fs::metadata(&p).ok().and_then(|m| m.modified().ok()).map(|t| (t, p))).collect();
    dated.sort_by_key(|b| std::cmp::Reverse(b.0));
    dated.into_iter().take(count).map(|(_, p)| p).collect()
}

/// Recent gebruikte bestanden uit `recently-used.xbel` (GTK op Linux), nieuwste eerst.
pub fn parse_xbel(xml: &str) -> Vec<PathBuf> {
    static RX: OnceLock<Regex> = OnceLock::new();
    let rx = RX.get_or_init(|| Regex::new(r#"<bookmark\s[^>]*href="file://([^"]+)"[^>]*?\smodified="([^"]+)""#).expect("geldig"));
    let mut found: Vec<(String, PathBuf)> = rx
        .captures_iter(xml)
        .map(|c| {
            let path = percent_encoding::percent_decode_str(&c[1]).decode_utf8_lossy().replace("&amp;", "&");
            (c[2].to_string(), PathBuf::from(path))
        })
        .collect();
    found.sort_by(|a, b| b.0.cmp(&a.0));
    found.into_iter().map(|(_, p)| p).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_home() -> PathBuf {
        let dir = std::env::temp_dir().join(format!("nook-home-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(dir.join("Documenten/Werk")).unwrap();
        std::fs::create_dir_all(dir.join(".ssh")).unwrap();
        std::fs::create_dir_all(dir.join("project/node_modules")).unwrap();
        std::fs::write(dir.join("Documenten/Werk/offerte lisa.txt"), "Offerte voor de verbouwing").unwrap();
        std::fs::write(dir.join("Documenten/notities.md"), "Bel Lisa over de offerte morgen").unwrap();
        std::fs::write(dir.join(".ssh/id_rsa"), "geheim").unwrap();
        std::fs::write(dir.join("Documenten/wachtwoorden.txt"), "geheim").unwrap();
        std::fs::write(dir.join("project/node_modules/offerte.js"), "x").unwrap();
        dir
    }

    #[test]
    fn only_your_own_documents() {
        let home = temp_home();
        assert!(is_allowed(&home.join("Documenten/notities.md"), &home));
        assert!(!is_allowed(&home.join(".ssh/id_rsa"), &home), "verborgen map");
        assert!(!is_allowed(&home.join("Documenten/wachtwoorden.txt"), &home), "wachtwoordexport");
        assert!(!is_allowed(Path::new("/etc/passwd"), &home), "buiten de thuismap");
        assert!(is_sensitive(Path::new("/x/kluis.kdbx")));
        assert!(could_execute(Path::new("setup.exe")));
        assert!(!could_execute(Path::new("brief.pdf")));
        let _ = std::fs::remove_dir_all(home);
    }

    #[test]
    fn searches_names_then_contents_without_build_output() {
        let home = temp_home();
        let found = walk_search(&home, "offerte", WalkLimits::default());
        let names: Vec<String> = found.iter().map(|p| p.file_name().unwrap().to_string_lossy().to_string()).collect();
        assert_eq!(names, vec!["offerte lisa.txt", "notities.md"], "naam eerst, dan inhoud, nooit node_modules");
        let _ = std::fs::remove_dir_all(home);
    }

    #[test]
    fn ranks_documents_before_code() {
        let ranked = rank_files(&["/h/a.rs".into(), "/h/brief.docx".into(), "/h/target/debug/x.txt".into()], false);
        assert_eq!(ranked, vec!["/h/brief.docx", "/h/a.rs"]);
        assert!(is_code_query("waar staat de functie voor login"));
        assert_eq!(words("Offerte  Lisa a"), vec!["offerte", "lisa"]);
    }

    #[test]
    fn reads_text_and_html() {
        let home = temp_home();
        let page = home.join("Documenten/pagina.html");
        std::fs::write(&page, "<html><style>x{}</style><p>Hallo &amp; welkom</p></html>").unwrap();
        assert_eq!(read_text(&page, 1_000_000).unwrap().trim(), "Hallo & welkom");
        assert!(read_text(&home.join("Documenten/notities.md"), 1_000_000).unwrap().contains("Lisa"));
        assert_eq!(expand("~/Documenten", &home), home.join("Documenten"));
        let _ = std::fs::remove_dir_all(home);
    }

    #[test]
    fn recent_files_from_xbel() {
        let xml = r#"<xbel><bookmark href="file:///home/a/Oud%20bestand.txt" added="x" modified="2026-01-01T10:00:00Z" visited="x"/>
<bookmark href="file:///home/a/nieuw.odt" added="x" modified="2026-10-01T10:00:00Z" visited="x"/></xbel>"#;
        assert_eq!(parse_xbel(xml), vec![PathBuf::from("/home/a/nieuw.odt"), PathBuf::from("/home/a/Oud bestand.txt")]);
    }
}
