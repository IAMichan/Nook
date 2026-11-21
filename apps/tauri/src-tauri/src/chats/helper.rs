//! Nook's own chat helper, nook-chatd (`apps/chatd`, `ChatHelper` on the Mac): Nook starts it as its child on
//! 127.0.0.1 with a fresh token each time, reads it into the shared inbox (`ChatdBridge`), listens on its live line,
//! and stops it when Nook quits. On Windows a Job Object stops it with Nook even when Nook does not get to quit
//! cleanly (the helper's own parent check cannot tell there); on Linux and macOS the helper sees its parent go.

use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use chrono::Utc;
use nook_core::chats::chatd::{ChatdBridge, ChatdClient, LiveEvent, PORT};
use nook_core::chats::typing::TypingState;
use nook_core::chats::{ChatBridge, ChatInbox, InboxStore};
use serde::Serialize;
use tauri::{AppHandle, Emitter};
use tokio::sync::Notify;

/// The helper's file name in this build of Nook: beside Nook's own program (Tauri's `externalBin`).
#[cfg(windows)]
const FILE_NAME: &str = "nook-chatd.exe";
#[cfg(not(windows))]
const FILE_NAME: &str = "nook-chatd";

/// How long a start waits for the helper to answer.
const START_WAIT: Duration = Duration::from_secs(30);
/// Reads while the live line is up only catch what it missed; without it, they are the only news.
const LIVE_INTERVAL: Duration = Duration::from_secs(120);
const PING_GAP: Duration = Duration::from_secs(30);

/// Payload of the `chat-typing` event sent to the window whenever someone starts or stops typing.
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TypingUpdate {
    pub key: String,
    pub typing: Vec<String>,
}

pub struct ChatHelper {
    process: Mutex<Option<Child>>,
    /// Why it did not start, in its own words; `None` while it runs or was never tried.
    problem: Mutex<Option<String>>,
    pub bridge: Arc<ChatdBridge>,
    live: Mutex<bool>,
    /// Wakes the reading loop: the live line said a chat changed.
    wake: Notify,
    /// Who is currently typing in each chat (live ephemeral state, keyed by inbox thread key).
    typing: Mutex<TypingState>,
    /// App handle for emitting live `chat-typing` updates.
    app: Mutex<Option<AppHandle>>,
    #[cfg(windows)]
    job: Mutex<Option<windows_job::Job>>,
}

