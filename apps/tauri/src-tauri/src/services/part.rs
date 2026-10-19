//! Een schermdeel (⌥⌘4 op de Mac, Alt+Ctrl+4 hier): Nook maakt een schermafbeelding, je trekt een kader, en dat
//! stuk gaat als afbeelding naar de chat (of op het klembord). De afbeelding blijft op deze computer tot je hem
//! verstuurt.

use base64::Engine as _;
use serde::Serialize;
use tauri::{AppHandle, Manager};

use super::Services;

pub struct Pending {
    pub png: Vec<u8>,
    pub width: u32,
    pub height: u32,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Attachment {
    pub media_type: String,
    pub base64: String,
}

/// Maakt de schermafbeelding en opent het kader.
pub fn begin(app: &AppHandle) {
    let app = app.clone();
    std::thread::spawn(move || {
        let services = app.state::<Services>();
        // De balk hoort niet in het plaatje.
        #[cfg(desktop)]
        if let Some(bar) = app.get_webview_window(crate::platform::desktop::BAR) {
            let _ = bar.hide();
            std::thread::sleep(std::time::Duration::from_millis(150));
        }
        let capture = services.platform.screen.capture_screen();
        #[cfg(desktop)]
        if let Some(bar) = app.get_webview_window(crate::platform::desktop::BAR) {
            let _ = bar.show();
        }
        match capture {
            Ok(capture) => {
                let (w, h) = (capture.width as f64, capture.height as f64);
                *services.part.lock().unwrap_or_else(|e| e.into_inner()) =
                    Some(Pending { png: capture.png, width: capture.width, height: capture.height });
                #[cfg(desktop)]
                if let Err(e) = super::windows::open_part(&app, w, h) {
                    log::warn!("Schermdeel: {e}");
                }
            }
            Err(e) => {
                services.platform.system.notify("Schermdeel", &e);
            }
        }
    });
}

/// De schermafbeelding voor het kader, als data-URL.
pub fn image(app: &AppHandle) -> Option<String> {
    let services = app.state::<Services>();
    let guard = services.part.lock().unwrap_or_else(|e| e.into_inner());
    guard.as_ref().map(|p| format!("data:image/png;base64,{}", base64::engine::general_purpose::STANDARD.encode(&p.png)))
}

/// Snijdt het kader uit. `x`, `y`, `w`, `h` zijn fracties (0…1) van het scherm. `copy`: op het klembord in plaats
/// van naar de chat.
pub fn finish(app: &AppHandle, x: f64, y: f64, w: f64, h: f64, copy: bool) -> Result<(), String> {
    let services = app.state::<Services>();
    let pending = services.part.lock().unwrap_or_else(|e| e.into_inner()).take().ok_or("Er is geen schermafbeelding meer.")?;
    #[cfg(desktop)]
    super::windows::close_part(app);
    let image = image::load_from_memory(&pending.png).map_err(|e| e.to_string())?;
    let clamp = |v: f64| v.clamp(0.0, 1.0);
    let (px, py) = ((clamp(x) * pending.width as f64) as u32, (clamp(y) * pending.height as f64) as u32);
    let pw = ((clamp(w) * pending.width as f64) as u32).min(pending.width - px).max(1);
    let ph = ((clamp(h) * pending.height as f64) as u32).min(pending.height - py).max(1);
    if pw < 4 || ph < 4 {
        return Err("Het kader is te klein.".into());
    }
    let crop = image.crop_imm(px, py, pw, ph);
    let mut png = std::io::Cursor::new(Vec::new());
    crop.write_to(&mut png, image::ImageFormat::Png).map_err(|e| e.to_string())?;
    let png = png.into_inner();
    if copy {
        return services.platform.system.copy_image(&png);
    }
    let attachment = Attachment { media_type: "image/png".into(), base64: base64::engine::general_purpose::STANDARD.encode(&png) };
    // Het invoerveld van de balk neemt hem (het hoofdvenster laat hem liggen).
    super::emit(app, "attach-image", attachment);
    #[cfg(desktop)]
    crate::platform::desktop::open_bar(app, "chat");
    Ok(())
}

pub fn cancel(app: &AppHandle) {
    app.state::<Services>().part.lock().unwrap_or_else(|e| e.into_inner()).take();
    #[cfg(desktop)]
    super::windows::close_part(app);
}
