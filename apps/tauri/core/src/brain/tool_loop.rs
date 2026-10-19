use std::collections::{HashMap, HashSet};

use serde_json::{Map, Value};

use super::text::wrap_untrusted;
use super::{BrainPlan, LoopTool, ModelConversation, OnText, PlannedAction, ToolCallRequest, ToolKind, ToolResult};

#[derive(Debug, Clone, Copy)]
pub struct Limits {
    pub rounds: usize,
    pub calls: usize,
    /// Hoe vaak een model een actie met ongeldige invoer opnieuw mag proberen.
    pub repairs: usize,
}

impl Default for Limits {
    fn default() -> Self {
        Self { rounds: 6, calls: 12, repairs: 2 }
    }
}

/// Controleert de invoer van een actie; geeft problemen in gewone taal (leeg = goed).
pub type Validator = Box<dyn Fn(&str, &Value, &Value) -> Vec<String> + Send + Sync>;
/// Maakt de invoer schoon voor hij wordt voorgesteld (trimmen, typen omzetten, onbekende velden weg).
pub type Normalizer = Box<dyn Fn(&Value, &Value) -> Value + Send + Sync>;

pub const PROPOSED: &str = "Proposed to the user. It will only be executed after their confirmation.";
pub const ALREADY_PROPOSED: &str = "Already proposed.";
pub const ENOUGH: &str = "Enough information has been collected. Answer now without calling further tools.";

/// De ene plek waar tool-aanroepen van elk model behandeld worden, zodat ze zich allemaal hetzelfde gedragen:
/// - lees-tools draaien meteen, hun uitvoer wordt als onbetrouwbare data verpakt;
/// - acties draaien hier nooit: ze worden voorstellen, na controle van de invoer;
/// - ongeldige invoer krijgt een kans op herstel, met het precieze probleem;
/// - onbekende tools krijgen de lijst met geldige namen terug;
/// - identieke lees-aanroepen krijgen het eerste resultaat;
/// - limieten op rondes en aanroepen stoppen een model dat blijft aanroepen.
pub struct ToolRunner {
    tools: Vec<LoopTool>,
    pub limits: Limits,
    validate: Validator,
    normalize: Normalizer,
    actions: Vec<PlannedAction>,
    call_count: usize,
    repairs_used: usize,
    cache: HashMap<String, String>,
    /// Namen van aangeroepen tools, in volgorde (voor tests en diagnose).
    pub trace: Vec<String>,
}

impl ToolRunner {
    pub fn new(tools: Vec<LoopTool>) -> Self {
        Self::with(tools, Limits::default(), Box::new(|_, _, _| vec![]), Box::new(|input, _| input.clone()))
    }

    pub fn with(tools: Vec<LoopTool>, limits: Limits, validate: Validator, normalize: Normalizer) -> Self {
        Self { tools, limits, validate, normalize, actions: vec![], call_count: 0, repairs_used: 0, cache: HashMap::new(), trace: vec![] }
    }

    pub fn tools(&self) -> &[LoopTool] {
        &self.tools
    }

    pub fn replace_tools(&mut self, tools: Vec<LoopTool>) {
        self.tools = tools;
    }

    pub fn actions(&self) -> &[PlannedAction] {
        &self.actions
    }

    pub fn call_count(&self) -> usize {
        self.call_count
    }

    /// Behandelt één aanroep en geeft terug wat het model te zien krijgt.
    pub async fn handle(&mut self, name: &str, input: &Value) -> (String, bool) {
        self.call_count += 1;
        self.trace.push(name.to_string());
        if self.call_count > self.limits.calls {
            return (ENOUGH.into(), false);
        }
        let Some(tool) = self.tools.iter().find(|t| t.name == name).cloned() else {
            let mut names: Vec<&str> = self.tools.iter().map(|t| t.name.as_str()).collect();
            names.sort();
            let list = if names.is_empty() { "none".to_string() } else { names.join(", ") };
            return (format!("Unknown tool \"{name}\". Available tools: {list}."), true);
        };
        match tool.kind {
            ToolKind::Read => {
                let key = cache_key(name, input);
                if let Some(cached) = self.cache.get(&key) {
                    return (cached.clone(), false);
                }
                match (tool.run)(input.clone()).await {
                    Ok(output) => {
                        let wrapped = wrap_untrusted(&output);
                        self.cache.insert(key, wrapped.clone());
                        (wrapped, false)
                    }
                    Err(e) => (format!("Error: {e}"), true),
                }
            }
            ToolKind::Action => {
                let clean = (self.normalize)(input, &tool.schema);
                let problems = (self.validate)(name, &clean, &tool.schema);
                if !problems.is_empty() && self.repairs_used < self.limits.repairs {
                    self.repairs_used += 1;
                    return (format!("Not proposed: {}. Fix these fields and call {name} again.", problems.join("; ")), true);
                }
                // Geen herstelpogingen meer: toch voorstellen; het controlescherm toont de problemen en blokkeert uitvoeren.
                let key = cache_key(name, &clean);
                if self.actions.iter().any(|a| a.tool == name && cache_key(&a.tool, &a.input) == key) {
                    return (ALREADY_PROPOSED.into(), false);
                }
                self.actions.push(PlannedAction::new(name, clean));
                (PROPOSED.into(), false)
            }
        }
    }

