//! Kleine teksthulpjes voor agentsessies: korte paden, projectnamen en één zin uit een Markdown-antwoord.

use std::sync::OnceLock;

use regex::Regex;

/// De laatste map van een pad, of "geen map".
pub fn project_name(cwd: &str) -> String {
    let name = cwd.trim_end_matches(['/', '\\']).rsplit(['/', '\\']).next().unwrap_or("");
    if cwd.is_empty() || name.is_empty() {
        "geen map".into()
    } else {
        name.into()
    }
}

/// De laatste twee delen van een pad: `src/main.rs`.
pub fn short_path(path: &str) -> String {
    let parts: Vec<&str> = path.split(['/', '\\']).filter(|p| !p.is_empty()).collect();
    parts[parts.len().saturating_sub(2)..].join("/")
}

/// Eén regel, hooguit `limit` tekens, met "…" als er meer was.
pub fn shorten(text: &str, limit: usize) -> String {
    let single = text.replace('\n', " ");
    if single.chars().count() > limit {
        single.chars().take(limit).collect::<String>() + "…"
    } else {
        single
    }
}

/// Knipt een lange tekst af op `limit` tekens (getrimd).
pub fn clip(text: &str, limit: usize) -> String {
    let trimmed = text.trim();
    if trimmed.chars().count() > limit {
        trimmed.chars().take(limit.saturating_sub(1)).collect::<String>() + "…"
    } else {
        trimmed.into()
    }
}

/// De eerste regel van een tekst, afgekapt.
pub fn first_line(text: &str, limit: usize) -> String {
    let flat = text.lines().find(|l| !l.trim().is_empty()).unwrap_or("").trim();
    if flat.chars().count() > limit {
        flat.chars().take(limit.saturating_sub(1)).collect::<String>() + "…"
    } else {
        flat.into()
    }
}

/// De eerste bruikbare alinea van een Markdown-antwoord als gewone zin.
pub fn one_line(markdown: &str, limit: usize) -> String {
    static PREFIX: OnceLock<Regex> = OnceLock::new();
    static LINK: OnceLock<Regex> = OnceLock::new();
    let prefix = PREFIX.get_or_init(|| Regex::new(r"^(#{1,6}\s+|[-*+]\s+|\d+\.\s+|>\s*)").unwrap());
    let link = LINK.get_or_init(|| Regex::new(r"\[([^\]]+)\]\([^)]*\)").unwrap());
    if markdown.is_empty() {
        return String::new();
    }
    let mut in_code = false;
    let mut paragraph: Vec<String> = vec![];
    for raw in markdown.split('\n') {
        let line = raw.trim();
        if line.starts_with("```") {
            in_code = !in_code;
            continue;
        }
        if in_code {
            continue;
        }
        if line.is_empty() {
            if !paragraph.is_empty() {
                break;
            }
            continue;
        }
        let mut clean = prefix.replace(line, "").into_owned();
        if clean.contains("](") {
            clean = link.replace_all(&clean, "$1").into_owned();
        }
        clean = clean.replace("**", "").replace('`', "");
        if !clean.is_empty() {
            paragraph.push(clean);
        }
    }
    shorten(&paragraph.join(" "), limit)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn paths() {
        assert_eq!(project_name("/home/x/app"), "app");
        assert_eq!(project_name("C:\\Users\\x\\app\\"), "app");
        assert_eq!(project_name(""), "geen map");
        assert_eq!(short_path("/a/b/c.rs"), "b/c.rs");
    }

    #[test]
    fn one_line_skips_code_and_markup() {
        let md = "```\ncode\n```\n## Klaar\n- **Alles** werkt, zie [docs](https://x)\n\nTweede alinea";
        assert_eq!(one_line(md, 220), "Klaar Alles werkt, zie docs");
        assert_eq!(shorten("abcdef", 3), "abc…");
    }
}
