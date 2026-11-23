//! Mouse and keyboard control of one app, the way a person would use it (`UIControl` on the Mac): click a button or a
//! switch, type in a field, press a key, scroll. This is the part without the operating system (what a step is, which
//! steps are allowed, how an element the brain names is found again), so it is tested anywhere; the platform performs
//! the steps (UI Automation and `SendInput` on Windows, `platform::ScreenReader::ui_perform`).
//!
//! The brain reads an app's window with `read_ui` and proposes steps with `control_ui`. The user approves the exact
//! steps in the plan; they run in that one app only. Elements are named by their label, never by a number from an
//! earlier read, and are looked up again right before each step, so a window that changed since is not clicked blindly.

use serde_json::Value;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    Click,
    DoubleClick,
    RightClick,
    Type,
    Key,
    Scroll,
    Open,
    Wait,
    Drag,
    Hover,
}

impl Action {
    pub const ALL: [Action; 10] = [
        Action::Click,
        Action::DoubleClick,
        Action::RightClick,
        Action::Type,
        Action::Key,
        Action::Scroll,
        Action::Open,
        Action::Wait,
        Action::Drag,
        Action::Hover,
    ];

    pub fn name(self) -> &'static str {
        match self {
            Action::Click => "click",
            Action::DoubleClick => "double_click",
            Action::RightClick => "right_click",
            Action::Type => "type",
            Action::Key => "key",
            Action::Scroll => "scroll",
            Action::Open => "open",
            Action::Wait => "wait",
            Action::Drag => "drag",
            Action::Hover => "hover",
        }
    }

    pub fn parse(raw: &str) -> Option<Action> {
        let name = raw.trim().to_lowercase().replace(['-', ' '], "_");
        Action::ALL.into_iter().find(|a| a.name() == name)
    }
}

/// One step as the brain proposes it. Which fields matter depends on the action.
#[derive(Clone, Debug, PartialEq)]
pub struct Step {
    pub action: Action,
    /// Label of an element as `read_ui` shows it ("Bluetooth", "Dark", "Search").
    pub element: Option<String>,
    /// Role to tell elements with the same label apart: button, checkbox, switch, field, row…
    pub role: Option<String>,
    /// Which of several elements with this label and role, counted from the top left (1 = first).
    pub index: Option<usize>,
    /// A point on screen in pixels, top left of the main display is 0,0 (as `read_ui` reports it).
    pub x: Option<f64>,
    pub y: Option<f64>,
    pub text: Option<String>,
    /// Select what is in the field first, so the typed text replaces it.
    pub replace: bool,
    /// A key or shortcut: "enter", "escape", "tab", "ctrl+f", "ctrl+shift+n".
    pub keys: Option<String>,
    pub direction: Option<String>,
    pub amount: Option<i64>,
    /// For `open`: a Windows Settings page (ms-settings:…). Without it, the app itself is brought to the front.
    pub url: Option<String>,
    pub seconds: Option<f64>,
    pub to_element: Option<String>,
    pub to_x: Option<f64>,
    pub to_y: Option<f64>,
}

impl Step {
    pub fn new(action: Action) -> Step {
        Step {
            action,
            element: None,
            role: None,
            index: None,
            x: None,
            y: None,
            text: None,
            replace: false,
            keys: None,
            direction: None,
            amount: None,
            url: None,
            seconds: None,
            to_element: None,
            to_x: None,
            to_y: None,
        }
    }
}

pub const MAX_STEPS: usize = 15;
pub const MAX_TEXT: usize = 500;
pub const MAX_WAIT: f64 = 10.0;
pub const MAX_SCROLL: i64 = 30;
pub const DEFAULT_DESCRIBE_LIMIT: usize = 9_000;
pub const FEW_CONTROLS: usize = 3;

fn list(raw: &Value) -> Vec<Value> {
    match raw {
        Value::Array(items) => items.clone(),
        // Some models send the list as a JSON string.
        Value::String(text) => serde_json::from_str::<Vec<Value>>(text).unwrap_or_default(),
        _ => Vec::new(),
    }
}

fn number(object: &serde_json::Map<String, Value>, key: &str) -> Option<f64> {
    match object.get(key)? {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => s.trim().replace(',', ".").parse().ok(),
        _ => None,
    }
}

fn text(object: &serde_json::Map<String, Value>, key: &str) -> Option<String> {
    object.get(key).and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty()).map(str::to_string)
}

/// The steps in a `control_ui` call; entries that are not a step at all are dropped (and reported by `problems`).
pub fn steps(raw: &Value) -> Vec<Step> {
    list(raw)
        .iter()
        .filter_map(|entry| {
            let object = entry.as_object()?;
            let action = Action::parse(object.get("action")?.as_str()?)?;
            let mut step = Step::new(action);
            step.element = text(object, "element");
            step.role = text(object, "role").map(|r| r.to_lowercase());
            step.index = number(object, "index").filter(|n| n.fract() == 0.0 && *n >= 0.0).map(|n| n as usize);
            step.x = number(object, "x");
            step.y = number(object, "y");
            // Typed text keeps its spaces: "  " can be what the user wants.
            step.text = object.get("text").and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_string);
            step.replace = match object.get("replace") {
                Some(Value::Bool(b)) => *b,
                Some(Value::String(s)) => s.eq_ignore_ascii_case("true"),
                _ => false,
            };
            step.keys = text(object, "keys").or_else(|| text(object, "key"));
            step.direction = text(object, "direction").map(|d| d.to_lowercase());
            step.amount = number(object, "amount").filter(|n| n.fract() == 0.0).map(|n| n as i64);
            step.url = text(object, "url");
            step.seconds = number(object, "seconds");
            step.to_element = text(object, "to_element").or_else(|| text(object, "to"));
            step.to_x = number(object, "to_x");
            step.to_y = number(object, "to_y");
            Some(step)
        })
        .collect()
}

fn on_screen(x: f64, y: f64) -> bool {
    x.is_finite() && y.is_finite() && x > -20_000.0 && x < 20_000.0 && y > -20_000.0 && y < 20_000.0
}

