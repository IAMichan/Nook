//! Renders a pairing URL as a compact UTF-8 half-block QR code for terminal pairing.

use qrcode::{Color, QrCode};

/// Encodes `payload` into a scannable terminal QR code using Unicode half-blocks (`▀`, `▄`, `█`, ` `).
pub fn render_terminal_qr(payload: &str) -> Result<String, String> {
    let code = QrCode::new(payload.as_bytes()).map_err(|e| e.to_string())?;
    let width = code.width();
    let colors = code.to_colors();
    let dark = |x: isize, y: isize| -> bool {
        if x < 0 || y < 0 || x >= width as isize || y >= width as isize {
            false
        } else {
            colors[y as usize * width + x as usize] == Color::Dark
        }
    };
    let quiet = 2isize;
    let total = width as isize + quiet * 2;
    let mut out = String::new();
    let mut y = -quiet;
    while y < width as isize + quiet {
        for x in -quiet..width as isize + quiet {
            let top = dark(x, y);
            let bottom = if y + 1 < width as isize + quiet { dark(x, y + 1) } else { false };
            // On dark terminals invert modules so quiet zone is white (full blocks) and modules are dark spaces.
            let ch = match (top, bottom) {
                (false, false) => '█',
                (true, false) => '▄',
                (false, true) => '▀',
                (true, true) => ' ',
            };
            out.push(ch);
        }
        out.push('\n');
        y += 2;
    }
    let _ = total;
    Ok(out)
}
