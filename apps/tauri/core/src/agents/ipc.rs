//! Lokale verbinding tussen agents (het hook-script, de MCP-brug) en Nook, alleen voor de huidige gebruiker
//! (`UnixSocketServer` op de Mac).
//!
//! - Linux (en macOS): een Unix-socket in `~/.nook` (map `0700`, socket `0600`); elke verbinding wordt gecontroleerd op
//!   het gebruikers-id van de andere kant.
//! - Windows: een named pipe `\\.\pipe\nook-<naam>-<gebruiker>` met een beveiliging die alleen deze gebruiker (en het
//!   systeem) toelaat, en die verbindingen van andere computers weigert.
//!
//! Het protocol is één regel JSON heen en (soms) één regel terug. Sluit de agent de verbinding voor Nook antwoordde,
//! dan weet Nook dat de vraag elders beantwoord is.

use std::io;
#[cfg(unix)]
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

use super::hub::{AgentHub, Responder, Wait};

pub trait Stream: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> Stream for T {}
pub type BoxStream = Box<dyn Stream>;

/// Het adres van een eindpunt (`hub`, `bridge`): een pad op Unix, een pipe-naam op Windows.
pub fn address(name: &str) -> String {
    #[cfg(windows)]
    {
        let user: String = std::env::var("USERNAME")
            .unwrap_or_default()
            .chars()
            .filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_')
            .take(40)
            .collect();
        format!(r"\\.\pipe\nook-{name}-{user}")
    }
    #[cfg(not(windows))]
    {
        socket_dir().join(format!("{name}.sock")).to_string_lossy().into_owned()
    }
}

#[cfg(not(windows))]
fn socket_dir() -> PathBuf {
    // Zonder spaties en kort genoeg voor de 108 tekens van een socketpad.
    dirs::home_dir().unwrap_or_else(std::env::temp_dir).join(".nook")
}

/// Luistert op `address` en geeft elke verbinding van deze gebruiker aan `on_connection`.
pub async fn listen(address: String, on_connection: Arc<dyn Fn(BoxStream) + Send + Sync>) -> io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let path = PathBuf::from(&address);
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
            let _ = std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700));
        }
        let _ = std::fs::remove_file(&path);
        let listener = tokio::net::UnixListener::bind(&path)?;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
        // SAFETY: getuid kan niet mislukken en heeft geen bijwerkingen.
        let me = unsafe { libc::getuid() };
        loop {
            let (stream, _) = match listener.accept().await {
                Ok(pair) => pair,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(e) => return Err(e),
            };
            match stream.peer_cred() {
                Ok(cred) if cred.uid() == me => on_connection(Box::new(stream)),
                _ => drop(stream),
            }
        }
    }
    #[cfg(windows)]
    {
        use tokio::net::windows::named_pipe::ServerOptions;
        let security = windows_security::UserOnly::new()?;
        let mut first = true;
        loop {
            let mut options = ServerOptions::new();
            options.first_pipe_instance(first).reject_remote_clients(true).max_instances(64);
            // SAFETY: `security` leeft zolang de lus draait en beschrijft een geldige SECURITY_ATTRIBUTES.
            let server = unsafe { options.create_with_security_attributes_raw(&address, security.as_ptr())? };
            first = false;
            server.connect().await?;
            on_connection(Box::new(server));
        }
    }
    #[cfg(not(any(unix, windows)))]
    {
        let _ = (address, on_connection);
        Err(io::Error::new(io::ErrorKind::Unsupported, "Geen lokale verbinding op dit platform"))
    }
}

/// Leest één regel (tot 4 MB), met een tijdslimiet.
pub async fn read_line<R: AsyncRead + Unpin>(reader: &mut R, limit: Duration) -> Option<Vec<u8>> {
    let mut buffer = Vec::new();
    let mut chunk = [0u8; 65_536];
    let read = async {
        while buffer.len() < 4_000_000 {
            let n = reader.read(&mut chunk).await.ok()?;
            if n == 0 {
                break;
            }
            buffer.extend_from_slice(&chunk[..n]);
            if chunk[..n].contains(&b'\n') {
                break;
            }
        }
        Some(())
    };
    tokio::time::timeout(limit, read).await.ok()??;
    (!buffer.is_empty()).then_some(buffer)
}

