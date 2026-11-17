//! Windows toasts with buttons, a reply field, a group and a priority (the Mac's `SystemNotifier` on
//! `UNUserNotificationCenter`). The click on a toast is a `nook://notice` protocol link, registered for this user, so it
//! still opens the right place after Nook restarted; the buttons are answered by the running Nook (`Activated`).

use std::collections::HashMap;
use std::sync::Mutex;

use nook_core::services::toast::{Toast, ToastLevel, ToastLink, SCHEME};
use tauri::{AppHandle, Manager};
use windows::core::{Interface, HSTRING};
use windows::Data::Xml::Dom::XmlDocument;
use windows::Foundation::{IPropertyValue, TypedEventHandler};
use windows::UI::Notifications::{ToastActivatedEventArgs, ToastNotification, ToastNotificationManager, ToastNotificationPriority};

/// The app id Windows shows the toast under. The installer's Start menu shortcut carries the bundle identifier; a
/// build from `target\debug` or `target\release` has no shortcut and borrows PowerShell's (as tauri-plugin-notification).
fn app_id(app: &AppHandle) -> String {
    const POWERSHELL: &str = "{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\\WindowsPowerShell\\v1.0\\powershell.exe";
    if installed() {
        app.config().identifier.clone()
    } else {
        POWERSHELL.into()
    }
}

fn installed() -> bool {
    let Ok(exe) = std::env::current_exe() else { return false };
    let dir = exe.parent().map(|d| d.display().to_string().to_ascii_lowercase()).unwrap_or_default();
    !(dir.ends_with("\\target\\debug") || dir.ends_with("\\target\\release"))
}

/// The posted toasts, kept so their `Activated` handler stays alive while they are up.
#[derive(Default)]
struct Posted(Mutex<HashMap<String, ToastNotification>>);

pub fn setup(app: &AppHandle) {
    app.manage(Posted::default());
    if installed() {
        register_protocol();
    }
    remove_stale_requests(app);
}

/// `nook://` opens this Nook (HKCU, so no administrator is needed): a click on a toast after a restart lands here.
fn register_protocol() {
    use windows::Win32::System::Registry::{RegSetKeyValueW, HKEY_CURRENT_USER, REG_SZ};
    let Ok(exe) = std::env::current_exe() else { return };
    let command = format!("\"{}\" \"%1\"", exe.display());
    let base = format!("Software\\Classes\\{SCHEME}");
    let values: [(String, Option<&str>, String); 3] = [
        (base.clone(), None, "URL:Nook".into()),
        (base.clone(), Some("URL Protocol"), String::new()),
        (format!("{base}\\shell\\open\\command"), None, command),
    ];
    for (key, name, data) in values {
        let wide: Vec<u16> = data.encode_utf16().chain(std::iter::once(0)).collect();
        let key = HSTRING::from(key);
        let name = name.map(HSTRING::from);
        // SAFETY: valid, null-terminated UTF-16 strings that outlive the call; the size is in bytes.
        let result = unsafe {
            RegSetKeyValueW(
                HKEY_CURRENT_USER,
                &key,
                name.as_ref().map_or(windows::core::PCWSTR::null(), |n| windows::core::PCWSTR(n.as_ptr())),
                REG_SZ.0,
                Some(wide.as_ptr().cast()),
                (wide.len() * 2) as u32,
            )
        };
        if result.is_err() {
            log::warn!("Could not register the nook:// link: {result:?}");
        }
    }
}

/// Permission requests still in the notification center from before Nook restarted: their agent no longer waits on
/// Nook for them, so Allow there would do nothing. They go; Nook asks again for what is still open.
fn remove_stale_requests(app: &AppHandle) {
    let id = HSTRING::from(app_id(app));
    let Ok(history) = ToastNotificationManager::History() else { return };
    let Ok(list) = history.GetHistoryWithId(&id) else { return };
    for toast in list {
        let xml = toast.Content().and_then(|c| c.GetXml()).map(|x| x.to_string()).unwrap_or_default();
        if xml.contains("action=deny") {
            if let (Ok(tag), Ok(group)) = (toast.Tag(), toast.Group()) {
                let _ = history.RemoveGroupedTagWithId(&tag, &group, &id);
            }
        }
    }
}

pub fn show(app: &AppHandle, toast: &Toast) -> Result<(), String> {
    show_toast(app, toast).map_err(|e| e.to_string())
}

fn show_toast(app: &AppHandle, toast: &Toast) -> windows::core::Result<()> {
    let xml = XmlDocument::new()?;
    xml.LoadXml(&HSTRING::from(toast.windows_xml()))?;
    let notification = ToastNotification::CreateToastNotification(&xml)?;
    notification.SetTag(&HSTRING::from(toast.tag()))?;
    notification.SetGroup(&HSTRING::from(toast.group()))?;
    // Time-sensitive leads; passive goes straight to the notification center without a popup.
    notification.SetPriority(if toast.level == ToastLevel::TimeSensitive {
        ToastNotificationPriority::High
    } else {
        ToastNotificationPriority::Default
    })?;
    if toast.level == ToastLevel::Passive {
        notification.SetSuppressPopup(true)?;
    }
    let handle = app.clone();
    notification.Activated(&TypedEventHandler::new(move |_, args| {
        let (link, text) = activation(&args);
        if let Some(link) = link {
            crate::notices::respond(&handle, link, text);
        }
        Ok(())
    }))?;
    let notifier = ToastNotificationManager::CreateToastNotifierWithId(&HSTRING::from(app_id(app)))?;
    notifier.Show(&notification)?;
    if let Some(posted) = app.try_state::<Posted>() {
        posted.0.lock().unwrap_or_else(|e| e.into_inner()).insert(toast.id.clone(), notification);
    }
    Ok(())
}

/// The link a button or click carries, and what was typed in the reply field.
fn activation(args: &Option<windows::core::IInspectable>) -> (Option<ToastLink>, Option<String>) {
    let Some(args) = args.as_ref().and_then(|a| a.cast::<ToastActivatedEventArgs>().ok()) else { return (None, None) };
    let link = args.Arguments().ok().and_then(|a| ToastLink::parse(&a.to_string()));
    let text = args
        .UserInput()
        .ok()
        .and_then(|input| input.Lookup(&HSTRING::from("reply")).ok())
        .and_then(|value| value.cast::<IPropertyValue>().ok())
        .and_then(|value| value.GetString().ok())
        .map(|s| s.to_string());
    (link, text)
}

/// The toast goes away: what it says was handled elsewhere.
pub fn remove(app: &AppHandle, id: &str, group: &str) {
    if let Some(posted) = app.try_state::<Posted>() {
        posted.0.lock().unwrap_or_else(|e| e.into_inner()).remove(id);
    }
    let tag = Toast { id: id.into(), ..placeholder() }.tag();
    if let Ok(history) = ToastNotificationManager::History() {
        let _ = history.RemoveGroupedTagWithId(&HSTRING::from(tag), &HSTRING::from(group), &HSTRING::from(app_id(app)));
    }
}

fn placeholder() -> Toast {
    use nook_core::services::toast::{NoticeOptions, NoticeTarget};
    Toast::notice("", "", "", "", NoticeTarget::Nowhere, ToastLevel::Active, NoticeOptions::default())
}
