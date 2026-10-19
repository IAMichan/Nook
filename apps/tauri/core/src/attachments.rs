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
            Ok(Event::Text(t)) => out.push_str(&t.unescape().map(|c| c.to_string()).unwrap_or_default()),
            Ok(Event::Empty(e)) => match e.name().as_ref() {
                b"w:tab" | b"text:tab" => out.push('\t'),
                b"w:br" | b"text:line-break" => out.push('\n'),
                _ => {}
            },
            Ok(Event::End(e)) if e.name().as_ref() == paragraph.as_bytes() => out.push('\n'),
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
    let mut names: Vec<String> =
        archive.file_names().filter(|n| n.starts_with("ppt/slides/slide") && n.ends_with(".xml")).map(str::to_string).collect();
    names.sort_by_key(|n| n.trim_start_matches("ppt/slides/slide").trim_end_matches(".xml").parse::<u32>().unwrap_or(0));
    let mut out = vec![];
    for (index, name) in names.iter().enumerate() {
        let mut xml = String::new();
        if let Ok(mut file) = archive.by_name(name) {
            let _ = file.read_to_string(&mut xml);
        }
        out.push(format!("Dia {}:\n{}", index + 1, xml_text(&xml, "a:p").trim()));
    }
    Ok(out.join("\n\n"))
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
        let xml = r#"<w:document><w:body><w:p><w:r><w:t>Offerte</w:t></w:r><w:r><w:tab/><w:t>keuken &amp; bad</w:t></w:r></w:p><w:p><w:r><w:t>Totaal 8.450</w:t></w:r></w:p></w:body></w:document>"#;
        assert_eq!(read_text("offerte.docx", &docx(xml)).unwrap(), "Offerte\tkeuken & bad\nTotaal 8.450");
        assert!(read_text("foto.png", &[0x89, 0x50, 0x4e, 0x47, 0, 0, 0]).is_err());
        assert!(read_text("kapot.docx", b"geen zip").is_err());
        assert!(read_text("leeg.pdf", b"%PDF-1.4 kapot").is_err());
    }
}
