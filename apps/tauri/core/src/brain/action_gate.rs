//! De poort voor acties. Een tool-aanroep van het brein is alleen een voorstel; hier wordt hij gecontroleerd voor de
//! gebruiker hem ziet, en nog eens vlak voor hij echt uitgevoerd wordt (het brein kan zich vergissen of misleid worden door
//! tekst van anderen). Elke stap van een plan houdt zijn eigen toestand bij, zodat een plan dat halverwege mislukt veilig
//! verder kan zonder stappen te herhalen.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use super::command_risk::{self, Level};
use crate::nooks::StepState;

/// Acties die zonder controle op dubbel uitvoeren herhaald mogen worden.
pub const REPEATABLE: [&str; 4] = ["media_control", "set_volume", "open_app", "open_url"];
/// Hoe lang een actie als dubbel geldt.
pub const DUPLICATE_WINDOW_SECS: i64 = 12 * 3600;

fn empty() -> &'static Map<String, Value> {
    static E: std::sync::OnceLock<Map<String, Value>> = std::sync::OnceLock::new();
    E.get_or_init(Map::new)
}

fn properties(schema: &Value) -> &Map<String, Value> {
    schema["properties"].as_object().unwrap_or(empty())
}

fn required(schema: &Value) -> Vec<String> {
    schema["required"].as_array().into_iter().flatten().filter_map(|v| v.as_str().map(str::to_string)).collect()
}

/// Maakt invoer schoon (spaties weg, "12" wordt 12) zonder de betekenis te veranderen. Onbekende velden gaan eruit:
/// de tool kan ze niet gebruiken en de gebruiker kan ze niet controleren.
pub fn normalized(input: &Value, schema: &Value) -> Value {
    let props = properties(schema);
    let mut result = Map::new();
    for (key, value) in input.as_object().unwrap_or(empty()) {
        if !props.is_empty() && !props.contains_key(key) {
            continue;
        }
        let kind = props.get(key).and_then(|p| p["type"].as_str());
        let clean = match (value, kind) {
            (Value::String(text), Some("integer")) => text.trim().parse::<i64>().map(Value::from).unwrap_or_else(|_| value.clone()),
            (Value::String(text), Some("number")) => text
                .trim()
                .replace(',', ".")
                .parse::<f64>()
                .ok()
                .and_then(serde_json::Number::from_f64)
                .map(Value::Number)
                .unwrap_or_else(|| value.clone()),
            (Value::String(text), _) => Value::String(text.trim().to_string()),
            _ => value.clone(),
        };
        result.insert(key.clone(), clean);
    }
    Value::Object(result)
}

fn label(key: &str) -> String {
    match key {
        "title" => "De titel",
        "start" => "Het begin",
        "end" => "Het einde",
        "due" => "De datum",
        "name" => "De naam",
        "message" => "Het bericht",
        "body" => "De tekst",
        "repo" => "De repository",
        "number" => "Het nummer",
        "url" => "De link",
        "to" => "De ontvanger",
        "subject" => "Het onderwerp",
        "id" => "Het id",
        "event" => "Het oordeel",
        "text" => "De tekst",
        "what" => "Wat vergeten moet worden",
        other => other,
    }
    .to_string()
}

