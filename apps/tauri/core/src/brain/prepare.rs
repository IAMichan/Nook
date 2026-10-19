//! Alles wat het brein voor één vraag nodig heeft, voor elk model hetzelfde: de bronkeuze, Nooks eigen onderzoek
//! (zoeken met de woorden die de vraag dragen, de beste treffers volledig lezen) en de contexttekst.

use std::collections::{HashMap, HashSet};
use std::time::Duration;

use super::intent::ChatIntent;
use super::profile::ModelProfile;
use super::query_plan::{self, Kind, QueryPlan};
use super::research::{self, Terms};
use super::retrieval::{Outcome, RetrievalStep};
use super::sources::{self, prefetch, SourceScope};
use super::{ChatTurn, LoopTool, ToolKind};

/// Of het brein de vraag leest voor het onderzoek: niet bij een groet of een opdracht die niets opzoekt.
pub fn should_plan(text: &str, intent: &ChatIntent) -> bool {
    if intent.is_small_talk || (intent.wants_action && !research::is_lookup(text)) {
        return false;
    }
    text.trim().chars().count() >= 6
}

/// De lees-tools die Nook zelf kan draaien, met hun bron. Het geheugen staat al in de context.
pub fn available(tools: &[LoopTool]) -> Vec<prefetch::Available> {
    tools
        .iter()
        .filter(|t| t.kind == ToolKind::Read)
        .filter_map(|t| {
            let source = t.source.clone().or_else(|| sources::source_for_tool(&t.name))?;
            (source != sources::MEMORY && t.name != "use_source").then(|| prefetch::Available {
                name: t.name.clone(),
                source,
                required: t.required(),
                query: prefetch::Available::query_field(&t.schema),
            })
        })
        .collect()
}

/// De bronnen waaruit de planner mag kiezen, met wat Nook ermee kan.
pub fn planner_sources(
    available: &[prefetch::Available],
    scope: &SourceScope,
    active: &HashSet<String>,
    unreachable: &[(String, String)],
) -> Vec<query_plan::PlannerSource> {
    let mut ids: HashSet<String> = available.iter().map(|a| a.source.clone()).collect();
    ids.extend(unreachable.iter().map(|u| u.0.clone()));
    let order = sources::order();
    let mut list: Vec<String> = ids.into_iter().filter(|id| scope.allows(id) && !prefetch::in_context(id)).collect();
    list.sort_by_key(|id| (sources::rank(id, &order), id.clone()));
    list.into_iter()
        .map(|id| {
            let tools: Vec<&prefetch::Available> = available.iter().filter(|a| a.source == id).collect();
            let title = format!("{}{}", sources::title(&id), if active.contains(&id) { "" } else { " (cannot be read right now)" });
            query_plan::PlannerSource {
                can_search: tools.iter().any(|t| research::is_search(t)),
                can_list: tools.iter().any(|t| t.required.is_empty()),
                id,
                title,
            }
        })
        .collect()
}

/// Bronnen die eerder vragen met deze woorden beantwoordden, binnen de toegestane.
pub type Learned<'a> = &'a (dyn Fn(&[String], &HashSet<String>) -> Vec<String> + Sync);

pub struct ResearchInput<'a> {
    pub text: &'a str,
    pub history: &'a [ChatTurn],
    pub scope: &'a SourceScope,
    pub tools: &'a [LoopTool],
    /// Bronnen die nu gelezen kunnen worden.
    pub active: &'a HashSet<String>,
    pub plan: Option<&'a QueryPlan>,
    pub profile: ModelProfile,
    /// Bronnen die eerder vragen met deze woorden beantwoordden (uit het geheugen).
    pub learned: Learned<'a>,
}

#[derive(Debug, Clone, Default)]
pub struct Findings {
    pub terms: Terms,
    /// Zoekresultaten, in de gevraagde volgorde.
    pub found: Vec<String>,
    /// De beste treffers, volledig gelezen.
    pub opened: Vec<String>,
    pub sources: HashSet<String>,
}

