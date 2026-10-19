//! Nook Companion: een telefoon laat zien welke agent-sessies jou nodig hebben, en laat je goedkeuren, antwoorden,
//! een bericht sturen en stoppen. Hetzelfde protocol als de Mac en de iPhone-app (`packages/protocol`,
//! `docs/COMPANION.md`), byte voor byte: een Windows- of Linux-pc kan zo met de iPhone-app praten, en de Android-app
//! met een Mac of pc.
//!
//! - [`models`]: berichten, framing en regels; [`seal`]: verzegeling (HKDF-SHA256 + ChaCha20-Poly1305).
//! - [`server`] en [`store`]: de computerkant; de sessies komen uit een [`backend::CompanionBackend`].
//! - [`client`]: de telefoonkant. [`push`]: wanneer en wat een pushmelding zegt; [`apns`]: versturen via Apple.

pub mod apns;
pub mod backend;
pub mod client;
pub mod models;
pub mod push;
pub mod seal;
pub mod server;
pub mod sessions;
pub mod store;

pub use backend::{BackendSession, CompanionBackend, NoSessions};
pub use models::*;

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};

    use async_trait::async_trait;

    use super::client::{CompanionClient, DnsResolver, Phase};
    use super::server::{CompanionServer, ServerState};
    use super::store::CompanionStore;
    use super::*;
    use crate::secrets::{MemorySecrets, SecretStore};
    use crate::store::NookStore;

    /// Een werkruimte met één sessie die op toestemming wacht en één vraag.
    #[derive(Default)]
    struct FakeWorkspace {
        log: Mutex<Vec<String>>,
        done: Mutex<Vec<String>>,
    }

    #[async_trait]
    impl CompanionBackend for FakeWorkspace {
        async fn sessions(&self) -> Vec<BackendSession> {
            let done = self.done.lock().unwrap().clone();
            let mut items = vec![
                DigestItem {
                    id: "p1".into(),
                    kind: ItemKind::Approval,
                    title: "rm -rf build".into(),
                    detail: "Bash".into(),
                    can_allow: CompanionPolicy::can_allow("Bash", Some(false)),
                    options: vec![],
                },
                DigestItem {
                    id: "p2".into(),
                    kind: ItemKind::Approval,
                    title: "Bewerk src/main.rs".into(),
                    detail: "Edit".into(),
                    can_allow: CompanionPolicy::can_allow("Edit", None),
                    options: vec![],
                },
                DigestItem {
                    id: "q1".into(),
                    kind: ItemKind::Question,
                    title: "Welke database?".into(),
                    detail: "Opslag".into(),
                    can_allow: true,
                    options: vec!["SQLite".into(), "Postgres".into()],
                },
            ];
            items.retain(|i| !done.contains(&i.id));
            vec![
                BackendSession {
                    digest: SessionDigest {
                        id: "S1".into(),
                        title: "Login repareren".into(),
                        agent: "Claude Code".into(),
                        attention: "approval".into(),
                        folder: "nook".into(),
                        branch: Some("main".into()),
                        updated: 20.0,
                        excerpt: "x".repeat(900),
                        items,
                    },
                    active: true,
                    free_answers: vec![],
                },
                BackendSession {
                    digest: SessionDigest {
                        id: "S0".into(),
                        title: "Oud".into(),
                        agent: "Codex".into(),
                        attention: "idle".into(),
                        folder: "x".into(),
                        branch: None,
                        updated: 10.0,
                        excerpt: String::new(),
                        items: vec![],
                    },
                    active: false,
                    free_answers: vec![],
                },
            ]
        }
        async fn decide(&self, session: &str, item: &str, allow: bool) -> Result<(), String> {
            self.log.lock().unwrap().push(format!("decide {session} {item} {allow}"));
            self.done.lock().unwrap().push(item.into());
            Ok(())
        }
        async fn answer(&self, session: &str, item: &str, text: &str) -> Result<(), String> {
            self.log.lock().unwrap().push(format!("answer {session} {item} {text}"));
            self.done.lock().unwrap().push(item.into());
            Ok(())
        }
        async fn send(&self, session: &str, text: &str) -> Result<(), String> {
            self.log.lock().unwrap().push(format!("send {session} {text}"));
            Ok(())
        }
        async fn stop(&self, session: &str) -> Result<(), String> {
            self.log.lock().unwrap().push(format!("stop {session}"));
            Ok(())
        }
    }

    fn temp_file() -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("nook-companion-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("companion.json")
    }

    #[tokio::test]
    async fn pairs_and_controls_sessions_over_tcp() {
        let workspace = Arc::new(FakeWorkspace::default());
        let store = Arc::new(CompanionStore::load(temp_file(), Arc::new(MemorySecrets::default())));
        store.set_enabled(true);
        let audit = Arc::new(NookStore::in_memory().unwrap());
        let server = Arc::new(CompanionServer::new(store.clone(), workspace.clone(), Some(audit.clone()), "Testpc".into()));
        let ServerState::Listening { port } = server.apply().await else { panic!("luistert niet") };
        assert_eq!(store.port(), Some(port));

        let phone_secrets: Arc<dyn SecretStore> = Arc::new(MemorySecrets::default());
        let phone = CompanionClient::new(phone_secrets.clone(), Arc::new(DnsResolver));
        assert_eq!(phone.snapshot().phase, Phase::Unpaired);

        // Een verzonnen code werkt niet.
        let fake = PairingLink { host: "127.0.0.1".into(), port, key: vec![5; 32], mac_name: "x".into() };
        let failed = phone.pair(&fake.url(), "Pixel").await;
        assert_eq!(failed.phase, Phase::Unpaired);
        assert!(failed.notice.unwrap().starts_with("Koppelen mislukt"));

        let link = server.pairing_link("127.0.0.1").unwrap();
        let paired = phone.pair(&link.url(), "Pixel 8").await;
        assert_eq!(paired.phase, Phase::Connected, "{:?}", paired.notice);
        assert_eq!(paired.mac_name, "Testpc");
        assert_eq!(paired.sessions.len(), 2);
        assert_eq!(paired.sessions[0].id, "S1", "nieuwste eerst");
        assert_eq!(paired.sessions[0].excerpt.chars().count(), EXCERPT_LIMIT + 1);
        assert_eq!(store.devices().len(), 1);
        assert_eq!(store.devices()[0].name, "Pixel 8");
        // Een gestopt koppelvenster: die code werkt niet meer.
        let cancelled = server.pairing_link("127.0.0.1").unwrap();
        store.cancel_pairing();
        let other = CompanionClient::new(Arc::new(MemorySecrets::default()), Arc::new(DnsResolver));
        assert_eq!(other.pair(&cancelled.url(), "Ander").await.phase, Phase::Unpaired);
        assert_eq!(store.devices().len(), 1);

        // Riskant toestaan mag niet, weigeren wel; laag risico toestaan wel.
        let s = phone.decide("S1", "p1", true).await;
        assert_eq!(s.notice.as_deref(), Some("Dat kan niet vanaf de telefoon: open het op je computer."));
        phone.clear_notice();
        let s = phone.decide("S1", "p1", false).await;
        assert_eq!(s.notice, None);
        assert_eq!(s.sessions[0].items.len(), 2);
        phone.decide("S1", "p2", true).await;
        // Alleen een van de opties; een eigen antwoord weigert de computer hier.
        let s = phone.answer("S1", "q1", "MongoDB").await;
        assert_eq!(s.notice.as_deref(), Some("De computer weigerde dit."));
        let s = phone.answer("S1", "q1", "SQLite").await;
        assert!(s.sessions[0].items.is_empty());
        let s = phone.answer("S1", "q1", "SQLite").await;
        assert_eq!(s.notice.as_deref(), Some("Dat is al afgehandeld."));
        let s = phone.send("S1", "  ga door\u{7}  ").await;
        assert_eq!(s.notice.as_deref(), Some("In de wachtrij: de sessie is nog bezig."));
        phone.stop("S1").await;
        let s = phone.stop("S9").await;
        assert_eq!(s.notice.as_deref(), Some("Dat is al afgehandeld."));

        assert_eq!(
            *workspace.log.lock().unwrap(),
            vec!["decide S1 p1 false", "decide S1 p2 true", "answer S1 q1 SQLite", "send S1 ga door", "stop S1"]
        );
        let actions: Vec<String> = audit.audit_entries(50, "companion").into_iter().map(|e| e.tool).collect();
        for action in ["companion_paired", "companion_deny", "companion_allow", "companion_answer", "companion_send", "companion_stop"] {
            assert!(actions.contains(&action.to_string()), "{action} in {actions:?}");
        }

        // De koppeling blijft bewaard; ontkoppelen aan de computerkant sluit de telefoon buiten.
        let again = CompanionClient::new(phone_secrets, Arc::new(DnsResolver));
        assert_eq!(again.refresh().await.phase, Phase::Connected);
        store.remove(&store.devices()[0].id);
        assert_eq!(again.refresh().await.phase, Phase::Offline);

        server.stop();
        assert_eq!(server.state(), ServerState::Stopped);
    }

    #[tokio::test]
    async fn push_follows_the_rules_before_anything_leaves() {
        use super::push::{PushEvent, PushKind, PushSettings, PushSkip};
        use p256::pkcs8::{EncodePrivateKey, LineEnding};
        let store = Arc::new(CompanionStore::load(temp_file(), Arc::new(MemorySecrets::default())));
        let server = CompanionServer::new(store.clone(), Arc::new(NoSessions), None, "pc".into());
        let event = PushEvent {
            kind: PushKind::Approval,
            session: "S1".into(),
            item: Some("P1".into()),
            agent: "Claude Code".into(),
            title: "geheim".into(),
            can_allow: false,
        };
        store.set_enabled(true);
        assert_eq!(server.notify(event.clone(), 0, true).await, Some(PushSkip::Disabled), "geen sleutel");
        assert!(!store.save_apns_pem("geen sleutel"));
        let pem = p256::ecdsa::SigningKey::from_slice(&[7u8; 32]).unwrap().to_pkcs8_pem(LineEnding::LF).unwrap();
        assert!(store.save_apns_pem(&pem));
        store.set_apns_ids("ABC123DEFG", "35SMNHP9K7");
        assert!(store.can_push());
        assert_eq!(server.notify(event.clone(), 0, true).await, Some(PushSkip::NoDevices));
        let now = chrono::Utc::now();
        store.begin_pairing(now);
        let device = store.complete_pairing("iPhone", now).unwrap();
        store.set_push_token(&device.id, Some("ab".repeat(32)), Some(true));
        assert_eq!(server.notify(event.clone(), 0, true).await, Some(PushSkip::Disabled), "meldingen staan uit");
        store.set_push_settings(PushSettings { enabled: true, ..Default::default() });
        assert_eq!(server.notify(event.clone(), 0, false).await, Some(PushSkip::AtTheComputer));
        let limited = PushEvent { kind: PushKind::Limited, ..event };
        assert_eq!(server.notify(limited, 0, true).await, Some(PushSkip::KindOff));
    }

    #[tokio::test]
    async fn refuses_replays_and_garbage() {
        use super::seal::{self, Direction};
        let store = Arc::new(CompanionStore::load(temp_file(), Arc::new(MemorySecrets::default())));
        let server = CompanionServer::new(store.clone(), Arc::new(NoSessions), None, "pc".into());
        assert!(server.respond(b"not json").await.is_none());
        // Een toestel dat niet bestaat en geen open venster: verbinding dicht.
        let key = vec![3u8; 32];
        let device = PairedDevice::identifier(&key);
        let request = serde_json::to_vec(&CompanionRequest::new(CompanionOp::List)).unwrap();
        let frame = seal::seal(&request, &key, &device, Direction::Request);
        assert!(server.respond(&frame).await.is_none());

        // Gekoppeld: dezelfde aanvraag twee keer is een herhaling.
        let now = chrono::Utc::now();
        let key = store.begin_pairing(now);
        let device = PairedDevice::identifier(&key);
        let mut hello = CompanionRequest::new(CompanionOp::Hello);
        hello.text = Some("Telefoon".into());
        let open = |reply: Vec<u8>| -> CompanionResponse {
            let reader = &mut FrameReader::default();
            let frame = reader.feed(&reply).remove(0);
            serde_json::from_slice(&seal::open(&frame, &key, Direction::Response).unwrap()).unwrap()
        };
        let frame = seal::seal(&serde_json::to_vec(&hello).unwrap(), &key, &device, Direction::Request);
        assert!(open(server.respond(&frame).await.unwrap()).ok);
        assert_eq!(open(server.respond(&frame).await.unwrap()).error, Some(CompanionError::Replay));
        // Een antwoord teruggestuurd als aanvraag opent niet.
        let reply = server.respond(&seal::seal(&request, &key, &device, Direction::Request)).await.unwrap();
        let mut reader = FrameReader::default();
        assert!(server.respond(&reader.feed(&reply).remove(0)).await.is_none());
    }
}
