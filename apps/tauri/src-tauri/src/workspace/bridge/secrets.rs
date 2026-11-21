//! Secret request bridge tool (`request_secret`, AG-11).
//!
//! Always asks the user in Nook before sharing any secret (even under Bypass rights). By default (`delivery: "file"`),
//! writes the secret to an owner-only temporary file via [`SecretFiles`] and returns only the file path so the value
//! never enters the model's conversation history. Never logs or audits the secret value.

use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, SystemTime};

use nook_core::i18n::{tr, trf};
use nook_core::workspace::bridge::{BridgeCaller, BridgeTool, Reason, ToolResult, Verdict};
use nook_core::workspace::secret_files::{
    parse_delivery, secret_account, secret_detail, secret_envelope, sign_in_url, validate_secret_name, SecretDelivery, SecretFiles,
};
use serde_json::{Map, Value};
use tauri::{AppHandle, Manager};

use super::{audit, check, note_run, refusal, workspace, Context};
use crate::state::AppState;

static SWEEP_STARTED: AtomicBool = AtomicBool::new(false);

fn ensure_sweeper() {
    if SWEEP_STARTED.swap(true, Ordering::SeqCst) {
        return;
    }
    tauri::async_runtime::spawn(async move {
        let store = SecretFiles::standard();
        loop {
            let _ = store.sweep(SystemTime::now());
            tokio::time::sleep(Duration::from_secs(3600)).await;
        }
    });
}

fn delivery_label(delivery: SecretDelivery) -> &'static str {
    match delivery {
        SecretDelivery::File => "bestand",
        SecretDelivery::Value => "waarde",
    }
}

fn caller_scope(caller: &BridgeCaller) -> String {
    match &caller.run {
        Some(id) => format!("run-{id}"),
        None => SecretFiles::folder_scope(&caller.directory),
    }
}

pub(super) async fn request_secret(
    app: &AppHandle,
    a: &Map<String, Value>,
    caller: &BridgeCaller,
    context: &Context,
) -> Result<ToolResult, String> {
    let ws = workspace(app).ok_or("Nook is not ready.")?;
    let name = validate_secret_name(a.get("name").and_then(Value::as_str))?;
    let reason = super::arg(a, "reason");
    if reason.is_empty() {
        return Err("Explain in reason why you need this secret (shown to the user).".into());
    }
    let delivery = parse_delivery(a.get("delivery"))?;
    let sign_in = sign_in_url(a.get("sign_in_url").and_then(Value::as_str));

    if let Verdict::Refuse(r) = check(app, BridgeTool::RequestSecret, caller, None) {
        return Err(refusal(r).into());
    }

    let account = secret_account(&name);
    let stored = app
        .try_state::<AppState>()
        .and_then(|s| s.secrets.read(&account))
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty());

    let title = trf(
        "{agent} vraagt om geheim {name}",
        "{agent} requests secret {name}",
        &[("agent", &caller.agent), ("name", &name)],
    );
    let detail = secret_detail(&name, reason, sign_in.as_deref());
    let note = match (stored.is_some(), delivery) {
        (true, SecretDelivery::File) => tr(
            "Dit geheim staat al in Nook bewaard (je kunt hieronder ook een nieuwe waarde plakken). De agent krijgt alleen een privébestand, nooit de waarde in het gesprek.",
            "This secret is already saved in Nook (or paste a new value below). The agent receives only a private file, never the value in chat history.",
        ),
        (true, SecretDelivery::Value) => tr(
            "Dit geheim staat al in Nook bewaard (je kunt hieronder ook een nieuwe waarde plakken). Let op: de agent vroeg om de waarde rechtstreeks.",
            "This secret is already saved in Nook (or paste a new value below). Note: the agent requested the value inline.",
        ),
        (false, SecretDelivery::File) => tr(
            "Plak de waarde hieronder om toe te staan. Nook schrijft hem naar een privébestand (alleen leesbaar voor jou) en verwijdert het na 24 uur.",
            "Paste the value below to allow. Nook writes it to a private owner-only file and deletes it automatically after 24 hours.",
        ),
        (false, SecretDelivery::Value) => tr(
            "Plak de waarde hieronder om toe te staan. Let op: de agent vroeg om de waarde rechtstreeks in zijn antwoord.",
            "Paste the value below to allow. Note: the agent requested the value inline in its tool response.",
        ),
    };

    let decision = ws
        .bridge
        .ask_secret(app, caller, BridgeTool::RequestSecret, title, detail, note.into(), &context.connection)
        .await;

    if !decision.allowed {
        audit(app, BridgeTool::RequestSecret, caller, &name, "niet toegestaan");
        return Err(refusal(Reason::Secret).into());
    }

    let value = match decision.secret {
        Some((typed, remember)) if !typed.is_empty() => {
            if remember {
                if let Some(state) = app.try_state::<AppState>() {
                    let _ = state.secrets.write(&account, &typed);
                }
            }
            typed
        }
        _ => match stored {
            Some(v) => v,
            None => {
                audit(app, BridgeTool::RequestSecret, caller, &name, "geen waarde ingevuld");
                return Err(format!(
                    "The user approved {name} without entering a value and no saved value exists in Nook. Ask the user to paste the secret in the approval card."
                ));
            }
        },
    };

    // Never log or audit `value`: only the secret's name and delivery mode.
    audit(app, BridgeTool::RequestSecret, caller, &name, delivery_label(delivery));
    note_run(app, caller, &format!("Geheim {name} gedeeld ({})", delivery_label(delivery)));

    match delivery {
        SecretDelivery::File => {
            ensure_sweeper();
            let store = SecretFiles::standard();
            let _ = store.sweep(SystemTime::now());
            let path = store
                .write(&value, &name, &caller_scope(caller))
                .map_err(|e| format!("Nook could not write the temporary secret file: {e}"))?;
            Ok(ToolResult::text(SecretFiles::instructions(&name, &path)))
        }
        SecretDelivery::Value => Ok(ToolResult::text(secret_envelope(&name, &value))),
    }
}
