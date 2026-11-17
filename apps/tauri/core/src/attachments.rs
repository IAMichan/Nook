//! Bijlagen in de chat: de tekst van een bestand dat je op de chat sleept (tekst, pdf, docx en andere documenten).
//! De tekst gaat als onbetrouwbare data mee, net als schermtekst.

use std::io::Read;

use crate::{NookError, Result};

/// Hoogstens zoveel bytes per bestand; een groter bestand is zelden wat je bedoelt.
pub const MAX_BYTES: usize = 25 * 1024 * 1024;

/// Bestanden die tekst zijn, aan hun naam herkend.
const TEXT_EXTENSIONS: [&str; 36] = [
    "txt", "md", "markdown", "csv", "tsv", "json", "xml", "yaml", "yml", "toml", "ini", "log", "html", "htm", "rtf", "tex", "org", "rst",
    "srt", "vtt", "ics", "vcf", "eml", "rs", "py", "js", "ts", "svelte", "swift", "java", "kt", "go", "c", "h", "sh", "sql",
];

fn extension(name: &str) -> String {
    name.rsplit('.').next().filter(|e| *e != name).unwrap_or("").to_lowercase()
}

/// De tekst van een bijlage. `name` is de bestandsnaam (voor het soort bestand).
pub fn read_text(name: &str, bytes: &[u8]) -> Result<String> {
    if bytes.len() > MAX_BYTES {
        return Err(NookError(format!("{name} is te groot (meer dan 25 MB).")));
    }
    let text = match extension(name).as_str() {
        "zip" => zip_text(name, bytes)?,
        "pdf" => pdf(bytes)?,
        "docx" => office_xml(bytes, "word/document.xml", "w:p")?,
        "odt" => office_xml(bytes, "content.xml", "text:p")?,
        "pptx" => slides(bytes)?,
        "html" | "htm" => crate::brain::web::readable(&String::from_utf8_lossy(bytes)),
        ext if TEXT_EXTENSIONS.contains(&ext) || looks_like_text(bytes) => String::from_utf8_lossy(bytes).to_string(),
        _ => return Err(NookError(format!("Nook kan {name} niet lezen. Tekst, pdf, docx, odt en pptx lukken wel."))),
    };
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Err(NookError(format!("Er staat geen leesbare tekst in {name}. Een gescande pdf heeft eerst tekstherkenning nodig.")));
    }
    Ok(trimmed.to_string())
}

/// Geen nulbytes en grotendeels geldige UTF-8: waarschijnlijk tekst.
fn looks_like_text(bytes: &[u8]) -> bool {
    let sample = &bytes[..bytes.len().min(4096)];
    !sample.contains(&0) && std::str::from_utf8(sample).is_ok()
}

fn pdf(bytes: &[u8]) -> Result<String> {
    // pdf-extract kan bij een vreemd bestand in paniek raken; dat mag Nook niet laten vallen.
    let owned = bytes.to_vec();
    std::panic::catch_unwind(move || pdf_extract::extract_text_from_mem(&owned))
        .map_err(|_| NookError::new("Deze pdf kon Nook niet lezen."))?
        .map_err(|e| NookError(format!("Deze pdf kon Nook niet lezen: {e}")))
}

fn entry(bytes: &[u8], path: &str) -> Result<String> {
    let mut archive = zip::ZipArchive::new(std::io::Cursor::new(bytes))
        .map_err(|_| NookError::new("Dit document is beschadigd of geen Office-bestand."))?;
    let file = archive.by_name(path).map_err(|_| NookError::new("Dit document heeft geen tekstgedeelte."))?;
    let mut xml = String::new();
    file.take(50 * 1024 * 1024).read_to_string(&mut xml)?;
    Ok(xml)
}

/// De tekst van een XML-document: één regel per alinea (`paragraph`), tabs en regeleinden waar ze staan.
fn xml_text(xml: &str, paragraph: &str) -> String {
    use quick_xml::events::Event;
    let mut reader = quick_xml::Reader::from_str(xml);
    let mut out = String::new();
    loop {
        match reader.read_event() {
            Ok(Event::Text(t)) => out.push_str(&t.xml10_content()),
            Ok(Event::GeneralRef(r)) => match r.resolve_char_ref() {
                Ok(Some(c)) => out.push(c),
                _ => out.push_str(match r.xml10_content().as_ref() {
                    "amp" => "&",
                    "lt" => "<",
                    "gt" => ">",
                    "quot" => "\"",
                    "apos" => "'",
                    _ => "",
                }),
            },
            Ok(Event::Empty(e)) => match e.name().as_ref() {
                "w:tab" | "text:tab" => out.push('\t'),
                "w:br" | "text:line-break" => out.push('\n'),
                _ => {}
            },
            Ok(Event::End(e)) if e.name().as_ref() == paragraph => out.push('\n'),
            Ok(Event::Eof) | Err(_) => break,
            _ => {}
        }
    }
    out
}

