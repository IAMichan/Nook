//! UI control and takeover tools (`read_ui`, `control_ui`, `wait_for_user`, `list_app_menu`, `app_menu_command`) — BR-29.
//!
//! Wires the pure planning/safety policy from `nook_core::brain::{ui_control, takeover, app_menu}` to the platform
//! `ScreenReader` (`WindowsUiScreen` on Windows), enforcing blocked apps, password-field refusal, card/SSN refusal,
//! forbidden shortcuts, 3rd-repeat stops, point-of-no-return checkpoints, and fresh `read_ui` snapshots after actions.

use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use nook_core::brain::takeover::{
    self, GateDecision, RepeatTracker, Window as TakeoverWindow, CONTROL_TOOL, LIST_MENU_TOOL, MENU_TOOL, READ_TOOL, WAIT_TOOL,
};
use nook_core::brain::{app_menu, ui_control, LoopTool};
use nook_core::i18n::{tr, trf};
use nook_core::platform::{MenuCommandOutcome, RunningApp, ScreenReader, SystemControl};
use nook_core::services::fuzzy;
use serde_json::{json, Value};
use tauri::Manager;

use super::{text, ToolCtx, ToolSource};
use crate::services::Services;

pub struct UiControl;

static SESSION_TRACKER: OnceLock<Mutex<RepeatTracker>> = OnceLock::new();

fn tracker() -> &'static Mutex<RepeatTracker> {
    SESSION_TRACKER.get_or_init(|| Mutex::new(RepeatTracker::new()))
}

/// Resets the shared repeat/cookie-banner tracker (call when starting a fresh takeover session).
#[allow(dead_code)]
pub fn reset_tracker() {
    if let Ok(mut guard) = tracker().lock() {
        guard.reset();
    }
}

/// Evaluates takeover safety rules (hard refusals, 3rd consecutive repeat, and point-of-no-return checkpoints)
/// using live screen hit-testing (`ui_label_at`) and focus inspection (`ui_focused_label`).
#[allow(dead_code)]
pub fn gate_takeover_call(
    screen: &dyn ScreenReader,
    pid: Option<u32>,
    tool: &str,
    input: &Value,
    summary: &str,
    state: &mut RepeatTracker,
) -> GateDecision {
    let label_at = |x: f64, y: f64| screen.ui_label_at(x, y);
    let focused_label = || pid.and_then(|p| screen.ui_focused_label(p));
    let window = TakeoverWindow { cookie_banner: state.cookie_banner(), label_at: &label_at, focused_label: &focused_label };
    takeover::evaluate_gate(tool, input, summary, &window, state)
}

fn blocked_error(app: &str) -> String {
    trf(
        "Nook bestuurt {app} niet: die app bewaart wachtwoorden, voert commando's uit of is Nook zelf.",
        "Nook does not control {app}: it holds passwords, runs commands or is Nook itself.",
        &[("app", &app)],
    )
}

fn match_running<'a>(apps: &'a [RunningApp], wanted: &str) -> Option<&'a RunningApp> {
    let names: Vec<String> = apps.iter().flat_map(|a| [a.name.clone(), a.id.clone()]).collect();
    let best = fuzzy::best(wanted, &names)?;
    apps.iter().find(|a| a.name == best || a.id == best)
}