/// Problemen met een voorgestelde actie; leeg als hij goed is. Controleert het schema en velden met een vaste betekenis
/// (datums, links, mailadressen, repositories).
pub fn problems(tool: &str, input: &Value, schema: &Value) -> Vec<String> {
    let mut problems = vec![];
    let props = properties(schema);
    for key in required(schema) {
        let missing = match input.get(&key) {
            None | Some(Value::Null) => true,
            Some(Value::String(s)) => s.trim().is_empty(),
            _ => false,
        };
        if missing {
            problems.push(format!("{} ontbreekt.", label(&key)));
        }
    }
    for (key, value) in input.as_object().unwrap_or(empty()) {
        let Some(property) = props.get(key) else {
            problems.push(format!("Onbekend veld {key}."));
            continue;
        };
        match property["type"].as_str() {
            Some("string") => {
                let Some(text) = value.as_str() else {
                    problems.push(format!("{} moet tekst zijn.", label(key)));
                    continue;
                };
                if text.chars().count() > 20_000 {
                    problems.push(format!("{} is te lang.", label(key)));
                }
                if let Some(options) = property["enum"].as_array() {
                    let options: Vec<&str> = options.iter().filter_map(|o| o.as_str()).collect();
                    let fits = options.contains(&text)
                        || options.contains(&text.to_uppercase().as_str())
                        || options.contains(&text.to_lowercase().as_str());
                    if !text.is_empty() && !fits {
                        problems.push(format!("{} moet een van deze zijn: {}.", label(key), options.join(", ")));
                    }
                }
            }
            Some("integer") => {
                let whole = value.as_i64().is_some() || value.as_f64().is_some_and(|f| f.fract() == 0.0);
                if !whole {
                    problems.push(format!("{} moet een heel getal zijn.", label(key)));
                }
            }
            Some("number") if !value.is_number() => problems.push(format!("{} moet een getal zijn.", label(key))),
            Some("boolean") if !value.is_boolean() => problems.push(format!("{} moet ja of nee zijn.", label(key))),
            _ => {}
        }
    }

    // Een commando van het brein draait nooit als het duidelijk gevaarlijk is, wat de gebruiker ook aanklikt.
    if tool == "run_command" {
        if let Some(command) = input["command"].as_str() {
            let assessment = command_risk::assess(command);
            if assessment.level == Level::Danger {
                problems.push(format!("Dit commando voer ik niet uit: {}", assessment.note));
            }
        }
    }

    // Velden met een vaste betekenis.
    let mut dates = std::collections::HashMap::new();
    for key in ["start", "end", "due", "from", "to", "date"] {
        let Some(text) = input[key].as_str().filter(|t| !t.is_empty()) else { continue };
        let iso = props.get(key).and_then(|p| p["description"].as_str()).is_some_and(|d| d.contains("ISO"));
        if !iso {
            continue;
        }
        match super::dates::parse(text) {
            Some(date) => {
                dates.insert(key, date);
            }
            None => problems.push(format!("{} is geen geldige datum ({text}).", label(key))),
        }
    }
    if let (Some(start), Some(end)) = (dates.get("start"), dates.get("end")) {
        if end <= start {
            problems.push("Het einde ligt niet na het begin.".into());
        }
    }
    if let Some(link) = input["url"].as_str().filter(|u| !u.is_empty()) {
        let ok = url::Url::parse(link).ok().is_some_and(|u| u.scheme() == "https" && u.host_str().is_some());
        if !ok {
            problems.push("Alleen https-links mogen.".into());
        }
    }
    if let Some(repo) = input["repo"].as_str().filter(|r| !r.is_empty()) {
        if !is_repository(repo) {
            problems.push("De repository moet eigenaar/naam zijn.".into());
        }
    }
    if tool == "compose_mail" || tool == "send_mail" {
        for key in ["to", "cc"] {
            let Some(text) = input[key].as_str().filter(|t| !t.is_empty()) else { continue };
            for address in text.split([',', ';']) {
                if !is_mail_address(address) {
                    problems.push(format!("{} is geen geldig mailadres.", address.trim()));
                }
            }
        }
    }
    problems
}