    /// Voert een gesprek in rondes tot het model antwoordt zonder tools aan te roepen.
    pub async fn run(&mut self, conversation: &mut dyn ModelConversation, on_text: OnText<'_>) -> crate::Result<BrainPlan> {
        let mut final_text = String::new();
        for round in 0..self.limits.rounds {
            let before = if final_text.is_empty() { String::new() } else { format!("{final_text}\n\n") };
            let prefixed = |partial: String| {
                if let Some(cb) = on_text {
                    cb(format!("{before}{partial}"));
                }
            };
            let mut turn = conversation.next(&self.tools, Some(&prefixed)).await?;

            // Kleine modellen schrijven een tool-aanroep vaak als JSON in hun tekst in plaats van hem aan te roepen.
            if turn.calls.is_empty() && !turn.finished {
                let known: HashSet<String> = self.tools.iter().map(|t| t.name.clone()).collect();
                let (text, calls) = extract_tool_calls(&turn.text, &known);
                if !calls.is_empty() {
                    turn.text = text;
                    turn.calls = calls
                        .into_iter()
                        .enumerate()
                        .map(|(i, (name, input))| ToolCallRequest { id: format!("text-{round}-{i}"), name, input })
                        .collect();
                }
            }
            let text = turn.text.trim();
            if !text.is_empty() {
                final_text = format!("{before}{text}");
            }
            if turn.calls.is_empty() {
                break;
            }
            let mut results = Vec::new();
            for call in &turn.calls {
                let (output, is_error) = self.handle(&call.name, &call.input).await;
                results.push(ToolResult { call: call.clone(), output, is_error });
            }
            conversation.add_results(&results);
            // Alleen voorstellen deze ronde en niets meer op te zoeken: het plan is klaar.
            if results.iter().all(|r| r.output == PROPOSED || r.output == ALREADY_PROPOSED) {
                break;
            }
            if round + 2 == self.limits.rounds || self.call_count >= self.limits.calls {
                conversation.add_instruction(ENOUGH);
            }
        }
        Ok(BrainPlan { text: final_text.trim().to_string(), actions: self.actions.clone() })
    }
}

fn sorted(value: &Value) -> Value {
    match value {
        Value::Object(map) => {
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort();
            let mut out = Map::new();
            for k in keys {
                out.insert(k.clone(), sorted(&map[k]));
            }
            Value::Object(out)
        }
        Value::Array(list) => Value::Array(list.iter().map(sorted).collect()),
        other => other.clone(),
    }
}

fn cache_key(name: &str, input: &Value) -> String {
    format!("{name}:{}", sorted(input))
}

