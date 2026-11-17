//! A picture of the page in Nook's browser (`browser_screenshot`; `SessionBrowser.screenshot` on the Mac). Tauri has
//! no screenshot of a webview of its own, so each platform asks its webview engine: WebView2 through the DevTools
//! protocol (`Page.captureScreenshot`), WebKitGTK through `webkit_web_view_get_snapshot`, and WKWebView through
//! `takeSnapshotWithConfiguration`. Every engine hands back a PNG; [`shrink`] turns it into the JPEG the agent gets.

use std::io::Cursor;
use std::time::Duration;

use tauri::WebviewWindow;

/// Default and bounds of `max_width` (the Mac uses 1280 too).
pub const DEFAULT_WIDTH: u32 = 1280;
const MIN_WIDTH: u32 = 320;
const MAX_WIDTH: u32 = 2560;

/// The width the agent asked for, within sane bounds.
pub fn width(requested: Option<i64>) -> u32 {
    requested.map(|w| w.clamp(i64::from(MIN_WIDTH), i64::from(MAX_WIDTH)) as u32).unwrap_or(DEFAULT_WIDTH)
}

/// The PNG of the engine as a JPEG at most `max_width` pixels wide, plus its size.
pub fn shrink(png: &[u8], max_width: u32) -> Result<(Vec<u8>, u32, u32), String> {
    let image = image::load_from_memory(png).map_err(|e| format!("The browser's picture could not be read: {e}"))?;
    let image = if image.width() > max_width { image.resize(max_width, u32::MAX, image::imageops::FilterType::Triangle) } else { image };
    let mut jpeg = Vec::new();
    image.to_rgb8().write_to(&mut Cursor::new(&mut jpeg), image::ImageFormat::Jpeg).map_err(|e| e.to_string())?;
    Ok((jpeg, image.width(), image.height()))
}

/// A PNG of what the browser window shows now.
pub async fn png(window: &WebviewWindow) -> Result<Vec<u8>, String> {
    let (tx, rx) = tokio::sync::oneshot::channel::<Result<Vec<u8>, String>>();
    let tx = std::sync::Mutex::new(Some(tx));
    let send = move |r: Result<Vec<u8>, String>| {
        if let Some(tx) = tx.lock().unwrap_or_else(|e| e.into_inner()).take() {
            let _ = tx.send(r);
        }
    };
    window.with_webview(move |webview| platform::capture(webview, Box::new(send))).map_err(|e| e.to_string())?;
    match tokio::time::timeout(Duration::from_secs(10), rx).await {
        Ok(Ok(result)) => result,
        _ => Err("The browser did not deliver a picture in time. Is the window minimised?".into()),
    }
}

type Reply = Box<dyn Fn(Result<Vec<u8>, String>) + Send + Sync>;

#[cfg(target_os = "windows")]
mod platform {
    use base64::Engine;
    use webview2_com::CallDevToolsProtocolMethodCompletedHandler;
    use windows::core::w;

    use super::Reply;

