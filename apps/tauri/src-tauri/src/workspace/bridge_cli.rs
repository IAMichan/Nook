//! `nook --mcp` (of `~/.nook/nook-mcp`): de MCP-server op stdin/stdout die een agent Nooks werkruimte geeft
//! (`WorkspaceBridgeScript` op de Mac). Hij beantwoordt `initialize` en `tools/list` zelf en geeft elke tool-aanroep
//! door aan de draaiende Nook over de lokale verbinding `bridge` (alleen voor de huidige gebruiker). Nook beslist; dit
//! programma voert niets zelf uit. Elke aanroep krijgt een eigen verbinding: sluit de agent af, dan gaat die dicht en
//! trekt Nook een openstaande vraag in.

use std::io::{BufRead, Write};
use std::sync::{Arc, Mutex};

use nook_core::agents::ipc;
use nook_core::workspace::bridge::{call_response, handle_rpc, RpcAction, ToolResult};
use serde_json::{json, Value};

/// Draait tot stdin sluit.
pub fn run(args: &[String]) -> i32 {
    // Alleen een korte naam ([a-z0-9_-]): die komt in de vraag aan jou terecht.
    let agent = args
        .iter()
        .position(|a| a == "--agent")
        .and_then(|i| args.get(i + 1))
        .filter(|a| {
            let mut c = a.chars();
            c.next().is_some_and(|f| f.is_ascii_lowercase() || f.is_ascii_digit())
                && a.len() <= 32
                && c.all(|x| x.is_ascii_lowercase() || x.is_ascii_digit() || x == '_' || x == '-')
        })
        .cloned()
        .unwrap_or_else(|| "agent".into());
    let cwd = std::env::current_dir().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default();
    let mut env = serde_json::Map::new();
    for key in ["NOOK_RUN_ID", "CLAUDE_PROJECT_DIR", "CODEX_HOME", "CLAUDE_CONFIG_DIR"] {
        if let Ok(v) = std::env::var(key) {
            env.insert(key.into(), Value::String(v));
        }
    }
    let out = Arc::new(Mutex::new(std::io::stdout()));
    let address = ipc::address("bridge");
    let mut workers = vec![];
    for line in std::io::stdin().lock().lines() {
        let Ok(line) = line else { break };
        if line.trim().is_empty() {
            continue;
        }
        let Ok(message) = serde_json::from_str::<Value>(&line) else {
            write(&out, &json!({"jsonrpc": "2.0", "id": null, "error": {"code": -32700, "message": "Parse error"}}));
            continue;
        };
        match handle_rpc(&message) {
            RpcAction::Ignore => {}
            RpcAction::Reply(mut reply) => {
                // Een schermafbeelding van de browser kan Nook hier (nog) niet maken: die tool biedt hij niet aan.
                if let Some(tools) = reply.pointer_mut("/result/tools").and_then(Value::as_array_mut) {
                    tools.retain(|t| t.get("name").and_then(Value::as_str) != Some("browser_screenshot"));
                }
                write(&out, &reply)
            }
            RpcAction::Call { id, .. } => {
                // Een aanroep kan lang op jouw OK wachten: in een eigen draad, zodat andere berichten doorgaan.
                let envelope = json!({"agent": agent, "cwd": cwd, "env": env, "message": message}).to_string() + "\n";
                let (out, address) = (out.clone(), address.clone());
                workers.push(std::thread::spawn(move || {
                    let reply = ipc::send_line(&address, &envelope, true)
                        .filter(|r| !r.trim().is_empty())
                        .and_then(|r| serde_json::from_str::<Value>(r.trim()).ok());
                    let reply = reply.unwrap_or_else(|| {
                        call_response(&id, &ToolResult::error("Nook is not running, so its workspace tools are not available right now."))
                    });
                    write(&out, &reply);
                }));
            }
        }
    }
    for w in workers {
        let _ = w.join();
    }
    0
}

fn write(out: &Mutex<std::io::Stdout>, value: &Value) {
    let mut o = out.lock().unwrap_or_else(|e| e.into_inner());
    let _ = writeln!(o, "{value}");
    let _ = o.flush();
}