/// Resolves an app by name (or the frontmost app when `query` is empty), enforcing [`ui_control::is_blocked_app`].
/// When `launch_if_closed` is true and the platform supports opening apps, starts the app and waits briefly for it.
fn resolve_target_app(
    screen: &dyn ScreenReader,
    system: &dyn SystemControl,
    query: &str,
    launch_if_closed: bool,
    wait_step: Duration,
) -> Result<RunningApp, String> {
    let wanted = query.trim();
    if wanted.is_empty() {
        let front = screen
            .active_app()
            .ok_or_else(|| tr("Geen actieve app gevonden om te lezen.", "No active app found to read.").to_string())?;
        if ui_control::is_blocked_app(&front.name) || ui_control::is_blocked_app(&front.id) {
            return Err(blocked_error(&front.name));
        }
        return Ok(front);
    }
    if ui_control::is_blocked_app(wanted) {
        return Err(blocked_error(wanted));
    }
    let running = screen.running_apps();
    if let Some(found) = match_running(&running, wanted) {
        if ui_control::is_blocked_app(&found.name) || ui_control::is_blocked_app(&found.id) {
            return Err(blocked_error(&found.name));
        }
        return Ok(found.clone());
    }
    if !launch_if_closed {
        return Err(trf("{app} draait op dit moment niet.", "{app} is not running right now.", &[("app", &wanted)]));
    }
    system.open_app(wanted)?;
    for _ in 0..40 {
        if !wait_step.is_zero() {
            std::thread::sleep(wait_step);
        }
        let apps = screen.running_apps();
        if let Some(found) = match_running(&apps, wanted) {
            if ui_control::is_blocked_app(&found.name) || ui_control::is_blocked_app(&found.id) {
                return Err(blocked_error(&found.name));
            }
            if !wait_step.is_zero() {
                std::thread::sleep(wait_step * 2);
            }
            return Ok(found.clone());
        }
        if wait_step.is_zero() {
            break;
        }
    }
    Err(trf("{app} is niet gestart.", "{app} did not start.", &[("app", &wanted)]))
}

/// Reads the UI element tree of `app` (or frontmost app) and formats it with [`ui_control::describe`].
/// When fewer than [`ui_control::FEW_CONTROLS`] interactive controls are found, appends visible text from `read_app`
/// as an OCR / fallback supplement.
fn read_ui_for_app(
    screen: &dyn ScreenReader,
    system: &dyn SystemControl,
    query: &str,
    launch_if_closed: bool,
    wait_step: Duration,
    state: &mut RepeatTracker,
) -> Result<String, String> {
    let target = resolve_target_app(screen, system, query, launch_if_closed, wait_step)?;
    let (win_title, elements) = screen.ui_elements(target.pid)?;
    let title_opt = (!win_title.trim().is_empty()).then_some(win_title.as_str());
    let mut description = ui_control::describe(&target.name, title_opt, &elements, ui_control::DEFAULT_DESCRIBE_LIMIT);
    if ui_control::needs_seen_text(&elements) {
        if let Ok(sections) = screen.read_app(&target.name, 3_000) {
            let text_block: String = sections
                .into_iter()
                .map(|(_, body)| body.trim().to_string())
                .filter(|b| !b.is_empty())
                .collect::<Vec<_>>()
                .join("\n");
            if !text_block.is_empty() {
                let clipped: String = text_block.chars().take(2_500).collect();
                description.push_str("\n\nVisible text (fallback):\n");
                description.push_str(&clipped);
            }
        }
    }
    state.note_read(&description);
    Ok(description)
}

fn read_ui_snapshot_for_pid(screen: &dyn ScreenReader, app_name: &str, pid: u32) -> String {
    let Ok((win_title, elements)) = screen.ui_elements(pid) else {
        return String::new();
    };
    let title_opt = (!win_title.trim().is_empty()).then_some(win_title.as_str());
    ui_control::describe(app_name, title_opt, &elements, takeover::AFTER_READ_LIMIT)
}