/// Everything wrong with a proposal, in plain language for the model and the plan (empty = fine).
pub fn problems(app: &str, raw: &Value) -> Vec<String> {
    let mut out = Vec::new();
    let name = app.trim();
    if name.is_empty() {
        out.push("The app is missing.".to_string());
    }
    if is_blocked(name) {
        out.push(format!("Nook does not control {name} with mouse and keyboard: it holds passwords, runs commands or is Nook itself."));
    }
    let count = list(raw).len();
    let parsed = steps(raw);
    if parsed.is_empty() {
        out.push("There are no steps.".to_string());
    }
    if parsed.len() < count {
        let names: Vec<&str> = Action::ALL.iter().map(|a| a.name()).collect();
        out.push(format!("{} step(s) have no valid action (use one of: {}).", count - parsed.len(), names.join(", ")));
    }
    if parsed.len() > MAX_STEPS {
        out.push(format!("At most {MAX_STEPS} steps at a time."));
    }
    for (i, step) in parsed.iter().enumerate() {
        out.extend(step_problems(step).into_iter().map(|p| format!("Step {}: {p}", i + 1)));
    }
    out
}

pub fn step_problems(step: &Step) -> Vec<String> {
    let mut out = Vec::new();
    let has_point = step.x.is_some() && step.y.is_some();
    if step.x.is_some() != step.y.is_some() {
        out.push("give both x and y".to_string());
    }
    if let (Some(x), Some(y)) = (step.x, step.y) {
        if !on_screen(x, y) {
            out.push("the point is not on a screen".to_string());
        }
    }
    if step.index == Some(0) {
        out.push("index starts at 1".to_string());
    }
    match step.action {
        Action::Click | Action::DoubleClick | Action::RightClick | Action::Hover => {
            if step.element.is_none() && !has_point {
                out.push("name the element (its label) or give x and y".to_string());
            }
        }
        Action::Type => match &step.text {
            None => out.push("the text to type is missing".to_string()),
            Some(t) if t.chars().count() > MAX_TEXT => out.push(format!("at most {MAX_TEXT} characters at a time")),
            _ => {}
        },
        Action::Key => match &step.keys {
            None => out.push("the key is missing, e.g. \"enter\" or \"ctrl+f\"".to_string()),
            Some(keys) => match parse_keys(keys) {
                Some(combo) => {
                    if let Some(reason) = forbidden(&combo) {
                        out.push(reason.to_string());
                    }
                }
                None => out.push(format!("unknown key \"{keys}\"")),
            },
        },
        Action::Scroll => {
            if !["up", "down", "left", "right"].contains(&step.direction.as_deref().unwrap_or("")) {
                out.push("direction must be up, down, left or right".to_string());
            }
            if let Some(a) = step.amount {
                if !(1..=MAX_SCROLL).contains(&a) {
                    out.push(format!("amount must be 1 to {MAX_SCROLL}"));
                }
            }
        }
        Action::Open => {
            if let Some(url) = &step.url {
                if !is_settings_page(url) {
                    out.push("only Windows Settings pages (ms-settings:…) can be opened here; use open_url for web pages".to_string());
                }
            }
        }
        Action::Wait => {
            if let Some(s) = step.seconds {
                if !(s > 0.0 && s <= MAX_WAIT) {
                    out.push(format!("wait at most {} seconds", MAX_WAIT as i64));
                }
            }
        }
        Action::Drag => {
            if step.element.is_none() && !has_point {
                out.push("name the element to drag or give x and y".to_string());
            }
            if step.to_x.is_some() != step.to_y.is_some() {
                out.push("give both to_x and to_y".to_string());
            }
            if step.to_element.is_none() && (step.to_x.is_none() || step.to_y.is_none()) {
                out.push("name where it goes (to_element) or give to_x and to_y".to_string());
            }
            if let (Some(x), Some(y)) = (step.to_x, step.to_y) {
                if !on_screen(x, y) {
                    out.push("the end point is not on a screen".to_string());
                }
            }
        }
    }
    out
}

/// A Windows Settings page (`ms-settings:bluetooth`), the Windows side of the Mac's System Settings panes.
pub fn is_settings_page(url: &str) -> bool {
    url.to_lowercase().starts_with("ms-settings:") && !url.contains(' ')
}

/// How many times in a row the conversation was continued with `marker`, counted back from the newest question.
pub fn rounds(questions: &[String], marker: &str) -> usize {
    questions.iter().rev().take_while(|q| q.as_str() == marker).count()
}

// MARK: Apps Nook never drives

/// Apps that hold passwords or run anything typed into them, the parts of Windows that guard the session, and Nook
/// itself (clicking its own Run button would approve its own plans).
pub const BLOCKED_NAMES: &[&str] = &[
    "cmd",
    "command prompt",
    "opdrachtprompt",
    "eingabeaufforderung",
    "invite de commandes",
    "símbolo del sistema",
    "powershell",
    "windows powershell",
    "pwsh",
    "terminal",
    "windows terminal",
    "windowsterminal",
    "wt",
    "conhost",
    "openconsole",
    "git bash",
    "mintty",
    "wsl",
    "bash",
    "ubuntu",
    "alacritty",
    "wezterm",
    "kitty",
    "hyper",
    "warp",
    "ghostty",
    "regedit",
    "registry editor",
    "register-editor",
    "registrierungs-editor",
    "éditeur du registre",
    "editor del registro",
    "credential manager",
    "referentiebeheer",
    "anmeldeinformationsverwaltung",
    "gestionnaire d'identification",
    "administrador de credenciales",
    "1password",
    "bitwarden",
    "lastpass",
    "dashlane",
    "enpass",
    "keepass",
    "keepassxc",
    "taskmgr",
    "task manager",
    "taakbeheer",
    "task-manager",
    "gestionnaire des tâches",
    "administrador de tareas",
    "mmc",
    "consent",
    "logonui",
    "lockapp",
    "credentialuibroker",
    "nook",
];