fn office_xml(bytes: &[u8], path: &str, paragraph: &str) -> Result<String> {
    Ok(xml_text(&entry(bytes, path)?, paragraph))
}

fn slides(bytes: &[u8]) -> Result<String> {
    let mut archive = zip::ZipArchive::new(std::io::Cursor::new(bytes)).map_err(|_| NookError::new("Deze presentatie is beschadigd."))?;
    let mut names: Vec<String> = archive
        .file_names()
        .flatten()
        .filter(|n| n.starts_with("ppt/slides/slide") && n.ends_with(".xml"))
        .map(|n| n.to_string())
        .collect();
    names.sort_by_key(|n| n.trim_start_matches("ppt/slides/slide").trim_end_matches(".xml").parse::<u32>().unwrap_or(0));
    let mut out = vec![];
    for (index, name) in names.iter().enumerate() {
        let mut xml = String::new();
        if let Ok(file) = archive.by_name(name) {
            let _ = file.take(50 * 1024 * 1024).read_to_string(&mut xml);
        }
        out.push(format!("Dia {}:\n{}", index + 1, xml_text(&xml, "a:p").trim()));
    }
    Ok(out.join("\n\n"))
}

// MARK: Zip archives, folders and paths (the Mac's `ZipText` and `FileText`)

/// The most a zip archive may hold unpacked: more is refused before anything is read (a zip bomb stays packed).
pub const ZIP_MAX_UNPACKED: u64 = 500_000_000;
/// The files of an archive or folder listed by name.
pub const LIST_LIMIT: usize = 500;
/// One file inside an archive is read only when it is smaller than this.
pub const ZIP_FILE_LIMIT: u64 = 2_000_000;
/// Characters of text an archive gives at most.
pub const ZIP_TEXT_LIMIT: usize = 400_000;

fn hidden_part(path: &str) -> bool {
    path.split(['/', '\\']).any(|p| p.starts_with('.') || p == "__MACOSX")
}

/// A zip archive as text: the files it holds, then what the readable ones say, read in memory. Nothing is written
/// to disk, so no path inside the archive can land anywhere.
pub fn zip_text(name: &str, bytes: &[u8]) -> Result<String> {
    use crate::i18n::trf;
    let unreadable = || {
        NookError(trf(
            "{name} is geen zip-bestand dat Nook kan openen, of het is beschadigd.",
            "{name} is not a zip file Nook can open, or it is damaged.",
            &[("name", &name)],
        ))
    };
    let mut archive = zip::ZipArchive::new(std::io::Cursor::new(bytes)).map_err(|_| unreadable())?;
    let mut files: Vec<(String, usize, u64)> = vec![];
    let mut unpacked: u64 = 0;
    for index in 0..archive.len() {
        let Ok(entry) = archive.by_index_raw(index) else { return Err(unreadable()) };
        unpacked = unpacked.saturating_add(entry.size());
        if entry.is_dir() || entry.is_symlink() {
            continue;
        }
        let Ok(path) = entry.name().map(|n| n.to_string()) else { continue };
        if hidden_part(&path) {
            continue;
        }
        files.push((path, index, entry.size()));
    }
    if unpacked > ZIP_MAX_UNPACKED {
        return Err(NookError(trf(
            "{name} is uitgepakt groter dan 500 MB. Pak het zelf uit en voeg de bestanden toe die je nodig hebt.",
            "{name} is larger than 500 MB unpacked. Unpack it yourself and attach the files you need.",
            &[("name", &name)],
        )));
    }
    if files.is_empty() {
        return Err(NookError(trf("Nook vond geen bestanden in {name}.", "Nook found no files in {name}.", &[("name", &name)])));
    }
    files.sort_by_key(|f| f.0.to_lowercase());
    let mut listed: Vec<&str> = files.iter().take(LIST_LIMIT).map(|f| f.0.as_str()).collect();
    if files.len() > LIST_LIMIT {
        listed.push("…");
    }
    let count = files.len();
    let mut text = format!("Zip archive {name}, {count} file{}:\n{}", if count == 1 { "" } else { "s" }, listed.join("\n"));
    let mut budget = ZIP_TEXT_LIMIT.saturating_sub(text.chars().count());
    let mut skipped = 0;
    for (path, index, size) in &files {
        if budget == 0 {
            skipped += 1;
            continue;
        }
        if *size >= ZIP_FILE_LIMIT || extension(path) == "zip" {
            continue;
        }
        let mut content = Vec::new();
        let Ok(entry) = archive.by_index(*index) else { continue };
        if entry.take(ZIP_FILE_LIMIT).read_to_end(&mut content).is_err() {
            continue;
        }
        let Ok(inner) = read_text(path, &content) else { continue };
        let part = format!("\n\n--- {path} ---\n{inner}");
        let taken: String = if part.chars().count() > budget { part.chars().take(budget).collect::<String>() + "\n…" } else { part };
        budget = budget.saturating_sub(taken.chars().count());
        text += &taken;
    }
    if skipped > 0 {
        text += &format!("\n\n({skipped} more file{} not read: the archive is too long.)", if skipped == 1 { "" } else { "s" });
    }
    Ok(text)
}