impl ChatHelper {
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            process: Mutex::default(),
            problem: Mutex::default(),
            bridge: Arc::new(ChatdBridge::new()),
            live: Mutex::new(false),
            wake: Notify::new(),
            typing: Mutex::default(),
            app: Mutex::default(),
            #[cfg(windows)]
            job: Mutex::default(),
        })
    }

    /// Names of people currently typing in `key` (non-expired).
    pub fn typing_in(&self, key: &str) -> Vec<String> {
        lock(&self.typing).names(key, Utc::now())
    }

    /// Where the helper is: `NOOK_CHATD` (a development build), else beside Nook's program; `None` when this build
    /// came without it (the chat apps then wait for it).
    pub fn binary() -> Option<PathBuf> {
        if let Some(path) = std::env::var_os("NOOK_CHATD").map(PathBuf::from).filter(|p| p.is_file()) {
            return Some(path);
        }
        let path = std::env::current_exe().ok()?.parent()?.join(FILE_NAME);
        path.is_file().then_some(path)
    }

    /// Its linked accounts and chats, in Nook's data directory.
    pub fn data_directory() -> PathBuf {
        nook_core::paths::support_directory().join("ChatHelper")
    }

    /// Something was linked through the helper once: it then starts with Nook.
    pub fn is_ready() -> bool {
        Self::binary().is_some() && Self::data_directory().is_dir()
    }

    pub fn is_running(&self) -> bool {
        let mut process = lock(&self.process);
        match process.as_mut().map(|c| c.try_wait()) {
            Some(Ok(None)) => true,
            Some(_) => {
                *process = None;
                false
            }
            None => false,
        }
    }

    pub fn is_live(&self) -> bool {
        *lock(&self.live)
    }

    pub fn problem(&self) -> Option<String> {
        lock(&self.problem).clone()
    }

    /// A new token for every start, kept only in memory: only this Nook can use the helper.
    fn new_token() -> String {
        format!("{}{}", uuid::Uuid::new_v4().simple(), uuid::Uuid::new_v4().simple())
    }

    /// Starts the helper when it is not running and waits until it answers (half a minute at most). True once it runs.
    pub async fn start(&self) -> bool {
        if self.is_running() && self.bridge.client().is_some() {
            return true;
        }
        let Some(binary) = Self::binary() else { return false };
        self.stop();
        let token = Self::new_token();
        let data = Self::data_directory();
        let _ = std::fs::create_dir_all(&data);
        nook_core::paths::restrict(&data, 0o700);
        let mut command = Command::new(binary);
        command
            .arg("-addr")
            .arg(format!("127.0.0.1:{PORT}"))
            .arg("-data")
            .arg(&data)
            // The token goes through the environment, not the command line (the process list shows that).
            .env("NOOK_CHATD_TOKEN", &token)
            // Its output may name contacts or quote messages: it goes nowhere.
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            const CREATE_NO_WINDOW: u32 = 0x0800_0000;
            command.creation_flags(CREATE_NO_WINDOW);
        }
        let child = match command.spawn() {
            Ok(child) => child,
            Err(error) => {
                *lock(&self.problem) = Some(error.to_string());
                return false;
            }
        };
        #[cfg(windows)]
        {
            *lock(&self.job) = windows_job::Job::binding(&child);
        }
        log::info!("Chats: nook-chatd started (pid {})", child.id());
        *lock(&self.process) = Some(child);
        let client = ChatdClient::local(&token);
        let end = Instant::now() + START_WAIT;
        while Instant::now() < end && self.is_running() {
            if client.answers().await {
                *lock(&self.problem) = None;
                self.bridge.set_client(Some(client));
                return true;
            }
            tokio::time::sleep(Duration::from_millis(300)).await;
        }
        *lock(&self.problem) = Some(if self.is_running() { "unreachable".into() } else { "exited".into() });
        self.stop();
        false
    }

    /// Stops the helper if Nook started it, waiting two seconds at most.
    pub fn stop(&self) {
        self.bridge.set_client(None);
        *lock(&self.live) = false;
        lock(&self.typing).clear();
        let Some(mut child) = lock(&self.process).take() else { return };
        #[cfg(unix)]
        {
            // SIGTERM first, so it closes its databases.
            unsafe {
                libc::kill(child.id() as i32, libc::SIGTERM);
            }
            let deadline = Instant::now() + Duration::from_secs(2);
            while Instant::now() < deadline {
                if matches!(child.try_wait(), Ok(Some(_))) {
                    return;
                }
                std::thread::sleep(Duration::from_millis(50));
            }
        }
        let _ = child.kill();
        let _ = child.wait();
    }

    fn emit_typing(&self, key: &str, typing: Vec<String>) {
        if let Some(app) = lock(&self.app).clone() {
            let _ = app.emit("chat-typing", TypingUpdate { key: key.to_string(), typing });
        }
    }

    fn handle_typing(self: &Arc<Self>, chat_id: &str, person: &str, name: &str, seconds: f64) {
        let Some(sc) = self.bridge.chat_by_id(chat_id) else { return };
        if sc.me.as_deref() == Some(person) {
            return;
        }
        let key = ChatInbox::key(&sc.app, &sc.id);
        let display = if !name.trim().is_empty() {
            name.trim().to_string()
        } else if let Some(known) = sc.people.get(person).filter(|n| !n.trim().is_empty()) {
            known.trim().to_string()
        } else if !sc.is_group {
            sc.title.clone()
        } else {
            String::new()
        };
        let now = Utc::now();
        let (changed, names, hold) = {
            let mut state = lock(&self.typing);
            let before = state.names(&key, now);
            let hold = if seconds > 0.0 {
                let d = TypingState::hold_duration(seconds);
                state.typing(&key, person, &display, now + d);
                Some(d)
            } else {
                state.stopped(&key, person);
                None
            };
            let after = state.names(&key, now);
            (before != after, after, hold)
        };
        if changed {
            self.emit_typing(&key, names);
        }
        if let Some(hold) = hold {
            let me = self.clone();
            let wait = hold.to_std().unwrap_or(Duration::from_secs(15)) + Duration::from_millis(250);
            tauri::async_runtime::spawn(async move {
                tokio::time::sleep(wait).await;
                let now = Utc::now();
                let expired: Vec<(String, Vec<String>)> = {
                    let mut state = lock(&me.typing);
                    let touched = state.expire_keys(now);
                    touched
                        .into_iter()
                        .map(|k| {
                            let names = state.names(&k, now);
                            (k, names)
                        })
                        .collect()
                };
                for (k, names) in expired {
                    me.emit_typing(&k, names);
                }
            });
        }
    }

    /// Reads the helper into the inbox at its pace, sooner when the live line says a chat changed, and keeps the line
    /// open while the helper runs. `changed` is called after every read that changed the inbox.
    pub fn run(self: &Arc<Self>, chats: Arc<InboxStore>, changed: impl Fn(&nook_core::chats::ChatInbox, &InboxStore) + Send + Sync + 'static) {
        let me = self.clone();
        tauri::async_runtime::spawn(async move {
            loop {
                if Self::is_ready() && !me.is_running() {
                    me.start().await;
                }
                if me.is_running() {
                    me.ensure_live();
                    // What the inbox held before the read, to tell what is new after it.
                    let before = chats.read(|inbox| inbox.clone());
                    match chats.read_bridge(me.bridge.as_ref()).await {
                        Ok(true) => changed(&before, &chats),
                        Ok(false) => {}
                        Err(error) => log::info!("Chats: reading nook-chatd failed: {error}"),
                    }
                }
                let wait = if me.is_live() { LIVE_INTERVAL } else { me.bridge.interval() };
                tokio::select! {
                    _ = tokio::time::sleep(wait) => {}
                    _ = me.wake.notified() => {}
                }
            }
        });
    }

    /// Opens the live line unless it is open: every change it tells wakes the reading loop; when it drops, everything
    /// is read again and it opens again at the next turn.
    fn ensure_live(self: &Arc<Self>) {
        let Some(client) = self.bridge.client() else { return };
        {
            let mut live = lock(&self.live);
            if *live {
                return;
            }
            *live = true;
        }
        let me = self.clone();
        tauri::async_runtime::spawn(async move {
            let bridge = me.bridge.clone();
            let woken = me.clone();
            let result = client
                .live(PING_GAP, move |event| match event {
                    LiveEvent::Changed { chat, message } => {
                        bridge.changed(&chat, message.as_deref());
                        woken.wake.notify_one();
                    }
                    LiveEvent::Typing { chat, person, name, seconds } => {
                        woken.handle_typing(&chat, &person, &name, seconds);
                    }
                    _ => {}
                })
                .await;
            if let Err(error) = result {
                log::info!("Chats: nook-chatd live line dropped: {error}");
            }
            *lock(&me.live) = false;
            me.bridge.dropped();
            me.wake.notify_one();
        });
    }
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// Starts the helper's reading loop. Called from `connectors::setup`.
pub fn setup(app: &AppHandle, chats: Arc<InboxStore>) -> Arc<ChatHelper> {
    let helper = ChatHelper::new();
    *lock(&helper.app) = Some(app.clone());
    let handle = app.clone();
    helper.run(chats, move |before, store| {
        let _ = handle.emit("chats-changed", ());
        store.read(|now| super::notify::arrived(&handle, before, now));
    });
    helper
}