/// eigenaar/naam zonder "." of "..": voorkomt een sprong naar een ander API-pad.
pub fn is_repository(text: &str) -> bool {
    super::matches(rx!(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"), text) && !text.split('/').any(|p| p == "." || p == "..")
}

pub fn is_mail_address(raw: &str) -> bool {
    let mut text = raw.trim();
    if let (Some(open), Some(close)) = (text.rfind('<'), text.rfind('>')) {
        if open < close {
            text = &text[open + 1..close];
        }
    }
    super::matches(rx!(r"^[^\s@<>,;]+@[^\s@<>,;]+\.[A-Za-z]{2,}$"), text)
}

/// Eén veld van een voorstel zoals het in de plankaart staat, eventueel aan te passen.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActionField {
    pub key: String,
    pub label: String,
    pub value: String,
    pub editable: bool,
    pub multiline: bool,
}

fn short_label(key: &str) -> String {
    let known = match key {
        "title" => "Titel",
        "start" => "Begin",
        "end" => "Einde",
        "due" => "Wanneer",
        "location" => "Plaats",
        "notes" => "Notities",
        "name" => "Naam",
        "message" => "Bericht",
        "to" => "Aan",
        "cc" => "Cc",
        "subject" => "Onderwerp",
        "body" => "Tekst",
        "repo" => "Repository",
        "number" => "Nummer",
        "event" => "Oordeel",
        "method" => "Methode",
        "url" => "Link",
        "level" => "Niveau",
        "action" => "Actie",
        "id" => "Id",
        "labels" => "Labels",
        "state" => "Status",
        "text" => "Tekst",
        "what" => "Wat",
        "kind" => "Soort",
        "subject_" => "Over",
        _ => "",
    };
    if !known.is_empty() {
        return known.into();
    }
    let mut chars = key.chars();
    chars.next().map(|c| c.to_uppercase().collect::<String>() + chars.as_str()).unwrap_or_default()
}

/// Alle velden van een voorstel, in de volgorde van het schema (verplichte eerst). Volledig, niet ingekort: de gebruiker
/// moet alles kunnen controleren voor het uitgevoerd wordt.
pub fn fields(input: &Value, schema: &Value) -> Vec<ActionField> {
    let props = properties(schema);
    let required = required(schema);
    let mut rest: Vec<&String> = props.keys().filter(|k| !required.contains(k)).collect();
    rest.sort();
    let mut order: Vec<String> = required.clone();
    order.extend(rest.into_iter().cloned());
    // Velden die het schema niet kent, staan er ook (de controle meldt ze).
    for key in input.as_object().unwrap_or(empty()).keys() {
        if !order.contains(key) {
            order.push(key.clone());
        }
    }
    order
        .into_iter()
        .filter_map(|key| {
            let property = props.get(&key);
            let is_string = property.is_some_and(|p| p["type"] == "string" && p.get("enum").is_none());
            // Een verplicht tekstveld dat ontbreekt staat er leeg bij, zodat je het in de plankaart kunt invullen.
            let fillable = is_string && required.contains(&key);
            let text = match input.get(&key) {
                Some(Value::String(s)) => s.clone(),
                Some(Value::Number(n)) => n.to_string(),
                Some(Value::Bool(b)) => if *b { "ja" } else { "nee" }.into(),
                None | Some(Value::Null) if fillable => String::new(),
                None | Some(Value::Null) => return None,
                Some(other) => super::tool_loop::sorted(other).to_string(),
            };
            if text.is_empty() && !fillable {
                return None;
            }
            let multiline =
                is_string && (text.chars().count() > 60 || text.contains('\n') || ["body", "message", "notes"].contains(&key.as_str()));
            Some(ActionField { label: short_label(&key), key, value: text, editable: is_string, multiline })
        })
        .collect()
}

/// Vaste sleutel voor een actie: dezelfde tool en invoer geven dezelfde sleutel (FNV-1a, net als op de Mac).
pub fn identity(tool: &str, input: &Value) -> String {
    let data = super::tool_loop::sorted(input).to_string();
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in tool.bytes().chain(std::iter::once(b'|')).chain(data.bytes()) {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x0100_0000_01b3);
    }
    format!("{tool}:{hash:x}")
}

/// Eén stap van een plan.
#[derive(Debug, Clone, PartialEq)]
pub struct Step {
    pub tool: String,
    pub input: Value,
}

