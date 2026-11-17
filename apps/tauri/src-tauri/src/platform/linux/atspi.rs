//! AT-SPI: de toegankelijkheidslaag van Linux (die ook Orca gebruikt). Nook leest de tekst van vensters zonder
//! schermafbeelding, ook als ze achter andere vensters staan, net als `AppTextReader` op de Mac. GTK, Qt, Firefox,
//! Chromium en LibreOffice doen mee zodra toegankelijkheid aanstaat; Nook zet dat aan (`org.a11y.Status.IsEnabled`).

use std::time::{Duration, Instant};

use nook_core::brain::app_menu;
use nook_core::platform::MenuCommandOutcome;
use zbus::{block_on, Connection, OwnedObjectPath, OwnedVariant};

const REGISTRY: &str = "org.a11y.atspi.Registry";
const ROOT: &str = "/org/a11y/atspi/accessible/root";
const ACCESSIBLE: &str = "org.a11y.atspi.Accessible";
const ACTION: &str = "org.a11y.atspi.Action";
const TEXT: &str = "org.a11y.atspi.Text";

// Rollen (ATSPI_ROLE_*).
const ROLE_CHECK_MENU_ITEM: u32 = 8;
const ROLE_FRAME: u32 = 23;
const ROLE_DIALOG: u32 = 16;
const ROLE_WINDOW: u32 = 69;
const ROLE_PASSWORD: u32 = 40;
const ROLE_MENU: u32 = 33;
const ROLE_MENU_BAR: u32 = 34;
const ROLE_MENU_ITEM: u32 = 35;
const ROLE_POPUP_MENU: u32 = 41;
const ROLE_RADIO_MENU_ITEM: u32 = 45;
const ROLE_TOOL_BAR: u32 = 63;
const ROLE_SCROLL_BAR: u32 = 48;
/// Rollen waarvan de naam inhoud is (knoppen, links, cellen, koppen…).
const NAMED: [u32; 12] = [43, 29, 56, 32, 37, 44, 62, 27, 7, 88, 83, 101];

// Toestanden (ATSPI_STATE_*), bitnummers.
const STATE_ACTIVE: u32 = 1;
const STATE_ENABLED: u32 = 8;
const STATE_SHOWING: u32 = 25;
const STATE_ICONIFIED: u32 = 15;
const STATE_SENSITIVE: u32 = 24;

/// Een element: busnaam en objectpad.
type Node = (String, OwnedObjectPath);

pub struct Atspi {
    bus: Connection,
}

/// Een venster (frame) van een app.
#[derive(Debug, Clone)]
pub struct Frame {
    pub app: String,
    pub pid: u32,
    pub title: String,
    pub active: bool,
    pub showing: bool,
    node: Node,
}

impl Frame {
    pub fn id(&self) -> String {
        format!("atspi:{}:{}", self.node.0, self.node.1.as_str())
    }
}

impl Atspi {
    /// Verbindt met de toegankelijkheidsbus (en zet toegankelijkheid aan voor apps die daarna starten).
    pub fn connect() -> Result<Self, String> {
        block_on(async {
            let session = Connection::session().await.map_err(|e| format!("Geen sessiebus: {e}"))?;
            let _ = session
                .call_method(
                    Some("org.a11y.Bus"),
                    "/org/a11y/bus",
                    Some("org.freedesktop.DBus.Properties"),
                    "Set",
                    &("org.a11y.Status", "IsEnabled", zbus::Variant::from(true)),
                )
                .await;
            let reply = session
                .call_method(Some("org.a11y.Bus"), "/org/a11y/bus", Some("org.a11y.Bus"), "GetAddress", &())
                .await
                .map_err(|e| format!("De toegankelijkheidsbus (at-spi) draait niet: {e}"))?;
            let address: String = reply.body().deserialize().map_err(|e| e.to_string())?;
            let bus = zbus::connection::Builder::address(address.as_str())
                .method_timeout(Duration::from_millis(1500))
                .build()
                .await
                .map_err(|e| format!("Kon niet met at-spi verbinden: {e}"))?;
            Ok(Self { bus })
        })
    }

    fn call<B: serde::Serialize + zbus::DynamicType, R: for<'d> serde::Deserialize<'d> + zbus::Type>(
        &self,
        node: &Node,
        iface: &str,
        method: &str,
        body: &B,
    ) -> Option<R> {
        let reply = block_on(self.bus.call_method(Some(node.0.as_str()), node.1.as_str(), Some(iface), method, body)).ok()?;
        reply.body().deserialize().ok()
    }

