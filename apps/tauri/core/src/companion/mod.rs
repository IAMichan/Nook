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
pub mod chat_digest;
pub mod client;
pub mod device_key;
#[cfg(test)]
mod fixtures;
pub mod home_digest;
pub mod inbox_digest;
pub mod keep_awake;
pub mod live;
pub mod models;
pub mod pull_digest;
pub mod push;
pub mod relay;
pub mod relay_push;
pub mod remote_digest;
pub mod scopes;
pub mod seal;
pub mod server;
pub mod sessions;
pub mod store;
pub mod transport;

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
                    ..Default::default()
                },
                DigestItem {
                    id: "p2".into(),
                    kind: ItemKind::Approval,
                    title: "Bewerk src/main.rs".into(),
                    detail: "Edit".into(),
                    can_allow: CompanionPolicy::can_allow("Edit", None),
                    options: vec![],
                    ..Default::default()
                },
                DigestItem {
                    id: "q1".into(),
                    kind: ItemKind::Question,
                    title: "Welke database?".into(),
                    detail: "Opslag".into(),
                    can_allow: true,
                    options: vec!["SQLite".into(), "Postgres".into()],
                    ..Default::default()
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
                        ..Default::default()
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
                        ..Default::default()
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
        let fake = PairingLink { host: "127.0.0.1".into(), port, key: vec![5; 32], mac_name: "x".into(), ..Default::default() };
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
        // Right after pairing the phone bound its own device key, and from then on signs: the pairing key alone (a copy
        // of it) no longer gets an answer, a ping aside.
        assert!(store.devices()[0].device_key.is_some());
        let routes = [transport::Route::Direct { host: "127.0.0.1".into(), port }];
        let copied = CompanionRequest::new(CompanionOp::List);
        let (refused, _) = client::request(&link, &routes, &copied, None, &DnsResolver).await.unwrap();
        assert_eq!(refused.error, Some(CompanionError::NotAllowedFromPhone));
        assert_eq!(refused.message.as_deref(), Some("signature"));
        let (pinged, _) = client::request(&link, &routes, &CompanionRequest::new(CompanionOp::Ping), None, &DnsResolver).await.unwrap();
        assert!(pinged.ok);
        let s = phone.refresh().await;
        assert_eq!((s.phase, s.notice), (Phase::Connected, None), "the phone's own requests are signed");
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
        // A backend without extras lists only what the server does itself: the phone offers no timeline, and a request
        // beyond it is answered with a refusal rather than a closed connection.
        let s = phone.refresh().await;
        assert!(s.features.contains(&feature::DEVICE_KEY.to_string()) && s.features.contains(&feature::STREAM.to_string()));
        assert!(!s.features.contains(&feature::TIMELINE.to_string()));
        assert_eq!(s.scopes, Some(scopes::names(&scopes::all())), "a new pairing may do everything by default");
        let (s, answer) =
            phone.call(client::ClientCall { op: Some(CompanionOp::Timeline), session: Some("S1".into()), ..Default::default() }).await;
        assert!(answer.is_none());
        assert_eq!(s.phase, Phase::Connected);
        assert_eq!(s.notice.as_deref(), Some("De computer weigerde dit."));
        phone.clear_notice();
        // Pairing and push registration are the client's own: the interface cannot send them.
        let (s, answer) = phone.call(client::ClientCall { op: Some(CompanionOp::Register), ..Default::default() }).await;
        assert!(answer.is_none());
        assert_eq!(s.notice.as_deref(), Some("De computer weigerde dit."));
        phone.clear_notice();
        // `call` with `list` answers like a refresh.
        let (_, answer) = phone.call(client::ClientCall { op: Some(CompanionOp::List), ..Default::default() }).await;
        assert_eq!(answer.and_then(|a| a.sessions).map(|s| s.len()), Some(2));

        // Scopes per phone: one that may only approve sees no sessions, gets no music and is refused a message.
        let device = store.devices()[0].id.clone();
        server.set_scopes(&device, &[scopes::CompanionScope::Approve].into());
        let s = phone.refresh().await;
        assert_eq!(s.scopes, Some(vec!["approve".to_string()]));
        assert!(s.sessions.is_empty());
        let s = phone.send("S1", "nog iets").await;
        assert!(s.notice.is_some(), "a message needs operate");
        phone.clear_notice();
        assert!(!workspace.log.lock().unwrap().iter().any(|l| l == "send S1 nog iets"));
        server.set_scopes(&device, &scopes::all());
        assert_eq!(phone.refresh().await.sessions.len(), 2);

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

    /// Push through the relay (`relay_push`): an Android phone registers its Firebase token and its notification goes
    /// sealed to the relay's `/v1/push`, which the phone (and only the phone) opens; an iPhone follows the route.
    #[tokio::test]
    async fn pushes_go_sealed_through_the_relay() {
        use super::push::{PushEvent, PushKind, PushSettings};
        use super::relay_push::{self, PushRoute};
        let relay = crate::connectors::testserver::TestServer::start(vec![("POST /v1/push", 200, r#"{"apns":200}"#.into())]).await;
        let store = Arc::new(CompanionStore::load(temp_file(), Arc::new(MemorySecrets::default())));
        let server = CompanionServer::new(store.clone(), Arc::new(NoSessions), None, "pc".into());
        store.set_enabled(true);
        store.set_push_settings(PushSettings { enabled: true, ..Default::default() });
        let now = chrono::Utc::now();
        let key = store.begin_pairing(now);
        let android = store.complete_pairing("Pixel", now).unwrap();
        let event = PushEvent {
            kind: PushKind::Approval,
            // Long enough that the sealed (random base64) body never holds them by chance, as "S1" sometimes did.
            session: "session-secret-S1".into(),
            item: Some("P1".into()),
            agent: "Claude Code".into(),
            title: "geheim-onderwerp".into(),
            can_allow: false,
        };

        // A Firebase token registers through `register` with "fcm"; without a relay nothing can go.
        let fcm = format!("dQw4w9WgXcQ:APA91b{}", "x".repeat(140));
        let register =
            CompanionRequest { text: Some(fcm.clone()), item: Some("fcm".into()), ..CompanionRequest::new(CompanionOp::Register) };
        let frame = seal::seal(&serde_json::to_vec(&register).unwrap(), &key, &android.id, seal::Direction::Request);
        let reply = server.respond(&frame).await.unwrap();
        let answer: CompanionResponse = serde_json::from_slice(
            &super::transport::unpack(&seal::open(&FrameReader::default().feed(&reply)[0], &key, seal::Direction::Response).unwrap())
                .unwrap(),
        )
        .unwrap();
        assert!(answer.ok);
        assert_eq!(answer.message.as_deref(), Some("nopush"), "no relay yet");
        assert_eq!(store.device(&android.id).unwrap().push_service.as_deref(), Some("fcm"));
        assert_eq!(server.notify(event.clone(), 0, true).await, Some(super::push::PushSkip::Disabled));

        // With a relay in use (and no Apple key) the route starts on the relay and the push goes out sealed.
        server.set_reach(server::Reach { relay: format!("http://127.0.0.1:{}", relay.port), ..Default::default() });
        assert_eq!(server.push_route(), PushRoute::Own, "a build without Nook's relay starts on your own key");
        server.set_build_relay(true);
        assert_eq!(server.push_route(), PushRoute::Relay);
        assert_eq!(server.notify(event.clone(), 0, true).await, None);
        let sent = relay.received.lock().unwrap().clone();
        assert_eq!(sent.len(), 1);
        let body: relay_push::RelayPushRequest = serde_json::from_str(&sent[0].body).unwrap();
        assert_eq!(body.service.as_deref(), Some("fcm"));
        assert_eq!(body.token, fcm);
        assert_eq!(body.room, super::transport::relay_room(&key));
        assert!(!sent[0].body.contains("session-secret") && !sent[0].body.contains("geheim-onderwerp"), "the relay sees no ids or words");
        let envelope = serde_json::to_vec(&body.sealed).unwrap();
        let content = relay_push::open(&envelope, &relay_push::push_key(&key)).expect("the phone opens it");
        assert_eq!((content.session.as_str(), content.item.as_deref()), ("session-secret-S1", Some("P1")));
        assert_eq!(content.mac.as_deref(), Some(android.id.as_str()));
        assert!(server.last_push().unwrap_or_default().contains("Pixel: ok"));

        // An iPhone on your own key route without a key is told so; the Android phone still goes through the relay.
        store.set_push_route(PushRoute::Own);
        let now = chrono::Utc::now();
        store.begin_pairing(now);
        let iphone = store.complete_pairing("iPhone", now).unwrap();
        store.set_push_token(&iphone.id, Some("ab".repeat(32)), Some(true));
        assert_eq!(server.notify(event.clone(), 1, true).await, Some(super::push::PushSkip::Disabled), "no way for the iPhone");
        store.set_push_route(PushRoute::Relay);
        let second = PushEvent { item: Some("P2".into()), ..event };
        assert_eq!(server.notify(second, 0, true).await, None);
        let sent = relay.received.lock().unwrap().clone();
        assert_eq!(sent.len(), 3, "both phones through the relay");
        let apple: relay_push::RelayPushRequest = serde_json::from_str(&sent[2].body).unwrap();
        assert!(apple.service.is_none() && apple.token == "ab".repeat(32));
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

    /// A Mac that keeps the connection open: answers `subscribe` like `list`, then sends a change to the open session's
    /// conversation, and hears the phone's pings.
    #[tokio::test]
    async fn keeps_a_live_connection() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let key = vec![7u8; KEY_LENGTH];
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let mac_key = key.clone();
        let mac = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut frames = FrameReader::default();
            let mut buf = vec![0u8; 65536];
            let mut seen = Vec::new();
            let device = PairedDevice::identifier(&mac_key);
            let send = |r: CompanionResponse| {
                let json = serde_json::to_vec(&r).unwrap();
                FrameReader::frame(&seal::seal(&json, &mac_key, &device, seal::Direction::Response)).unwrap()
            };
            while seen.len() < 2 {
                let n = socket.read(&mut buf).await.unwrap();
                for frame in frames.feed(&buf[..n]) {
                    let plain = seal::open(&frame, &mac_key, seal::Direction::Request).unwrap();
                    let request: CompanionRequest = serde_json::from_slice(&plain).unwrap();
                    seen.push((request.op, request.foreground));
                    if request.op == CompanionOp::Subscribe {
                        let list = CompanionResponse {
                            mac_name: Some("Mac".into()),
                            sessions: Some(vec![]),
                            features: Some(vec!["stream".into()]),
                            ..CompanionResponse::success(&request.id)
                        };
                        socket.write_all(&send(list)).await.unwrap();
                        let update = CompanionResponse {
                            seq: Some(1),
                            timeline: Some(
                                serde_json::json!([{"id": "e2", "kind": "assistant", "text": "hi", "date": 1.0, "failed": false}]),
                            ),
                            timeline_session: Some("S1".into()),
                            timeline_after: Some("e1".into()),
                            ..CompanionResponse::success(&request.id)
                        };
                        socket.write_all(&send(update)).await.unwrap();
                    }
                }
            }
            seen
        });
        let secrets: Arc<dyn SecretStore> = Arc::new(MemorySecrets::default());
        let link = PairingLink { host: "127.0.0.1".into(), port, key, mac_name: "Mac".into(), ..Default::default() };
        secrets
            .write(
                "companion.pairing",
                &serde_json::json!({"host": "127.0.0.1", "port": port, "key": base64url_encode(&link.key), "macName": "Mac"}).to_string(),
            )
            .unwrap();
        let phone = CompanionClient::new(secrets, Arc::new(DnsResolver));
        let mut updates = Vec::new();
        let _ =
            tokio::time::timeout(std::time::Duration::from_secs(7), phone.stream(|| true, |snapshot, r| updates.push((snapshot, r)))).await;
        assert_eq!(updates.len(), 2, "the answer to subscribe and one update");
        assert_eq!(updates[0].0.features, vec!["stream".to_string()]);
        assert_eq!(updates[0].0.phase, Phase::Connected);
        assert_eq!(updates[1].1.timeline_after.as_deref(), Some("e1"));
        assert_eq!(updates[1].1.timeline_session.as_deref(), Some("S1"));
        let seen = mac.await.unwrap();
        assert_eq!(seen[0], (CompanionOp::Subscribe, Some(true)));
        assert_eq!(seen[1], (CompanionOp::Ping, Some(true)));
    }

    /// A backend with one session whose conversation grows, for the live connection of a real server.
    #[derive(Default)]
    struct LiveWorkspace {
        entries: Mutex<Vec<serde_json::Value>>,
        waiting: Mutex<bool>,
    }

    #[async_trait]
    impl CompanionBackend for LiveWorkspace {
        async fn sessions(&self) -> Vec<BackendSession> {
            let items = if *self.waiting.lock().unwrap() {
                vec![DigestItem { id: "p1".into(), kind: ItemKind::Approval, title: "ls".into(), ..Default::default() }]
            } else {
                vec![]
            };
            vec![BackendSession {
                digest: SessionDigest { id: "S1".into(), title: "Live".into(), items, ..Default::default() },
                active: true,
                free_answers: vec![],
            }]
        }
        async fn decide(&self, _: &str, _: &str, _: bool) -> Result<(), String> {
            *self.waiting.lock().unwrap() = false;
            Ok(())
        }
        async fn answer(&self, _: &str, _: &str, _: &str) -> Result<(), String> {
            Ok(())
        }
        async fn send(&self, _: &str, _: &str) -> Result<(), String> {
            Ok(())
        }
        async fn stop(&self, _: &str) -> Result<(), String> {
            Ok(())
        }
        fn features(&self) -> Vec<&'static str> {
            vec![feature::TIMELINE]
        }
        async fn extra(&self, request: &CompanionRequest, _device: &str) -> Option<CompanionResponse> {
            (request.op == CompanionOp::Timeline && request.session.as_deref() == Some("S1")).then(|| CompanionResponse {
                timeline: Some(serde_json::Value::Array(self.entries.lock().unwrap().clone())),
                timeline_session: Some("S1".into()),
                ..CompanionResponse::success(&request.id)
            })
        }
    }

    /// A real server keeps the phone's connection open: it says what kind of computer it is and what it can do, sends
    /// the sessions when they change, and the open session's conversation as only what came after.
    #[tokio::test]
    async fn server_streams_sessions_and_the_open_conversation() {
        let entry = |id: &str, text: &str| serde_json::json!({"id": id, "kind": "assistant", "text": text, "date": 1.0, "failed": false});
        let workspace = Arc::new(LiveWorkspace::default());
        *workspace.waiting.lock().unwrap() = true;
        workspace.entries.lock().unwrap().push(entry("e1", "hallo"));
        let store = Arc::new(CompanionStore::load(temp_file(), Arc::new(MemorySecrets::default())));
        store.set_enabled(true);
        let server = Arc::new(CompanionServer::new(store.clone(), workspace.clone(), None, "Linux-pc".into()));
        server.set_app_version("1.2.3");
        let ServerState::Listening { .. } = server.apply().await else { panic!("not listening") };
        let link = server.pairing_link("127.0.0.1").unwrap();
        let phone = Arc::new(CompanionClient::new(Arc::new(MemorySecrets::default()), Arc::new(DnsResolver)));
        let paired = phone.pair(&link.url(), "Pixel").await;
        assert_eq!(paired.phase, Phase::Connected, "{:?}", paired.notice);
        for f in [feature::STREAM, feature::LIVE_TIMELINE, feature::RETRY, feature::TIMELINE] {
            assert!(paired.features.contains(&f.to_string()), "{f} in {:?}", paired.features);
        }

        let updates = Arc::new(Mutex::new(Vec::<CompanionResponse>::new()));
        let collected = updates.clone();
        let streaming = phone.clone();
        let live = tokio::spawn(async move {
            let _ = tokio::time::timeout(
                std::time::Duration::from_secs(8),
                streaming.stream(|| true, move |_, r| collected.lock().unwrap().push(r)),
            )
            .await;
        });
        async fn wait_for(updates: &Mutex<Vec<CompanionResponse>>, check: impl Fn(&[CompanionResponse]) -> bool) -> bool {
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(6);
            while std::time::Instant::now() < deadline {
                if check(&updates.lock().unwrap()) {
                    return true;
                }
                tokio::time::sleep(std::time::Duration::from_millis(50)).await;
            }
            false
        }
        assert!(wait_for(&updates, |u: &[CompanionResponse]| !u.is_empty()).await, "the answer to subscribe");
        {
            let first = &updates.lock().unwrap()[0];
            assert_eq!(
                first.platform.as_deref(),
                Some(if cfg!(target_os = "windows") {
                    "windows"
                } else if cfg!(target_os = "macos") {
                    "macos"
                } else {
                    "linux"
                })
            );
            assert_eq!(first.app_version.as_deref(), Some("1.2.3"));
            assert_eq!(first.protocol_version, Some(PROTOCOL_VERSION));
            assert_eq!(first.oldest_phone, Some(OLDEST_PHONE));
        }
        // The computer keeps what the phone said it runs, for Settings.
        let device = &store.devices()[0];
        assert_eq!(device.protocol_version, Some(PROTOCOL_VERSION));
        assert_eq!(device.app_version.as_deref(), Some(env!("CARGO_PKG_VERSION")));

        // An approval answered elsewhere: the list follows by itself.
        phone.decide("S1", "p1", false).await;
        assert!(
            wait_for(&updates, |u: &[CompanionResponse]| u
                .iter()
                .any(|r| r.seq.is_some() && r.sessions.as_ref().is_some_and(|s| s[0].items.is_empty())))
            .await,
            "the new list"
        );

        // The phone opens the session; a new entry arrives as only that entry, after the one it has.
        let (_, watched) =
            phone.call(client::ClientCall { op: Some(CompanionOp::Watch), session: Some("S1".into()), ..Default::default() }).await;
        assert_eq!(watched.and_then(|w| w.timeline).map(|t| t.as_array().unwrap().len()), Some(1));
        workspace.entries.lock().unwrap().push(entry("e2", "klaar"));
        server.nudge();
        assert!(
            wait_for(&updates, |u: &[CompanionResponse]| u.iter().any(|r| r.timeline_after.as_deref() == Some("e1")
                && r.timeline.as_ref().and_then(|t| t.as_array()).is_some_and(|t| t.len() == 1 && t[0]["id"] == "e2")))
            .await,
            "only the new entry"
        );
        // Removing the phone tells it first.
        let device = store.devices()[0].id.clone();
        assert!(server.revoke(&device));
        assert!(wait_for(&updates, |u: &[CompanionResponse]| u.iter().any(|r| r.revoked == Some(true))).await, "revoked");
        live.abort();
    }

    /// Two computers paired with one phone: the second becomes active, the first is asked for its sessions as one of the
    /// others, switching moves back, and unpairing leaves the other. A code with a dead first address still pairs
    /// through its alternate.
    #[tokio::test]
    async fn pairs_with_several_computers_and_falls_back_to_other_addresses() {
        let start = |name: &str| {
            let store = Arc::new(CompanionStore::load(temp_file(), Arc::new(MemorySecrets::default())));
            store.set_enabled(true);
            Arc::new(CompanionServer::new(store, Arc::new(FakeWorkspace::default()), None, name.into()))
        };
        let a = start("Mac A");
        let b = start("Mac B");
        let ServerState::Listening { .. } = a.apply().await else { panic!() };
        let ServerState::Listening { port: port_b } = b.apply().await else { panic!() };
        let phone = CompanionClient::new(Arc::new(MemorySecrets::default()), Arc::new(DnsResolver));
        let first = phone.pair(&a.pairing_link("127.0.0.1").unwrap().url(), "Pixel").await;
        assert_eq!(first.phase, Phase::Connected, "{:?}", first.notice);
        assert_eq!(first.route, "internet");
        // B's code names an address nothing listens on first, then the real one as an alternate.
        let mut link_b = b.pairing_link("127.0.0.1").unwrap();
        link_b.host = "127.0.0.2".into();
        link_b.alternates = vec!["127.0.0.1".into()];
        let _ = port_b;
        let second = phone.pair(&link_b.url(), "Pixel").await;
        assert_eq!(second.phase, Phase::Connected, "{:?}", second.notice);
        assert_eq!(second.mac_name, "Mac B");
        assert_eq!(second.macs.iter().map(|m| (m.name.as_str(), m.active)).collect::<Vec<_>>(), vec![("Mac A", false), ("Mac B", true)]);
        let s = phone.refresh_others().await;
        assert_eq!(s.others.len(), 1);
        assert_eq!(s.others[0].name, "Mac A");
        assert!(s.others[0].reachable);
        assert_eq!(s.others[0].sessions.len(), 2);
        // Each computer says what it is, so the phone shows its icon and names it (a Mac, or a PC).
        let here = if cfg!(target_os = "windows") {
            "windows"
        } else if cfg!(target_os = "macos") {
            "macos"
        } else {
            "linux"
        };
        assert!(s.macs.iter().all(|m| m.platform == here), "{:?}", s.macs);
        assert_eq!(s.others[0].platform, here);
        let a_id = s.macs[0].id.clone();
        let s = phone.switch_to(&a_id);
        assert_eq!(s.mac_name, "Mac A");
        assert!(s.others.is_empty());
        assert_eq!(phone.refresh().await.phase, Phase::Connected);
        let s = phone.unpair();
        assert_eq!(s.macs.len(), 1);
        assert_eq!(s.mac_name, "Mac B");
        assert_eq!(phone.refresh().await.mac_name, "Mac B");
    }

    /// A message for a computer that keeps an outbox waits while it is away, and can be taken out.
    #[tokio::test]
    async fn keeps_a_message_while_the_computer_is_away() {
        let secrets: Arc<dyn SecretStore> = Arc::new(MemorySecrets::default());
        let key = base64url_encode(&[3u8; KEY_LENGTH]);
        secrets
            .write(
                "companion.pairings",
                &serde_json::json!([{ "host": "127.0.0.1", "port": 9, "key": key, "macName": "Mac", "features": ["retry"] }]).to_string(),
            )
            .unwrap();
        let phone = CompanionClient::new(secrets.clone(), Arc::new(DnsResolver));
        let (s, answer) = phone
            .call(client::ClientCall {
                op: Some(CompanionOp::Send),
                session: Some("S1".into()),
                text: Some("later".into()),
                ..Default::default()
            })
            .await;
        assert_eq!(answer.and_then(|a| a.message).as_deref(), Some("outbox"));
        assert_eq!(s.outbox.len(), 1);
        assert_eq!(s.outbox[0].text, "later");
        // A message to a chat of the Chats tab waits too, with the chat it goes to.
        let (s, answer) = phone
            .call(client::ClientCall {
                op: Some(CompanionOp::InboxSend),
                item: Some("w1".into()),
                text: Some("see you".into()),
                ..Default::default()
            })
            .await;
        assert_eq!(answer.and_then(|a| a.message).as_deref(), Some("outbox"));
        assert_eq!(s.outbox[1].item.as_deref(), Some("w1"));
        assert_eq!(client::outbox_max_age(CompanionOp::InboxSend), 3600.0);
        assert_eq!(client::outbox_max_age(CompanionOp::Send), client::OUTBOX_MAX_AGE);
        let id = s.outbox[1].id.clone();
        assert_eq!(phone.discard(&id).outbox.len(), 1);
        // Its push key is the one the Mac seals with (`RelayPush.pushKey`).
        assert_eq!(phone.push_keys()[0].mac, PairedDevice::identifier(&[3u8; KEY_LENGTH]));
        // It is kept across a restart of the app.
        let again = CompanionClient::new(secrets, Arc::new(DnsResolver));
        let id = again.snapshot().outbox[0].id.clone();
        assert!(again.discard(&id).outbox.is_empty());
        // Approvals never wait: they go now or not at all.
        let s = again.decide("S1", "p1", true).await;
        assert_eq!(s.phase, Phase::Offline);
        assert!(s.outbox.is_empty());
    }

    /// Away from home: no address answers, and the phone reaches the computer through the relay's WebSocket, in the room
    /// only it and the computer know. The relay here passes each frame to the computer's server and back.
    #[tokio::test]
    #[allow(clippy::result_large_err)] // tungstenite's handshake callback returns its own large error type
    async fn reaches_the_computer_through_the_relay() {
        use futures_util::{SinkExt, StreamExt};
        let store = Arc::new(CompanionStore::load(temp_file(), Arc::new(MemorySecrets::default())));
        store.set_enabled(true);
        let mac = Arc::new(CompanionServer::new(store, Arc::new(FakeWorkspace::default()), None, "Mac".into()));
        let ServerState::Listening { .. } = mac.apply().await else { panic!() };
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let relay_port = listener.local_addr().unwrap().port();
        let rooms = Arc::new(Mutex::new(Vec::<String>::new()));
        let (server, seen) = (mac.clone(), rooms.clone());
        tokio::spawn(async move {
            loop {
                let (socket, _) = listener.accept().await.unwrap();
                let (server, seen) = (server.clone(), seen.clone());
                tokio::spawn(async move {
                    let path = Arc::new(Mutex::new(String::new()));
                    let p = path.clone();
                    let mut ws = tokio_tungstenite::accept_hdr_async(
                        socket,
                        move |req: &tokio_tungstenite::tungstenite::handshake::server::Request, res| {
                            *p.lock().unwrap() = req.uri().to_string();
                            Ok(res)
                        },
                    )
                    .await
                    .unwrap();
                    seen.lock().unwrap().push(path.lock().unwrap().clone());
                    let mut frames = FrameReader::default();
                    while let Some(Ok(message)) = ws.next().await {
                        for frame in frames.feed(&message.into_data()) {
                            if let Some(reply) = server.respond(&frame).await {
                                ws.send(tokio_tungstenite::tungstenite::Message::Binary(reply.into())).await.unwrap();
                            }
                        }
                    }
                });
            }
        });
        let mut link = mac.pairing_link("127.0.0.1").unwrap();
        link.host = "127.0.0.2".into();
        link.port = 9;
        link.relay = Some(format!("http://127.0.0.1:{relay_port}"));
        let phone = CompanionClient::new(Arc::new(MemorySecrets::default()), Arc::new(DnsResolver));
        let s = phone.pair(&link.url(), "Pixel").await;
        assert_eq!(s.phase, Phase::Connected, "{:?}", s.notice);
        assert_eq!(s.route, "relay");
        assert_eq!(s.sessions.len(), 2);
        let room = super::transport::relay_room(&link.key);
        assert_eq!(rooms.lock().unwrap()[0], format!("/v1/rooms/{room}?role=phone"));
        assert_eq!(phone.decide("S1", "p2", true).await.route, "relay");
    }

    /// The computer as a server away from home (`relay::RelayHost`): it dials out to the relay and keeps a room per
    /// phone, so a phone that reaches none of its addresses pairs and works through the relay. The relay here speaks
    /// the real mux (`apps/relay/worker/room.js`): the computer's socket carries `[kind][connection][payload]`, the
    /// phone's the payload alone.
    #[tokio::test]
    #[allow(clippy::result_large_err)] // tungstenite's handshake callback returns its own large error type
    async fn the_computer_serves_phones_through_its_relay_rooms() {
        use super::relay::{mux_decode, mux_encode, MuxKind, RelayHost, RelayStatus};
        use futures_util::{SinkExt, StreamExt};
        use std::collections::HashMap;
        use tokio::sync::mpsc;
        use tokio_tungstenite::tungstenite::Message;

        type Out = mpsc::UnboundedSender<Message>;
        #[derive(Default)]
        struct Rooms {
            macs: HashMap<String, Out>,
            phones: HashMap<(String, u32), Out>,
            next: u32,
        }
        let rooms = Arc::new(Mutex::new(Rooms::default()));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let relay = format!("http://127.0.0.1:{}", listener.local_addr().unwrap().port());
        let shared = rooms.clone();
        tokio::spawn(async move {
            loop {
                let (socket, _) = listener.accept().await.unwrap();
                let rooms = shared.clone();
                tokio::spawn(async move {
                    let path = Arc::new(Mutex::new(String::new()));
                    let p = path.clone();
                    let ws = tokio_tungstenite::accept_hdr_async(
                        socket,
                        move |req: &tokio_tungstenite::tungstenite::handshake::server::Request, res| {
                            *p.lock().unwrap() = req.uri().to_string();
                            Ok(res)
                        },
                    )
                    .await
                    .unwrap();
                    let path = path.lock().unwrap().clone();
                    let room = path.trim_start_matches("/v1/rooms/").split('?').next().unwrap().to_string();
                    let mac = path.ends_with("role=mac");
                    let (mut sink, mut stream) = ws.split();
                    let (tx, mut rx) = mpsc::unbounded_channel::<Message>();
                    tokio::spawn(async move {
                        while let Some(m) = rx.recv().await {
                            if sink.send(m).await.is_err() {
                                return;
                            }
                        }
                    });
                    let connection = if mac {
                        rooms.lock().unwrap().macs.insert(room.clone(), tx.clone());
                        0
                    } else {
                        let mut r = rooms.lock().unwrap();
                        let Some(mac) = r.macs.get(&room).cloned() else {
                            let _ = tx.send(Message::Close(Some(tokio_tungstenite::tungstenite::protocol::CloseFrame {
                                code: 4404.into(),
                                reason: "".into(),
                            })));
                            return;
                        };
                        r.next += 1;
                        let c = r.next;
                        r.phones.insert((room.clone(), c), tx.clone());
                        let _ = mac.send(Message::Binary(mux_encode(MuxKind::Open, c, &[]).into()));
                        c
                    };
                    while let Some(Ok(message)) = stream.next().await {
                        match message {
                            Message::Text(t) if t.as_str() == "ping" => {
                                let _ = tx.send(Message::Text("pong".into()));
                            }
                            Message::Binary(b) if mac => {
                                let Some((kind, c, payload)) = mux_decode(&b) else { continue };
                                let phone = rooms.lock().unwrap().phones.get(&(room.clone(), c)).cloned();
                                if let Some(phone) = phone {
                                    let _ = phone.send(match kind {
                                        MuxKind::Data => Message::Binary(payload.to_vec().into()),
                                        _ => Message::Close(None),
                                    });
                                }
                            }
                            Message::Binary(b) => {
                                let mac = rooms.lock().unwrap().macs.get(&room).cloned();
                                if let Some(mac) = mac {
                                    let _ = mac.send(Message::Binary(mux_encode(MuxKind::Data, connection, &b).into()));
                                }
                            }
                            _ => {}
                        }
                    }
                    if !mac {
                        let mac = rooms.lock().unwrap().macs.get(&room).cloned();
                        if let Some(mac) = mac {
                            let _ = mac.send(Message::Binary(mux_encode(MuxKind::Close, connection, &[]).into()));
                        }
                    }
                });
            }
        });

        let store = Arc::new(CompanionStore::load(temp_file(), Arc::new(MemorySecrets::default())));
        store.set_enabled(true);
        let pc = Arc::new(CompanionServer::new(store.clone(), Arc::new(FakeWorkspace::default()), None, "Windows-pc".into()));
        let ServerState::Listening { port } = pc.apply().await else { panic!() };
        let host = RelayHost::new(pc.clone(), tokio::runtime::Handle::current());
        // No paired phone and no pairing window: no room, nothing to connect.
        host.apply(true, Some(&relay));
        assert_eq!(host.status(), RelayStatus::Off);
        assert_eq!(host.advertised(), relay);
        pc.set_reach(server::Reach {
            hosts: vec![server::ReachHost { host: "100.101.1.2".into(), tailnet: true }],
            relay: host.advertised(),
        });

        // A pairing window opens a room; the code carries the relay and the Tailscale address.
        let mut link = pc.pairing_link("127.0.0.2").unwrap();
        assert_eq!(link.relay.as_deref(), Some(relay.as_str()));
        assert_eq!(link.alternates, vec!["100.101.1.2".to_string()]);
        host.apply(true, Some(&relay));
        for _ in 0..100 {
            if host.status() == RelayStatus::Connected {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
        assert_eq!(host.status(), RelayStatus::Connected);

        // The phone reaches none of the addresses, so it pairs through the relay.
        link.port = 9;
        link.alternates.clear();
        let phone = CompanionClient::new(Arc::new(MemorySecrets::default()), Arc::new(DnsResolver));
        let s = phone.pair(&link.url(), "iPhone").await;
        assert_eq!(s.phase, Phase::Connected, "{:?}", s.notice);
        assert_eq!(s.route, "relay");
        assert_eq!(s.mac_name, "Windows-pc");
        assert_eq!(store.devices().len(), 1);

        // Paired: the pairing window's room goes, the phone's own room comes, and actions work through it.
        host.apply(true, Some(&relay));
        let room = super::transport::relay_room(&store.key(&store.devices()[0].id).unwrap());
        for _ in 0..100 {
            if rooms.lock().unwrap().macs.contains_key(&room) {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
        let s = phone.decide("S1", "p2", true).await;
        assert_eq!(s.route, "relay", "{:?}", s.notice);
        assert!(s.notice.is_none(), "{:?}", s.notice);

        // Settings' *Test relay* takes the same way round.
        assert!(host.test().await.is_ok());

        // `list` tells the phone where else the computer is, and which relay it uses.
        let reach = pc.reach();
        assert_eq!(reach.relay, relay);
        let _ = port;

        // Off: every room closes, and phones are told to drop the relay.
        host.apply(false, Some(&relay));
        assert_eq!(host.status(), RelayStatus::Off);
        assert_eq!(host.advertised(), "");
    }

    /// The push key and a sealed push as the Mac makes them (the vectors of `RelayPushTests` on the Mac, made outside
    /// Swift): what the Android app's notification service gets and opens.
    #[test]
    fn push_keys_open_what_the_mac_seals() {
        let pairing: Vec<u8> = (0u8..32).collect();
        let key = client::push_key(&pairing);
        let hex: String = key.iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(hex, "7a429408bc2815112a429079b335fb1a10ddd5ca648231192c2182f7ce957c07");
        let vector = br#"{"d": "630dcd2966c43366", "s": "AAAAAAAAAAAAAAAABS3kO4MIl6sxb1ccggt5baLczbPE5rpaZZaRXcuXSEkU4GmcxaFGzXF2q8bQTP2LEs8QYTtYj28NxxIl6Jzq5FRLlKT08PCoTrtIfWad9wFhK/oWpdxpklboXglaJ9jrZzvC7W6L/zlNGKz8GyQVJJtQdWS9SyRboYTAbGjAzZDq+8r9QGuqTk4csyaBfiMwc1M="}"#;
        let plain = seal::open(vector, &key, seal::Direction::Response).expect("the push key opens it");
        let content: serde_json::Value = serde_json::from_slice(&plain).unwrap();
        assert!(content.get("title").is_some() && content.get("category").is_some(), "{content}");
        assert!(seal::open(vector, &pairing, seal::Direction::Response).is_err(), "the pairing key itself does not");
    }
}
