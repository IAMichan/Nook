//! Geïnstalleerde apps op Linux: de `.desktop`-bestanden van XDG (ook Flatpak en Snap), en ze starten zonder shell.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

#[derive(Debug, Clone, PartialEq)]
pub struct DesktopEntry {
    pub id: String,
    pub name: String,
    /// De naam in de taal van de gebruiker (`Name[nl]`), als die er is.
    pub local_name: Option<String>,
    pub generic: Option<String>,
    pub exec: String,
    pub path: PathBuf,
    pub wm_class: Option<String>,
}

fn dirs() -> Vec<PathBuf> {
    let home = dirs::home_dir().unwrap_or_default();
    let mut out =
        vec![std::env::var_os("XDG_DATA_HOME").map(PathBuf::from).unwrap_or_else(|| home.join(".local/share")).join("applications")];
    let data = std::env::var("XDG_DATA_DIRS").unwrap_or_else(|_| "/usr/local/share:/usr/share".into());
    out.extend(data.split(':').filter(|d| !d.is_empty()).map(|d| Path::new(d).join("applications")));
    out.push(PathBuf::from("/var/lib/flatpak/exports/share/applications"));
    out.push(home.join(".local/share/flatpak/exports/share/applications"));
    out.push(PathBuf::from("/var/lib/snapd/desktop/applications"));
    out
}

/// De taalcode van de gebruiker ("nl" uit `LANG=nl_NL.UTF-8`).
fn language() -> String {
    std::env::var("LC_MESSAGES").or_else(|_| std::env::var("LANG")).unwrap_or_default().chars().take(2).collect()
}

/// Leest één `.desktop`-bestand. `None` voor wat geen zichtbare app is.
pub fn parse(id: &str, path: &Path, text: &str, language: &str) -> Option<DesktopEntry> {
    let mut in_entry = false;
    let mut fields = BTreeMap::new();
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_entry = line == "[Desktop Entry]";
            continue;
        }
        if !in_entry || line.starts_with('#') {
            continue;
        }
        if let Some((key, value)) = line.split_once('=') {
            fields.entry(key.trim().to_string()).or_insert_with(|| value.trim().to_string());
        }
    }
    let yes = |key: &str| fields.get(key).is_some_and(|v| v == "true");
    if fields.get("Type").map(String::as_str) != Some("Application") || yes("NoDisplay") || yes("Hidden") {
        return None;
    }
    let exec = fields.get("Exec")?.clone();
    Some(DesktopEntry {
        id: id.into(),
        name: fields.get("Name")?.clone(),
        local_name: fields.get(&format!("Name[{language}]")).cloned(),
        generic: fields.get(&format!("GenericName[{language}]")).or(fields.get("GenericName")).cloned(),
        exec,
        path: path.to_path_buf(),
        wm_class: fields.get("StartupWMClass").cloned(),
    })
}

pub fn installed() -> Vec<DesktopEntry> {
    let language = language();
    let mut seen = std::collections::BTreeSet::new();
    let mut out = Vec::new();
    for dir in dirs() {
        let Ok(entries) = std::fs::read_dir(&dir) else { continue };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("desktop") {
                continue;
            }
            let id = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
            // Eerdere mappen gaan voor (je eigen ~/.local wint van /usr).
            if !seen.insert(id.clone()) {
                continue;
            }
            if let Some(app) = std::fs::read_to_string(&path).ok().and_then(|t| parse(&id, &path, &t, &language)) {
                out.push(app);
            }
        }
    }
    out
}

/// WM_CLASS (kleine letters) → de naam die de gebruiker kent: via `StartupWMClass`, het bestand of het programma.
pub fn names_by_class() -> std::collections::HashMap<String, String> {
    let mut map = std::collections::HashMap::new();
    for app in installed() {
        let name = app.local_name.clone().unwrap_or_else(|| app.name.clone());
        let program = command_line(&app.exec).first().and_then(|p| Path::new(p).file_name().map(|f| f.to_string_lossy().to_lowercase()));
        let id = app.id.trim_end_matches(".desktop").to_lowercase();
        let last = id.rsplit('.').next().map(String::from);
        for key in [app.wm_class.map(|c| c.to_lowercase()), program, Some(id.clone()), last].into_iter().flatten() {
            map.entry(key).or_insert_with(|| name.clone());
        }
    }
    map
}

/// De opdracht uit `Exec`, als losse argumenten, zonder veldcodes (%f, %U…). Volgt de aanhalingsregels van de spec.
pub fn command_line(exec: &str) -> Vec<String> {
    let mut args = Vec::new();
    let mut current = String::new();
    let mut quoted = false;
    let mut has = false;
    let mut chars = exec.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '"' => {
                quoted = !quoted;
                has = true;
            }
            '\\' if quoted => {
                if let Some(next) = chars.next() {
                    current.push(next);
                }
            }
            ' ' | '\t' if !quoted => {
                if has || !current.is_empty() {
                    args.push(std::mem::take(&mut current));
                    has = false;
                }
            }
            '%' => {
                if chars.next() == Some('%') {
                    current.push('%');
                }
            }
            other => current.push(other),
        }
    }
    if has || !current.is_empty() {
        args.push(current);
    }
    args.into_iter().filter(|a| !a.is_empty()).collect()
}

/// Start de app los van Nook (zonder shell, zonder Nooks in- en uitvoer).
pub fn launch(app: &DesktopEntry) -> Result<(), String> {
    let args = command_line(&app.exec);
    let (program, rest) = args.split_first().ok_or_else(|| format!("{} heeft geen startopdracht.", app.name))?;
    Command::new(program)
        .args(rest)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map(|_| ())
        .map_err(|e| format!("{} kon niet starten: {e}", app.name))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_a_desktop_file() {
        let text = "[Desktop Entry]\nType=Application\nName=Calculator\nName[nl]=Rekenmachine\nExec=gnome-calculator %U\n\n[Desktop Action new]\nName=Nieuw\nExec=x";
        let app = parse("org.gnome.Calculator.desktop", Path::new("/x"), text, "nl").unwrap();
        assert_eq!(app.local_name.as_deref(), Some("Rekenmachine"));
        assert_eq!(command_line(&app.exec), vec!["gnome-calculator"]);
        assert!(parse("x.desktop", Path::new("/x"), "[Desktop Entry]\nType=Application\nName=X\nExec=x\nNoDisplay=true", "nl").is_none());
    }

    #[test]
    fn exec_quoting() {
        assert_eq!(command_line(r#""/opt/My App/app" --name "a \"b\"" %f 100%%"#), vec!["/opt/My App/app", "--name", "a \"b\"", "100%"]);
        assert_eq!(command_line("flatpak run org.mozilla.firefox @@u %u @@"), vec!["flatpak", "run", "org.mozilla.firefox", "@@u", "@@"]);
    }
}