    fn property(&self, node: &Node, iface: &str, name: &str) -> Option<OwnedVariant> {
        self.call(node, "org.freedesktop.DBus.Properties", "Get", &(iface, name))
    }

    fn name(&self, node: &Node) -> String {
        self.property(node, ACCESSIBLE, "Name").and_then(|v| String::try_from(v).ok()).unwrap_or_default()
    }

    fn role(&self, node: &Node) -> u32 {
        self.call(node, ACCESSIBLE, "GetRole", &()).unwrap_or(0)
    }

    fn states(&self, node: &Node) -> Vec<u32> {
        self.call(node, ACCESSIBLE, "GetState", &()).unwrap_or_default()
    }

    fn children(&self, node: &Node) -> Vec<Node> {
        self.call::<_, Vec<(String, OwnedObjectPath)>>(node, ACCESSIBLE, "GetChildren", &()).unwrap_or_default()
    }

    fn interfaces(&self, node: &Node) -> Vec<String> {
        self.call(node, ACCESSIBLE, "GetInterfaces", &()).unwrap_or_default()
    }

    fn pid(&self, bus_name: &str) -> u32 {
        block_on(self.bus.call_method(
            Some("org.freedesktop.DBus"),
            "/org/freedesktop/DBus",
            Some("org.freedesktop.DBus"),
            "GetConnectionUnixProcessID",
            &(bus_name,),
        ))
        .ok()
        .and_then(|r| r.body().deserialize::<u32>().ok())
        .unwrap_or(0)
    }

    fn has(states: &[u32], state: u32) -> bool {
        states.get((state / 32) as usize).is_some_and(|word| word & (1 << (state % 32)) != 0)
    }

    /// Alle vensters van alle apps die meedoen.
    pub fn frames(&self) -> Vec<Frame> {
        let root: Node = (REGISTRY.into(), OwnedObjectPath::try_from(ROOT).expect("geldig pad"));
        let own = std::process::id();
        let mut frames = Vec::new();
        for app in self.children(&root) {
            let app_name = self.name(&app);
            let pid = self.pid(&app.0);
            if pid == own {
                continue;
            }
            for child in self.children(&app).into_iter().take(12) {
                let role = self.role(&child);
                if ![ROLE_FRAME, ROLE_WINDOW, ROLE_DIALOG].contains(&role) {
                    continue;
                }
                let states = self.states(&child);
                frames.push(Frame {
                    app: app_name.clone(),
                    pid,
                    title: self.name(&child),
                    active: Self::has(&states, STATE_ACTIVE),
                    showing: Self::has(&states, STATE_SHOWING) && !Self::has(&states, STATE_ICONIFIED),
                    node: child,
                });
            }
        }
        frames
    }

    /// De tekst van een venster, binnen `chars` tekens en `elements` elementen.
    pub fn text(&self, frame: &Frame, chars: usize, elements: usize) -> String {
        let mut lines: Vec<String> = Vec::new();
        let mut budget = elements;
        let mut count = 0;
        let deadline = Instant::now() + Duration::from_millis(2500);
        self.collect(&frame.node, 0, &mut lines, &mut budget, &mut count, chars, deadline);
        lines.join("\n").trim().to_string()
    }

    fn collect(
        &self,
        node: &Node,
        depth: usize,
        lines: &mut Vec<String>,
        budget: &mut usize,
        count: &mut usize,
        chars: usize,
        deadline: Instant,
    ) {
        if depth > 60 || *budget == 0 || *count >= chars || Instant::now() > deadline {
            return;
        }
        *budget -= 1;
        let role = self.role(node);
        // Nooit wachtwoordvelden.
        if role == ROLE_PASSWORD {
            return;
        }
        if [ROLE_MENU_BAR, ROLE_MENU, ROLE_POPUP_MENU, ROLE_TOOL_BAR, ROLE_SCROLL_BAR].contains(&role) {
            return;
        }
        let mut parts = Vec::new();
        if self.interfaces(node).iter().any(|i| i == TEXT) {
            let text: Option<String> = self.call(node, TEXT, "GetText", &(0i32, -1i32));
            if let Some(text) = text.filter(|t| !t.trim().is_empty()) {
                parts.push(text);
            }
        }
        if parts.is_empty() || NAMED.contains(&role) {
            let name = self.name(node);
            if !name.trim().is_empty() && depth > 0 {
                parts.push(name);
            }
        }
        for part in parts {
            let clean = part.trim().replace('\u{fffc}', "");
            if !clean.is_empty() && lines.last() != Some(&clean) {
                *count += clean.chars().count() + 1;
                lines.push(clean);
            }
        }
        for child in self.children(node) {
            self.collect(&child, depth + 1, lines, budget, count, chars, deadline);
        }
    }