/// Executes a validated `control_ui` batch against `screen`, re-reading elements before each named step and appending
/// a fresh `read_ui` snapshot afterwards.
fn execute_control_ui_with(
    screen: &dyn ScreenReader,
    system: &dyn SystemControl,
    input: &Value,
    can_open_apps: bool,
    settle: Duration,
    state: &mut RepeatTracker,
) -> Result<String, String> {
    let app_name = text(input, "app");
    let problems = ui_control::problems(&app_name, &input["steps"]);
    if !problems.is_empty() {
        return Err(problems.join("; "));
    }
    if let Some(reason) = takeover::refusal(CONTROL_TOOL, input) {
        return Err(reason);
    }
    state.check_and_record(CONTROL_TOOL, input).map_err(str::to_string)?;

    let steps = ui_control::steps(&input["steps"]);
    let opens_settings_url = steps
        .first()
        .is_some_and(|s| s.action == ui_control::Action::Open && s.url.as_deref().is_some_and(|u| !u.trim().is_empty()));

    let target_app = if opens_settings_url {
        match resolve_target_app(screen, system, &app_name, false, Duration::ZERO) {
            Ok(found) => Some(found),
            Err(_) => None,
        }
    } else {
        Some(resolve_target_app(screen, system, &app_name, can_open_apps, settle)?)
    };

    let mut pid = target_app.as_ref().map(|a| a.pid).unwrap_or(0);
    let mut resolved_name = target_app.as_ref().map(|a| a.name.clone()).unwrap_or_else(|| app_name.clone());
    let mut done_lines: Vec<String> = Vec::with_capacity(steps.len());

    for (idx, step) in steps.iter().enumerate() {
        // Resolve the Settings PID if step 0 opened an `ms-settings:` URL and later steps follow.
        if pid == 0 && !(step.action == ui_control::Action::Open && step.url.is_some()) {
            let found = resolve_target_app(screen, system, &app_name, can_open_apps, settle)?;
            pid = found.pid;
            resolved_name = found.name;
        }

        let needs_lookup = step.element.is_some() || step.to_element.is_some();
        let (target_el, to_el) = if needs_lookup {
            let (_, elements) = screen.ui_elements(pid)?;
            let target = match step.element.as_deref() {
                Some(label) => {
                    let found = ui_control::find(label, step.role.as_deref(), step.index, &elements)
                        .map_err(|e| format!("Step {}: {e}", idx + 1))?;
                    if !found.enabled && matches!(
                        step.action,
                        ui_control::Action::Click
                            | ui_control::Action::DoubleClick
                            | ui_control::Action::RightClick
                            | ui_control::Action::Type
                    ) {
                        return Err(format!(
                            "Step {}: {}",
                            idx + 1,
                            trf("“{label}” is uitgeschakeld.", "“{label}” is disabled.", &[("label", &found.label)])
                        ));
                    }
                    if step.action == ui_control::Action::Type && found.secure {
                        return Err(format!(
                            "Step {}: {}",
                            idx + 1,
                            tr("Nook typt nooit in wachtwoordvelden.", "Nook never types into password fields.")
                        ));
                    }
                    Some(found)
                }
                None => None,
            };
            let to = match step.to_element.as_deref() {
                Some(label) => Some(
                    ui_control::find(label, None, None, &elements).map_err(|e| format!("Step {}: {e}", idx + 1))?,
                ),
                None => None,
            };
            (target, to)
        } else {
            (None, None)
        };

        let line = screen.ui_perform(pid, step, target_el.as_ref(), to_el.as_ref())?;
        done_lines.push(line);

        if !settle.is_zero() {
            let delay = if step.action == ui_control::Action::Open { settle * 3 } else { settle };
            std::thread::sleep(delay);
        }

        if pid == 0 && step.action == ui_control::Action::Open {
            if let Ok(found) = resolve_target_app(screen, system, &app_name, false, Duration::ZERO) {
                pid = found.pid;
                resolved_name = found.name;
            }
        }
    }

    let summary = format!("{resolved_name}: {}", done_lines.join(" → "));
    let fresh = if pid != 0 { read_ui_snapshot_for_pid(screen, &resolved_name, pid) } else { String::new() };
    Ok(state.after_window(&summary, &fresh))
}

