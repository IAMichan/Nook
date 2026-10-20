//! Grafieken in de chat. Het brein roept `show_chart` aan; schrijft het toch code, JSON, Mermaid of een tabel, dan maakt
//! Nook daar zelf een echte grafiek van. Wie om een grafiek vraagt, wil een grafiek zien, geen code.

use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};

use super::matches;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum ChartKind {
    #[default]
    Bar,
    Line,
    Area,
    Pie,
    Point,
}

impl ChartKind {
    pub const ALL: [&'static str; 5] = ["bar", "line", "area", "pie", "point"];

    pub fn parse(raw: &str) -> Self {
        match raw.to_lowercase().as_str() {
            "line" => Self::Line,
            "area" => Self::Area,
            "pie" | "doughnut" | "donut" | "arc" => Self::Pie,
            "scatter" | "point" | "bubble" => Self::Point,
            _ => Self::Bar,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Point {
    pub label: String,
    pub value: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Series {
    pub name: String,
    pub points: Vec<Point>,
}

/// Een grafiek die Nook in de chat tekent.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatChart {
    pub id: String,
    pub title: String,
    pub kind: ChartKind,
    #[serde(default)]
    pub unit: String,
    pub series: Vec<Series>,
}

impl ChatChart {
    pub fn new(title: &str, kind: ChartKind, unit: &str, series: Vec<Series>) -> Self {
        Self { id: uuid::Uuid::new_v4().to_string(), title: title.into(), kind, unit: unit.into(), series }
    }

    /// Een grafiek uit de invoer van het model: reeksen met punten (of data), of een platte lijst met data.
    pub fn parse(input: &Value) -> Option<Self> {
        let title = input["title"].as_str().unwrap_or("");
        let kind = ChartKind::parse(input["type"].as_str().unwrap_or("bar"));
        let unit = input["unit"].as_str().unwrap_or("");
        let points = |raw: &Value| -> Vec<Point> {
            raw.as_array()
                .into_iter()
                .flatten()
                .filter_map(|item| {
                    let object = item.as_object()?;
                    let label = object.get("label").and_then(|l| l.as_str()).map(str::to_string).or_else(|| object.get("x").map(text))?;
                    let value = number(object.get("value").or_else(|| object.get("y"))?)?;
                    Some(Point { label, value })
                })
                .collect()
        };
        let mut series: Vec<Series> = input["series"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|item| {
                let list = points(item.get("points").or_else(|| item.get("data"))?);
                (!list.is_empty()).then(|| Series { name: item["name"].as_str().unwrap_or("").into(), points: list })
            })
            .collect();
        if series.is_empty() {
            let list = points(input.get("data").or_else(|| input.get("points")).unwrap_or(&Value::Null));
            if !list.is_empty() {
                series.push(Series { name: title.into(), points: list });
            }
        }
        if series.is_empty() {
            return None;
        }
        series.truncate(8);
        Some(Self::new(title, kind, unit, series))
    }

    /// Het schema van `show_chart`.
    pub fn schema() -> Value {
        let point = json!({"type": "object", "properties": {"label": {"type": "string"}, "value": {"type": "number"}}, "required": ["label", "value"]});
        let series = json!({"type": "object", "properties": {"name": {"type": "string"}, "points": {"type": "array", "items": point}}, "required": ["points"]});
        json!({"type": "object", "properties": {
            "title": {"type": "string", "description": "Short title above the chart."},
            "type": {"type": "string", "enum": ChartKind::ALL, "description": "Type of chart."},
            "unit": {"type": "string", "description": "Unit of measurement, e.g. \"€\", \"hours\", or \"%\". Optional."},
            "series": {"type": "array", "items": series, "description": "One or more data series (max 4 for lines and bars). For pie charts, exactly one series."}
        }, "required": ["title", "type", "series"]})
    }
}

fn text(value: &Value) -> String {
    match value {
        Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}

/// Een getal uit "€ 1.234,50", "12%", "3.5 uur" of gewoon 42.
pub fn number(raw: &Value) -> Option<f64> {
    match raw {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => number_text(s),
        _ => None,
    }
}

pub fn number_text(raw: &str) -> Option<f64> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    let stripped = rx!(r"\*\*|__").replace_all(trimmed, "");
    let negative = stripped.starts_with('-') || stripped.starts_with('−');
    let mut digits: String = stripped.chars().filter(|c| c.is_ascii_digit() || *c == ',' || *c == '.').collect();
    if !digits.chars().any(|c| c.is_ascii_digit()) {
        return None;
    }
    if digits.contains(',') && digits.contains('.') {
        // Het laatste scheidingsteken is de komma: 1.234,50 of 1,234.50.
        if digits.rfind(',') > digits.rfind('.') {
            digits = digits.replace('.', "").replace(',', ".");
        } else {
            digits = digits.replace(',', "");
        }
    } else if digits.contains(',') {
        digits = digits.replace(',', ".");
    } else if digits.matches('.').count() > 1 {
        digits = digits.replace('.', "");
    }
    let value: f64 = digits.parse().ok()?;
    Some(if negative { -value } else { value })
}

/// A table cell that is a number, possibly with a sign, currency or short unit around it ("€ 12,50", "568 commits",
/// "+3%"). Stricter than `number_text`: a name with digits in it, such as "nook-test-183d" or a commit hash, is not one.
pub fn table_number(cell: &str) -> Option<f64> {
    let text = rx!(r"\*\*|__|`").replace_all(cell, "").to_string();
    if !matches(rx!(r"^\s*[^\p{L}\d]{0,3}\d[\d.,\s]*[\p{L}\p{Sc}%°]*\s*$"), &text) {
        return None;
    }
    number_text(&text)
}

/// Vraagt de gebruiker om een grafiek?
pub fn wants_chart(text: &str) -> bool {
    matches(rx!(r"(?i)grafiek|diagram|\bchart|\bplot|visualis|grafisch|staafje|taartje|\bgraph"), text)
}

/// Tijdens het streamen: codeblokken die op een grafiek lijken verbergen (ook als ze nog niet af zijn).
pub fn hiding_chart_code(text: &str) -> String {
    let mut visible = rx!(r"(?i)```(json|chart|vega|vega-lite|mermaid|javascript|js|python|py|swift)?[^\n]*\n[\s\S]*?```")
        .replace_all(text, "")
        .to_string();
    if visible.matches("```").count() % 2 == 1 {
        if let Some(open) = visible.rfind("```") {
            visible.truncate(open);
        }
    }
    visible
}

fn fix_json(text: &str) -> Option<Map<String, Value>> {
    let fixed = rx!(r",\s*([}\]])").replace_all(text, "$1").to_string();
    if let Ok(Value::Object(object)) = serde_json::from_str(&fixed) {
        return Some(object);
    }
    let fixed = rx!(r"([{,]\s*)([A-Za-z_][A-Za-z0-9_]*)\s*:").replace_all(&fixed, "$1\"$2\":").replace('\'', "\"");
    match serde_json::from_str(&fixed) {
        Ok(Value::Object(object)) => Some(object),
        _ => None,
    }
}

fn from_json(object: &Map<String, Value>, title: &str) -> Option<ChatChart> {
    // Een tool-aanroep als tekst: {"name": "show_chart", "parameters": {...}}.
    if let Some(name) = object.get("name").or_else(|| object.get("tool")).and_then(|n| n.as_str()) {
        if name == "show_chart" {
            let input = ["parameters", "arguments", "input"].iter().find_map(|k| object.get(*k)).cloned().unwrap_or(json!({}));
            return ChatChart::parse(&input);
        }
    }
    // Chart.js: {"type": "bar", "data": {"labels": [...], "datasets": [{"label": ..., "data": [...]}]}}.
    if let (Some(labels), Some(sets)) =
        (object.get("data").and_then(|d| d["labels"].as_array()), object.get("data").and_then(|d| d["datasets"].as_array()))
    {
        let names: Vec<String> = labels.iter().map(text).collect();
        let series: Vec<Series> = sets
            .iter()
            .filter_map(|set| {
                let values: Vec<Option<f64>> = set["data"].as_array()?.iter().map(number).collect();
                if values.is_empty() || values.len() != names.len() || values.iter().any(Option::is_none) {
                    return None;
                }
                Some(Series {
                    name: set["label"].as_str().unwrap_or("").into(),
                    points: names.iter().zip(values).map(|(l, v)| Point { label: l.clone(), value: v.unwrap_or(0.0) }).collect(),
                })
            })
            .take(4)
            .collect();
        if series.is_empty() {
            return None;
        }
        let heading = object.get("options").and_then(|o| o["plugins"]["title"]["text"].as_str()).unwrap_or(title);
        return Some(ChatChart::new(heading, ChartKind::parse(object.get("type").and_then(|t| t.as_str()).unwrap_or("bar")), "", series));
    }
    // Vega-Lite: {"data": {"values": [...]}, "encoding": {"x": {"field": ...}, "y": {"field": ...}}, "mark": "bar"}.
    if let (Some(values), Some(encoding)) = (object.get("data").and_then(|d| d["values"].as_array()), object.get("encoding")) {
        let field = |key: &str| encoding[key]["field"].as_str();
        if let (Some(x), Some(y)) = (field("x").or_else(|| field("color")), field("y").or_else(|| field("theta"))) {
            let points: Vec<Point> = values
                .iter()
                .filter_map(|row| Some(Point { label: row.get(x).map(text).unwrap_or_default(), value: number(row.get(y)?)? }))
                .collect();
            if !points.is_empty() {
                let mark = object.get("mark").and_then(|m| m.as_str().or_else(|| m["type"].as_str())).unwrap_or("bar");
                let heading = object.get("title").and_then(|t| t.as_str()).unwrap_or(title);
                return Some(ChatChart::new(heading, ChartKind::parse(mark), "", vec![Series { name: y.into(), points }]));
            }
        }
    }
    let mut chart = ChatChart::parse(&Value::Object(object.clone()))?;
    if chart.title.is_empty() {
        chart.title = title.into();
    }
    Some(chart)
}

fn list_in(line: &str) -> Vec<String> {
    match (line.find('['), line.rfind(']')) {
        (Some(open), Some(close)) if open < close => line[open + 1..close].split(',').map(|s| s.trim().to_string()).collect(),
        _ => vec![],
    }
}

/// Mermaid: `pie` met `"Label" : 42`, of `xychart-beta` met `x-axis [a, b]` en `bar [1, 2]` / `line [...]`.
fn mermaid(body: &str, title: &str) -> Option<ChatChart> {
    let lines: Vec<&str> = body.lines().map(str::trim).collect();
    let mut heading = title.to_string();
    if let Some(line) = lines.iter().find(|l| l.starts_with("title")) {
        heading = line[5..].trim_matches(|c: char| c == ' ' || c == '"').to_string();
    } else if let Some(first) = lines.first().filter(|f| f.starts_with("pie") && f.contains("title")) {
        heading = first.rsplit("title").next().unwrap_or(title).trim_matches(|c: char| c == ' ' || c == '"').to_string();
    }
    if lines.first().is_some_and(|f| f.starts_with("pie")) {
        let points: Vec<Point> = lines[1..]
            .iter()
            .filter_map(|line| {
                let (label, value) = line.split_once(':')?;
                Some(Point { label: label.trim_matches(|c: char| c == ' ' || c == '"').into(), value: number_text(value)? })
            })
            .collect();
        if points.is_empty() {
            return None;
        }
        return Some(ChatChart::new(&heading, ChartKind::Pie, "", vec![Series { name: heading.clone(), points }]));
    }
    let axis = lines.iter().find(|l| l.starts_with("x-axis"))?;
    let labels: Vec<String> = list_in(axis).into_iter().map(|l| l.trim_matches(|c: char| c == ' ' || c == '"').to_string()).collect();
    let mut series = vec![];
    let mut kind = ChartKind::Bar;
    for line in lines.iter().filter(|l| l.starts_with("bar") || l.starts_with("line")) {
        let values: Vec<Option<f64>> = list_in(line).iter().map(|v| number_text(v)).collect();
        if values.len() != labels.len() || values.iter().any(Option::is_none) {
            continue;
        }
        if line.starts_with("line") && series.is_empty() {
            kind = ChartKind::Line;
        }
        series.push(Series {
            name: String::new(),
            points: labels.iter().zip(values).map(|(l, v)| Point { label: l.clone(), value: v.unwrap_or(0.0) }).collect(),
        });
    }
    if series.is_empty() {
        return None;
    }
    series.truncate(4);
    Some(ChatChart::new(&heading, kind, "", series))
}

/// Python, JavaScript: een lijst met labels en een even lange lijst met getallen.
fn from_lists(body: &str, title: &str) -> Option<ChatChart> {
    let lists: Vec<Vec<String>> = rx!(r"\[([^\[\]]+)\]")
        .captures_iter(body)
        .flatten()
        .map(|c| c[1].split(',').map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect())
        .collect();
    let labels = lists.iter().find(|l| l.len() >= 2 && l.iter().all(|s| s.starts_with('"') || s.starts_with('\'')))?;
    let names: Vec<String> = labels.iter().map(|l| l.trim_matches(|c| c == '"' || c == '\'').to_string()).collect();
    let series: Vec<Series> = lists
        .iter()
        .filter(|l| l.len() == names.len() && l.iter().all(|s| number_text(s).is_some()))
        .take(4)
        .map(|values| Series {
            name: String::new(),
            points: names.iter().zip(values).map(|(n, v)| Point { label: n.clone(), value: number_text(v).unwrap_or(0.0) }).collect(),
        })
        .collect();
    if series.is_empty() {
        return None;
    }
    let heading =
        rx!(r#"title\(\s*["']([^"']+)["']"#).captures(body).ok().flatten().map(|c| c[1].to_string()).unwrap_or_else(|| title.to_string());
    let kind = if body.contains("pie(") || body.contains("'pie'") || body.contains("\"pie\"") {
        ChartKind::Pie
    } else if body.contains("plot(") || body.contains("'line'") || body.contains("\"line\"") {
        ChartKind::Line
    } else {
        ChartKind::Bar
    };
    Some(ChatChart::new(&heading, kind, "", series))
}

pub fn from_code(body: &str, language: &str, title: &str) -> Option<ChatChart> {
    if language == "mermaid" || body.starts_with("pie") || body.starts_with("xychart") {
        return mermaid(body, title);
    }
    if let Some(chart) = fix_json(body).and_then(|o| from_json(&o, title)) {
        return Some(chart);
    }
    if let (Some(open), Some(close)) = (body.find('{'), body.rfind('}')) {
        if open < close {
            if let Some(chart) = fix_json(&body[open..=close]).and_then(|o| from_json(&o, title)) {
                return Some(chart);
            }
        }
    }
    from_lists(body, title)
}

/// Haalt grafieken uit codeblokken en geeft de tekst zonder die blokken terug. Lege codeblokken gaan ook weg.
pub fn extract(text: &str, title: &str) -> (String, Vec<ChatChart>) {
    let mut result = text.to_string();
    let mut charts: Vec<ChatChart> = vec![];
    let blocks: Vec<(String, String, String)> = rx!(r"```([A-Za-z0-9_+-]*)[^\n]*\n([\s\S]*?)```")
        .captures_iter(text)
        .flatten()
        .map(|c| (c[0].to_string(), c[1].to_lowercase(), c[2].trim().to_string()))
        .collect();
    for (whole, language, body) in blocks.into_iter().rev() {
        let mut remove = body.is_empty();
        if !body.is_empty() {
            if let Some(chart) = from_code(&body, &language, title) {
                charts.insert(0, chart);
                remove = true;
            }
        }
        if remove {
            if let Some(i) = result.find(&whole) {
                result.replace_range(i..i + whole.len(), "");
            }
        }
    }
    // Een los JSON-object zonder codeblok.
    if charts.is_empty() {
        if let (Some(open), Some(close)) = (result.find('{'), result.rfind('}')) {
            if open < close {
                if let Some(chart) = fix_json(&result[open..=close]).and_then(|o| from_json(&o, title)) {
                    charts.push(chart);
                    result.replace_range(open..=close, "");
                }
            }
        }
    }
    let cleaned = rx!(r"\n{3,}").replace_all(&result, "\n\n").trim().to_string();
    (cleaned, charts)
}

fn cells(line: &str) -> Vec<String> {
    line.trim().trim_matches('|').split('|').map(|c| c.trim().to_string()).collect()
}

/// Markdown-tabellen in een tekst: kop en rijen.
pub fn tables(text: &str) -> Vec<(Vec<String>, Vec<Vec<String>>)> {
    let lines: Vec<&str> = text.lines().collect();
    let mut found = vec![];
    let mut i = 0;
    while i + 1 < lines.len() {
        let separator = matches(rx!(r"^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$"), lines[i + 1]);
        if lines[i].contains('|') && separator {
            let header = cells(lines[i]);
            let mut rows = vec![];
            let mut j = i + 2;
            while j < lines.len() && lines[j].contains('|') {
                rows.push(cells(lines[j]));
                j += 1;
            }
            found.push((header, rows));
            i = j;
        } else {
            i += 1;
        }
    }
    found
}

fn looks_like_time(labels: &[String]) -> bool {
    labels.iter().all(|l| {
        matches(rx!(r"(?i)^(\d{1,2}[-/ ]\w+|\w{2,3}\.?$|\d{4}|(ma|di|wo|do|vr|za|zo|jan|feb|mrt|apr|mei|jun|jul|aug|sep|okt|nov|dec)\w*|\d{1,2}:\d{2}|week|q\d)"), l)
    })
}

/// Een tabel waarvan de eerste kolom de rijen noemt en de andere kolommen getallen zijn, wordt een grafiek.
pub fn from_table(header: &[String], rows: &[Vec<String>], title: &str) -> Option<ChatChart> {
    if rows.len() < 2 || header.len() < 2 {
        return None;
    }
    let labels: Vec<String> = rows.iter().map(|r| r.first().cloned().unwrap_or_default()).collect();
    let mut series = vec![];
    for (column, name) in header.iter().enumerate().skip(1) {
        let values: Vec<Option<f64>> = rows.iter().map(|r| r.get(column).and_then(|c| table_number(c))).collect();
        if values.iter().any(Option::is_none) {
            continue;
        }
        series.push(Series {
            name: name.clone(),
            points: labels.iter().zip(values).map(|(l, v)| Point { label: l.clone(), value: v.unwrap_or(0.0) }).collect(),
        });
    }
    if series.is_empty() {
        return None;
    }
    series.truncate(4);
    let kind = if looks_like_time(&labels) && labels.len() > 5 { ChartKind::Line } else { ChartKind::Bar };
    let sample: String = rows.iter().filter_map(|r| r.get(1).cloned()).collect();
    let unit = if sample.contains('€') {
        "€"
    } else if sample.contains('$') {
        "$"
    } else if sample.contains('%') {
        "%"
    } else {
        ""
    };
    Some(ChatChart::new(title, kind, unit, series))
}

pub fn from_markdown_table(text: &str, title: &str) -> Option<ChatChart> {
    tables(text).iter().find_map(|(h, r)| from_table(h, r, title))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_tool_input() {
        let chart = ChatChart::parse(&json!({"title": "Afspraken", "type": "line", "series": [{"name": "Week", "points": [{"label": "ma", "value": 3}, {"label": "di", "value": "4,5"}]}]})).unwrap();
        assert_eq!(chart.kind, ChartKind::Line);
        assert_eq!(chart.series[0].points[1].value, 4.5);
        let flat = ChatChart::parse(&json!({"title": "X", "data": [{"x": "a", "y": 1}]})).unwrap();
        assert_eq!(flat.series[0].name, "X");
        assert!(ChatChart::parse(&json!({"title": "leeg"})).is_none());
    }

    #[test]
    fn names_with_digits_are_not_table_numbers() {
        assert_eq!(table_number("worktrees/nook/nook-test-183d"), None);
        assert_eq!(table_number("1c58d13"), None);
        assert_eq!(table_number("568 commits"), Some(568.0));
        assert_eq!(table_number("€ 12,50"), Some(12.5));
        assert_eq!(table_number("**+3%**"), Some(3.0));
        let s = |v: &[&str]| v.iter().map(|x| x.to_string()).collect::<Vec<_>>();
        assert!(from_table(&s(&["Map", "Branch"]), &[s(&["a", "nook/test-183d"]), s(&["b", "nook/test-dd40"])], "").is_none());
        assert!(from_table(&s(&["Maand", "Omzet"]), &[s(&["jan", "10"]), s(&["feb", "20"])], "").is_some());
    }

    #[test]
    fn numbers_in_any_spelling() {
        assert_eq!(number_text("€ 1.234,50"), Some(1234.5));
        assert_eq!(number_text("1,234.50"), Some(1234.5));
        assert_eq!(number_text("12%"), Some(12.0));
        assert_eq!(number_text("-3"), Some(-3.0));
        assert_eq!(number_text("1.000.000"), Some(1_000_000.0));
        assert_eq!(number_text("geen"), None);
    }

    #[test]
    fn rescues_json_chartjs_mermaid_and_lists() {
        let (text, charts) = extract("Hier:\n```json\n{\"labels\": 1, \"type\": \"bar\", \"data\": {\"labels\": [\"ma\", \"di\"], \"datasets\": [{\"label\": \"Uren\", \"data\": [3, 4]}]}}\n```\nKlaar.", "Uren");
        assert_eq!(charts.len(), 1);
        assert_eq!(charts[0].series[0].name, "Uren");
        assert_eq!(text, "Hier:\n\nKlaar.");
        let (_, pie) = extract("```mermaid\npie title Verdeling\n\"Werk\" : 40\n\"Vrij\" : 60\n```", "x");
        assert_eq!(pie[0].kind, ChartKind::Pie);
        assert_eq!(pie[0].title, "Verdeling");
        let (_, xy) = extract("```mermaid\nxychart-beta\nx-axis [jan, feb, mrt]\nline [1, 2, 3]\n```", "Groei");
        assert_eq!(xy[0].kind, ChartKind::Line);
        let (_, py) = extract("```python\nlabels = ['a', 'b']\nvalues = [1, 2]\nplt.pie(values)\n```", "x");
        assert_eq!(py[0].kind, ChartKind::Pie);
        let (_, call) = extract("{\"name\": \"show_chart\", \"parameters\": {\"title\": \"T\", \"type\": \"bar\", \"series\": [{\"points\": [{\"label\": \"a\", \"value\": 1}]}]}}", "x");
        assert_eq!(call[0].title, "T");
        let (_, vega) = extract("```json\n{\"mark\": \"line\", \"data\": {\"values\": [{\"d\": \"ma\", \"n\": 1}]}, \"encoding\": {\"x\": {\"field\": \"d\"}, \"y\": {\"field\": \"n\"}}}\n```", "x");
        assert_eq!(vega[0].kind, ChartKind::Line);
    }

    #[test]
    fn tables_become_charts() {
        let text = "| Dag | Afspraken |\n|---|---|\n| ma | 3 |\n| di | 5 |\n| wo | € 2 |";
        let chart = from_markdown_table(text, "Week").unwrap();
        assert_eq!(chart.series[0].points.len(), 3);
        assert_eq!(chart.kind, ChartKind::Bar);
        assert!(from_markdown_table("| a | b |\n|---|---|\n| x | geen |\n| y | ook niet |", "x").is_none());
    }

    #[test]
    fn hides_chart_code_while_streaming() {
        assert_eq!(hiding_chart_code("Even tekenen\n```json\n{\"a\":"), "Even tekenen\n");
        assert_eq!(hiding_chart_code("A\n```json\n{}\n```\nB"), "A\n\nB");
        assert!(wants_chart("maak een grafiek van mijn week") && !wants_chart("hoe laat is het"));
    }
}