/// Wat het uitvoeren van een plan nodig heeft van de app.
#[async_trait::async_trait]
pub trait PlanExecutor: Send + Sync {
    /// Controle vlak voor het uitvoeren (tool beschikbaar, invoer goed, bron toegestaan). Leeg als het mag.
    fn check(&self, step: &Step) -> Vec<String>;
    async fn execute(&self, step: &Step) -> Result<String, String>;
    /// Wanneer deze actie eerder (binnen het venster) lukte, als tekst, of niets.
    fn executed_before(&self, key: &str) -> Option<String>;
    fn record_executed(&self, key: &str, step: &Step, result: &str);
    fn progress(&self, _states: &[StepState]) {}
    /// Leest het resultaat terug bij de dienst: ja = bevestigd, nee = niet gevonden, niets = kan niet gecontroleerd worden.
    async fn verify(&self, _step: &Step, _result: &str) -> Option<bool> {
        None
    }
}

/// Voert een goedgekeurd plan stap voor stap uit. Gelukte stappen draaien nooit opnieuw; bij de eerste fout stopt het
/// (latere stappen kunnen ervan afhangen). `force`: stappen die als dubbel gemarkeerd waren, mogen toch.
pub async fn run_plan(
    executor: &dyn PlanExecutor,
    steps: &[Step],
    initial: &[StepState],
    include: &[bool],
    force: &[usize],
) -> Vec<StepState> {
    let mut states: Vec<StepState> = if initial.len() == steps.len() { initial.to_vec() } else { vec![StepState::Pending; steps.len()] };
    let included = |i: usize| include.get(i).copied().unwrap_or(true);
    // De klik keurt elke stap goed die nog moet; dat is zichtbaar voor de eerste begint.
    for (index, state) in states.iter_mut().enumerate() {
        if included(index) && state.can_run() {
            *state = StepState::Approved;
        }
    }
    executor.progress(&states);
    let mut stopped = false;
    for (index, step) in steps.iter().enumerate() {
        match &states[index] {
            StepState::Done(_) | StepState::Verified(_) => continue,
            StepState::Duplicate(_) if !force.contains(&index) => continue,
            StepState::Skipped if !included(index) => continue,
            _ => {}
        }
        if stopped {
            states[index] = StepState::NotRun;
            continue;
        }
        if !included(index) {
            states[index] = StepState::Skipped;
            continue;
        }
        let problems = executor.check(step);
        if !problems.is_empty() {
            states[index] = StepState::Failed(problems.join(" "));
            stopped = true;
            executor.progress(&states);
            continue;
        }
        let key = identity(&step.tool, &step.input);
        if !REPEATABLE.contains(&step.tool.as_str()) && !force.contains(&index) {
            if let Some(when) = executor.executed_before(&key) {
                states[index] = StepState::Duplicate(when);
                executor.progress(&states);
                continue;
            }
        }
        states[index] = StepState::Running;
        executor.progress(&states);
        match executor.execute(step).await {
            Ok(result) => {
                executor.record_executed(&key, step, &result);
                states[index] = match executor.verify(step, &result).await {
                    Some(true) => StepState::Verified(result),
                    Some(false) => {
                        stopped = true;
                        StepState::Failed(
                            "De dienst meldde succes, maar Nook kon het resultaat daarna niet vinden. Controleer het zelf.".into(),
                        )
                    }
                    None => StepState::Done(result),
                };
            }
            Err(error) => {
                states[index] = StepState::Failed(error);
                stopped = true;
            }
        }
        executor.progress(&states);
    }
    states
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::sync::Mutex;

    fn event_schema() -> Value {
        json!({"type": "object", "properties": {
            "title": {"type": "string", "description": "Titel."},
            "start": {"type": "string", "description": "Begin, ISO 8601 met tijdzone."},
            "end": {"type": "string", "description": "Einde, ISO 8601 met tijdzone."}
        }, "required": ["title", "start"]})
    }

    #[test]
    fn validation() {
        assert!(problems("create_event", &json!({"title": "Koffie", "start": "2026-10-16T14:00:00+02:00"}), &event_schema()).is_empty());
        let bad = problems("create_event", &json!({"start": "volgende week"}), &event_schema());
        assert!(bad.contains(&"De titel ontbreekt.".to_string()));
        assert!(bad.iter().any(|p| p.contains("geen geldige datum")));
        let reversed = problems(
            "create_event",
            &json!({"title": "X", "start": "2026-10-16T14:00:00+02:00", "end": "2026-10-16T13:00:00+02:00"}),
            &event_schema(),
        );
        assert_eq!(reversed, vec!["Het einde ligt niet na het begin."]);
        let schema = json!({"type": "object", "properties": {"event": {"type": "string", "enum": ["APPROVE", "COMMENT"]}, "repo": {"type": "string"}, "number": {"type": "integer"}}, "required": ["event", "repo", "number"]});
        let review = problems("github_review_pr", &json!({"event": "MERGE_ALL", "repo": "../etc", "number": 3, "admin": true}), &schema);
        assert!(review.contains(&"Onbekend veld admin.".to_string()));
        assert!(review.iter().any(|p| p.starts_with("Het oordeel moet een van")));
        assert!(review.contains(&"De repository moet eigenaar/naam zijn.".to_string()));
        let link = json!({"type": "object", "properties": {"url": {"type": "string"}}, "required": ["url"]});
        assert_eq!(problems("open_url", &json!({"url": "file:///etc/passwd"}), &link), vec!["Alleen https-links mogen."]);
        assert!(problems("open_url", &json!({"url": "https://nook.app"}), &link).is_empty());
        let mail = json!({"properties": {"to": {"type": "string"}, "subject": {"type": "string"}}});
        assert_eq!(problems("compose_mail", &json!({"to": "lisa", "subject": "Hoi"}), &mail), vec!["lisa is geen geldig mailadres."]);
        let command = json!({"properties": {"command": {"type": "string"}}});
        assert!(problems("run_command", &json!({"command": "rm -rf ~"}), &command)[0].starts_with("Dit commando voer ik niet uit"));
    }

    #[test]
    fn mail_addresses() {
        assert!(is_mail_address("lisa@example.nl"));
        assert!(is_mail_address("Lisa de Vries <lisa@example.nl>"));
        assert!(!is_mail_address("lisa"));
        assert!(!is_mail_address("lisa@example"));
    }

    #[test]
    fn normalized_trims_and_coerces() {
        let schema = json!({"type": "object", "properties": {"number": {"type": "integer"}, "title": {"type": "string"}}});
        let result = normalized(&json!({"number": "12", "title": "  Hallo \n", "extra": "x"}), &schema);
        assert_eq!(result, json!({"number": 12, "title": "Hallo"}));
    }

    #[test]
    fn fields_show_full_content_in_schema_order() {
        let body = "Lange tekst. ".repeat(20);
        let list = fields(&json!({"start": "2026-10-16T14:00:00+02:00", "title": "Koffie", "end": body}), &event_schema());
        assert_eq!(list.iter().map(|f| f.key.as_str()).collect::<Vec<_>>(), vec!["title", "start", "end"]);
        assert_eq!(list.last().unwrap().value, body);
        assert!(list.last().unwrap().multiline && list[0].editable);
    }

    #[test]
    fn missing_required_text_field_stays_fillable() {
        let list = fields(&json!({"start": "2026-10-16T14:00:00+02:00"}), &event_schema());
        let title = list.iter().find(|f| f.key == "title").expect("titel blijft zichtbaar");
        assert!(title.value.is_empty() && title.editable);
        assert!(!list.iter().any(|f| f.key == "end"));
    }

    #[test]
    fn identity_is_stable_and_order_independent() {
        let a = identity("create_event", &json!({"title": "A", "start": "x"}));
        let b = identity("create_event", &json!({"start": "x", "title": "A"}));
        assert_eq!(a, b);
        assert_ne!(a, identity("create_event", &json!({"title": "B", "start": "x"})));
    }

    struct Fake {
        fail_title: Mutex<Option<String>>,
        executed: Mutex<Vec<String>>,
        done: Mutex<std::collections::HashMap<String, String>>,
        always_duplicate: bool,
        blocked: Option<String>,
    }

    impl Fake {
        fn new() -> Self {
            Self {
                fail_title: Mutex::new(None),
                executed: Mutex::default(),
                done: Mutex::default(),
                always_duplicate: false,
                blocked: None,
            }
        }
    }

    #[async_trait::async_trait]
    impl PlanExecutor for Fake {
        fn check(&self, step: &Step) -> Vec<String> {
            if self.blocked.as_deref() == Some(step.tool.as_str()) {
                vec!["Deze bron staat uit voor dit gesprek.".into()]
            } else {
                vec![]
            }
        }
        async fn execute(&self, step: &Step) -> Result<String, String> {
            let title = step.input["title"].as_str().unwrap_or("").to_string();
            if self.fail_title.lock().unwrap().as_deref() == Some(title.as_str()) {
                return Err("Herinneringen gaf geen antwoord.".into());
            }
            self.executed.lock().unwrap().push(title.clone());
            Ok(format!("Herinnering gemaakt: {title}"))
        }
        fn executed_before(&self, key: &str) -> Option<String> {
            if self.always_duplicate {
                return Some("vandaag 09:00".into());
            }
            self.done.lock().unwrap().get(key).cloned()
        }
        fn record_executed(&self, key: &str, _step: &Step, _result: &str) {
            self.done.lock().unwrap().insert(key.into(), "nu".into());
        }
    }

    fn steps(count: usize) -> Vec<Step> {
        (0..count).map(|i| Step { tool: "create_reminder".into(), input: json!({"title": format!("Taak {i}")}) }).collect()
    }

    #[tokio::test]
    async fn partial_failure_stops_and_retry_does_not_repeat_done_steps() {
        let fake = Fake::new();
        *fake.fail_title.lock().unwrap() = Some("Taak 1".into());
        let plan = steps(3);
        let first = run_plan(&fake, &plan, &[], &[true, true, true], &[]).await;
        assert_eq!(
            first,
            vec![
                StepState::Done("Herinnering gemaakt: Taak 0".into()),
                StepState::Failed("Herinneringen gaf geen antwoord.".into()),
                StepState::NotRun
            ]
        );
        *fake.fail_title.lock().unwrap() = None;
        let second = run_plan(&fake, &plan, &first, &[true, true, true], &[]).await;
        assert_eq!(*fake.executed.lock().unwrap(), vec!["Taak 0", "Taak 1", "Taak 2"]);
        assert!(second.iter().all(|s| s.is_finished()));
    }

    #[tokio::test]
    async fn skipped_duplicate_and_blocked_steps() {
        let fake = Fake::new();
        assert_eq!(
            run_plan(&fake, &steps(2), &[], &[false, true], &[]).await,
            vec![StepState::Skipped, StepState::Done("Herinnering gemaakt: Taak 1".into())]
        );
        let duplicate = Fake { always_duplicate: true, ..Fake::new() };
        let first = run_plan(&duplicate, &steps(1), &[], &[true], &[]).await;
        assert!(matches!(first[0], StepState::Duplicate(_)));
        assert!(duplicate.executed.lock().unwrap().is_empty());
        let forced = run_plan(&duplicate, &steps(1), &first, &[true], &[0]).await;
        assert_eq!(forced, vec![StepState::Done("Herinnering gemaakt: Taak 0".into())]);
        let repeatable =
            run_plan(&duplicate, &[Step { tool: "media_control".into(), input: json!({"action": "next"}) }], &[], &[true], &[]).await;
        assert!(matches!(repeatable[0], StepState::Done(_)));
        let blocked = Fake { blocked: Some("send_to_source".into()), ..Fake::new() };
        let plan =
            vec![Step { tool: "send_to_source".into(), input: json!({}) }, Step { tool: "create_reminder".into(), input: json!({}) }];
        let states = run_plan(&blocked, &plan, &[], &[true, true], &[]).await;
        assert_eq!(states, vec![StepState::Failed("Deze bron staat uit voor dit gesprek.".into()), StepState::NotRun]);
        assert!(blocked.executed.lock().unwrap().is_empty());
    }
}