/// Folders a listing skips: build output and dependencies say nothing about the work itself.
const SKIPPED_FOLDERS: [&str; 9] = ["node_modules", "target", "build", "dist", ".build", "DerivedData", "Pods", "vendor", "__pycache__"];

/// A folder as text: where it is and the files in it (not what they say), without hidden folders and build output.
pub fn folder_text(path: &std::path::Path) -> Result<String> {
    let mut files: Vec<String> = vec![];
    let mut stack = vec![path.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else { continue };
        let mut entries: Vec<_> = entries.flatten().collect();
        entries.sort_by_key(|e| e.file_name());
        for entry in entries {
            let name = entry.file_name().to_string_lossy().to_string();
            if name.starts_with('.') {
                continue;
            }
            let Ok(kind) = entry.file_type() else { continue };
            if kind.is_symlink() {
                continue;
            }
            if kind.is_dir() {
                if !SKIPPED_FOLDERS.contains(&name.as_str()) {
                    stack.push(entry.path());
                }
            } else if let Ok(relative) = entry.path().strip_prefix(path) {
                files.push(relative.to_string_lossy().replace('\\', "/"));
            }
            if files.len() > LIST_LIMIT {
                break;
            }
        }
        if files.len() > LIST_LIMIT {
            break;
        }
    }
    let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    if files.is_empty() {
        return Err(NookError(crate::i18n::trf(
            "Nook vond geen bestanden in {name}.",
            "Nook found no files in {name}.",
            &[("name", &name)],
        )));
    }
    files.sort_by_key(|f| f.to_lowercase());
    let more = if files.len() > LIST_LIMIT { "\n…" } else { "" };
    files.truncate(LIST_LIMIT);
    Ok(format!("Folder {}\n\n{}{more}", path.display(), files.join("\n")))
}

/// Keys, certificates, keychains and password exports are never read, wherever they are.
const SENSITIVE_EXTENSIONS: [&str; 22] = [
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
    "cer",
    "der",
    "crt",
    "jks",
    "keystore",
];

pub fn is_sensitive(path: &std::path::Path) -> bool {
    let ext = path.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
    if SENSITIVE_EXTENSIONS.contains(&ext.as_str()) {
        return true;
    }
    let stem = path.file_stem().map(|s| s.to_string_lossy().to_lowercase()).unwrap_or_default();
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
    patterns.iter().any(|p| stem.contains(p)) && ["", "txt", "csv", "json", "md", "rtf"].contains(&ext.as_str())
}

/// Only files in the user's own home folder, not in hidden folders or the app-data folders (keys, passwords,
/// settings: `Library` on a Mac, `AppData` on Windows), and never a key or password file.
pub fn is_allowed(path: &std::path::Path, home: &std::path::Path) -> bool {
    let (Ok(path), Ok(home)) = (path.canonicalize(), home.canonicalize()) else { return false };
    let Ok(relative) = path.strip_prefix(&home) else { return false };
    let parts: Vec<String> = relative.components().map(|c| c.as_os_str().to_string_lossy().to_string()).collect();
    if parts.is_empty() || parts.iter().any(|p| p.starts_with('.')) {
        return false;
    }
    if ["Library", "AppData"].contains(&parts[0].as_str()) {
        return false;
    }
    !is_sensitive(&path)
}

