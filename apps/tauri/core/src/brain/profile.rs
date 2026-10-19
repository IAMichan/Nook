//! Wat een model aankan, zodat prompts en tools passen in plaats van stilletjes over te lopen, en welk lokaal model bij
//! deze computer past (de modeladviseur). Op Windows, Linux en Android denkt Nook lokaal via Ollama of LM Studio.

use serde::Serialize;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelProfile {
    /// Tokens die het model in één keer leest (prompt + antwoord).
    pub context_tokens: u32,
    /// Tokens voor het antwoord.
    pub max_output_tokens: u32,
    /// Hoogstens zoveel tools per ronde; kleine modellen kiezen slechter uit lange lijsten.
    pub max_tools: usize,
    /// Alleen de eerste zin van elke toolbeschrijving (kortere prompt, lokaal sneller).
    pub compact_descriptions: bool,
    /// Rondes met tools voor het model moet antwoorden.
    pub rounds: usize,
    /// Kleine modellen krijgen een eenvoudiger prompt en minder tools.
    pub is_small: bool,
    /// Een sterk lokaal model (mixture of experts, 26B en meer): de volledige instructies en tools, net als extern.
    pub rich_prompt: bool,
}

impl ModelProfile {
    const fn new(context: u32, output: u32, tools: usize, compact: bool, rounds: usize, small: bool) -> Self {
        Self {
            context_tokens: context,
            max_output_tokens: output,
            max_tools: tools,
            compact_descriptions: compact,
            rounds,
            is_small: small,
            rich_prompt: false,
        }
    }

    pub const CLOUD: Self = Self::new(120_000, 8_192, 64, false, 10, false);
    pub const LOCAL_LARGE: Self = Self::new(16_384, 1_200, 14, true, 4, true);
    pub const LOCAL_SMALL: Self = Self::new(8_192, 800, 8, true, 3, true);
    /// Een compact model dat goed is met tools (Qwen 3, 4B).
    pub const LOCAL_COMPACT: Self = Self::new(8_192, 900, 10, true, 4, true);
    /// 12B en groter: een groter venster en meer tools.
    pub const LOCAL_XL: Self = Self::new(24_576, 1_500, 18, true, 5, true);
    /// Huidige kleine modellen (Qwen 3.5 4B): lange context en betrouwbare tool-aanroepen.
    pub const LOCAL_MODERN_SMALL: Self = Self::new(16_384, 1_500, 12, true, 5, true);
    /// Huidige middelgrote modellen (Qwen 3.5 9B, Gemma 4 12B, Qwen 3.6 27B).
    pub const LOCAL_MODERN: Self = Self::new(32_768, 2_500, 20, false, 6, true);
    /// Sterke mixture-of-experts-modellen: snel genoeg voor de volledige prompt en tools.
    pub const LOCAL_PRO: Self = Self { rich_prompt: true, ..Self::new(32_768, 4_096, 40, false, 8, true) };

    /// Ruimte voor het antwoord als het model eerst redeneert.
    pub fn thinking_output_tokens(&self) -> u32 {
        (self.max_output_tokens * 3).max(4_096).min(self.context_tokens / 2)
    }

    /// Een klein venster op een computer met geheugen over verspilt wat Nook leest: documenten die volledig geopend zijn,
    /// hebben ruimte nodig. Van 8k naar 16k kost een model van 3–4B ongeveer 1,2 GB extra.
    pub fn roomier(self, memory_gb: u64) -> Self {
        if !self.is_small || self.context_tokens > 8_192 || memory_gb < 16 {
            return self;
        }
        Self { context_tokens: 16_384, ..self }
    }

    /// Ruwe schatting zonder tokenizer: ongeveer 3,5 tekens per token.
    pub fn estimate_tokens(text: &str) -> usize {
        (text.chars().count() * 2).div_ceil(7)
    }

    /// Tekens prompt die nog passen na het antwoord en een marge.
    pub fn prompt_character_budget(&self) -> usize {
        (((self.context_tokens as i64 - self.max_output_tokens as i64 - 256) * 7 / 2).max(2_000)) as usize
    }

    /// Ruimte genoeg om alle toegestane bronnen te bereiken (alleen de kleinste lokale modellen niet).
    pub fn roomy(&self) -> bool {
        !self.is_small || self.context_tokens >= 16_000
    }
}

