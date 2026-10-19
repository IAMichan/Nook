//! AT-SPI: de toegankelijkheidslaag van Linux (die ook Orca gebruikt). Nook leest de tekst van vensters zonder
//! schermafbeelding, ook als ze achter andere vensters staan, net als `AppTextReader` op de Mac. GTK, Qt, Firefox,
//! Chromium en LibreOffice doen mee zodra toegankelijkheid aanstaat; Nook zet dat aan (`org.a11y.Status.IsEnabled`).

use std::time::{Duration, Instant};

use zbus::blocking::Connection;
use zbus::zvariant::{OwnedObjectPath, OwnedValue};

const REGISTRY: &str = "org.a11y.atspi.Registry";
const ROOT: &str = "/org/a11y/atspi/accessible/root";
const ACCESSIBLE: &str = "org.a11y.atspi.Accessible";
const TEXT: &str = "org.a11y.atspi.Text";

// Rollen (ATSPI_ROLE_*).
const ROLE_FRAME: u32 = 23;
const ROLE_DIALOG: u32 = 16;
const ROLE_WINDOW: u32 = 69;
const ROLE_PASSWORD: u32 = 40;
const ROLE_MENU: u32 = 33;
const ROLE_MENU_BAR: u32 = 34;
const ROLE_POPUP_MENU: u32 = 41;
const ROLE_TOOL_BAR: u32 = 63;
const ROLE_SCROLL_BAR: u32 = 48;
/// Rollen waarvan de naam inhoud is (knoppen, links, cellen, koppen…).
const NAMED: [u32; 12] = [43, 29, 56, 32, 37, 44, 62, 27, 7, 88, 83, 101];

// Toestanden (ATSPI_STATE_*), bitnummers.
const STATE_ACTIVE: u32 = 1;
const STATE_SHOWING: u32 = 25;
const STATE_ICONIFIED: u32 = 15;

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
        let session = Connection::session().map_err(|e| format!("Geen sessiebus: {e}"))?;
        let _ = session.call_method(
            Some("org.a11y.Bus"),
            "/org/a11y/bus",
            Some("org.freedesktop.DBus.Properties"),
            "Set",
            &("org.a11y.Status", "IsEnabled", zbus::zvariant::Value::from(true)),
        );
        let reply = session
            .call_method(Some("org.a11y.Bus"), "/org/a11y/bus", Some("org.a11y.Bus"), "GetAddress", &())
            .map_err(|e| format!("De toegankelijkheidsbus (at-spi) draait niet: {e}"))?;
        let address: String = reply.body().deserialize().map_err(|e| e.to_string())?;
        let bus = zbus::blocking::connection::Builder::address(address.as_str())
            .map_err(|e| e.to_string())?
            .method_timeout(Duration::from_millis(1500))
            .build()
            .map_err(|e| format!("Kon niet met at-spi verbinden: {e}"))?;
        Ok(Self { bus })
    }

    fn call<B: serde::Serialize + zbus::zvariant::DynamicType, R: for<'d> serde::Deserialize<'d> + zbus::zvariant::Type>(
        &self,
        node: &Node,
        iface: &str,
        method: &str,
        body: &B,
    ) -> Option<R> {
        let reply = self.bus.call_method(Some(node.0.as_str()), node.1.as_str(), Some(iface), method, body).ok()?;
        reply.body().deserialize().ok()
    }

    fn property(&self, node: &Node, iface: &str, name: &str) -> Option<OwnedValue> {
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
        self.bus
            .call_method(
                Some("org.freedesktop.DBus"),
                "/org/freedesktop/DBus",
                Some("org.freedesktop.DBus"),
                "GetConnectionUnixProcessID",
                &(bus_name,),
            )
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
}