/// Eén verbinding van het hook-script: bericht lezen, aan de hub geven en wachten op het antwoord, het sluiten door
/// de agent of de tijdslimiet.
pub async fn serve_hook(hub: Arc<AgentHub>, stream: BoxStream) {
    let (mut reader, mut writer) = tokio::io::split(stream);
    let Some(line) = read_line(&mut reader, Duration::from_secs(5)).await else { return };
    let (responder, rx) = Responder::new();
    let wait = hub.handle(&line, responder);
    let limit = match &wait {
        Wait::Approval(_, d) | Wait::Question(_, d) => *d,
        Wait::Done => Duration::from_secs(5),
    };
    let closed = async {
        let mut sink = [0u8; 4096];
        loop {
            match reader.read(&mut sink).await {
                Ok(0) | Err(_) => break,
                Ok(_) => continue,
            }
        }
    };
    tokio::pin!(closed);
    let mut replied = false;
    tokio::select! {
        reply = rx => {
            if let Ok(Some(text)) = reply {
                let _ = writer.write_all(format!("{text}\n").as_bytes()).await;
                let _ = writer.flush().await;
                replied = true;
            }
        }
        _ = &mut closed => {
            hub.peer_closed(&wait);
            return;
        }
        _ = tokio::time::sleep(limit) => hub.expire(&wait),
    }
    // Wacht tot de agent het antwoord gelezen heeft en zelf sluit (een named pipe gooit ongelezen data weg).
    if replied {
        let _ = tokio::time::timeout(Duration::from_secs(2), &mut closed).await;
    }
    let _ = writer.shutdown().await;
}

/// Stuurt één regel en leest (hooguit) één regel terug, blokkerend. Voor het hook-script en de MCP-brug, die
/// draaien voor er een Tauri of async-runtime is. `None` als Nook niet draait.
pub fn send_line(address: &str, message: &str, read_reply: bool) -> Option<String> {
    use std::io::{BufRead, BufReader, Write};
    #[cfg(unix)]
    {
        let mut stream = std::os::unix::net::UnixStream::connect(address).ok()?;
        stream.write_all(message.as_bytes()).ok()?;
        stream.flush().ok()?;
        if !read_reply {
            return Some(String::new());
        }
        let mut line = String::new();
        BufReader::new(&stream).read_line(&mut line).ok()?;
        Some(line)
    }
    #[cfg(windows)]
    {
        // Alle instanties kunnen even bezet zijn; Nook maakt er na elke verbinding meteen een nieuwe.
        let mut pipe = None;
        for _ in 0..40 {
            match std::fs::OpenOptions::new().read(true).write(true).open(address) {
                Ok(file) => {
                    pipe = Some(file);
                    break;
                }
                Err(e) if e.raw_os_error() == Some(231) => std::thread::sleep(Duration::from_millis(50)),
                Err(_) => return None,
            }
        }
        let mut pipe = pipe?;
        pipe.write_all(message.as_bytes()).ok()?;
        pipe.flush().ok()?;
        if !read_reply {
            return Some(String::new());
        }
        let mut line = String::new();
        BufReader::new(&pipe).read_line(&mut line).ok()?;
        Some(line)
    }
    #[cfg(not(any(unix, windows)))]
    {
        let _ = (address, message, read_reply);
        None
    }
}

#[cfg(windows)]
mod windows_security {
    //! Een beveiligingsbeschrijving die alleen de huidige gebruiker en het systeem toegang geeft.
    use std::ffi::c_void;
    use std::io;
    use std::ptr::null_mut;

    use windows_sys::Win32::Foundation::{CloseHandle, LocalFree, HANDLE};
    use windows_sys::Win32::Security::Authorization::{
        ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1,
    };
    use windows_sys::Win32::Security::{
        GetTokenInformation, TokenUser, PSECURITY_DESCRIPTOR, SECURITY_ATTRIBUTES, TOKEN_QUERY, TOKEN_USER,
    };
    use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

    pub struct UserOnly {
        attributes: Box<SECURITY_ATTRIBUTES>,
        descriptor: PSECURITY_DESCRIPTOR,
    }