/// Draait opzoekingen tegelijk, elk met een tijdslimiet; geeft de antwoorden in de gevraagde volgorde.
async fn run_all(
    calls: &[prefetch::Call],
    tools: &[LoopTool],
    timeout: Duration,
    limit: usize,
    shape: &(dyn Fn(&str, &str) -> String + Sync),
) -> Vec<(String, String)> {
    let runnable: Vec<(&prefetch::Call, &LoopTool)> =
        calls.iter().filter_map(|c| tools.iter().find(|t| t.name == c.tool).map(|t| (c, t))).collect();
    let futures = runnable.iter().map(|(call, tool)| async move {
        let output = tokio::time::timeout(timeout, (tool.run)(call.input.clone())).await.ok()?.ok()?;
        if output.trim().is_empty() {
            return None;
        }
        let shaped = shape(&call.tool, &output);
        let mut text: String = shaped.chars().take(limit).collect();
        if shaped.chars().count() > limit {
            text += "\n… (shortened)";
        }
        Some((call.tool.clone(), text))
    });
    futures_util::future::join_all(futures).await.into_iter().flatten().collect()
}

/// Nooks eigen onderzoek: zoekt in elke relevante bron met de woorden die de vraag dragen (overal waar het kan als de
/// vraag geen bron noemt), rangschikt wat het vindt over bronnen heen en leest de beste treffers volledig.
pub async fn research(input: &ResearchInput<'_>) -> Findings {
    let profile = input.profile;
    let roomy = profile.roomy();
    let available = available(input.tools);
    let intent = ChatIntent::detect(input.text);
    let regex_terms = research::terms(input.text, input.history);
    let terms = match input.plan {
        Some(plan) if !plan.queries.is_empty() => plan.terms(),
        Some(plan) if plan.kind == Kind::Listing => Terms::default(),
        _ => regex_terms,
    };
    let relevant = sources::router::relevant(input.text, input.scope, input.active);
    let previous = input
        .history
        .iter()
        .rev()
        .find(|t| t.from_user)
        .map(|t| sources::router::relevant(&t.text, input.scope, input.active))
        .unwrap_or_default();
    let searchable: HashSet<String> =
        available.iter().map(|a| a.source.clone()).filter(|s| input.active.contains(s) && input.scope.allows(s)).collect();
    let learned: HashSet<String> = (input.learned)(&terms.all(), &searchable).into_iter().collect();
    // De bronnen die de vraag zelf noemt ("in WhatsApp"), of die het plan koos: nooit overal anders zoeken.
    let mut named: HashSet<String> = sources::mentions(input.text).into_iter().flat_map(|(_, ids)| ids).collect();
    if let Some(plan) = input.plan {
        named.extend(plan.sources.iter().cloned());
    }
    named.retain(|s| input.scope.allows(s));
    let limit = if roomy { 12 } else { 9 };
    let (chosen, mut calls) = match input.plan {
        Some(plan) if !plan.sources.is_empty() || matches!(plan.kind, Kind::General | Kind::Chat) => {
            let mut usable = plan.clone();
            usable.sources.retain(|s| input.active.contains(s) && input.scope.allows(s));
            if plan.kind == Kind::Lookup && named.is_empty() {
                let mut extra: Vec<String> = learned.iter().filter(|s| !usable.sources.contains(s)).cloned().collect();
                extra.sort();
                usable.sources.extend(extra);
            }
            let mut chosen: HashSet<String> = usable.sources.iter().cloned().collect();
            chosen.extend(relevant.iter().filter(|s| prefetch::in_context(s)).cloned());
            (chosen, query_plan::lookups(&usable, input.text, &available, limit))
        }
        _ => {
            let base = if named.is_empty() { relevant.union(&learned).cloned().collect() } else { relevant.clone() };
            let active: HashSet<String> = input.active.iter().filter(|s| input.scope.allows(s)).cloned().collect();
            let chosen = research::sources_for(input.text, &intent, &terms, &base, &previous, &named, &available, &active);
            let calls = research::lookups(input.text, &terms, &chosen, &available, limit);
            (chosen, calls)
        }
    };
    calls.dedup_by(|a, b| a.tool == b.tool && a.input == b.input);

    // Alleen wat over de vraag gaat, bereikt het model.
    let search_limit = if profile.is_small {
        if roomy {
            2_500
        } else {
            1_800
        }
    } else {
        5_000
    };
    let shape_terms = terms.clone();
    let shape = move |tool: &str, output: &str| {
        if tool == "read_app" {
            research::focus(output, &shape_terms, search_limit)
        } else {
            research::relevant_only(output, tool, &shape_terms)
        }
    };
    let results = run_all(&calls, input.tools, Duration::from_secs(8), search_limit, &shape).await;
    let readers: HashSet<String> = input.tools.iter().map(|t| t.name.clone()).collect();
    let open_limit = if profile.is_small {
        if roomy {
            3
        } else {
            2
        }
    } else {
        4
    };
    let openers: HashMap<String, research::Opener> = research::openers(&available);
    let hits = research::to_open(&results, &terms, research::wants_content(input.text), &readers, open_limit, 2, &openers);
    let reads: Vec<prefetch::Call> =
        hits.iter().filter_map(|h| h.read.clone().map(|tool| prefetch::Call { tool, input: h.input.clone() })).collect();
    let read_limit = if profile.is_small {
        if roomy {
            4_000
        } else {
            2_500
        }
    } else {
        10_000
    };
    let read_terms = terms.clone();
    let read_shape = move |_: &str, output: &str| {
        if output.chars().count() > read_limit {
            research::focus(output, &read_terms, read_limit)
        } else {
            output.to_string()
        }
    };
    let opened = run_all(&reads, input.tools, Duration::from_secs(6), read_limit, &read_shape).await;
    Findings {
        terms,
        found: results.into_iter().map(|r| r.1).collect(),
        opened: opened.into_iter().map(|r| r.1).collect(),
        sources: chosen,
    }
}