fn execute_menu_command_with(
    screen: &dyn ScreenReader,
    system: &dyn SystemControl,
    input: &Value,
    can_open_apps: bool,
    wait_step: Duration,
    state: &mut RepeatTracker,
) -> Result<String, String> {
    let name = text(input, "app");
    let path = app_menu::path(&input["path"]);
    let problems = app_menu::problems(&name, &path);
    if !problems.is_empty() {
        return Err(problems.join("; "));
    }
    if let Some(reason) = takeover::refusal(MENU_TOOL, input) {
        return Err(reason);
    }
    let target = resolve_target_app(screen, system, &name, can_open_apps, wait_step)?;
    let joined = path.join(" › ");
    match screen.click_app_menu(target.pid, &path)? {
        MenuCommandOutcome::Done => {
            if !wait_step.is_zero() {
                std::thread::sleep(wait_step);
            }
            let summary = format!("{}: {joined} done", target.name);
            let fresh = read_ui_snapshot_for_pid(screen, &target.name, target.pid);
            Ok(state.after_window(&summary, &fresh))
        }
        MenuCommandOutcome::Disabled => {
            Err(format!("{joined} is not available in {} right now (nothing selected?).", target.name))
        }
        MenuCommandOutcome::NotFound => {
            Err(format!("{} has no menu item {joined}. Check the path with {LIST_MENU_TOOL}.", target.name))
        }
    }
}

fn execute_wait_for_user(input: &Value, state: &mut RepeatTracker) -> Result<String, String> {
    let req = text(input, "request");
    if req.is_empty() {
        return Err(tr("Geef aan wat de gebruiker moet doen.", "Describe what the user needs to do.").into());
    }
    state.reset();
    Ok(trf("Wacht op gebruiker: {request}", "Waiting for user: {request}", &[("request", &req)]))
}