    pub fn capture(webview: tauri::webview::PlatformWebview, reply: Reply) {
        let reply = std::sync::Arc::new(reply);
        let on_done = reply.clone();
        let handler = CallDevToolsProtocolMethodCompletedHandler::create(Box::new(move |result, json: String| {
            on_done(result.map_err(|e| e.message()).and_then(|_| decode(&json)));
            Ok(())
        }));
        // SAFETY: called on the UI thread by `with_webview`, with the controller WebView2 handed us.
        let started = unsafe {
            webview
                .controller()
                .CoreWebView2()
                .and_then(|core| core.CallDevToolsProtocolMethod(w!("Page.captureScreenshot"), w!(r#"{"format":"png"}"#), &handler))
        };
        if let Err(e) = started {
            reply(Err(format!("WebView2 could not take a picture: {}", e.message())));
        }
    }

    /// `{"data": "<base64 PNG>"}` from the DevTools protocol.
    fn decode(json: &str) -> Result<Vec<u8>, String> {
        let value: serde_json::Value = serde_json::from_str(json).map_err(|e| e.to_string())?;
        let data = value.get("data").and_then(serde_json::Value::as_str).ok_or("WebView2 returned no picture.")?;
        base64::engine::general_purpose::STANDARD.decode(data).map_err(|e| e.to_string())
    }
}

#[cfg(target_os = "linux")]
mod platform {
    use webkit2gtk::{SnapshotOptions, SnapshotRegion, WebViewExt};

    use super::Reply;

    pub fn capture(webview: tauri::webview::PlatformWebview, reply: Reply) {
        webview.inner().snapshot(SnapshotRegion::Visible, SnapshotOptions::NONE, None::<&webkit2gtk::gio::Cancellable>, move |result| {
            reply(match result {
                Ok(surface) => png(surface),
                Err(e) => Err(format!("WebKitGTK could not take a picture: {e}")),
            });
        });
    }

    /// Cairo's ARGB32 surface (premultiplied, native byte order) as a PNG, encoded by `image`.
    fn png(surface: cairo::Surface) -> Result<Vec<u8>, String> {
        let surface = cairo::ImageSurface::try_from(surface).map_err(|_| "WebKitGTK returned no image.".to_string())?;
        let (width, height, stride) = (surface.width() as u32, surface.height() as u32, surface.stride() as usize);
        let mut rgba = Vec::with_capacity((width * height * 4) as usize);
        surface
            .with_data(|data| {
                for row in data.chunks(stride).take(height as usize) {
                    for px in row[..width as usize * 4].chunks_exact(4) {
                        let argb = u32::from_ne_bytes([px[0], px[1], px[2], px[3]]);
                        let a = (argb >> 24) & 0xff;
                        let un = |c: u32| if a == 0 { 0 } else { ((c * 255 + a / 2) / a).min(255) as u8 };
                        rgba.extend_from_slice(&[un((argb >> 16) & 0xff), un((argb >> 8) & 0xff), un(argb & 0xff), a as u8]);
                    }
                }
            })
            .map_err(|e| e.to_string())?;
        let image = image::RgbaImage::from_raw(width, height, rgba).ok_or("WebKitGTK returned a broken image.")?;
        let mut out = Vec::new();
        image.write_to(&mut std::io::Cursor::new(&mut out), image::ImageFormat::Png).map_err(|e| e.to_string())?;
        Ok(out)
    }
}

#[cfg(target_os = "macos")]
mod platform {
    use block2::RcBlock;
    use objc2_app_kit::{NSBitmapImageFileType, NSBitmapImageRep, NSImage};
    use objc2_foundation::{NSDictionary, NSError};
    use objc2_web_kit::WKWebView;

    use super::Reply;

    pub fn capture(webview: tauri::webview::PlatformWebview, reply: Reply) {
        let block = RcBlock::new(move |image: *mut NSImage, error: *mut NSError| {
            // SAFETY: WebKit hands either a valid image or a valid error, alive for this call.
            let result = match unsafe { (image.as_ref(), error.as_ref()) } {
                (Some(image), _) => png(image),
                (None, Some(e)) => Err(format!("WebKit could not take a picture: {}", e.localizedDescription())),
                (None, None) => Err("WebKit returned no picture.".into()),
            };
            reply(result);
        });
        // SAFETY: `with_webview` runs on the main thread and `inner()` is the window's WKWebView.
        unsafe {
            let view = &*(webview.inner().cast::<WKWebView>());
            view.takeSnapshotWithConfiguration_completionHandler(None, &block);
        }
    }

    fn png(image: &NSImage) -> Result<Vec<u8>, String> {
        let tiff = image.TIFFRepresentation().ok_or("WebKit returned an empty picture.")?;
        let rep = NSBitmapImageRep::imageRepWithData(&tiff).ok_or("WebKit returned an unreadable picture.")?;
        // SAFETY: an empty property dictionary is valid for every file type.
        let data = unsafe { rep.representationUsingType_properties(NSBitmapImageFileType::PNG, &NSDictionary::new()) }
            .ok_or("The picture could not be turned into a PNG.")?;
        Ok(data.to_vec())
    }
}

#[cfg(not(any(target_os = "windows", target_os = "linux", target_os = "macos")))]
mod platform {
    use super::Reply;

    pub fn capture(_webview: tauri::webview::PlatformWebview, reply: Reply) {
        reply(Err("Nook cannot take a picture of its browser on this platform.".into()));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn png_of(width: u32, height: u32) -> Vec<u8> {
        let image = image::RgbaImage::from_pixel(width, height, image::Rgba([10, 120, 200, 255]));
        let mut out = Vec::new();
        image.write_to(&mut Cursor::new(&mut out), image::ImageFormat::Png).unwrap();
        out
    }

    #[test]
    fn widths_stay_in_bounds() {
        assert_eq!(width(None), 1280);
        assert_eq!(width(Some(10)), 320);
        assert_eq!(width(Some(800)), 800);
        assert_eq!(width(Some(100_000)), 2560);
        assert_eq!(width(Some(-5)), 320);
    }

    #[test]
    fn shrinks_wide_pictures_and_keeps_small_ones() {
        let (jpeg, w, h) = shrink(&png_of(2560, 1600), 1280).unwrap();
        assert_eq!((w, h), (1280, 800));
        assert_eq!(&jpeg[..2], &[0xFF, 0xD8], "a JPEG");
        let (_, w, h) = shrink(&png_of(800, 600), 1280).unwrap();
        assert_eq!((w, h), (800, 600));
        assert!(shrink(b"not a picture", 1280).is_err());
    }
}