pub fn is_blocked(name: &str) -> bool {
    let lower = name.trim().to_lowercase();
    let clean = lower.strip_suffix(".exe").unwrap_or(&lower);
    !clean.is_empty()
        && (BLOCKED_NAMES.contains(&clean)
            || clean.contains("password")
            || clean.contains("wachtwoord")
            || clean.contains("passwort")
            || clean.contains("mot de passe")
            || clean.contains("contraseña")
            || clean.contains("keychain")
            || clean.contains("sleutelhanger"))
}

/// Alias for [`is_blocked`]: apps Nook never drives with mouse or keyboard.
pub fn is_blocked_app(name: &str) -> bool {
    is_blocked(name)
}

// MARK: Keys

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Modifier {
    Ctrl,
    Shift,
    Alt,
    Win,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct KeyCombo {
    pub modifiers: Vec<Modifier>,
    pub key: String,
    /// The Windows virtual-key code of `key` on a US layout.
    pub code: u16,
}

impl KeyCombo {
    pub fn has(&self, m: Modifier) -> bool {
        self.modifiers.contains(&m)
    }
}

fn modifier(name: &str) -> Option<Modifier> {
    Some(match name {
        // A brain that learned the Mac's shortcuts writes cmd: on Windows that is Ctrl.
        "ctrl" | "control" | "ctl" | "⌃" | "cmd" | "command" | "⌘" => Modifier::Ctrl,
        "shift" | "⇧" => Modifier::Shift,
        "alt" | "opt" | "option" | "⌥" | "altgr" => Modifier::Alt,
        "win" | "windows" | "super" | "meta" | "start" => Modifier::Win,
        _ => return None,
    })
}

/// Virtual-key codes (VK_…) by the names a model uses.
pub fn key_code(name: &str) -> Option<u16> {
    let alias = match name {
        "arrowleft" | "leftarrow" => "left",
        "arrowright" | "rightarrow" => "right",
        "arrowup" | "uparrow" => "up",
        "arrowdown" | "downarrow" => "down",
        "comma" => ",",
        "period" => ".",
        "slash" => "/",
        "minus" => "-",
        "equal" | "plus" => "=",
        "spacebar" => "space",
        "del" | "forwarddelete" => "delete",
        "return" => "enter",
        "esc" => "escape",
        "bksp" => "backspace",
        other => other,
    };
    let mut chars = alias.chars();
    if let (Some(c), None) = (chars.next(), chars.next()) {
        if c.is_ascii_alphabetic() {
            return Some(c.to_ascii_uppercase() as u16);
        }
        if c.is_ascii_digit() {
            return Some(c as u16);
        }
        return Some(match c {
            ';' => 0xBA,
            '=' => 0xBB,
            ',' => 0xBC,
            '-' => 0xBD,
            '.' => 0xBE,
            '/' => 0xBF,
            '`' => 0xC0,
            '[' => 0xDB,
            '\\' => 0xDC,
            ']' => 0xDD,
            '\'' => 0xDE,
            _ => return None,
        });
    }
    if let Some(n) = alias.strip_prefix('f').and_then(|n| n.parse::<u16>().ok()) {
        if (1..=12).contains(&n) {
            return Some(0x6F + n);
        }
    }
    Some(match alias {
        "enter" => 0x0D,
        "tab" => 0x09,
        "space" => 0x20,
        "backspace" => 0x08,
        "delete" => 0x2E,
        "escape" => 0x1B,
        "home" => 0x24,
        "end" => 0x23,
        "pageup" => 0x21,
        "pagedown" => 0x22,
        "left" => 0x25,
        "up" => 0x26,
        "right" => 0x27,
        "down" => 0x28,
        "insert" => 0x2D,
        "menu" | "apps" | "contextmenu" => 0x5D,
        _ => return None,
    })
}

/// The key name `key_code` was given, the way `dangerous_key` and the plan write it.
fn canonical_key(name: &str) -> String {
    match name {
        "return" => "enter",
        "esc" => "escape",
        "del" | "forwarddelete" => "delete",
        "bksp" => "backspace",
        "arrowleft" | "leftarrow" => "left",
        "arrowright" | "rightarrow" => "right",
        "arrowup" | "uparrow" => "up",
        "arrowdown" | "downarrow" => "down",
        "spacebar" => "space",
        other => other,
    }
    .to_string()
}

/// "ctrl+shift+n", "Ctrl-F", "Alt+F4", "Enter" → the combo, or None when a part is unknown.
pub fn parse_keys(raw: &str) -> Option<KeyCombo> {
    let mut text = raw.trim().to_lowercase();
    for (spaced, joined) in [("page up", "pageup"), ("page down", "pagedown"), ("forward delete", "forwarddelete"), ("arrow ", "")] {
        text = text.replace(spaced, joined);
    }
    if text.is_empty() {
        return None;
    }
    let mut modifiers = Vec::new();
    for (symbol, m) in [("⌘", Modifier::Ctrl), ("⇧", Modifier::Shift), ("⌥", Modifier::Alt), ("⌃", Modifier::Ctrl)] {
        if text.contains(symbol) {
            if !modifiers.contains(&m) {
                modifiers.push(m);
            }
            text = text.replace(symbol, "");
        }
    }
    // "+" can also be the key itself ("ctrl++"), so split by hand.
    let mut parts: Vec<String> = Vec::new();
    let mut current = String::new();
    let chars: Vec<char> = text.chars().collect();
    for (i, &c) in chars.iter().enumerate() {
        let is_sep = c == '+' || c == '-' || c == ' ';
        if is_sep {
            if !current.is_empty() {
                parts.push(std::mem::take(&mut current));
            } else if c != ' ' && chars[i + 1..].iter().all(|ch| ch.is_whitespace()) {
                current.push(c);
            }
        } else {
            current.push(c);
        }
    }
    if !current.is_empty() {
        parts.push(current);
    }
    let last = parts.last()?.clone();
    for part in &parts[..parts.len() - 1] {
        let m = modifier(part)?;
        if !modifiers.contains(&m) {
            modifiers.push(m);
        }
    }
    modifiers.sort();
    let key = if last == "+" { "=".to_string() } else { canonical_key(&last) };
    let code = key_code(&key)?;
    Some(KeyCombo { modifiers, key, code })
}

/// Shortcuts that end or lock the session, open the task manager or a shell, or switch away from the approved app.
pub fn forbidden(combo: &KeyCombo) -> Option<&'static str> {
    let ctrl = combo.has(Modifier::Ctrl);
    let alt = combo.has(Modifier::Alt);
    let win = combo.has(Modifier::Win);
    let shift = combo.has(Modifier::Shift);
    let key = combo.key.as_str();
    if win && key == "l" {
        return Some("locking the screen is not something Nook does");
    }
    if ctrl && alt && key == "delete" {
        return Some("the security screen is not something Nook opens");
    }
    if ctrl && shift && key == "escape" {
        return Some("the task manager is outside the approved app");
    }
    if win && (key == "r" || key == "x") {
        return Some("the Run box and the power menu run commands; Nook does not open them");
    }
    if (alt || win) && key == "tab" {
        return Some("switching apps is outside the approved app");
    }
    if win && ctrl && ["left", "right", "d", "f4"].contains(&key) {
        return Some("switching desktops is outside the approved app");
    }
    if win && combo.modifiers.len() == 1 && ["d", "m"].contains(&key) {
        return Some("showing the desktop is outside the approved app");
    }
    None
}