#[async_trait::async_trait]
impl ToolSource for UiControl {
    fn id(&self) -> &'static str {
        "screen"
    }

    fn tools(&self, ctx: &ToolCtx) -> Vec<LoopTool> {
        let Some(services) = ctx.app.try_state::<Services>() else { return vec![] };
        if !services.platform.screen.available() {
            return vec![];
        }
        let app_read = ctx.app.clone();
        let app_menu_list = ctx.app.clone();
        vec![
            LoopTool::read(
                READ_TOOL,
                "Reads the interactive elements of a desktop app's front window (buttons, fields, checkboxes, switches, tabs, rows, links) with their exact labels, values, states, and screen coordinates. Password fields are marked [password field] and their values are never read. Pass app to inspect a specific app, or omit app to inspect the app in front. Always call this before control_ui.",
                ui_control::read_ui_schema(),
                move |input| {
                    let app = app_read.clone();
                    async move {
                        let name = text(&input, "app");
                        let can_open = crate::platform::capabilities().open_apps;
                        tauri::async_runtime::spawn_blocking(move || {
                            let services = app.state::<Services>();
                            let mut state = tracker().lock().unwrap_or_else(|e| e.into_inner());
                            read_ui_for_app(
                                services.platform.screen.as_ref(),
                                services.platform.system.as_ref(),
                                &name,
                                can_open,
                                Duration::from_millis(100),
                                &mut state,
                            )
                        })
                        .await
                        .map_err(|e| nook_core::NookError(e.to_string()))?
                        .map_err(nook_core::NookError)
                    }
                },
            ),
            LoopTool::action(
                CONTROL_TOOL,
                "Controls a desktop app with mouse and keyboard (click, double_click, right_click, type, key, scroll, open, wait, drag, hover) in a small batch of steps after approval. Always call read_ui first and name elements by their exact label; use x,y only when nothing is named. Never controls password managers, terminals, admin tools, or Nook itself, and never types passwords or card numbers.",
                ui_control::control_ui_schema(),
            ),
            LoopTool::action(
                WAIT_TOOL,
                "Pauses and asks the user to complete a step Nook cannot or must not do on its own (signing in, entering a password or card number, solving a captcha, or making a choice only they can make).",
                takeover::wait_for_user_schema(),
            ),
            LoopTool::read(
                LIST_MENU_TOOL,
                "Lists the menu commands of any desktop app (File > New Folder, Edit > Copy, Format > Bold …), started first when it is closed. Use this before app_menu_command when the user asks to do something in an app that has no tool of its own. Pass a filter word (e.g. \"save\", \"export\", \"new\") to see only matching commands.",
                json!({
                    "type": "object",
                    "properties": {
                        "app": {"type": "string", "description": "Name of the app, e.g. \"Notepad\", \"Firefox\" or \"Slack\"."},
                        "filter": {"type": "string", "description": "Optional word to narrow the list, e.g. \"delete\"."}
                    },
                    "required": ["app"]
                }),
                move |input| {
                    let app = app_menu_list.clone();
                    async move {
                        let name = text(&input, "app");
                        let filter = text(&input, "filter");
                        let can_open = crate::platform::capabilities().open_apps;
                        let (process, lines) = tauri::async_runtime::spawn_blocking(move || -> Result<(String, Vec<String>), String> {
                            if name.is_empty() {
                                return Err("App name is missing.".into());
                            }
                            let services = app.state::<Services>();
                            let target = resolve_target_app(
                                services.platform.screen.as_ref(),
                                services.platform.system.as_ref(),
                                &name,
                                can_open,
                                Duration::from_millis(100),
                            )?;
                            let lines = services.platform.screen.list_app_menu(target.pid)?;
                            Ok((target.name, lines))
                        })
                        .await
                        .map_err(|e| nook_core::NookError(e.to_string()))?
                        .map_err(nook_core::NookError)?;
                        let filter = (!filter.is_empty()).then_some(filter);
                        Ok(app_menu::describe(&lines, &process, filter.as_deref(), app_menu::DEFAULT_LIMIT))
                    }
                },
            ),
            LoopTool::action(
                MENU_TOOL,
                "Runs one menu command in any desktop app, exactly as the user would pick it from the menu bar, after the user approved it. This is how Nook acts in apps without a tool of their own (export, new folder, save as, archive …). Get the exact path from list_app_menu first; select the right item in the app first when the command works on a selection.",
                json!({
                    "type": "object",
                    "properties": {
                        "app": {"type": "string", "description": "Name of the app, e.g. \"Notepad\"."},
                        "path": {"type": "array", "items": {"type": "string"}, "description": "Menu titles from the menu bar down to the item, e.g. [\"File\", \"Save As...\"], exactly as list_app_menu shows them."}
                    },
                    "required": ["app", "path"]
                }),
            ),
        ]
    }

    fn summarize(&self, tool: &str, input: &Value) -> Option<String> {
        match tool {
            CONTROL_TOOL => {
                let app = text(input, "app");
                let steps = ui_control::steps(&input["steps"]);
                Some(ui_control::batch_summary(&app, &steps))
            }
            WAIT_TOOL => {
                let req = text(input, "request");
                Some(if req.is_empty() { tr("Wachten op de gebruiker", "Wait for the user").into() } else { req })
            }
            MENU_TOOL => {
                let app = text(input, "app");
                let label = if app.is_empty() { "App" } else { &app };
                let path = app_menu::path(&input["path"]).join(" › ");
                Some(format!("{label}: {path}"))
            }
            _ => None,
        }
    }

    async fn execute(&self, ctx: &ToolCtx, tool: &str, input: &Value) -> Option<Result<String, String>> {
        match tool {
            CONTROL_TOOL => {
                let app = ctx.app.clone();
                let payload = input.clone();
                let can_open = crate::platform::capabilities().open_apps;
                let res = tauri::async_runtime::spawn_blocking(move || {
                    let services = app.state::<Services>();
                    let mut state = tracker().lock().unwrap_or_else(|e| e.into_inner());
                    execute_control_ui_with(
                        services.platform.screen.as_ref(),
                        services.platform.system.as_ref(),
                        &payload,
                        can_open,
                        Duration::from_millis(80),
                        &mut state,
                    )
                })
                .await
                .unwrap_or_else(|e| Err(e.to_string()));
                Some(res)
            }
            MENU_TOOL => {
                let app = ctx.app.clone();
                let payload = input.clone();
                let can_open = crate::platform::capabilities().open_apps;
                let res = tauri::async_runtime::spawn_blocking(move || {
                    let services = app.state::<Services>();
                    let mut state = tracker().lock().unwrap_or_else(|e| e.into_inner());
                    execute_menu_command_with(
                        services.platform.screen.as_ref(),
                        services.platform.system.as_ref(),
                        &payload,
                        can_open,
                        Duration::from_millis(100),
                        &mut state,
                    )
                })
                .await
                .unwrap_or_else(|e| Err(e.to_string()));
                Some(res)
            }
            WAIT_TOOL => {
                let mut state = tracker().lock().unwrap_or_else(|e| e.into_inner());
                Some(execute_wait_for_user(input, &mut state))
            }
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use nook_core::brain::ui_control::{Element, Step};
    use nook_core::platform::WindowText;

    struct FakeSystem {
        opened: Mutex<Vec<String>>,
    }

    impl FakeSystem {
        fn new() -> Self {
            Self { opened: Mutex::new(Vec::new()) }
        }
    }

    impl SystemControl for FakeSystem {
        fn open_app(&self, name: &str) -> Result<(), String> {
            self.opened.lock().unwrap().push(name.to_string());
            Ok(())
        }
        fn open_url(&self, _url: &str) -> Result<(), String> {
            Ok(())
        }
        fn notify(&self, _title: &str, _body: &str) {}
    }

    struct FakeScreen {
        apps: Vec<RunningApp>,
        window_title: String,
        elements: Mutex<Vec<Element>>,
        after_elements: Mutex<Option<Vec<Element>>>,
        performed: Mutex<Vec<String>>,
        label_at_value: Mutex<Option<String>>,
        focused_value: Mutex<Option<String>>,
        ocr_text: Option<String>,
    }

    impl FakeScreen {
        fn new(elements: Vec<Element>) -> Self {
            Self {
                apps: vec![
                    RunningApp { name: "Edge".into(), id: "msedge".into(), pid: 42, frontmost: true, title: "Shop".into() },
                    RunningApp {
                        name: "PowerShell".into(),
                        id: "pwsh".into(),
                        pid: 99,
                        frontmost: false,
                        title: "Admin".into(),
                    },
                ],
                window_title: "Shop".into(),
                elements: Mutex::new(elements),
                after_elements: Mutex::new(None),
                performed: Mutex::new(Vec::new()),
                label_at_value: Mutex::new(None),
                focused_value: Mutex::new(None),
                ocr_text: None,
            }
        }
    }

    impl ScreenReader for FakeScreen {
        fn available(&self) -> bool {
            true
        }
        fn frontmost(&self) -> Option<WindowText> {
            None
        }
        fn all_windows(&self) -> Vec<WindowText> {
            vec![]
        }
        fn active_app(&self) -> Option<RunningApp> {
            self.apps.iter().find(|a| a.frontmost).cloned()
        }
        fn running_apps(&self) -> Vec<RunningApp> {
            self.apps.clone()
        }
        fn read_app(&self, _query: &str, _limit: usize) -> Result<Vec<(String, String)>, String> {
            match &self.ocr_text {
                Some(t) => Ok(vec![(self.window_title.clone(), t.clone())]),
                None => Err("no text".into()),
            }
        }
        fn click_app_menu(&self, _pid: u32, path: &[String]) -> Result<MenuCommandOutcome, String> {
            self.performed.lock().unwrap().push(format!("menu:{}", path.join(">")));
            Ok(MenuCommandOutcome::Done)
        }
        fn ui_elements(&self, _pid: u32) -> Result<(String, Vec<Element>), String> {
            Ok((self.window_title.clone(), self.elements.lock().unwrap().clone()))
        }
        fn ui_perform(
            &self,
            _pid: u32,
            step: &Step,
            target: Option<&Element>,
            _to: Option<&Element>,
        ) -> Result<String, String> {
            self.performed.lock().unwrap().push(format!(
                "{}:{}",
                step.action.name(),
                target.map(|e| e.label.as_str()).unwrap_or("")
            ));
            if let Some(next) = self.after_elements.lock().unwrap().take() {
                *self.elements.lock().unwrap() = next;
            }
            Ok(ui_control::step_summary(step))
        }
        fn ui_label_at(&self, _x: f64, _y: f64) -> Option<String> {
            self.label_at_value.lock().unwrap().clone()
        }
        fn ui_focused_label(&self, _pid: u32) -> Option<String> {
            self.focused_value.lock().unwrap().clone()
        }
    }

    fn el(role: &str, label: &str, x: f64, y: f64) -> Element {
        Element::new(role, label, x, y, 80.0, 24.0)
    }

    #[test]
    fn read_ui_describes_elements_handles_ocr_fallback_and_blocks_terminals() {
        let mut screen = FakeScreen::new(vec![el("text", "Canvas heading", 0.0, 0.0), el("button", "Start", 10.0, 20.0)]);
        screen.ocr_text = Some("Drawn button text".into());
        let sys = FakeSystem::new();
        let mut state = RepeatTracker::new();

        let output = read_ui_for_app(&screen, &sys, "Edge", false, Duration::ZERO, &mut state).unwrap();
        assert!(output.contains("App: Edge — window \"Shop\""));
        assert!(output.contains("- button \"Start\""));
        assert!(output.contains("Visible text (fallback):\nDrawn button text"));

        // Blocked apps are always refused.
        let blocked = read_ui_for_app(&screen, &sys, "PowerShell", false, Duration::ZERO, &mut state);
        assert!(blocked.is_err());
        assert!(read_ui_for_app(&screen, &sys, "1Password", false, Duration::ZERO, &mut state).is_err());
    }

    #[test]
    fn control_ui_executes_refuses_secure_disabled_cards_and_stops_third_repeat() {
        let mut disabled = el("button", "Submit", 10.0, 80.0);
        disabled.enabled = false;
        let mut password = el("password", "Password", 10.0, 120.0);
        password.secure = true;
        let screen = FakeScreen::new(vec![
            el("field", "Search", 10.0, 10.0),
            el("button", "Next", 10.0, 40.0),
            disabled,
            password,
        ]);
        let sys = FakeSystem::new();
        let mut state = RepeatTracker::new();

        // Disabled button is refused.
        let disabled_call = json!({"app": "Edge", "steps": [{"action": "click", "element": "Submit"}]});
        assert!(execute_control_ui_with(&screen, &sys, &disabled_call, false, Duration::ZERO, &mut state).is_err());

        // Password field typing is refused.
        let pw_call = json!({"app": "Edge", "steps": [{"action": "type", "element": "Password", "text": "hunter2"}]});
        assert!(execute_control_ui_with(&screen, &sys, &pw_call, false, Duration::ZERO, &mut state).is_err());

        // Credit card number is refused even in a normal field.
        let card_call = json!({"app": "Edge", "steps": [{"action": "type", "element": "Search", "text": "4111 1111 1111 1111"}]});
        let card_err = execute_control_ui_with(&screen, &sys, &card_call, false, Duration::ZERO, &mut state).unwrap_err();
        assert!(card_err.contains("wait_for_user"));

        // Harmless step runs twice with fresh window appended, then 3rd identical call is refused.
        let next_call = json!({"app": "Edge", "steps": [{"action": "click", "element": "Next"}]});
        let first = execute_control_ui_with(&screen, &sys, &next_call, false, Duration::ZERO, &mut state).unwrap();
        assert!(first.contains("Edge: Click “Next”"));
        assert!(first.contains("The window now (a fresh read_ui"));
        let second = execute_control_ui_with(&screen, &sys, &next_call, false, Duration::ZERO, &mut state).unwrap();
        assert!(second.contains("reads exactly as it did before"));
        let third = execute_control_ui_with(&screen, &sys, &next_call, false, Duration::ZERO, &mut state).unwrap_err();
        assert_eq!(third, takeover::REPEAT_REFUSAL);
    }

    #[test]
    fn gate_takeover_call_checks_live_point_focus_cookie_banner_and_menu() {
        let screen = FakeScreen::new(vec![el("text", "We use cookies", 0.0, 0.0), el("button", "Accept", 10.0, 30.0)]);
        let mut state = RepeatTracker::new();
        state.note_read("App: Edge\n- text \"We use cookies\" @ 10,10");

        // Plain "Accept" allowed while cookie banner is visible.
        let accept = json!({"app": "Edge", "steps": [{"action": "click", "element": "Accept"}]});
        assert_eq!(gate_takeover_call(&screen, Some(42), CONTROL_TOOL, &accept, "Click Accept", &mut state), GateDecision::Allow);

        // Coordinate click over "Buy now" triggers checkpoint via live ui_label_at.
        *screen.label_at_value.lock().unwrap() = Some("Buy now".into());
        let pt_click = json!({"app": "Edge", "steps": [{"action": "click", "x": 100, "y": 200}]});
        assert_eq!(
            gate_takeover_call(&screen, Some(42), CONTROL_TOOL, &pt_click, "Edge: Click 100,200", &mut state),
            GateDecision::Checkpoint("Edge: Click 100,200".into())
        );

        // Space while focused on "Place order" triggers checkpoint via live ui_focused_label.
        *screen.focused_value.lock().unwrap() = Some("Place order".into());
        let space = json!({"app": "Edge", "steps": [{"action": "key", "keys": "space"}]});
        assert_eq!(
            gate_takeover_call(&screen, Some(42), CONTROL_TOOL, &space, "Edge: Press space", &mut state),
            GateDecision::Checkpoint("Edge: Press space".into())
        );

        // Risky menu command checkpoints; harmless menu command allowed; blocked app refused.
        let del_menu = json!({"app": "Edge", "path": ["File", "Delete"]});
        assert!(matches!(
            gate_takeover_call(&screen, Some(42), MENU_TOOL, &del_menu, "Edge: File › Delete", &mut state),
            GateDecision::Checkpoint(_)
        ));
        let save_menu = json!({"app": "Edge", "path": ["File", "Save As"]});
        assert_eq!(
            gate_takeover_call(&screen, Some(42), MENU_TOOL, &save_menu, "Edge: File › Save As", &mut state),
            GateDecision::Allow
        );
        let blocked_menu = json!({"app": "PowerShell", "path": ["File", "Exit"]});
        assert!(matches!(
            gate_takeover_call(&screen, Some(99), MENU_TOOL, &blocked_menu, "PowerShell: File › Exit", &mut state),
            GateDecision::Refuse(_)
        ));
    }

    #[test]
    fn wait_for_user_and_menu_command_and_summaries_work() {
        let screen = FakeScreen::new(vec![el("button", "OK", 10.0, 10.0)]);
        *screen.after_elements.lock().unwrap() = Some(vec![el("button", "Done", 10.0, 10.0)]);
        let sys = FakeSystem::new();
        let mut state = RepeatTracker::new();

        assert!(execute_wait_for_user(&json!({"request": "  "}), &mut state).is_err());
        let waited = execute_wait_for_user(&json!({"request": "Sign in to your bank"}), &mut state).unwrap();
        assert!(waited.contains("Sign in to your bank"));

        let menu_out = execute_menu_command_with(
            &screen,
            &sys,
            &json!({"app": "Edge", "path": ["File", "Save As"]}),
            false,
            Duration::ZERO,
            &mut state,
        )
        .unwrap();
        assert!(menu_out.contains("Edge: File › Save As done"));
        assert!(menu_out.contains("The window now (a fresh read_ui"));

        assert_eq!(
            UiControl.summarize(CONTROL_TOOL, &json!({"app": "Edge", "steps": [{"action": "click", "element": "Next"}]})).as_deref(),
            Some("Edge: Click “Next”")
        );
        assert_eq!(
            UiControl.summarize(WAIT_TOOL, &json!({"request": "Solve the captcha"})).as_deref(),
            Some("Solve the captcha")
        );
        assert_eq!(
            UiControl.summarize(MENU_TOOL, &json!({"app": "Notepad", "path": ["File", "Save"]})).as_deref(),
            Some("Notepad: File › Save")
        );
    }
}