/// Past de delen van een prompt in een budget: delen met een lagere prioriteit worden eerst ingekort, nooit onder hun minimum.
pub struct Part {
    pub text: String,
    /// Hoger blijft langer.
    pub priority: i32,
    pub minimum: usize,
}

pub fn fit(parts: &[Part], budget: usize) -> Vec<String> {
    let mut texts: Vec<String> = parts.iter().map(|p| p.text.clone()).collect();
    let mut total: usize = texts.iter().map(|t| t.chars().count()).sum();
    if total <= budget {
        return texts;
    }
    let mut order: Vec<usize> = (0..parts.len()).collect();
    order.sort_by_key(|i| parts[*i].priority);
    for index in order {
        if total <= budget {
            break;
        }
        let length = texts[index].chars().count();
        let excess = total - budget;
        let keep = parts[index].minimum.max(length.saturating_sub(excess));
        if keep >= length {
            continue;
        }
        total -= length - keep;
        texts[index] =
            if keep == 0 { String::new() } else { format!("{}\n… (shortened)", texts[index].chars().take(keep).collect::<String>()) };
    }
    texts
}

/// De familie van een model: bepaalt de sampling.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum ModelFamily {
    Qwen,
    Gemma4,
    Llama,
    Other,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Sampling {
    pub temperature: f32,
    pub top_p: f32,
    pub top_k: u32,
}

impl ModelFamily {
    pub fn of(model: &str) -> Self {
        let lower = model.to_lowercase();
        if lower.contains("qwen") {
            Self::Qwen
        } else if lower.contains("gemma4") || lower.contains("gemma-4") {
            Self::Gemma4
        } else if lower.contains("llama") {
            Self::Llama
        } else {
            Self::Other
        }
    }

    /// De sampling die de makers aanraden; veel beter dan één instelling voor elk model.
    pub fn sampling(self, thinking: bool) -> Sampling {
        match self {
            Self::Qwen if thinking => Sampling { temperature: 0.6, top_p: 0.95, top_k: 20 },
            Self::Qwen => Sampling { temperature: 0.7, top_p: 0.8, top_k: 20 },
            Self::Gemma4 => Sampling { temperature: 1.0, top_p: 0.95, top_k: 64 },
            Self::Llama | Self::Other => Sampling { temperature: 0.6, top_p: 0.9, top_k: 0 },
        }
    }
}

/// Wanneer een model dat kan redeneren dat ook doet: alleen bij vragen waar het loont.
pub fn wants_thinking(question: &str) -> bool {
    const CUES: [&str; 37] = [
        "waarom",
        "why",
        "warum",
        "leg uit",
        "uitleg",
        "explain",
        "erkläre",
        "analyse",
        "analyze",
        "analyseer",
        "vergelijk",
        "compare",
        "vergleich",
        "bereken",
        "calculate",
        "berechne",
        "strategie",
        "strategy",
        "hoe kan ik",
        "how can i",
        "how do i",
        "wie kann ich",
        "wat is beter",
        "which is better",
        "pros and cons",
        "voor- en nadelen",
        "bewijs",
        "prove",
        "debug",
        "fout in",
        "bug",
        "algoritme",
        "algorithm",
        "stap voor stap",
        "step by step",
        "afweging",
        "advies",
    ];
    let text = question.to_lowercase();
    text.chars().count() > 280 || text.contains("```") || CUES.iter().any(|c| text.contains(c)) || text.contains("advice")
}

/// Een lokaal model dat Nook via Ollama kan installeren.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalModelOption {
    /// De naam bij Ollama ("qwen3.5:4b").
    pub id: &'static str,
    pub title: &'static str,
    pub size_gb: f64,
    /// Onder deze hoeveelheid geheugen loopt de computer vast.
    pub min_memory_gb: u64,
    /// Hoe goed het model tools kiest en invult (hoger is beter).
    pub tool_skill: u32,
    pub profile: ModelProfile,
    pub family: ModelFamily,
    pub can_think: bool,
}

impl LocalModelOption {
    pub fn sees_images(&self) -> bool {
        let lower = self.id.to_lowercase();
        lower.contains("qwen3.5") || lower.contains("qwen3.6") || lower.contains("gemma4")
    }
}