    // SAFETY: de beschrijving wordt alleen gelezen en pas bij Drop vrijgegeven.
    unsafe impl Send for UserOnly {}

    impl UserOnly {
        pub fn new() -> io::Result<Self> {
            let sid = current_user_sid()?;
            let sddl: Vec<u16> = format!("D:P(A;;GA;;;{sid})(A;;GA;;;SY)\0").encode_utf16().collect();
            let mut descriptor: PSECURITY_DESCRIPTOR = null_mut();
            // SAFETY: geldige, met nul afgesloten tekst; de uitvoer geven we vrij met LocalFree.
            let ok = unsafe {
                ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.as_ptr(), SDDL_REVISION_1, &mut descriptor, null_mut())
            };
            if ok == 0 {
                return Err(io::Error::last_os_error());
            }
            let attributes = Box::new(SECURITY_ATTRIBUTES {
                nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
                lpSecurityDescriptor: descriptor,
                bInheritHandle: 0,
            });
            Ok(Self { attributes, descriptor })
        }

        pub fn as_ptr(&self) -> *mut c_void {
            &*self.attributes as *const SECURITY_ATTRIBUTES as *mut c_void
        }
    }

    impl Drop for UserOnly {
        fn drop(&mut self) {
            // SAFETY: door ConvertStringSecurityDescriptorToSecurityDescriptorW toegewezen.
            unsafe { LocalFree(self.descriptor as _) };
        }
    }

    fn current_user_sid() -> io::Result<String> {
        // SAFETY: standaard Win32-aanroepen met gecontroleerde buffers; handles en geheugen worden vrijgegeven.
        unsafe {
            let mut token: HANDLE = null_mut();
            if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) == 0 {
                return Err(io::Error::last_os_error());
            }
            let mut length = 0u32;
            GetTokenInformation(token, TokenUser, null_mut(), 0, &mut length);
            let mut buffer = vec![0u8; length as usize];
            let ok = GetTokenInformation(token, TokenUser, buffer.as_mut_ptr() as *mut c_void, length, &mut length);
            CloseHandle(token);
            if ok == 0 {
                return Err(io::Error::last_os_error());
            }
            let user = &*(buffer.as_ptr() as *const TOKEN_USER);
            let mut text: *mut u16 = null_mut();
            if ConvertSidToStringSidW(user.User.Sid, &mut text) == 0 {
                return Err(io::Error::last_os_error());
            }
            let mut len = 0;
            while *text.add(len) != 0 {
                len += 1;
            }
            let sid = String::from_utf16_lossy(std::slice::from_raw_parts(text, len));
            LocalFree(text as _);
            Ok(sid)
        }
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use crate::agents::models::ApprovalDecision;
    use serde_json::json;

    #[tokio::test(flavor = "multi_thread")]
    async fn hook_round_trip_over_socket() {
        let dir = std::env::temp_dir().join(format!("nook-ipc-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let address = dir.join("hub.sock").to_string_lossy().into_owned();
        let hub = Arc::new(AgentHub::new(None, |_| {}));
        let h = hub.clone();
        let server = tokio::spawn(listen(
            address.clone(),
            Arc::new(move |stream| {
                tokio::spawn(serve_hook(h.clone(), stream));
            }),
        ));
        tokio::time::sleep(Duration::from_millis(100)).await;
        let message = json!({"agent": "claude-code", "mode": "permission", "env": {}, "event": {"hook_event_name": "PermissionRequest",
            "session_id": "s", "tool_name": "Bash", "tool_input": {"command": "npm install"}}})
        .to_string()
            + "\n";
        let a = address.clone();
        let client = tokio::task::spawn_blocking(move || send_line(&a, &message, true));
        let mut id = None;
        for _ in 0..50 {
            tokio::time::sleep(Duration::from_millis(20)).await;
            if let Some(a) = hub.approvals().first() {
                id = Some(a.id.clone());
                break;
            }
        }
        hub.decide(&id.expect("vraag kwam aan"), ApprovalDecision::Allow);
        let reply = client.await.unwrap().unwrap();
        assert!(reply.contains("\"behavior\":\"allow\""), "{reply}");
        server.abort();
        let _ = std::fs::remove_dir_all(dir);
    }
}