    fn is_menu_role(role: u32) -> bool {
        matches!(role, ROLE_MENU | ROLE_MENU_ITEM | ROLE_CHECK_MENU_ITEM | ROLE_RADIO_MENU_ITEM)
    }

    fn is_enabled(&self, node: &Node) -> bool {
        let states = self.states(node);
        Self::has(&states, STATE_ENABLED) && Self::has(&states, STATE_SENSITIVE)
    }

    fn frame_for_pid(&self, pid: u32) -> Option<Frame> {
        let mut frames: Vec<Frame> = self.frames().into_iter().filter(|f| f.pid == pid).collect();
        frames.sort_by_key(|f| (!f.active, !f.showing));
        frames.into_iter().next()
    }

    fn find_menu_bars(&self, node: &Node, depth: usize, deadline: Instant, out: &mut Vec<Node>) {
        if depth > 10 || Instant::now() > deadline || out.len() >= 8 {
            return;
        }
        let role = self.role(node);
        if role == ROLE_MENU_BAR {
            out.push(node.clone());
            return;
        }
        if role == ROLE_PASSWORD {
            return;
        }
        for child in self.children(node) {
            self.find_menu_bars(&child, depth + 1, deadline, out);
        }
    }

    fn menu_children(&self, node: &Node) -> Vec<Node> {
        let mut out = Vec::new();
        for child in self.children(node) {
            let role = self.role(&child);
            if Self::is_menu_role(role) {
                out.push(child);
            } else if role == ROLE_POPUP_MENU {
                for sub in self.children(&child) {
                    if Self::is_menu_role(self.role(&sub)) {
                        out.push(sub);
                    }
                }
            }
        }
        out
    }

    fn walk_menu(&self, node: &Node, prefix: &[String], depth: usize, deadline: Instant, out: &mut Vec<String>) {
        if depth >= app_menu::MAX_DEPTH || Instant::now() > deadline || out.len() >= 400 {
            return;
        }
        for child in self.menu_children(node) {
            if !self.is_enabled(&child) {
                continue;
            }
            let label = app_menu::clean_label(&self.name(&child));
            if label.is_empty() {
                continue;
            }
            let mut next = prefix.to_vec();
            next.push(label);
            let sub = self.menu_children(&child);
            if !sub.is_empty() && depth + 1 < app_menu::MAX_DEPTH {
                self.walk_menu(&child, &next, depth + 1, deadline, out);
            } else if depth >= 1 {
                out.push(next.join(" > "));
            }
        }
    }

    pub fn list_app_menu(&self, pid: u32) -> Vec<String> {
        let Some(frame) = self.frame_for_pid(pid) else { return vec![] };
        let deadline = Instant::now() + Duration::from_millis(3500);
        let mut bars = Vec::new();
        self.find_menu_bars(&frame.node, 0, deadline, &mut bars);
        let mut out = Vec::new();
        for bar in bars {
            self.walk_menu(&bar, &[], 0, deadline, &mut out);
        }
        out
    }

    pub fn click_app_menu(&self, pid: u32, path: &[String]) -> Result<MenuCommandOutcome, String> {
        if path.is_empty() {
            return Ok(MenuCommandOutcome::NotFound);
        }
        let Some(frame) = self.frame_for_pid(pid) else {
            return Ok(MenuCommandOutcome::NotFound);
        };
        let deadline = Instant::now() + Duration::from_millis(3000);
        let mut bars = Vec::new();
        self.find_menu_bars(&frame.node, 0, deadline, &mut bars);
        let mut current = None;
        for bar in bars {
            if let Some(found) = self.menu_children(&bar).into_iter().find(|n| app_menu::label_matches(&self.name(n), &path[0])) {
                current = Some(found);
                break;
            }
        }
        let Some(mut node) = current else {
            return Ok(MenuCommandOutcome::NotFound);
        };
        for segment in &path[1..] {
            let Some(next) = self.menu_children(&node).into_iter().find(|n| app_menu::label_matches(&self.name(n), segment)) else {
                return Ok(MenuCommandOutcome::NotFound);
            };
            node = next;
        }
        if !self.is_enabled(&node) {
            return Ok(MenuCommandOutcome::Disabled);
        }
        let ok: Option<bool> = self.call(&node, ACTION, "DoAction", &(0i32,));
        if ok == Some(true) {
            Ok(MenuCommandOutcome::Done)
        } else {
            Err("Menu command action failed.".into())
        }
    }
}