// MARK: Elements

/// One element of a window, as read through UI Automation.
#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct Element {
    /// Short role name: button, checkbox, switch, radio, popup, field, text, row, link, slider, tab, menuitem…
    pub role: String,
    pub label: String,
    pub value: Option<String>,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    pub enabled: bool,
    pub focused: bool,
    /// A password field: its value is never read, typing into it is refused.
    pub secure: bool,
    /// Inside the window's visible area. A long web page lists what is scrolled out of view too; that goes last.
    pub visible: bool,
}

impl Element {
    pub fn new(role: &str, label: &str, x: f64, y: f64, width: f64, height: f64) -> Element {
        Element {
            role: role.into(),
            label: label.into(),
            value: None,
            x,
            y,
            width,
            height,
            enabled: true,
            focused: false,
            secure: false,
            visible: true,
        }
    }
    pub fn center_x(&self) -> f64 {
        self.x + self.width / 2.0
    }
    pub fn center_y(&self) -> f64 {
        self.y + self.height / 2.0
    }
    pub fn contains(&self, px: f64, py: f64) -> bool {
        px >= self.x && px <= self.x + self.width && py >= self.y && py <= self.y + self.height
    }
}

/// The short role for a UI Automation control type (`UIA_*ControlTypeId`), the Windows side of the Mac's AX roles.
/// `password`: the element says it holds a password (`IsPassword`).
pub fn role_for_control_type(control_type: i32, password: bool, toggle_switch: bool) -> &'static str {
    if password {
        return "password";
    }
    match control_type {
        50000 => "button",
        50002 => {
            if toggle_switch {
                "switch"
            } else {
                "checkbox"
            }
        }
        50003 => "combobox",
        50004 => "field",
        50005 => "link",
        50007 => "row",
        50011 => "menuitem",
        50013 => "radio",
        50015 => "slider",
        50016 => "stepper",
        50019 => "tab",
        50020 => "text",
        50029 => "cell",
        50030 => "textarea",
        50031 => "menubutton",
        50024 => "row",
        50036 => "row",
        _ => "other",
    }
}

/// Roles a person clicks, types in or reads to know where they are; the rest of the tree only holds these.
pub const LISTED_ROLES: &[&str] = &[
    "button",
    "checkbox",
    "switch",
    "toggle",
    "radio",
    "popup",
    "menubutton",
    "combobox",
    "field",
    "search",
    "password",
    "textarea",
    "text",
    "slider",
    "stepper",
    "link",
    "row",
    "cell",
    "menuitem",
    "disclosure",
    "tab",
    "color",
    "date",
];

fn role_aliases(role: &str) -> Vec<&'static str> {
    match role {
        "button" => vec!["button", "menubutton"],
        "checkbox" => vec!["checkbox", "switch", "toggle"],
        "switch" => vec!["switch", "checkbox", "toggle"],
        "toggle" => vec!["toggle", "switch", "checkbox"],
        "radio" => vec!["radio", "tab"],
        "popup" => vec!["popup", "menubutton", "combobox"],
        "menu" => vec!["popup", "menubutton", "menuitem"],
        "field" => vec!["field", "search", "textarea", "combobox", "password"],
        "textfield" => vec!["field", "search", "textarea", "combobox"],
        "search" => vec!["search", "field"],
        "text" => vec!["text"],
        "row" => vec!["row", "cell"],
        "cell" => vec!["cell", "row"],
        "item" => vec!["row", "cell", "menuitem"],
        "menuitem" => vec!["menuitem"],
        "link" => vec!["link"],
        "slider" => vec!["slider"],
        "tab" => vec!["tab", "radio"],
        "stepper" => vec!["stepper"],
        _ => vec![],
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MatchError {
    NotFound(String),
    Ambiguous(String, usize),
}

impl std::fmt::Display for MatchError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            MatchError::NotFound(label) => {
                write!(f, "No element \"{label}\" in the window now. Read it again (read_ui) and name an element exactly as listed.")
            }
            MatchError::Ambiguous(label, n) => {
                write!(f, "\"{label}\" is there {n} times. Add role or index (1 = the first from the top left).")
            }
        }
    }
}

