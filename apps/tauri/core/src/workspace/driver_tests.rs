//! Sessions over Codex's app-server and ACP, end to end through the manager, against fake agents: small shell scripts
//! that speak the protocol on stdin/stdout the way the real ones do (as the manager's own test fakes `claude`).

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use uuid::Uuid;

use crate::agents::models::ApprovalDecision;
use crate::workspace::manager::{Hooks, Manager, ManagerEvent};
use crate::workspace::models::*;

fn script(dir: &Path, name: &str, body: &str) -> String {
    let path = dir.join(name);
    std::fs::write(&path, body).unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    path.to_string_lossy().into_owned()
}

struct World {
    root: PathBuf,
    project: PathBuf,
    manager: Arc<Manager>,
    events: Arc<Mutex<Vec<String>>>,
}

impl World {
    fn new(exe: impl Fn(&Path) -> String) -> Self {
        let root = std::env::temp_dir().join(format!("nook-driver-{}", Uuid::new_v4()));
        let project = root.join("project");
        std::fs::create_dir_all(&project).unwrap();
        let exe = exe(&root);
        let events = Arc::new(Mutex::new(Vec::<String>::new()));
        let log = events.clone();
        let hooks = Hooks {
            executable: Box::new(move |_| Some(exe.clone())),
            account_environment: Box::new(|_| BTreeMap::new()),
            bridge: Box::new(|| None),
            worktree_root: Box::new(|| "/tmp".into()),
            auto_resume_limited: Box::new(|| false),
        };
        let manager = Manager::new(root.join("store"), hooks, tokio::runtime::Handle::current(), move |e| {
            let name = match e {
                ManagerEvent::Approval(a) => format!("approval:{}:{}", a.tool, a.command),
                ManagerEvent::TurnFinished(r, last) => format!("finished:{:?}:{last}", r.status),
                _ => return,
            };
            log.lock().unwrap().push(name);
        });
        Self { root, project, manager, events }
    }

    fn start(&self, provider: RunProvider) -> Uuid {
        let config = NewRunConfig {
            task: "Ruim op".into(),
            provider,
            profile_id: provider.id().into(),
            project_path: self.project.to_string_lossy().into(),
            ..Default::default()
        };
        self.manager.start(config, false).unwrap()
    }