#[cfg(windows)]
mod windows_job {
    //! A Job Object that ends the helper when Nook's process ends, however it ends: the job's last handle closes with
    //! Nook, and `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` then ends every process in it.

    use std::os::windows::io::AsRawHandle;

    use windows::Win32::Foundation::{CloseHandle, HANDLE};
    use windows::Win32::System::JobObjects::{
        AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation, SetInformationJobObject,
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    };

    pub struct Job(isize);

    impl Job {
        pub fn binding(child: &std::process::Child) -> Option<Job> {
            unsafe {
                let job = CreateJobObjectW(None, None).ok()?;
                let mut info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
                info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
                let set = SetInformationJobObject(
                    job,
                    JobObjectExtendedLimitInformation,
                    &info as *const _ as *const core::ffi::c_void,
                    std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
                );
                if set.is_err() || AssignProcessToJobObject(job, HANDLE(child.as_raw_handle())).is_err() {
                    let _ = CloseHandle(job);
                    return None;
                }
                Some(Job(job.0 as isize))
            }
        }
    }

    impl Drop for Job {
        fn drop(&mut self) {
            unsafe {
                let _ = CloseHandle(HANDLE(self.0 as *mut core::ffi::c_void));
            }
        }
    }
}

/// Where Nook's chat helper stands, for Settings › Chats.
#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HelperStatus {
    /// This build of Nook comes with the helper.
    pub built: bool,
    pub running: bool,
    pub live: bool,
    /// Why it did not start, in its own words.
    pub problem: Option<String>,
}

#[tauri::command]
pub fn chat_helper_status(state: tauri::State<'_, crate::connectors::Connectors>) -> HelperStatus {
    let helper = &state.chat_helper;
    HelperStatus { built: ChatHelper::binary().is_some(), running: helper.is_running(), live: helper.is_live(), problem: helper.problem() }
}