/// Haalt tool-aanroepen die als JSON in de tekst staan eruit, zoals `{"name": "list_events", "parameters": {…}}`.
/// Kan ook afgebroken JSON aan (ontbrekende sluithaak). Geeft de aanroepen en de schoongemaakte tekst.
pub fn extract_tool_calls(text: &str, known: &HashSet<String>) -> (String, Vec<(String, Value)>) {
    let mut remaining: Vec<char> = text.chars().collect();
    let mut calls = Vec::new();
    let mut offset = 0;
    while let Some(open) = remaining[offset.min(remaining.len())..].iter().position(|c| *c == '{').map(|p| p + offset) {
        let (mut depth, mut in_string, mut escaped) = (0i32, false, false);
        let mut close = None;
        for (i, c) in remaining.iter().enumerate().skip(open) {
            if in_string {
                if escaped {
                    escaped = false
                } else if *c == '\\' {
                    escaped = true
                } else if *c == '"' {
                    in_string = false
                }
                continue;
            }
            match c {
                '"' => in_string = true,
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if depth == 0 {
                        close = Some(i);
                        break;
                    }
                }
                _ => {}
            }
        }
        let mut candidate: String = match close {
            Some(end) => remaining[open..=end].iter().collect(),
            None => remaining[open..].iter().collect::<String>() + &"}".repeat(depth.max(0) as usize),
        };
        if close.is_none() && in_string {
            candidate = remaining[open..].iter().collect::<String>() + "\"" + &"}".repeat(depth.max(0) as usize);
        }
        let parsed: Option<(String, Value)> = serde_json::from_str::<Value>(&candidate).ok().and_then(|object| {
            let name = object.get("name").or_else(|| object.get("tool"))?.as_str()?.to_string();
            if !known.contains(&name) {
                return None;
            }
            let input = ["parameters", "arguments", "input"]
                .iter()
                .find_map(|k| object.get(*k).filter(|v| v.is_object()).cloned())
                .unwrap_or_else(|| Value::Object(Map::new()));
            Some((name, input))
        });
        match parsed {
            Some(call) => {
                calls.push(call);
                let end = close.map(|c| c + 1).unwrap_or(remaining.len());
                remaining.drain(open..end);
                offset = open;
            }
            None => offset = open + 1,
        }
    }
    let rest: String = remaining.into_iter().collect();
    static FENCE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let fence = FENCE.get_or_init(|| regex::Regex::new(r"```(json)?\s*```").unwrap());
    (fence.replace_all(&rest, "").trim().to_string(), calls)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::brain::ModelTurn;
    use serde_json::json;

    fn known(names: &[&str]) -> HashSet<String> {
        names.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn extracts_calls_from_text() {
        let (text, calls) = extract_tool_calls(
            "Ik kijk even.\n```json\n{\"name\": \"list_events\", \"parameters\": {\"from\": \"today\"}}\n```",
            &known(&["list_events"]),
        );
        assert_eq!(text, "Ik kijk even.");
        assert_eq!(calls, vec![("list_events".into(), json!({"from": "today"}))]);
    }

    #[test]
    fn extracts_truncated_json_and_ignores_unknown() {
        let (_, calls) = extract_tool_calls("{\"name\": \"weather\", \"arguments\": {\"city\": \"Utrecht\"}", &known(&["weather"]));
        assert_eq!(calls.len(), 1);
        let (text, calls) = extract_tool_calls("{\"name\": \"nope\"}", &known(&["weather"]));
        assert!(calls.is_empty());
        assert_eq!(text, "{\"name\": \"nope\"}");
    }

    struct Scripted {
        turns: Vec<ModelTurn>,
        results: Vec<Vec<ToolResult>>,
    }

    #[async_trait::async_trait]
    impl ModelConversation for Scripted {
        async fn next(&mut self, _tools: &[LoopTool], on_text: OnText<'_>) -> crate::Result<ModelTurn> {
            let turn = if self.turns.is_empty() { ModelTurn::default() } else { self.turns.remove(0) };
            if let Some(cb) = on_text {
                cb(turn.text.clone());
            }
            Ok(turn)
        }
        fn add_results(&mut self, results: &[ToolResult]) {
            self.results.push(results.to_vec());
        }
        fn add_instruction(&mut self, _text: &str) {}
    }

    fn call(name: &str, input: Value) -> ToolCallRequest {
        ToolCallRequest { id: name.into(), name: name.into(), input }
    }

    #[tokio::test]
    async fn reads_run_and_actions_become_proposals() {
        let tools = vec![
            LoopTool::read("weather", "", json!({}), |_| async { Ok("zon".to_string()) }),
            LoopTool::action("create_event", "", json!({})),
        ];
        let mut runner = ToolRunner::new(tools);
        let mut convo = Scripted {
            turns: vec![
                ModelTurn { text: String::new(), calls: vec![call("weather", json!({}))], finished: false },
                ModelTurn {
                    text: "Zon. Zal ik het plannen?".into(),
                    calls: vec![call("create_event", json!({"title": "Wandelen"}))],
                    finished: false,
                },
            ],
            results: vec![],
        };
        let plan = runner.run(&mut convo, None).await.unwrap();
        assert_eq!(plan.actions.len(), 1);
        assert_eq!(plan.actions[0].tool, "create_event");
        assert!(convo.results[0][0].output.contains("<tool_data>\nzon\n</tool_data>"));
        assert_eq!(convo.results[1][0].output, PROPOSED);
        assert_eq!(plan.text, "Zon. Zal ik het plannen?");
    }

    #[tokio::test]
    async fn invalid_actions_get_a_repair_and_unknown_tools_a_list() {
        let validate: Validator =
            Box::new(|_, input, _| if input.get("title").is_some() { vec![] } else { vec!["title is required".into()] });
        let mut runner = ToolRunner::with(
            vec![LoopTool::action("create_event", "", json!({}))],
            Limits::default(),
            validate,
            Box::new(|v, _| v.clone()),
        );
        let (out, err) = runner.handle("create_event", &json!({})).await;
        assert!(err && out.starts_with("Not proposed: title is required"));
        let (out, err) = runner.handle("bogus", &json!({})).await;
        assert!(err && out.contains("Available tools: create_event"));
    }
}