const fn option(
    id: &'static str,
    title: &'static str,
    size_gb: f64,
    min_memory_gb: u64,
    tool_skill: u32,
    profile: ModelProfile,
    family: ModelFamily,
    can_think: bool,
) -> LocalModelOption {
    LocalModelOption { id, title, size_gb, min_memory_gb, tool_skill, profile, family, can_think }
}

/// Keuzes bij Ollama, nieuwste generatie eerst. Qwen 3.5 / 3.6 hebben de voorkeur om hun betrouwbare tool-aanroepen,
/// lange context en Nederlands; Gemma 4 is een sterk alternatief. Oudere modellen blijven staan zodat een geïnstalleerd
/// model blijft werken; de adviseur stelt ze niet meer voor als er iets beters past.
pub const CATALOG: [LocalModelOption; 14] = [
    option("qwen3.5:4b", "Qwen 3.5 (4B)", 3.4, 8, 6, ModelProfile::LOCAL_MODERN_SMALL, ModelFamily::Qwen, true),
    option("qwen3.5:9b", "Qwen 3.5 (9B)", 6.6, 16, 8, ModelProfile::LOCAL_MODERN, ModelFamily::Qwen, true),
    option("gemma4:12b", "Gemma 4 (12B)", 8.1, 16, 7, ModelProfile::LOCAL_MODERN, ModelFamily::Gemma4, false),
    option("qwen3.6:27b", "Qwen 3.6 (27B)", 17.0, 32, 9, ModelProfile::LOCAL_MODERN, ModelFamily::Qwen, true),
    option("gemma4:26b", "Gemma 4 (26B-A4B)", 16.0, 32, 8, ModelProfile::LOCAL_PRO, ModelFamily::Gemma4, false),
    option("qwen3.6:35b-a3b", "Qwen 3.6 (35B-A3B)", 23.0, 36, 10, ModelProfile::LOCAL_PRO, ModelFamily::Qwen, true),
    option("qwen3:4b", "Qwen 3 (4B)", 2.5, 8, 4, ModelProfile::LOCAL_COMPACT, ModelFamily::Qwen, false),
    option("qwen3:8b", "Qwen 3 (8B)", 5.2, 16, 5, ModelProfile::LOCAL_LARGE, ModelFamily::Qwen, false),
    option(
        "qwen3:30b-a3b",
        "Qwen 3 (30B-A3B)",
        19.0,
        32,
        7,
        ModelProfile::new(24_576, 2_000, 24, false, 6, true),
        ModelFamily::Qwen,
        false,
    ),
    option("qwen2.5:3b", "Qwen 2.5 (3B)", 1.9, 8, 2, ModelProfile::LOCAL_SMALL, ModelFamily::Qwen, false),
    option("llama3.2:3b", "Llama 3.2 (3B)", 2.0, 8, 1, ModelProfile::LOCAL_SMALL, ModelFamily::Llama, false),
    option("qwen2.5:7b", "Qwen 2.5 (7B)", 4.7, 16, 3, ModelProfile::LOCAL_LARGE, ModelFamily::Qwen, false),
    option("llama3.1:8b", "Llama 3.1 (8B)", 4.9, 16, 3, ModelProfile::LOCAL_LARGE, ModelFamily::Llama, false),
    option("qwen2.5:14b", "Qwen 2.5 (14B)", 9.0, 32, 4, ModelProfile::LOCAL_XL, ModelFamily::Qwen, false),
];

/// Zonder ":latest" en hoofdletters, zodat "Qwen3.5:4B" en "qwen3.5:4b" hetzelfde model zijn.
fn tag(name: &str) -> String {
    name.trim().to_lowercase().trim_end_matches(":latest").to_string()
}

pub fn catalog_entry(name: &str) -> Option<&'static LocalModelOption> {
    let wanted = tag(name);
    CATALOG.iter().find(|o| tag(o.id) == wanted)
}

/// Het aantal miljard parameters uit de naam ("qwen2.5:14b" → 14), afgerond.
pub fn parameter_billions(name: &str) -> Option<u64> {
    let lower = name.to_lowercase();
    let caps = rx!(r"(\d+(?:\.\d+)?)b\b").captures(&lower).ok()??;
    caps[1].parse::<f64>().ok().map(|v| v.round() as u64)
}