/// The element a step names: an exact label first, then one that starts with it, then one that contains it. With
/// several of the best kind, `index` picks one (in reading order); without it the step fails instead of guessing.
pub fn find(label: &str, role: Option<&str>, index: Option<usize>, elements: &[Element]) -> Result<Element, MatchError> {
    let wanted = normalize(label);
    if wanted.is_empty() {
        return Err(MatchError::NotFound(label.into()));
    }
    let roles: Option<Vec<String>> = role.map(|r| {
        let r = r.to_lowercase();
        let aliases = role_aliases(&r);
        if aliases.is_empty() {
            vec![r]
        } else {
            aliases.into_iter().map(String::from).collect()
        }
    });
    let candidates: Vec<&Element> = elements.iter().filter(|e| roles.as_ref().is_none_or(|r| r.contains(&e.role))).collect();
    let tiers: [&dyn Fn(&str) -> bool; 3] = [&|l| l == wanted, &|l| l.starts_with(&wanted), &|l| l.contains(&wanted)];
    for tier in tiers {
        let mut found: Vec<&Element> = candidates.iter().copied().filter(|e| tier(&normalize(&e.label))).collect();
        if found.is_empty() {
            continue;
        }
        // Text that is only a label is clicked only when asked for, or when nothing else has that name.
        if role.is_none() && found.iter().any(|e| e.role != "text") {
            found.retain(|e| e.role != "text");
        }
        found.sort_by(|a, b| (a.y, a.x).partial_cmp(&(b.y, b.x)).unwrap_or(std::cmp::Ordering::Equal));
        if let Some(i) = index {
            return found.get(i.wrapping_sub(1)).map(|e| (*e).clone()).ok_or_else(|| MatchError::NotFound(label.into()));
        }
        if found.len() == 1 {
            return Ok(found[0].clone());
        }
        // The same control listed twice (a row and the text in it at the same spot) is one control.
        let spots: std::collections::HashSet<(i64, i64)> = found.iter().map(|e| (e.center_x() as i64, e.center_y() as i64)).collect();
        if spots.len() == 1 {
            return Ok(found[0].clone());
        }
        return Err(MatchError::Ambiguous(label.into(), found.len()));
    }
    Err(MatchError::NotFound(label.into()))
}

pub fn normalize(text: &str) -> String {
    let lower = text.to_lowercase().replace('…', "").replace("...", "");
    let joined = lower.split_whitespace().collect::<Vec<_>>().join(" ");
    joined.trim_matches(|c| matches!(c, '"' | '\'' | '“' | '”' | '‘' | '’' | ':')).to_string()
}

/// The window as the brain reads it: one line per element, with the label to name it by and where it is. When the
/// window holds more than `limit` characters of elements, what is in view goes before what is scrolled out of it, and
/// within that what you fill in and switch goes first, then buttons, then rows, links and plain text last.
pub fn describe(app: &str, window: Option<&str>, elements: &[Element], limit: usize) -> String {
    let mut lines =
        vec![format!("App: {app}{}", window.filter(|w| !w.is_empty()).map(|w| format!(" — window \"{w}\"")).unwrap_or_default())];
    lines.push(
        "Elements (role \"label\" [value] @ x,y). Name an element by its label in control_ui; add role or index when labels repeat.".into(),
    );
    let budget = limit.saturating_sub(lines.join("\n").chars().count());
    let rendered: Vec<String> = elements.iter().map(describe_line).collect();
    let tiers: Vec<u8> = elements.iter().map(shown_tier).collect();
    let chosen = shown_lines(&rendered.iter().map(|l| l.chars().count()).collect::<Vec<_>>(), &tiers, budget);
    lines.extend(chosen.iter().map(|&i| rendered[i].clone()));
    if chosen.len() < elements.len() {
        lines.push(format!("… {} more elements not shown (scroll, or use a search field).", elements.len() - chosen.len()));
    }
    if elements.is_empty() {
        lines.push("(no elements could be read; the window may still be loading)".into());
    }
    lines.join("\n")
}

fn describe_line(e: &Element) -> String {
    let mut line = format!("- {} \"{}\"", e.role, e.label);
    if e.secure {
        line.push_str(" [password field]");
    } else if let Some(v) = e.value.as_deref().filter(|v| !v.is_empty()) {
        line.push_str(&format!(" [{}]", v.chars().take(80).collect::<String>()));
    }
    if !e.enabled {
        line.push_str(" (disabled)");
    }
    if e.focused {
        line.push_str(" (focused)");
    }
    if !e.visible {
        line.push_str(" (off screen)");
    }
    line.push_str(&format!(" @ {},{}", e.center_x().round() as i64, e.center_y().round() as i64));
    line
}

pub fn shown_tier(e: &Element) -> u8 {
    (if e.focused { 0 } else { tier(&e.role) }) + if e.visible { 0 } else { 4 }
}

/// 0 what you fill in and switch, 1 buttons and tabs, 2 rows and menu items, 3 links and plain text.
pub fn tier(role: &str) -> u8 {
    match role {
        "field" | "search" | "textarea" | "combobox" | "password" | "checkbox" | "switch" | "toggle" | "radio" | "popup" | "menubutton"
        | "slider" | "stepper" | "date" | "color" => 0,
        "button" | "tab" | "disclosure" => 1,
        "row" | "cell" | "menuitem" => 2,
        _ => 3,
    }
}

/// The indices of the lines that fit in `budget` characters: all when they fit, else the best tiers first; in order.
pub fn shown_lines(lengths: &[usize], tiers: &[u8], budget: usize) -> Vec<usize> {
    if lengths.iter().map(|l| l + 1).sum::<usize>() <= budget {
        return (0..lengths.len()).collect();
    }
    let mut order: Vec<usize> = (0..lengths.len()).collect();
    order.sort_by_key(|&i| (tiers[i], i));
    let mut used = 0;
    let mut chosen = Vec::new();
    for i in order {
        if used + lengths[i] + 1 > budget {
            continue;
        }
        used += lengths[i] + 1;
        chosen.push(i);
    }
    chosen.sort();
    chosen
}

/// Whether typed text shows up in the field afterwards: letters and digits only, so a field that formats what you
/// type still counts; with `replace` the field must hold nothing else.
pub fn typed_landed(text: &str, value: &str, replace: bool) -> bool {
    let keep = |s: &str| s.to_lowercase().chars().filter(|c| c.is_alphanumeric()).collect::<String>();
    let wanted = keep(text);
    if wanted.is_empty() {
        return true;
    }
    let now = keep(value);
    if replace {
        now == wanted
    } else {
        now.contains(&wanted)
    }
}