/// What a dropped or pasted path holds: the text of a file (a zip archive too), or a folder's files. Pictures are the
/// caller's: they go along as pictures.
pub fn read_path(path: &std::path::Path, home: &std::path::Path) -> Result<(String, String)> {
    let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| path.display().to_string());
    if !is_allowed(path, home) {
        return Err(NookError::new(crate::i18n::tr(
            "Nook leest alleen bestanden in je eigen map (niet in verborgen mappen of app-gegevens).",
            "Nook only reads files in your home folder (not in hidden folders or app data).",
        )));
    }
    if path.is_dir() {
        return Ok((name, folder_text(path)?));
    }
    let size = std::fs::metadata(path)?.len();
    if size as usize > MAX_BYTES {
        return Err(NookError(crate::i18n::trf(
            "{name} is te groot (meer dan 25 MB).",
            "{name} is too large (more than 25 MB).",
            &[("name", &name)],
        )));
    }
    let bytes = std::fs::read(path)?;
    Ok((name.clone(), read_text(&name, &bytes)?))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn docx(document: &str) -> Vec<u8> {
        let mut buffer = std::io::Cursor::new(Vec::new());
        {
            let mut zip = zip::ZipWriter::new(&mut buffer);
            zip.start_file::<_, ()>("word/document.xml", zip::write::FileOptions::default()).unwrap();
            zip.write_all(document.as_bytes()).unwrap();
            zip.finish().unwrap();
        }
        buffer.into_inner()
    }

    #[test]
    fn reads_text_and_docx() {
        assert_eq!(read_text("notities.md", "# Hoi\nTekst".as_bytes()).unwrap(), "# Hoi\nTekst");
        let xml = r#"<w:document><w:body><w:p><w:r><w:t>Offerte</w:t></w:r><w:r><w:tab/><w:t>keuken &amp; bad</w:t></w:r></w:p><w:p><w:r><w:t>Totaal 8.450 &#8364; &lt;incl.&gt;</w:t></w:r></w:p></w:body></w:document>"#;
        assert_eq!(read_text("offerte.docx", &docx(xml)).unwrap(), "Offerte\tkeuken & bad\nTotaal 8.450 € <incl.>");
        assert!(read_text("foto.png", &[0x89, 0x50, 0x4e, 0x47, 0, 0, 0]).is_err());
        assert!(read_text("kapot.docx", b"geen zip").is_err());
        assert!(read_text("leeg.pdf", b"%PDF-1.4 kapot").is_err());
    }

    fn zip_of(files: &[(&str, &[u8])]) -> Vec<u8> {
        let mut buffer = std::io::Cursor::new(Vec::new());
        {
            let mut zip = zip::ZipWriter::new(&mut buffer);
            for (name, bytes) in files {
                zip.start_file::<_, ()>(*name, zip::write::FileOptions::default()).unwrap();
                zip.write_all(bytes).unwrap();
            }
            zip.finish().unwrap();
        }
        buffer.into_inner()
    }

    #[test]
    fn a_zip_lists_its_files_and_reads_the_readable_ones() {
        let bytes = zip_of(&[
            ("notes/b.md", b"# Plan\nShip it"),
            ("a.txt", b"Hello"),
            ("__MACOSX/._a.txt", b"junk"),
            (".hidden", b"secret"),
            ("photo.bin", &[0u8, 1, 2, 0]),
        ]);
        let text = read_text("project.zip", &bytes).unwrap();
        assert!(text.starts_with("Zip archive project.zip, 3 files:\na.txt\nnotes/b.md\nphoto.bin"));
        assert!(text.contains("--- a.txt ---\nHello") && text.contains("--- notes/b.md ---\n# Plan"));
        assert!(!text.contains("junk") && !text.contains("secret"));
        assert!(read_text("broken.zip", b"not a zip").is_err());
        assert!(read_text("empty.zip", &zip_of(&[])).is_err());
    }

    #[test]
    fn a_folder_lists_its_files_without_hidden_ones_and_build_output() {
        let home = std::env::temp_dir().join(format!("nook-home-{}", uuid::Uuid::new_v4()));
        let folder = home.join("Project");
        std::fs::create_dir_all(folder.join("src")).unwrap();
        std::fs::create_dir_all(folder.join("node_modules/x")).unwrap();
        std::fs::create_dir_all(folder.join(".git")).unwrap();
        std::fs::write(folder.join("src/main.rs"), "fn main() {}").unwrap();
        std::fs::write(folder.join("README.md"), "hi").unwrap();
        std::fs::write(folder.join("node_modules/x/index.js"), "").unwrap();
        std::fs::write(folder.join(".git/config"), "").unwrap();
        let (name, text) = read_path(&folder, &home).unwrap();
        assert_eq!(name, "Project");
        assert!(text.contains("README.md") && text.contains("src/main.rs"));
        assert!(!text.contains("node_modules") && !text.contains(".git"));
        let (_, readme) = read_path(&folder.join("README.md"), &home).unwrap();
        assert_eq!(readme, "hi");
        // Outside the home folder, hidden folders, app data and key files are never read.
        std::fs::create_dir_all(home.join(".ssh")).unwrap();
        std::fs::write(home.join(".ssh/id_ed25519"), "key").unwrap();
        assert!(read_path(&home.join(".ssh/id_ed25519"), &home).is_err());
        std::fs::create_dir_all(home.join("AppData")).unwrap();
        std::fs::write(home.join("AppData/x.txt"), "x").unwrap();
        assert!(read_path(&home.join("AppData/x.txt"), &home).is_err());
        std::fs::write(home.join("server.pem"), "k").unwrap();
        assert!(read_path(&home.join("server.pem"), &home).is_err());
        assert!(read_path(&folder, &folder.join("src")).is_err(), "outside the home folder");
        let _ = std::fs::remove_dir_all(home);
    }
}