/// Profiel voor een model van Ollama of LM Studio: uit de catalogus, of uit de grootte in de naam.
pub fn profile_for_server_model(name: &str) -> ModelProfile {
    if let Some(entry) = catalog_entry(name) {
        return entry.profile;
    }
    match parameter_billions(name).unwrap_or(3) {
        size if size >= 12 => ModelProfile::LOCAL_XL,
        size if size >= 6 => ModelProfile::LOCAL_LARGE,
        _ => ModelProfile::LOCAL_SMALL,
    }
}

/// Hoe geschikt een servermodel is: families die goed zijn met tools scoren hoger; te groot voor het geheugen scoort nul.
pub fn server_score(name: &str, memory_gb: u64) -> u64 {
    let lower = name.to_lowercase();
    if lower.contains("embed") || lower.contains("whisper") || (lower.contains("vision") && !lower.contains("instruct")) {
        return 0;
    }
    let size = parameter_billions(&lower).unwrap_or(4);
    // Gewichten in 4 bit kosten ongeveer 0,6 GB per miljard parameters; houd de helft van het geheugen vrij.
    if size as f64 * 0.6 > memory_gb as f64 / 2.0 {
        return 0;
    }
    let mut score = 1;
    if lower.contains("qwen") {
        score += 3;
    }
    if ["llama3", "llama-3", "mistral", "gemma3", "gemma-3"].iter().any(|f| lower.contains(f)) {
        score += 2;
    }
    if ["gemma4", "gemma-4", "gpt-oss", "qwen3.5", "qwen3.6"].iter().any(|f| lower.contains(f)) {
        score += 2;
    }
    if lower.contains("instruct") || lower.contains("chat") || !lower.contains("base") {
        score += 1;
    }
    score + size.min(14) / 4
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Server {
    Ollama,
    Lmstudio,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ServerModel {
    pub server: Server,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum Choice {
    /// Een model uit de catalogus bij Ollama (installeren met één klik, of al geïnstalleerd).
    Pull { option: LocalModelOption },
    /// Een model dat Ollama of LM Studio al heeft.
    Server { model: ServerModel },
    /// Hier draait lokaal niets goed; de reden zegt waarom.
    Unavailable,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Recommendation {
    pub choice: Choice,
    /// Staat al op deze computer: meteen te gebruiken.
    pub ready: bool,
    /// Eén zin voor de gebruiker.
    pub reason: String,
    pub title: String,
}

fn formatted(value: f64) -> String {
    if value == value.round() {
        format!("{}", value as u64)
    } else {
        format!("{value:.1}").replace('.', ",")
    }
}

fn server_title(server: &Server) -> &'static str {
    match server {
        Server::Ollama => "Ollama",
        Server::Lmstudio => "LM Studio",
    }
}

/// Kiest het beste lokale model voor deze computer, zodat iedereen een goede start heeft zonder modellen te kennen. Weegt,
/// in deze volgorde: wat hier draait, wat er al staat (geen download), en hoe goed het model met tools is.
pub fn recommend(memory_gb: u64, installed: &[String], servers: &[ServerModel]) -> Vec<Recommendation> {
    let mut result: Vec<Recommendation> = vec![];
    let installed: Vec<String> = installed.iter().map(|i| tag(i)).collect();
    let mut best: Vec<&LocalModelOption> = CATALOG.iter().filter(|o| o.min_memory_gb <= memory_gb).collect();
    best.sort_by(|a, b| b.tool_skill.cmp(&a.tool_skill).then(a.size_gb.total_cmp(&b.size_gb)));
    let is_installed = |o: &LocalModelOption| installed.contains(&tag(o.id));
    let pull = |o: &LocalModelOption, ready: bool, reason: String| Recommendation {
        choice: Choice::Pull { option: o.clone() },
        ready,
        reason,
        title: o.title.to_string(),
    };
    let contains = |list: &[Recommendation], id: &str| list.iter().any(|r| matches!(&r.choice, Choice::Pull { option } if option.id == id));
    // Modellen die Ollama al heeft maar die niet in de catalogus staan, en alles van LM Studio.
    let mut usable: Vec<&ServerModel> =
        servers.iter().filter(|s| catalog_entry(&s.name).is_none() && server_score(&s.name, memory_gb) > 0).collect();
    usable.sort_by_key(|s| std::cmp::Reverse(server_score(&s.name, memory_gb)));
    let server = |model: &ServerModel, reason: String| Recommendation {
        title: format!("{} via {}", model.name, server_title(&model.server)),
        choice: Choice::Server { model: model.clone() },
        ready: true,
        reason,
    };

    if let Some(top) = best.first().filter(|t| is_installed(t)) {
        result.push(pull(top, true, format!("Past het best bij {memory_gb} GB en staat al op deze computer.")));
    }
    if let Some(first) = usable.first() {
        result.push(server(first, format!("Staat al klaar in {}, niets te downloaden.", server_title(&first.server))));
    }
    if let Some(top) = best.first() {
        if !contains(&result, top.id) {
            result.push(pull(
                top,
                is_installed(top),
                format!(
                    "Beste balans tussen kwaliteit en snelheid voor {memory_gb} GB geheugen (download van ± {} GB, één keer).",
                    formatted(top.size_gb)
                ),
            ));
        }
    }
    for option in best.iter().filter(|o| is_installed(o)) {
        if !contains(&result, option.id) {
            result.push(pull(option, true, "Staat al op deze computer.".into()));
        }
    }
    for model in usable.iter().skip(1) {
        result.push(server(model, format!("Beschikbaar in {}.", server_title(&model.server))));
    }
    for option in &best {
        if !contains(&result, option.id) {
            result.push(pull(option, false, format!("Download van ± {} GB.", formatted(option.size_gb))));
        }
    }
    if result.is_empty() {
        result.push(Recommendation {
            choice: Choice::Unavailable,
            ready: false,
            reason: "Deze computer heeft te weinig geheugen voor een lokaal model. Draai Ollama op een andere computer in je netwerk, of kies een externe AI.".into(),
            title: "Geen lokaal model mogelijk".into(),
        });
    }
    result
}

/// Het geheugen van deze computer in GB (afgerond naar beneden), of niets als het niet te lezen is.
pub fn system_memory_gb() -> Option<u64> {
    #[cfg(any(target_os = "linux", target_os = "android"))]
    {
        let text = std::fs::read_to_string("/proc/meminfo").ok()?;
        let line = text.lines().find(|l| l.starts_with("MemTotal:"))?;
        let kib: u64 = line.split_whitespace().nth(1)?.parse().ok()?;
        // Een paar honderd MB gaat naar de kernel; rond af zoals fabrikanten het noemen.
        Some(((kib as f64 / 1_048_576.0) + 0.5) as u64)
    }
    #[cfg(not(any(target_os = "linux", target_os = "android")))]
    {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn first(memory: u64, installed: &[&str], servers: &[ServerModel]) -> Recommendation {
        let installed: Vec<String> = installed.iter().map(|s| s.to_string()).collect();
        recommend(memory, &installed, servers).remove(0)
    }

    fn id(r: &Recommendation) -> Option<&'static str> {
        match &r.choice {
            Choice::Pull { option } => Some(option.id),
            _ => None,
        }
    }

    #[test]
    fn picks_by_memory() {
        assert_eq!(id(&first(8, &[], &[])), Some("qwen3.5:4b"));
        assert_eq!(id(&first(16, &[], &[])), Some("qwen3.5:9b"));
        assert_eq!(id(&first(24, &[], &[])), Some("qwen3.5:9b"));
        assert_eq!(id(&first(32, &[], &[])), Some("qwen3.6:27b"));
        assert_eq!(id(&first(64, &[], &[])), Some("qwen3.6:35b-a3b"));
        assert_eq!(first(4, &[], &[]).choice, Choice::Unavailable);
    }

    #[test]
    fn installed_models_are_ready() {
        let top = first(16, &["qwen3.5:9b"], &[]);
        assert_eq!(id(&top), Some("qwen3.5:9b"));
        assert!(top.ready);
        let all = recommend(16, &["qwen3:8b".into()], &[]);
        assert_eq!(id(&all[0]), Some("qwen3.5:9b"));
        assert!(all.iter().any(|r| id(r) == Some("qwen3:8b") && r.ready));
    }

    #[test]
    fn existing_server_models_beat_a_download() {
        let lm = ServerModel { server: Server::Lmstudio, name: "qwen2.5-7b-instruct".into() };
        let top = first(16, &[], std::slice::from_ref(&lm));
        assert_eq!(top.choice, Choice::Server { model: lm });
        let big = ServerModel { server: Server::Ollama, name: "llama3.3:70b".into() };
        let embed = ServerModel { server: Server::Ollama, name: "nomic-embed-text".into() };
        assert!(id(&first(16, &[], &[big, embed])).is_some());
    }

    #[test]
    fn every_model_fits_its_window() {
        for option in &CATALOG {
            assert!(option.profile.max_output_tokens < option.profile.context_tokens / 2, "{}", option.id);
            assert!(option.profile.thinking_output_tokens() <= option.profile.context_tokens / 2);
        }
        assert_eq!(CATALOG.iter().map(|o| o.id).collect::<std::collections::HashSet<_>>().len(), CATALOG.len());
    }

    #[test]
    fn sampling_and_thinking() {
        assert_eq!(ModelFamily::Qwen.sampling(false), Sampling { temperature: 0.7, top_p: 0.8, top_k: 20 });
        assert_eq!(ModelFamily::Qwen.sampling(true).top_p, 0.95);
        assert_eq!(ModelFamily::Gemma4.sampling(false).top_k, 64);
        assert!(!wants_thinking("Hoi!") && !wants_thinking("Wat staat er morgen in mijn agenda?"));
        assert!(wants_thinking("Waarom faalt de build van Nook?") && wants_thinking("Vergelijk de offertes van Sanne en Pieter"));
        assert!(wants_thinking("Explain step by step how OAuth works"));
    }

    #[test]
    fn parameter_size_from_name() {
        assert_eq!(parameter_billions("qwen2.5:14b"), Some(14));
        assert_eq!(parameter_billions("llama3.2:3b-instruct-q4"), Some(3));
        assert_eq!(parameter_billions("phi3.5:3.8b"), Some(4));
        assert_eq!(parameter_billions("mistral"), None);
        assert_eq!(profile_for_server_model("mistral-nemo:14b"), ModelProfile::LOCAL_XL);
        assert_eq!(profile_for_server_model("llama3.2:3b"), ModelProfile::LOCAL_SMALL);
        assert_eq!(profile_for_server_model("qwen3.5:9b"), ModelProfile::LOCAL_MODERN);
    }

    #[test]
    fn budget_shortens_lowest_priority_first() {
        let parts = [
            Part { text: "s".repeat(100), priority: 3, minimum: 0 },
            Part { text: "c".repeat(300), priority: 1, minimum: 50 },
            Part { text: "h".repeat(200), priority: 2, minimum: 0 },
        ];
        let fitted = fit(&parts, 400);
        assert_eq!(fitted[0].len(), 100);
        assert_eq!(fitted[2].len(), 200);
        assert!(fitted[1].starts_with(&"c".repeat(100)) && fitted[1].chars().count() < 300);
        assert_eq!(fit(&parts, 1_000).iter().map(|t| t.len()).collect::<Vec<_>>(), vec![100, 300, 200]);
    }

    #[test]
    fn profiles() {
        assert!(ModelProfile::CLOUD.prompt_character_budget() > ModelProfile::LOCAL_LARGE.prompt_character_budget());
        assert!(ModelProfile::LOCAL_LARGE.prompt_character_budget() > ModelProfile::LOCAL_SMALL.prompt_character_budget());
        assert_eq!(ModelProfile::estimate_tokens(&"a".repeat(700)), 200);
        assert_eq!(ModelProfile::LOCAL_COMPACT.roomier(16).context_tokens, 16_384);
        assert_eq!(ModelProfile::LOCAL_COMPACT.roomier(8), ModelProfile::LOCAL_COMPACT);
        assert_eq!(ModelProfile::LOCAL_LARGE.roomier(64), ModelProfile::LOCAL_LARGE);
        assert_eq!(ModelProfile::CLOUD.roomier(64), ModelProfile::CLOUD);
    }

    #[test]
    fn reads_system_memory() {
        if cfg!(target_os = "linux") {
            assert!(system_memory_gb().is_some_and(|g| g > 0));
        }
    }
}