/// How one step reads in the plan the user approves ("Click “Save”", "Type “coffee filters” in “Search”").
pub fn step_summary(step: &Step) -> String {
    let target = || {
        step.element
            .as_ref()
            .map(|e| format!("“{e}”"))
            .or_else(|| step.x.zip(step.y).map(|(x, y)| format!("the point {},{}", x.round() as i64, y.round() as i64)))
            .unwrap_or_default()
    };
    match step.action {
        Action::Click => format!("Click {}", target()),
        Action::DoubleClick => format!("Double-click {}", target()),
        Action::RightClick => format!("Right-click {}", target()),
        Action::Hover => format!("Point at {}", target()),
        Action::Type => {
            let typed = step.text.clone().unwrap_or_default();
            let shown: String = typed.chars().take(60).collect();
            let more = if typed.chars().count() > 60 { "…" } else { "" };
            match &step.element {
                Some(e) => format!("Type “{shown}{more}” in “{e}”"),
                None => format!("Type “{shown}{more}”"),
            }
        }
        Action::Key => format!("Press {}", step.keys.clone().unwrap_or_default()),
        Action::Scroll => format!("Scroll {}", step.direction.clone().unwrap_or_default()),
        Action::Open => step.url.as_ref().map(|u| format!("Open {u}")).unwrap_or_else(|| "Bring the app to the front".into()),
        Action::Wait => format!("Wait {} s", step.seconds.unwrap_or(1.0)),
        Action::Drag => {
            let to = step
                .to_element
                .as_ref()
                .map(|e| format!("“{e}”"))
                .or_else(|| step.to_x.zip(step.to_y).map(|(x, y)| format!("{},{}", x.round() as i64, y.round() as i64)))
                .unwrap_or_default();
            format!("Drag {} to {to}", target())
        }
    }
}

/// How an entire `control_ui` batch reads on a plan card ("Edge: Click “Search” → Type “coffee filters” in “Search”").
pub fn batch_summary(app: &str, steps: &[Step]) -> String {
    let name = app.trim();
    let label = if name.is_empty() { "Front app" } else { name };
    if steps.is_empty() {
        return label.to_string();
    }
    let joined = steps.iter().map(step_summary).collect::<Vec<_>>().join(" → ");
    format!("{label}: {joined}")
}

/// Validates an already-parsed slice of steps for `app` (re-checked right before execution).
pub fn validate_steps(app: &str, parsed: &[Step]) -> Vec<String> {
    let mut out = Vec::new();
    let name = app.trim();
    if !name.is_empty() && is_blocked_app(name) {
        out.push(format!("Nook does not control {name} with mouse and keyboard: it holds passwords, runs commands or is Nook itself."));
    }
    if parsed.is_empty() {
        out.push("There are no steps.".to_string());
    }
    if parsed.len() > MAX_STEPS {
        out.push(format!("At most {MAX_STEPS} steps at a time."));
    }
    for (i, step) in parsed.iter().enumerate() {
        out.extend(step_problems(step).into_iter().map(|p| format!("Step {}: {p}", i + 1)));
    }
    out
}

/// Human-readable state value for checkboxes, switches, radio buttons and value-bearing controls.
pub fn state_text(role: &str, toggle_state: Option<i32>, value: Option<&str>) -> Option<String> {
    if matches!(role, "checkbox" | "switch" | "toggle" | "radio") {
        if let Some(state) = toggle_state {
            return Some(
                match state {
                    0 => "off",
                    1 => "on",
                    _ => "mixed",
                }
                .to_string(),
            );
        }
    }
    value.map(str::trim).filter(|v| !v.is_empty()).map(str::to_string)
}

/// Fewer than [`FEW_CONTROLS`] interactive controls suggests an owner-drawn window where OCR fallback helps.
pub fn needs_seen_text(elements: &[Element]) -> bool {
    elements.iter().filter(|e| tier(&e.role) <= 1).count() < FEW_CONTROLS
}

/// JSON schema for the `read_ui` tool.
pub fn read_ui_schema() -> Value {
    serde_json::json!({
        "type": "object",
        "properties": {
            "app": {
                "type": "string",
                "description": "Name of the app, e.g. \"Settings\", \"Edge\" or \"Notepad\". Without it: the app in front."
            }
        },
        "required": []
    })
}