/// "Nook searched for "offerte" in: Mail (search_mail: 3 results); …".
pub fn searched_line(steps: &[RetrievalStep], terms: &Terms) -> String {
    if steps.is_empty() {
        return String::new();
    }
    let words = terms.query(6);
    let outcomes: Vec<String> = steps
        .iter()
        .map(|s| match &s.outcome {
            Outcome::Found(n) => format!("{} ({}: {n} results)", s.source_title, s.tool),
            Outcome::Empty => format!("{} ({}: nothing found)", s.source_title, s.tool),
            Outcome::Failed(e) => format!("{} ({}: failed, {e})", s.source_title, s.tool),
            Outcome::Running => format!("{} ({})", s.source_title, s.tool),
        })
        .collect();
    let lead = if words.is_empty() { "Nook looked in: ".to_string() } else { format!("Nook searched for \"{words}\" in: ") };
    format!("{lead}{}.", outcomes.join("; "))
}

pub struct ContextParts<'a> {
    /// "Now: …" en de context van de bronnen; de eerste regel komt bovenaan, de rest onderaan.
    pub overview: &'a str,
    pub memories: &'a str,
    pub goal: &'a str,
    pub blocked: &'a [String],
    pub searched: &'a str,
    pub evidence: &'a str,
    pub findings: &'a Findings,
}

