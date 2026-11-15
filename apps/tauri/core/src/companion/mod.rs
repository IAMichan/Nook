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
#[cfg(test)]
mod fixtures;
pub mod models;
pub mod push;
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
        // This computer lists no features: the phone offers only the first version, and a request beyond it is
        // answered with a refusal rather than a closed connection.
        let s = phone.refresh().await;
        assert!(s.features.is_empty());
        assert_eq!(s.scopes, None);
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