    async fn approval(&self) -> crate::agents::models::AgentApproval {
        for _ in 0..400 {
            if let Some(a) = self.manager.pending_approvals().first() {
                return a.clone();
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        panic!("no approval; timeline: {:?}", self.manager.timeline(self.manager.runs()[0].id));
    }

    fn log(&self, name: &str) -> String {
        std::fs::read_to_string(self.root.join(name)).unwrap_or_default()
    }
}

impl Drop for World {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

const CODEX: &str = r#"#!/bin/sh
here="$(dirname "$0")"
if [ "$1" = "app-server" ] && [ "$2" = "--help" ]; then echo "Run the app server"; exit 0; fi
[ "$1" = "app-server" ] || { echo "unexpected: $*" >&2; exit 9; }
read init
echo '{"id":1,"result":{"userAgent":"fake"}}'
read initialized
read thread
echo "$thread" >> "$here/codex.log"
echo '{"id":2,"result":{"thread":{"id":"th-1"},"model":"gpt-fake"}}'
read turn
echo "$turn" >> "$here/codex.log"
echo '{"id":3,"result":{"turn":{"id":"t-1"}}}'
read mcp_status
echo '{"id":4,"result":{"data":[]}}'
echo '{"method":"turn/started","params":{"turn":{"id":"t-1"}}}'
case "$thread" in
*thread/resume*)
  echo '{"method":"item/completed","params":{"item":{"id":"m2","type":"agentMessage","text":"Verder."}}}'
  echo '{"method":"turn/completed","params":{"turn":{"id":"t-1","status":"completed"}}}'
  read rest
  exit 0 ;;
esac
echo '{"method":"item/agentMessage/delta","params":{"itemId":"m1","delta":"Ik "}}'
echo '{"method":"item/started","params":{"item":{"id":"c1","type":"commandExecution","command":"rm -rf build"}}}'
echo '{"id":"r1","method":"item/commandExecution/requestApproval","params":{"itemId":"c1","command":"rm -rf build","cwd":"/w"}}'
read answer
echo "$answer" | grep -q '"decision":"accept"' || exit 3
echo '{"method":"item/completed","params":{"item":{"id":"c1","type":"commandExecution","command":"rm -rf build","status":"completed","exitCode":0,"aggregatedOutput":"weg"}}}'
echo '{"method":"item/completed","params":{"item":{"id":"f1","type":"fileChange","status":"completed","changes":[{"path":"'"$PWD"'/a.txt","kind":{"type":"add"}}]}}}'
echo '{"method":"item/completed","params":{"item":{"id":"m1","type":"agentMessage","text":"Ik kijk even."}}}'
echo '{"method":"thread/tokenUsage/updated","params":{"tokenUsage":{"last":{"inputTokens":10,"cachedInputTokens":4,"outputTokens":3},"modelContextWindow":1000}}}'
echo '{"method":"turn/completed","params":{"turn":{"id":"t-1","status":"completed","durationMs":1200}}}'
read rest
"#;

#[tokio::test(flavor = "multi_thread")]
async fn codex_app_server_approval_and_resume() {
    let w = World::new(|dir| script(dir, "codex", CODEX));
    let id = w.start(RunProvider::Codex);
    let approval = w.approval().await;
    assert_eq!(approval.tool, "shell");
    assert!(approval.danger, "rm -rf is risky");
    assert!(approval.can_always, "Codex can allow for the session");
    assert_eq!(w.manager.run(id).unwrap().status, RunStatus::WaitingApproval);
    w.manager.decide(id, "codex-r1", ApprovalDecision::Allow).unwrap();
    assert!(w.manager.wait_idle(id, Duration::from_secs(10)).await);
    let run = w.manager.run(id).unwrap();
    assert_eq!(run.status, RunStatus::Completed, "{:?}", w.manager.timeline(id));
    assert_eq!(run.provider_session_id.as_deref(), Some("th-1"));
    assert_eq!(run.resolved_model.as_deref(), Some("gpt-fake"));
    assert_eq!(run.usage.context_window, Some(1000));
    assert_eq!(run.usage.cache_read_tokens, Some(4));
    let timeline = w.manager.timeline(id);
    assert!(timeline.iter().any(|e| e.kind == EventKind::Assistant && e.text == "Ik kijk even."));
    assert!(timeline.iter().any(|e| e.kind == EventKind::Tool && e.output.as_deref() == Some("weg") && e.state == Some(EventState::Done)));
    assert!(timeline.iter().any(|e| e.kind == EventKind::FileChange && e.text == "a.txt"));
    assert!(timeline.iter().any(|e| e.kind == EventKind::Approval && e.state == Some(EventState::Allowed)));
    assert!(w.log("codex.log").contains(r#""method":"thread/start""#));
    assert!(w.log("codex.log").contains(r#""approvalPolicy":"on-request""#));

    // The next message goes on in the same thread.
    w.manager.send(id, "Ga verder").unwrap();
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert!(w.manager.wait_idle(id, Duration::from_secs(10)).await);
    assert_eq!(w.manager.run(id).unwrap().status, RunStatus::Completed);
    assert!(w.log("codex.log").contains(r#""method":"thread/resume""#));
    assert!(w.log("codex.log").contains(r#""threadId":"th-1""#));
    assert_eq!(w.manager.last_answer(id), "Verder.");
    assert!(w.events.lock().unwrap().iter().any(|e| e.starts_with("finished:Completed:Verder.")));
}

#[tokio::test(flavor = "multi_thread")]
async fn codex_without_app_server_uses_exec() {
    let w = World::new(|dir| {
        script(
            dir,
            "codex",
            r#"#!/bin/sh
[ "$1" = "app-server" ] && { echo "error: unrecognized subcommand 'app-server'" >&2; exit 2; }
[ "$1" = "exec" ] || exit 9
echo '{"type":"thread.started","thread_id":"ex-1"}'
echo '{"type":"item.completed","item":{"id":"i1","type":"agent_message","text":"Via exec."}}'
echo '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
"#,
        )
    });
    let id = w.start(RunProvider::Codex);
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert!(w.manager.wait_idle(id, Duration::from_secs(10)).await);
    let run = w.manager.run(id).unwrap();
    assert_eq!(run.status, RunStatus::Completed, "{:?}", w.manager.timeline(id));
    assert_eq!(run.provider_session_id.as_deref(), Some("ex-1"));
    let timeline = w.manager.timeline(id);
    assert!(timeline.iter().any(|e| e.kind == EventKind::System && e.text.contains("codex exec")));
    assert_eq!(w.manager.last_answer(id), "Via exec.");
}

const ACP: &str = r#"#!/bin/sh
here="$(dirname "$0")"
echo "$*" > "$here/args.log"
read init
echo '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":false,"sessionCapabilities":{"resume":{}}}}}'
read open
echo "$open" >> "$here/acp.log"
echo '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"acp-1"}}'
read prompt
echo "$prompt" >> "$here/acp.log"
case "$open" in
*session/resume*)
  echo '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"acp-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Weer hier."}}}}'
  echo '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}'
  read rest
  exit 0 ;;
esac
echo '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"acp-1","update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"Even denken"}}}}'
echo '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"acp-1","update":{"sessionUpdate":"tool_call","toolCallId":"c1","title":"rm -rf build","kind":"execute","status":"pending","rawInput":{"command":"rm -rf build"}}}}'
echo '{"jsonrpc":"2.0","id":0,"method":"session/request_permission","params":{"sessionId":"acp-1","toolCall":{"toolCallId":"c1"},"options":[{"optionId":"ok","kind":"allow_once","name":"Allow"},{"optionId":"no","kind":"reject_once","name":"Reject"}]}}'
read answer
echo "$answer" | grep -q '"optionId":"ok"' || exit 3
echo '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"acp-1","update":{"sessionUpdate":"tool_call_update","toolCallId":"c1","status":"completed","content":[{"type":"content","content":{"type":"text","text":"weg"}}]}}}'
echo '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"acp-1","update":{"sessionUpdate":"tool_call","toolCallId":"c2","title":"Edit a.txt","kind":"edit","status":"completed","content":[{"type":"diff","path":"'"$PWD"'/a.txt","oldText":"a","newText":"b"}]}}}'
echo '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"acp-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Klaar."}}}}'
echo '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"acp-1","update":{"sessionUpdate":"usage_update","used":1200,"size":200000}}}'
echo '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn","usage":{"inputTokens":20,"outputTokens":5}}}'
read rest
"#;

#[tokio::test(flavor = "multi_thread")]
async fn acp_agent_approval_and_resume() {
    let w = World::new(|dir| script(dir, "grok", ACP));
    let id = w.start(RunProvider::Grok);
    let approval = w.approval().await;
    assert_eq!((approval.tool.as_str(), approval.agent_name.as_str()), ("shell", "Grok"));
    assert!(approval.danger);
    assert!(!approval.can_always, "the agent offered no allow_always");
    w.manager.decide(id, "acp-0", ApprovalDecision::Allow).unwrap();
    assert!(w.manager.wait_idle(id, Duration::from_secs(10)).await);
    let run = w.manager.run(id).unwrap();
    assert_eq!(run.status, RunStatus::Completed, "{:?}", w.manager.timeline(id));
    assert_eq!(run.provider_session_id.as_deref(), Some("acp-1"));
    assert_eq!((run.usage.input_tokens, run.usage.context_window, run.usage.context_tokens), (Some(20), Some(200_000), Some(1200)));
    assert_eq!(w.log("args.log").trim(), "agent stdio");
    let timeline = w.manager.timeline(id);
    assert!(timeline.iter().any(|e| e.kind == EventKind::Thinking && e.text == "Even denken"));
    assert!(timeline.iter().any(|e| e.kind == EventKind::Tool && e.output.as_deref() == Some("weg")));
    assert!(timeline.iter().any(|e| e.kind == EventKind::FileChange && e.text == "a.txt"));
    assert_eq!(w.manager.last_answer(id), "Klaar.");
    assert!(w.log("acp.log").contains(r#""method":"session/new""#));

    w.manager.send(id, "Nog iets").unwrap();
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert!(w.manager.wait_idle(id, Duration::from_secs(10)).await);
    assert!(w.log("acp.log").contains(r#""method":"session/resume""#), "{}", w.log("acp.log"));
    assert_eq!(w.manager.last_answer(id), "Weer hier.");
}

#[tokio::test(flavor = "multi_thread")]
async fn acp_stop_cancels_the_turn() {
    let w = World::new(|dir| {
        script(
            dir,
            "opencode",
            r#"#!/bin/sh
read init
echo '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{}}}'
read open
echo '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"s-9"}}'
read prompt
echo '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s-9","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Bezig"}}}}'
read cancel
echo "$cancel" | grep -q 'session/cancel' || exit 4
echo '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"cancelled"}}'
read rest
"#,
        )
    });
    let id = w.start(RunProvider::Opencode);
    for _ in 0..400 {
        if w.manager.timeline(id).iter().any(|e| e.text.contains("Bezig")) {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    w.manager.stop(id);
    assert!(w.manager.wait_idle(id, Duration::from_secs(10)).await);
    assert_eq!(w.manager.run(id).unwrap().status, RunStatus::Stopped, "{:?}", w.manager.timeline(id));
}

#[tokio::test(flavor = "multi_thread")]
async fn antigravity_signs_in_sets_its_mode_and_carries_on() {
    let w = World::new(|dir| {
        script(
            dir,
            "agy_acp_server",
            r#"#!/bin/sh
here="$(dirname "$0")"
echo "home=$GEMINI_HOME files=$AGY_ACP_FORCE_FILE_STORAGE args=$*" > "$here/env.log"
echo 'Open the following link to authenticate the ACP server: https://example.com/not-google'
read init
echo '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentInfo":{"name":"antigravity-acp"},"agentCapabilities":{},"authMethods":[{"id":"oauth-personal","name":"Google"}]}}'
read auth
echo "$auth" | grep -q 'oauth-personal' || exit 5
echo '{"jsonrpc":"2.0","id":2,"result":{}}'
read open
echo '{"jsonrpc":"2.0","id":3,"result":{"sessionId":"ag-1","modes":{"currentModeId":"default","availableModes":[{"id":"default"},{"id":"auto_edit"},{"id":"plan"},{"id":"yolo"}]}}}'
read mode
echo "$mode" >> "$here/ag.log"
echo '{"jsonrpc":"2.0","id":4,"result":{}}'
read prompt
echo '{"jsonrpc":"2.0","id":5,"result":{"stopReason":"end_turn"}}'
read again
echo "$again" >> "$here/ag.log"
echo '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"ag-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Gedaan."}}}}'
echo '{"jsonrpc":"2.0","id":6,"result":{"stopReason":"end_turn"}}'
read rest
"#,
        )
    });
    *crate::workspace::antigravity::SUPPORT_OVERRIDE.lock().unwrap() = Some(w.root.join("support"));
    let id = w.start(RunProvider::Antigravity);
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert!(w.manager.wait_idle(id, Duration::from_secs(10)).await);
    let run = w.manager.run(id).unwrap();
    assert_eq!(run.status, RunStatus::Completed, "{:?}", w.manager.timeline(id));
    let ag = w.log("ag.log");
    assert!(ag.contains(r#""modeId":"auto_edit""#), "{ag}");
    assert!(ag.contains("stopped without replying"), "{ag}");
    let env = w.log("env.log");
    assert!(env.contains("support/providers/antigravity/antigravity") && env.contains("files=1 args="), "{env}");
    assert!(w.root.join("support/providers/antigravity/antigravity/antigravity-acp/settings.json").exists());
    let timeline = w.manager.timeline(id);
    assert!(timeline.iter().any(|e| e.kind == EventKind::System && e.text.starts_with("Antigravity")));
    assert!(!timeline.iter().any(|e| e.text.contains("sign in")), "a link that is not Google's sign-in page is ignored");
    assert_eq!(w.manager.last_answer(id), "Gedaan.");
}

const PI_RPC: &str = r#"#!/bin/sh
here="$(dirname "$0")"
echo "perm=$NOOK_PI_PERMISSION args=$*" >> "$here/pi.log"
read state
echo "$state" >> "$here/pi.log"
echo '{"id":"nook-state","type":"response","command":"get_state","success":true,"data":{"model":{"provider":"openrouter","id":"deepseek/deepseek-v4-flash","contextWindow":1048576},"sessionFile":"/tmp/pi-session-1.jsonl"}}'
read prompt
echo "$prompt" >> "$here/pi.log"
echo '{"type":"response","command":"prompt","success":true}'
echo '{"type":"agent_start"}'
case "$*" in
*--session*)
  echo '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"Verder."}}'
  echo '{"type":"message_update","assistantMessageEvent":{"type":"text_end","content":"Verder."}}'
  echo '{"type":"message_end","message":{"role":"assistant","usage":{"input":10,"output":4,"cacheRead":50,"cacheWrite":0,"totalTokens":64,"cost":{"total":0.001}},"stopReason":"stop"}}'
  echo '{"type":"agent_end"}'
  echo '{"type":"agent_settled"}'
  read rest
  exit 0 ;;
esac
echo '{"type":"message_start","message":{"role":"user","content":[{"type":"text","text":"Ruim op"}]}}'
echo '{"type":"message_update","assistantMessageEvent":{"type":"thinking_delta","delta":"Even "}}'
echo '{"type":"message_update","assistantMessageEvent":{"type":"thinking_delta","delta":"kijken"}}'
echo '{"type":"message_update","assistantMessageEvent":{"type":"thinking_end","content":"Even kijken"}}'
echo '{"type":"tool_execution_start","toolCallId":"t1","toolName":"bash","args":{"command":"rm -rf build"}}'
echo '{"type":"extension_ui_request","id":"c-1","method":"confirm","title":"Allow bash?","message":"{\"command\":\"rm -rf build\"}"}'
read answer
echo "$answer" | grep -q '"confirmed":true' || exit 3
echo '{"type":"tool_execution_update","toolCallId":"t1","partialResult":{"content":[{"type":"text","text":"bezig..."}]}}'
echo '{"type":"tool_execution_end","toolCallId":"t1","toolName":"bash","result":{"content":[{"type":"text","text":"weg"}]},"isError":false}'
echo '{"type":"tool_execution_start","toolCallId":"t2","toolName":"edit","args":{"path":"'"$PWD"'/a.txt"}}'
echo '{"type":"tool_execution_end","toolCallId":"t2","toolName":"edit","result":{"content":[{"type":"text","text":"ok"}]},"isError":false}'
echo '{"type":"extension_ui_request","id":"d-1","method":"select","title":"Target","message":"Pick env","options":["staging","prod"]}'
read dialog
echo "$dialog" | grep -q '"value":"prod"' || exit 4
echo '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"Klaar."}}'
echo '{"type":"message_update","assistantMessageEvent":{"type":"text_end","content":"Klaar."}}'
echo '{"type":"message_end","message":{"role":"assistant","usage":{"input":120,"output":30,"cacheRead":0,"cacheWrite":0,"totalTokens":150,"cost":{"total":0.0025}},"stopReason":"stop"}}'
echo '{"type":"agent_end"}'
echo '{"type":"agent_settled"}'
read rest
"#;

#[tokio::test(flavor = "multi_thread")]
async fn pi_rpc_approval_dialog_file_change_and_resume() {
    let w = World::new(|dir| script(dir, "pi", PI_RPC));
    let id = w.start(RunProvider::Pi);
    let approval = w.approval().await;
    assert_eq!((approval.tool.as_str(), approval.agent_name.as_str()), ("bash", "Pi"));
    assert!(!approval.can_always, "Pi confirm has no always option");
    w.manager.decide(id, "c-1", ApprovalDecision::Allow).unwrap();

    // Wait for the select dialog question.
    let mut asked = false;
    for _ in 0..400 {
        if w.manager.pending_questions().iter().any(|q| q.id.ends_with(":pidialog-d-1")) {
            asked = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(asked, "expected Pi select dialog question; timeline: {:?}", w.manager.timeline(id));
    w.manager.answer_question(id, "pidialog-d-1", &[vec!["prod".into()]]).unwrap();

    assert!(w.manager.wait_idle(id, Duration::from_secs(10)).await);
    let run = w.manager.run(id).unwrap();
    assert_eq!(run.status, RunStatus::Completed, "{:?}", w.manager.timeline(id));
    assert_eq!(run.provider_session_id.as_deref(), Some("/tmp/pi-session-1.jsonl"));
    assert_eq!(run.resolved_model.as_deref(), Some("openrouter/deepseek/deepseek-v4-flash"));
    assert_eq!(
        (run.usage.input_tokens, run.usage.output_tokens, run.usage.context_tokens, run.usage.context_window),
        (Some(120), Some(30), Some(150), Some(1_048_576))
    );
    assert!(run.usage.reported_cost_usd.unwrap() > 0.0);
    let timeline = w.manager.timeline(id);
    assert!(timeline.iter().any(|e| e.kind == EventKind::Thinking && e.text == "Even kijken"));
    assert!(timeline.iter().any(|e| e.kind == EventKind::Tool && e.output.as_deref() == Some("weg")));
    assert!(timeline.iter().any(|e| e.kind == EventKind::FileChange && e.text == "a.txt"));
    assert_eq!(w.manager.last_answer(id), "Klaar.");
    let log = w.log("pi.log");
    assert!(log.contains("perm=acceptEdits"), "{log}");
    assert!(log.contains("--mode rpc") && log.contains("--extension"), "{log}");

    // Second turn resumes using --session /tmp/pi-session-1.jsonl.
    w.manager.send(id, "Nog iets").unwrap();
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert!(w.manager.wait_idle(id, Duration::from_secs(10)).await);
    assert!(w.log("pi.log").contains("--session /tmp/pi-session-1.jsonl"), "{}", w.log("pi.log"));
    assert_eq!(w.manager.last_answer(id), "Verder.");
}

#[tokio::test(flavor = "multi_thread")]
async fn pi_rpc_steer_receipt_and_stop() {
    let w = World::new(|dir| {
        script(
            dir,
            "pi",
            r#"#!/bin/sh
read state
echo '{"id":"nook-state","type":"response","command":"get_state","success":true,"data":{"sessionFile":"/tmp/pi-steer.jsonl"}}'
read prompt
echo '{"type":"response","command":"prompt","success":true}'
echo '{"type":"agent_start"}'
echo '{"type":"message_start","message":{"role":"user","content":[{"type":"text","text":"Ruim op"}]}}'
echo '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"Bezig"}}'
read steer
echo "$steer" | grep -q '"streamingBehavior":"steer"' || exit 5
echo '{"type":"message_start","message":{"role":"user","content":[{"type":"text","text":"Bijsturen"}]}}'
read abort
echo "$abort" | grep -q '"type":"abort"' || exit 6
echo '{"type":"message_end","message":{"role":"assistant","usage":{"input":5,"output":1,"totalTokens":6},"stopReason":"error","errorMessage":"This operation was aborted"}}'
echo '{"type":"agent_end"}'
echo '{"type":"agent_settled","aborted":true}'
read rest
"#,
        )
    });
    let id = w.start(RunProvider::Pi);
    for _ in 0..400 {
        if w.manager.timeline(id).iter().any(|e| e.text.contains("Bezig")) {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(w.manager.steer(id, "Bijsturen"));
    for _ in 0..400 {
        if w.manager.timeline(id).iter().any(|e| e.tool.as_deref() == Some("steer") && e.state == Some(EventState::Done)) {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(
        w.manager.timeline(id).iter().any(|e| e.tool.as_deref() == Some("steer") && e.state == Some(EventState::Done)),
        "expected steer receipt to flip Done; timeline: {:?}",
        w.manager.timeline(id)
    );
    w.manager.stop(id);
    assert!(w.manager.wait_idle(id, Duration::from_secs(10)).await);
    assert_eq!(w.manager.run(id).unwrap().status, RunStatus::Stopped, "{:?}", w.manager.timeline(id));
}