/// De context voor het brein. Wat gevonden is, komt eerst: als de context te lang is, wijkt het algemene overzicht, niet
/// de documenten die de vraag beantwoorden.
pub fn build_context(parts: &ContextParts<'_>) -> String {
    let (first, rest) = match parts.overview.split_once('\n') {
        Some((a, b)) => (a, Some(b)),
        None => (parts.overview, None),
    };
    let mut context = first.to_string();
    if !parts.memories.is_empty() {
        context += &format!("\n\n{}", parts.memories);
    }
    if !parts.goal.is_empty() {
        context += &format!("\n\nWhat the user wants (Nook's reading of the question): {}", parts.goal);
    }
    if !parts.blocked.is_empty() {
        context += &format!(
            "\n\nThe user asks about a source Nook cannot read right now: {}. Say this plainly at the start of the answer, with how to fix it. Never guess what is in that source and never answer yes or no about it from other sources.",
            parts.blocked.join("; ")
        );
    }
    let findings = parts.findings;
    if !findings.found.is_empty() || !findings.opened.is_empty() || !parts.searched.is_empty() {
        context +=
            &format!("\n\nLooked up for this question (use what is really about the question; ignore the rest):\n{}", parts.searched);
        if !parts.evidence.is_empty() {
            context += &format!("\n\n{}", parts.evidence);
        }
        if !findings.opened.is_empty() {
            context += &format!("\n\nRead in full (the best matches):\n{}", findings.opened.join("\n\n"));
        }
        if !findings.found.is_empty() {
            context += &format!("\n\nSearch results:\n{}", findings.found.join("\n\n"));
        }
    }
    if let Some(rest) = rest.filter(|r| !r.trim().is_empty()) {
        context += &format!("\n\n{rest}");
    }
    context
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::brain::retrieval::{ledgered, RetrievalLedger};
    use serde_json::json;
    use std::sync::Arc;

    fn notes() -> Vec<LoopTool> {
        let body = "De keuken wordt in november verbouwd. ".repeat(30);
        let search_body = body.clone();
        vec![
            LoopTool::read(
                "search_notes",
                "Searches notes.",
                json!({"properties": {"query": {"type": "string"}}, "required": ["query"]}),
                move |input| {
                    let body = search_body.clone();
                    async move {
                        assert_eq!(input["query"], "verbouwing");
                        Ok(format!("### Verbouwing keuken | 2026-10-01 [id: n2]\n{body}\n### Recept | 2026-09-01 [id: n3]\nappels"))
                    }
                },
            )
            .in_source("notes"),
            LoopTool::read(
                "read_note",
                "Reads a note.",
                json!({"properties": {"identifier": {"type": "string"}}, "required": ["identifier"]}),
                move |input| {
                    let body = body.clone();
                    async move {
                        assert_eq!(input["identifier"], "n2");
                        Ok(format!("### Verbouwing keuken\n{body} Het budget is 15.000 euro."))
                    }
                },
            )
            .in_source("notes"),
        ]
    }

    #[tokio::test]
    async fn nook_searches_and_reads_the_best_match() {
        let ledger = Arc::new(RetrievalLedger::new());
        let tools: Vec<LoopTool> = notes().into_iter().map(|t| ledgered(t, ledger.clone(), Duration::from_secs(5))).collect();
        let active: HashSet<String> = ["notes".to_string(), "calendar".to_string()].into();
        let none = |_: &[String], _: &HashSet<String>| vec![];
        let input = ResearchInput {
            text: "Wat staat er in mijn notitie over de verbouwing?",
            history: &[],
            scope: &SourceScope::default(),
            tools: &tools,
            active: &active,
            plan: None,
            profile: ModelProfile::LOCAL_MODERN_SMALL,
            learned: &none,
        };
        let findings = research(&input).await;
        assert_eq!(findings.opened.len(), 1);
        assert!(findings.opened[0].contains("15.000 euro"));
        assert!(!findings.found[0].contains("appels"));
        let steps = ledger.steps();
        assert_eq!(steps.len(), 2);
        let line = searched_line(&steps, &findings.terms);
        assert!(line.starts_with("Nook searched for \"verbouwing\" in: Notities (search_notes:"), "{line}");
        let context = build_context(&ContextParts {
            overview: "Now: maandag\nOpen loops:\n- x",
            memories: "What Nook remembers about the user: …",
            goal: "",
            blocked: &[],
            searched: &line,
            evidence: "",
            findings: &findings,
        });
        assert!(context.starts_with("Now: maandag\n\nWhat Nook remembers"));
        assert!(context.contains("Read in full (the best matches):"));
        assert!(context.ends_with("Open loops:\n- x"));
    }

    #[test]
    fn planning_is_for_questions() {
        assert!(!should_plan("Hoi!", &ChatIntent::detect("Hoi!")));
        assert!(!should_plan("Zet de muziek zachter", &ChatIntent::detect("Zet de muziek zachter")));
        assert!(should_plan("Heb ik chats openstaan?", &ChatIntent::detect("Heb ik chats openstaan?")));
    }
}