/// JSON schema for the `control_ui` tool.
pub fn control_ui_schema() -> Value {
    let actions: Vec<&str> = Action::ALL.iter().map(|a| a.name()).collect();
    serde_json::json!({
        "type": "object",
        "properties": {
            "app": {
                "type": "string",
                "description": "Name of the app to control, e.g. \"Settings\", \"Edge\" or \"Notepad\"."
            },
            "steps": {
                "type": "array",
                "description": format!("The steps, in order (at most {MAX_STEPS})."),
                "items": {
                    "type": "object",
                    "properties": {
                        "action": {
                            "type": "string",
                            "enum": actions,
                            "description": "click, double_click, right_click, type (into the focused field, or into element), key (a key or shortcut), scroll, open (the app, or a Windows Settings page with url), wait, drag (press on element or x,y, move to to_element or to_x,to_y, release), hover (move the mouse over element or x,y without clicking)."
                        },
                        "element": {"type": "string", "description": "Label of the element exactly as read_ui shows it."},
                        "role": {"type": "string", "description": "Role from read_ui to tell same labels apart: button, checkbox, switch, radio, popup, field, row, menuitem, tab…"},
                        "index": {"type": "integer", "description": "Which of several matching elements, counted from the top left; 1 is the first."},
                        "x": {"type": "number", "description": "Screen x of a point to click (from read_ui), only when the element has no label."},
                        "y": {"type": "number", "description": "Screen y of that point."},
                        "text": {"type": "string", "description": "For type: the text."},
                        "replace": {"type": "boolean", "description": "For type: replace what is in the field."},
                        "keys": {"type": "string", "description": "For key: e.g. \"enter\", \"escape\", \"tab\", \"down\", \"ctrl+f\", \"ctrl+shift+n\"."},
                        "direction": {"type": "string", "enum": ["up", "down", "left", "right"], "description": "For scroll."},
                        "amount": {"type": "integer", "description": format!("For scroll: lines (1–{MAX_SCROLL}).")},
                        "url": {"type": "string", "description": "For open in Windows Settings: a page, e.g. ms-settings:bluetooth or ms-settings:display."},
                        "seconds": {"type": "number", "description": format!("For wait: seconds (at most {}).", MAX_WAIT as i64)},
                        "to_element": {"type": "string", "description": "For drag: label of the element to drop on, exactly as read_ui shows it."},
                        "to_x": {"type": "number", "description": "For drag: screen x where it ends."},
                        "to_y": {"type": "number", "description": "For drag: screen y where it ends."}
                    },
                    "required": ["action"]
                }
            }
        },
        "required": ["app", "steps"]
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn steps_read_every_field_and_drop_unknown_actions() {
        let raw = json!([
            {"action": "click", "element": "Save", "role": "Button", "index": 2},
            {"action": "Double-Click", "x": "10,5", "y": 20},
            {"action": "fly"},
            {"action": "type", "text": "  hi", "replace": "true", "element": "Search"},
            {"action": "key", "key": "ctrl+f"},
            {"action": "drag", "element": "a.txt", "to": "Folder"}
        ]);
        let s = steps(&raw);
        assert_eq!(s.len(), 5);
        assert_eq!(s[0].role.as_deref(), Some("button"));
        assert_eq!(s[0].index, Some(2));
        assert_eq!(s[1].action, Action::DoubleClick);
        assert_eq!(s[1].x, Some(10.5));
        assert_eq!(s[2].text.as_deref(), Some("  hi"));
        assert!(s[2].replace);
        assert_eq!(s[3].keys.as_deref(), Some("ctrl+f"));
        assert_eq!(s[4].to_element.as_deref(), Some("Folder"));
        // A JSON string of steps is read too.
        assert_eq!(steps(&json!("[{\"action\":\"wait\"}]")).len(), 1);
    }

    #[test]
    fn problems_name_what_is_wrong() {
        let p = problems("Notepad", &json!([{"action": "click"}, {"action": "nope"}, {"action": "key", "keys": "win+l"}]));
        assert!(p.iter().any(|l| l.contains("1 step(s) have no valid action")));
        assert!(p.iter().any(|l| l.starts_with("Step 1:") && l.contains("name the element")));
        assert!(p.iter().any(|l| l.contains("locking the screen")));
        assert!(problems("Windows Terminal", &json!([{"action": "wait"}])).iter().any(|l| l.contains("does not control")));
        assert!(problems("Notepad", &json!([{"action": "open", "url": "https://x.nl"}])).iter().any(|l| l.contains("ms-settings")));
        assert!(problems("Settings", &json!([{"action": "open", "url": "ms-settings:bluetooth"}])).is_empty());
        assert!(problems("Notepad", &json!([{"action": "scroll", "direction": "sideways"}])).iter().any(|l| l.contains("direction")));
        assert!(problems("Notepad", &json!([])).iter().any(|l| l.contains("no steps")));
    }

    #[test]
    fn keys_parse_the_way_models_write_them() {
        let c = parse_keys("Ctrl+Shift+N").unwrap();
        assert_eq!(c.modifiers, vec![Modifier::Ctrl, Modifier::Shift]);
        assert_eq!(c.code, 'N' as u16);
        assert_eq!(parse_keys("cmd+f").unwrap().modifiers, vec![Modifier::Ctrl]);
        assert_eq!(parse_keys("Return").unwrap().key, "enter");
        assert_eq!(parse_keys("page down").unwrap().code, 0x22);
        assert_eq!(parse_keys("alt+F4").unwrap().code, 0x73);
        assert_eq!(parse_keys("ctrl++").unwrap().key, "=");
        assert!(parse_keys("hyper+q").is_none());
        assert!(parse_keys("").is_none());
    }

    #[test]
    fn forbidden_keys_leave_the_app_or_the_session() {
        for keys in ["win+l", "ctrl+alt+delete", "ctrl+shift+esc", "win+r", "alt+tab", "win+ctrl+right", "win+d"] {
            assert!(forbidden(&parse_keys(keys).unwrap()).is_some(), "{keys}");
        }
        for keys in ["ctrl+f", "enter", "alt+f4", "ctrl+shift+tab", "shift+delete"] {
            assert!(forbidden(&parse_keys(keys).unwrap()).is_none(), "{keys}");
        }
    }

    fn el(role: &str, label: &str, x: f64, y: f64) -> Element {
        Element::new(role, label, x, y, 40.0, 20.0)
    }

    #[test]
    fn find_prefers_exact_then_prefix_then_contains() {
        let all = vec![el("button", "Save as…", 0.0, 0.0), el("button", "Save", 50.0, 0.0), el("text", "Autosave is on", 100.0, 0.0)];
        assert_eq!(find("save", None, None, &all).unwrap().label, "Save");
        assert_eq!(find("Save as", None, None, &all).unwrap().label, "Save as…");
        assert_eq!(find("autosave", None, None, &all).unwrap().label, "Autosave is on");
    }

    #[test]
    fn find_asks_for_an_index_when_labels_repeat() {
        let all = vec![el("button", "Add", 0.0, 50.0), el("button", "Add", 0.0, 10.0), el("text", "Add", 300.0, 300.0)];
        assert_eq!(find("Add", None, None, &all), Err(MatchError::Ambiguous("Add".into(), 2)));
        assert_eq!(find("Add", None, Some(1), &all).unwrap().y, 10.0);
        assert_eq!(find("Add", Some("text"), None, &all).unwrap().x, 300.0);
        assert!(matches!(find("Add", None, Some(5), &all), Err(MatchError::NotFound(_))));
        // A row and its text at the same spot are one control.
        let same = vec![el("row", "Inbox", 0.0, 0.0), el("cell", "Inbox", 0.0, 0.0)];
        assert!(find("Inbox", None, None, &same).is_ok());
        assert!(matches!(find("Nothing", None, None, &same), Err(MatchError::NotFound(_))));
        assert_eq!(find("Inbox", Some("field"), None, &same), Err(MatchError::NotFound("Inbox".into())));
    }

    #[test]
    fn describe_lists_fields_before_links_when_space_runs_out() {
        let mut off = el("button", "Buy", 0.0, 900.0);
        off.visible = false;
        let mut field = el("field", "Search", 0.0, 10.0);
        field.value = Some("filters".into());
        let mut pass = el("password", "Password", 0.0, 40.0);
        pass.secure = true;
        pass.value = Some("secret".into());
        let elements = vec![el("link", "Home", 0.0, 0.0), field, pass, off];
        let full = describe("Edge", Some("Shop"), &elements, 9_000);
        assert!(full.starts_with("App: Edge — window \"Shop\""));
        assert!(full.contains("- field \"Search\" [filters] @ 20,20"));
        assert!(full.contains("[password field]") && !full.contains("secret"));
        assert!(full.contains("(off screen)"));
        let short = describe("Edge", None, &elements, 220);
        assert!(short.contains("Search") && !short.contains("Home"));
        assert!(short.contains("more elements not shown"));
        assert!(describe("Edge", None, &[], 9_000).contains("no elements could be read"));
    }

    #[test]
    fn typed_text_counts_when_the_field_formats_it() {
        assert!(typed_landed("06-1234", "06 1234", false));
        assert!(typed_landed("abc", "xx abc yy", false));
        assert!(!typed_landed("abc", "xx abc", true));
        assert!(typed_landed("", "anything", true));
    }

    #[test]
    fn roles_from_ui_automation_control_types() {
        assert_eq!(role_for_control_type(50000, false, false), "button");
        assert_eq!(role_for_control_type(50002, false, true), "switch");
        assert_eq!(role_for_control_type(50004, true, false), "password");
        assert_eq!(role_for_control_type(50004, false, false), "field");
        assert_eq!(role_for_control_type(50033, false, false), "other");
    }

    #[test]
    fn summaries_read_like_the_plan() {
        let s = steps(
            &json!([{"action": "type", "element": "Search", "text": "coffee filters"}, {"action": "click", "x": 10, "y": 20}, {"action": "key", "keys": "enter"}]),
        );
        assert_eq!(step_summary(&s[0]), "Type “coffee filters” in “Search”");
        assert_eq!(step_summary(&s[1]), "Click the point 10,20");
        assert_eq!(step_summary(&s[2]), "Press enter");
    }

    #[test]
    fn blocked_apps_hold_passwords_or_run_commands() {
        assert!(is_blocked("PowerShell.exe"));
        assert!(is_blocked("KeePassXC"));
        assert!(is_blocked("My Password Safe"));
        assert!(is_blocked_app("Ghostty"));
        assert!(is_blocked_app("Passwort-Manager"));
        assert!(is_blocked_app("Gestionnaire de mot de passe"));
        assert!(is_blocked_app("Gestor de contraseñas"));
        assert!(is_blocked_app("Sleutelhanger"));
        assert!(is_blocked_app("Keychain Access"));
        assert!(!is_blocked("Notepad"));
        assert!(!is_blocked_app("Microsoft Edge"));
        assert_eq!(rounds(&["a".into(), "go".into(), "go".into()], "go"), 2);
    }

    #[test]
    fn batch_summary_and_validate_steps_work_together() {
        let s = steps(&json!([
            {"action": "click", "element": "Search"},
            {"action": "type", "element": "Search", "text": "coffee filters"}
        ]));
        assert_eq!(batch_summary("Edge", &s), "Edge: Click “Search” → Type “coffee filters” in “Search”");
        assert_eq!(batch_summary("", &s), "Front app: Click “Search” → Type “coffee filters” in “Search”");
        assert_eq!(batch_summary("Edge", &[]), "Edge");

        assert!(validate_steps("Edge", &s).is_empty());
        assert!(validate_steps("PowerShell", &s).iter().any(|p| p.contains("does not control")));
        assert!(validate_steps("Edge", &[]).iter().any(|p| p.contains("no steps")));
        let mut wait = Step::new(Action::Wait);
        wait.seconds = Some(1.0);
        let too_many = vec![wait; MAX_STEPS + 1];
        assert!(validate_steps("Edge", &too_many).iter().any(|p| p.contains("At most")));
    }

    #[test]
    fn state_text_and_seen_text_threshold() {
        assert_eq!(state_text("checkbox", Some(0), None).as_deref(), Some("off"));
        assert_eq!(state_text("switch", Some(1), None).as_deref(), Some("on"));
        assert_eq!(state_text("toggle", Some(2), None).as_deref(), Some("mixed"));
        assert_eq!(state_text("field", None, Some("  hello  ")).as_deref(), Some("hello"));
        assert_eq!(state_text("field", None, Some("   ")), None);

        let few = vec![el("text", "Title", 0.0, 0.0), el("button", "OK", 10.0, 10.0), el("button", "Cancel", 60.0, 10.0)];
        assert!(needs_seen_text(&few));
        let enough = vec![el("field", "Search", 0.0, 0.0), el("button", "OK", 10.0, 10.0), el("button", "Cancel", 60.0, 10.0)];
        assert!(!needs_seen_text(&enough));
    }

    #[test]
    fn tool_schemas_list_expected_fields_and_actions() {
        let read = read_ui_schema();
        assert!(read["properties"]["app"].is_object());
        assert_eq!(read["required"], json!([]));

        let control = control_ui_schema();
        assert_eq!(control["required"], json!(["app", "steps"]));
        let enum_values: Vec<&str> = control["properties"]["steps"]["items"]["properties"]["action"]["enum"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|v| v.as_str())
            .collect();
        let all_names: Vec<&str> = Action::ALL.iter().map(|a| a.name()).collect();
        assert_eq!(enum_values, all_names);
    }
}
