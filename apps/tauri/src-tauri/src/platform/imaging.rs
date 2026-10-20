//! Plaatjes van het scherm: naar PNG, een vingerafdruk, en tekst eruit met tesseract als dat geïnstalleerd is.

use nook_core::services::screen::fingerprint;

/// RGBA → PNG.
pub fn png(rgba: &[u8], width: u32, height: u32) -> Result<Vec<u8>, String> {
    let image = image::RgbaImage::from_raw(width, height, rgba.to_vec()).ok_or("Ongeldige schermafbeelding.")?;
    let mut out = std::io::Cursor::new(Vec::new());
    image.write_to(&mut out, image::ImageFormat::Png).map_err(|e| e.to_string())?;
    Ok(out.into_inner())
}

/// De vingerafdruk van een RGBA-plaatje (zie `screen::fingerprint`).
pub fn rgba_fingerprint(rgba: &[u8], width: u32, height: u32) -> u64 {
    let gray: Vec<u8> =
        rgba.as_chunks::<4>().0.iter().map(|&[r, g, b, _]| ((r as u32 * 30 + g as u32 * 59 + b as u32 * 11) / 100) as u8).collect();
    fingerprint(&gray, width as usize, height as usize)
}

/// Of er een lokale OCR is (tesseract), en in welke talen. (Windows heeft zijn eigen OCR.)
#[cfg(not(target_os = "windows"))]
pub fn tesseract_languages() -> Option<String> {
    if !super::process::which("tesseract") {
        return None;
    }
    let listed = super::process::run_text("tesseract", &["--list-langs"], std::time::Duration::from_secs(5)).unwrap_or_default();
    let have: Vec<&str> = listed.lines().map(str::trim).collect();
    let wanted: Vec<&str> = ["nld", "eng", "deu", "fra", "spa"].into_iter().filter(|l| have.contains(l)).collect();
    Some(if wanted.is_empty() { "eng".into() } else { wanted.join("+") })
}

/// Tekst uit een PNG met tesseract, op deze computer.
#[cfg(not(target_os = "windows"))]
pub fn ocr(png: &[u8], languages: &str) -> Result<String, String> {
    let out = super::process::run(
        "tesseract",
        &["stdin", "stdout", "-l", languages, "--psm", "3"],
        Some(png),
        std::time::Duration::from_secs(20),
    )?;
    Ok(String::from_utf8_lossy(&out).lines().map(str::trim_end).filter(|l| !l.trim().is_empty()).collect::<Vec<_>>().join("\n"))
}
