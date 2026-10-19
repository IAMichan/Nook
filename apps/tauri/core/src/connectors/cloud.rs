//! Diensten met een sleutel: Vercel, Stripe, Notion, Cal.com, n8n en Resend. Ze lezen alleen; er gaat nooit geld weg,
//! er wordt niets gedeployd of verstuurd. Sleutels staan in de kluis onder `connector.<id>.<veld>`, zoals op de Mac.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use chrono::{DateTime, Duration, Utc};
use serde::Serialize;
use serde_json::{json, Value};

use super::agenda::{AgendaEntry, AgendaResult};
use super::hub::{Connector, Env, Scope};
use super::{
    dates, float, int, link, list, money, plural, short, string, with_query, CResult, ConnectorError, ConnectorItem, ConnectorState,
    ConnectorStatus, Tone,
};
use crate::brain::LoopTool;

fn base(service: &str, default: &str) -> String {
    super::api_base(default, &format!("NOOK_{}_API_URL", service.to_uppercase()))
}

/// Eén invoerveld van een dienst in de instellingen. De waarde staat in de kluis onder `account`.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Field {
    pub account: &'static str,
    pub label: &'static str,
    pub placeholder: &'static str,
    pub secret: bool,
}

/// Wat de instellingen over een dienst met sleutel tonen: velden, uitleg en waar je de sleutel maakt.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ServiceInfo {
    pub id: &'static str,
    pub title: &'static str,
    pub domain: &'static str,
    pub category: &'static str,
    pub tagline: &'static str,
    pub fields: Vec<Field>,
    pub help: &'static str,
    pub signup_url: Option<&'static str>,
    /// Wat Nook ermee kan, in een paar zinnen.
    pub capabilities: &'static str,
}

const fn field(account: &'static str, label: &'static str, placeholder: &'static str, secret: bool) -> Field {
    Field { account, label, placeholder, secret }
}

/// Alle diensten met een sleutel, in de volgorde van de instellingen.
pub fn services() -> Vec<ServiceInfo> {
    vec![
        ServiceInfo {
            id: "github",
            title: "GitHub",
            domain: "github.com",
            category: "development",
            tagline: "Pull requests, reviews en issues",
            fields: vec![field("connector.github.token", "Token", "ghp_… / github_pat_…", true)],
            help: "Het makkelijkst: Koppel met GitHub hierboven. Lukt dat niet? Klik Maak een token, de rechten staan dan al goed, en plak het token hier. Nook leest je pull requests en kan ze, na jouw goedkeuring, beoordelen, samenvoegen of sluiten; daarvoor moet het token schrijfrechten op pull requests hebben.",
            signup_url: Some(super::github::TOKEN_URL),
            capabilities: "Lezen: je open pull requests, reviews die op jou wachten, CI, issues en diffs. Doen (alleen na Uitvoeren): een review plaatsen of goedkeuren, reageren, samenvoegen, sluiten, een issue maken of bijwerken.",
        },
        ServiceInfo {
            id: "vercel",
            title: "Vercel",
            domain: "vercel.com",
            category: "development",
            tagline: "Projecten, deployments en logs",
            fields: vec![field("connector.vercel.token", "Token", "Vercel-token", true), field("connector.vercel.team", "Team-ID", "team_… (optioneel)", false)],
            help: "Maak een token onder Account › Tokens, met als scope alleen het team of account dat Nook mag zien. Team-ID is alleen nodig voor deploys van een team.",
            signup_url: Some("https://vercel.com/account/tokens"),
            capabilities: "Lezen: je laatste deployments per project, of ze live staan of mislukten, branch en commit. Nook deployt nooit zelf.",
        },
        ServiceInfo {
            id: "stripe",
            title: "Stripe",
            domain: "stripe.com",
            category: "business",
            tagline: "Omzet, betalingen en klanten",
            fields: vec![field("connector.stripe.key", "Sleutel", "rk_live_…", true)],
            help: "Gebruik bij voorkeur een beperkte sleutel (restricted key) met alleen leesrechten op Charges. Nook leest alleen; er gaat nooit geld weg.",
            signup_url: Some("https://dashboard.stripe.com/apikeys"),
            capabilities: "Lezen: omzet van vandaag en de laatste betalingen met klant en status. Er gaat nooit geld weg.",
        },
        ServiceInfo {
            id: "notion",
            title: "Notion",
            domain: "notion.so",
            category: "work",
            tagline: "Documenten, databases en notities",
            fields: vec![field("connector.notion.token", "Token", "ntn_… / secret_…", true)],
            help: "Maak een interne integratie met alleen 'Read content'. Deel daarna de pagina's die Nook mag zien met die integratie (••• › Verbindingen).",
            signup_url: Some("https://www.notion.so/profile/integrations"),
            capabilities: "Lezen: pagina's die je met de integratie deelt zoeken en lezen.",
        },
        ServiceInfo {
            id: "calcom",
            title: "Cal.com",
            domain: "cal.com",
            category: "work",
            tagline: "Afspraken en beschikbaarheid",
            fields: vec![field("connector.calcom.key", "API-sleutel", "cal_live_…", true)],
            help: "Maak een API-sleutel onder Instellingen › Developer › API keys. Nook leest alleen je komende boekingen.",
            signup_url: Some("https://app.cal.com/settings/developer/api-keys"),
            capabilities: "Lezen: je komende boekingen; ze tellen mee bij \"ben ik vrij op…?\".",
        },
        ServiceInfo {
            id: "n8n",
            title: "n8n",
            domain: "n8n.io",
            category: "automation",
            tagline: "Workflows en mislukte runs",
            fields: vec![field("connector.n8n.url", "Adres", "https://n8n.example.com", false), field("connector.n8n.key", "API-sleutel", "n8n API-sleutel", true)],
            help: "Maak een sleutel in n8n onder Settings › n8n API. Nook leest alleen je workflows en mislukte runs; het start of wijzigt niets.",
            signup_url: Some("https://docs.n8n.io/api/authentication/"),
            capabilities: "Lezen: hoeveel workflows actief zijn en welke runs mislukten.",
        },
        ServiceInfo {
            id: "resend",
            title: "Resend",
            domain: "resend.com",
            category: "automation",
            tagline: "Verzonden e-mails en domeinen",
            fields: vec![field("connector.resend.key", "API-sleutel", "re_…", true)],
            help: "Maak een sleutel met 'Full access': alleen daarmee kan Nook je verzonden mails en domeinen lezen. Nook verstuurt zelf nooit mail.",
            signup_url: Some("https://resend.com/api-keys"),
            capabilities: "Lezen: verzonden e-mails (bezorgd, gebounced) en de status van je domeinen. Nook verstuurt nooit mail.",
        },
        ServiceInfo {
            id: "icalfeeds",
            title: "Andere agenda's",
            domain: "calendar.google.com",
            category: "work",
            tagline: "Online agenda's via iCal / ICS",
            fields: vec![field(super::feeds::KEY_ACCOUNT, "ICS-adressen", "https://…/basic.ics", true)],
            help: "Plak het geheime iCal/ICS-adres van een agenda: in Google Agenda onder Instellingen › je agenda › Geheim adres in iCal-indeling, in Outlook onder Agenda publiceren (ICS), in iCloud via Deel agenda › Openbare agenda. Meerdere adressen mogen achter elkaar. Nook leest ze alleen en kijkt er bij \"ben ik vrij op…?\" altijd in, samen met Cal.com.",
            signup_url: None,
            capabilities: "Lezen: je afspraken van de komende week, en vrije tijd per dag als je vraagt wanneer je kunt.",
        },
        ServiceInfo {
            id: "customsources",
            title: "Eigen bronnen",
            domain: "",
            category: "automation",
            tagline: "Eigen API's en webhooks",
            fields: vec![field(super::custom::KEY_ACCOUNT, "Bronnen", "Naam | https://… | Authorization: Bearer …", true)],
            help: "Koppel bijna elke app of dienst met een web-API of webhook, zoals Slack, Discord, Teams, Telegram, n8n of Todoist. Per bron één regel: Naam | https://api.voorbeeld.nl/v1 | Authorization: Bearer jouwsleutel (het laatste deel is optioneel; een kale sleutel wordt een Bearer-token; zet er | webhook achter voor een gewone webhook). Meerdere bronnen scheid je met ;; of een nieuwe regel. Nook herkent de dienst aan het adres en laat zijn icoon zien. Lezen kan direct; een bericht versturen kan alleen na jouw Uitvoeren. Je sleutel gaat nooit naar een andere host.",
            signup_url: None,
            capabilities: "Lezen: elke web-API die je toevoegt. Doen (alleen na Uitvoeren): een bericht via Slack, Discord, Teams, Telegram of een webhook.",
        },
    ]
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// Wat elke dienst met sleutel deelt: de omgeving en zijn status.
struct Base {
    env: Arc<Env>,
    id: &'static str,
    status: Mutex<ConnectorStatus>,
}

impl Base {
    fn new(env: Arc<Env>, id: &'static str) -> Self {
        Self { env, id, status: Mutex::default() }
    }

    fn on(&self) -> bool {
        self.env.store.is_on(self.id)
    }

    fn key(&self, account: &str) -> Option<String> {
        self.env.secret(account)
    }

    fn loading(&self) {
        let mut s = lock(&self.status);
        if s.updated.is_none() {
            s.state = ConnectorState::Loading;
        }
    }

    fn set(&self, status: ConnectorStatus) {
        *lock(&self.status) = status;
    }

    fn fail(&self, e: &ConnectorError) {
        lock(&self.status).fail(e);
    }

    fn status(&self) -> ConnectorStatus {
        lock(&self.status).clone()
    }
}

// Vercel

#[derive(Debug, Clone)]
struct Deployment {
    id: String,
    project: String,
    state: String,
    created: Option<DateTime<Utc>>,
    branch: Option<String>,
    message: Option<String>,
    production: bool,
    url: Option<String>,
}

pub struct Vercel {
    base: Base,
    deployments: Mutex<Option<Vec<Deployment>>>,
}

const VERCEL_TOKEN: &str = "connector.vercel.token";
const VERCEL_TEAM: &str = "connector.vercel.team";

impl Vercel {
    pub fn new(env: Arc<Env>) -> Arc<Self> {
        Arc::new(Self { base: Base::new(env, "vercel"), deployments: Mutex::default() })
    }

    async fn fetch(&self, token: &str, limit: usize) -> CResult<Vec<Deployment>> {
        let mut query = vec![("limit", limit.to_string())];
        if let Some(team) = self.base.key(VERCEL_TEAM) {
            query.push(("teamId", team));
        }
        let url = with_query(&format!("{}/v6/deployments", base("vercel", "https://api.vercel.com")), &query);
        let root = self.base.env.http.get(&url, &[("Authorization", format!("Bearer {token}"))], "Vercel").await?;
        Ok(list(&root["deployments"])
            .iter()
            .filter_map(|d| {
                let uid = d["uid"].as_str()?;
                let meta = &d["meta"];
                let pick = |keys: [&str; 3]| keys.iter().find_map(|k| meta[*k].as_str().map(str::to_string));
                let mut url = link(d["inspectorUrl"].as_str());
                if url.is_none() {
                    if let Some(host) = d["url"].as_str().filter(|h| !h.is_empty()) {
                        url = link(Some(&if host.starts_with("https://") { host.to_string() } else { format!("https://{host}") }));
                    }
                }
                Some(Deployment {
                    id: uid.into(),
                    project: d["name"].as_str().unwrap_or("Project").into(),
                    state: d["state"].as_str().or(d["readyState"].as_str()).unwrap_or("UNKNOWN").to_uppercase(),
                    created: float(&d["created"])
                        .or_else(|| float(&d["createdAt"]))
                        .and_then(|ms| DateTime::from_timestamp_millis(ms as i64)),
                    branch: pick(["githubCommitRef", "gitlabCommitRef", "bitbucketCommitRef"]),
                    message: pick(["githubCommitMessage", "gitlabCommitMessage", "bitbucketCommitMessage"]),
                    production: d["target"] == "production",
                    url,
                })
            })
            .collect())
    }

    /// De API geeft de nieuwste eerst; alleen de laatste deploy per project telt.
    fn latest(list: &[Deployment]) -> Vec<Deployment> {
        let mut seen = std::collections::HashSet::new();
        list.iter().filter(|d| seen.insert(d.project.clone())).cloned().collect()
    }

    fn label(state: &str) -> String {
        match state {
            "READY" => "live".into(),
            "ERROR" => "failed".into(),
            "BUILDING" => "building".into(),
            "QUEUED" => "queued".into(),
            "INITIALIZING" => "initializing".into(),
            "CANCELED" => "canceled".into(),
            other => other.to_lowercase(),
        }
    }

    fn apply(&self, list: Vec<Deployment>) {
        let latest = Self::latest(&list);
        let broken: Vec<&Deployment> = latest.iter().filter(|d| d.state == "ERROR").collect();
        let busy = latest.iter().find(|d| ["BUILDING", "QUEUED", "INITIALIZING"].contains(&d.state.as_str()));
        let headline = if !broken.is_empty() {
            format!("Deploy mislukt: {}", broken.iter().take(2).map(|d| d.project.as_str()).collect::<Vec<_>>().join(", "))
        } else if let Some(b) = busy {
            format!("Bezig: {}", b.project)
        } else if latest.is_empty() {
            "Nog geen deploys".into()
        } else {
            "Alles live".into()
        };
        let detail = list
            .first()
            .map(|l| format!("Laatste: {}{}", l.project, l.created.map(|c| format!(" · {}", dates::ago(c))).unwrap_or_default()))
            .unwrap_or_default();
        let items = list
            .iter()
            .take(8)
            .map(|d| {
                let mut parts = vec![Self::label(&d.state)];
                if d.production {
                    parts.push("productie".into());
                }
                parts.extend(d.branch.clone());
                parts.extend(d.created.map(dates::ago));
                let title = d.message.as_ref().map(|m| format!("{}: {}", d.project, short(m, 50))).unwrap_or_else(|| d.project.clone());
                let tone = match d.state.as_str() {
                    "READY" => Tone::Good,
                    "ERROR" => Tone::Bad,
                    _ => Tone::Neutral,
                };
                ConnectorItem::new(&d.id, title, parts.join(" · "), tone, d.url.clone())
            })
            .collect();
        self.base.set(ConnectorStatus::ok(headline, detail, items, !broken.is_empty()));
        *lock(&self.deployments) = Some(list);
    }

    async fn overview(&self) -> CResult<String> {
        let token = self.base.key(VERCEL_TOKEN).filter(|_| self.base.on()).ok_or_else(|| ConnectorError::not_set_up("Vercel"))?;
        let list = self.fetch(&token, 20).await?;
        self.apply(list.clone());
        if list.is_empty() {
            return Ok("No Vercel deployments found.".into());
        }
        Ok(list
            .iter()
            .map(|d| {
                let mut line = format!("- {}: {}", d.project, Self::label(&d.state));
                if d.production {
                    line.push_str(" [production]");
                }
                if let Some(b) = &d.branch {
                    line.push_str(&format!(" · branch {b}"));
                }
                if let Some(m) = &d.message {
                    line.push_str(&format!(" · '{}'", short(m, 100)));
                }
                if let Some(c) = d.created {
                    line.push_str(&format!(" · {}", dates::short(c)));
                }
                if let Some(u) = &d.url {
                    line.push_str(&format!(" · {u}"));
                }
                line
            })
            .collect::<Vec<_>>()
            .join("\n"))
    }
}

#[async_trait]
impl Connector for Vercel {
    fn id(&self) -> String {
        "vercel".into()
    }
    fn title(&self) -> String {
        "Vercel".into()
    }
    fn configured(&self) -> bool {
        self.base.key(VERCEL_TOKEN).is_some()
    }
    fn active(&self) -> bool {
        self.configured() && self.base.on()
    }
    fn status(&self) -> ConnectorStatus {
        self.base.status()
    }
    fn refresh_interval(&self) -> u64 {
        150
    }
    async fn refresh(&self) {
        let Some(token) = self.base.key(VERCEL_TOKEN).filter(|_| self.base.on()) else {
            *lock(&self.deployments) = None;
            self.base.set(ConnectorStatus::default());
            return;
        };
        self.base.loading();
        match self.fetch(&token, 12).await {
            Ok(list) => self.apply(list),
            Err(e) => self.base.fail(&e),
        }
    }
    fn context_lines(&self) -> Vec<String> {
        if !self.base.status().is_ok() || !self.base.on() {
            return vec![];
        }
        let Some(list) = lock(&self.deployments).clone() else { return vec![] };
        let latest = Self::latest(&list);
        if latest.is_empty() {
            return vec!["Vercel: no deployments yet.".into()];
        }
        let summary: Vec<String> = latest
            .iter()
            .take(4)
            .map(|d| {
                format!(
                    "{}: {}{}",
                    d.project,
                    Self::label(&d.state),
                    d.created.map(|c| format!(" ({})", dates::ago(c))).unwrap_or_default()
                )
            })
            .collect();
        let mut lines = vec![format!("Vercel, latest deployments: {}", summary.join(", "))];
        for d in latest.iter().filter(|d| d.state == "ERROR") {
            let mut line = format!("Vercel deployment failed: {}", d.project);
            if let Some(b) = &d.branch {
                line.push_str(&format!(" ({b})"));
            }
            if let Some(m) = &d.message {
                line.push_str(&format!(" '{}'", short(m, 60)));
            }
            lines.push(line);
        }
        lines.truncate(8);
        lines
    }
    fn tools(self: Arc<Self>, _scope: &Scope) -> Vec<LoopTool> {
        let me = self.clone();
        vec![LoopTool::read(
            "vercel_deployments",
            "Fetches the user's latest Vercel deployments: project, status (live, failed, building), branch, commit, and link.",
            super::schema(json!({})),
            move |_| {
                let me = me.clone();
                async move { me.overview().await.map_err(Into::into) }
            },
        )]
    }
}

// Stripe

#[derive(Debug, Clone)]
struct Payment {
    id: String,
    amount: i64,
    refunded: i64,
    currency: String,
    status: String,
    created: DateTime<Utc>,
    who: String,
    failure: Option<String>,
}

#[derive(Debug, Clone)]
struct StripeSnapshot {
    today: Vec<Payment>,
    more_today: bool,
    recent: Vec<Payment>,
    test_mode: bool,
}

pub struct Stripe {
    base: Base,
    snapshot: Mutex<Option<StripeSnapshot>>,
}

const STRIPE_KEY: &str = "connector.stripe.key";

impl Stripe {
    pub fn new(env: Arc<Env>) -> Arc<Self> {
        Arc::new(Self { base: Base::new(env, "stripe"), snapshot: Mutex::default() })
    }

    fn parse(c: &Value) -> Option<Payment> {
        let non_empty = |v: &Value| v.as_str().filter(|s| !s.is_empty()).map(str::to_string);
        Some(Payment {
            id: c["id"].as_str()?.into(),
            amount: int(&c["amount"])?,
            refunded: int(&c["amount_refunded"]).unwrap_or(0),
            currency: c["currency"].as_str()?.into(),
            status: c["status"].as_str().unwrap_or("").into(),
            created: DateTime::from_timestamp(float(&c["created"]).unwrap_or(0.0) as i64, 0).unwrap_or_default(),
            who: non_empty(&c["billing_details"]["name"])
                .or_else(|| non_empty(&c["description"]))
                .or_else(|| non_empty(&c["receipt_email"]))
                .or_else(|| non_empty(&c["billing_details"]["email"]))
                .unwrap_or_else(|| "Payment".into()),
            failure: non_empty(&c["failure_message"]),
        })
    }

    async fn fetch(&self, key: &str, recent: usize) -> CResult<StripeSnapshot> {
        let api = base("stripe", "https://api.stripe.com");
        let auth = [("Authorization", format!("Bearer {key}"))];
        let start = dates::start_of_day(Utc::now()).timestamp();
        let today = self
            .base
            .env
            .http
            .get(
                &with_query(&format!("{api}/v1/charges"), &[("limit", "100".into()), ("created[gte]", start.to_string())]),
                &auth,
                "Stripe",
            )
            .await?;
        let latest =
            self.base.env.http.get(&with_query(&format!("{api}/v1/charges"), &[("limit", recent.to_string())]), &auth, "Stripe").await?;
        Ok(StripeSnapshot {
            today: list(&today["data"]).iter().filter_map(Self::parse).collect(),
            more_today: today["has_more"].as_bool().unwrap_or(false),
            recent: list(&latest["data"]).iter().filter_map(Self::parse).collect(),
            test_mode: key.starts_with("sk_test") || key.starts_with("rk_test"),
        })
    }

    /// Netto-omzet van vandaag per valuta, grootste eerst.
    fn revenue(s: &StripeSnapshot) -> String {
        let mut totals: HashMap<String, i64> = HashMap::new();
        for p in s.today.iter().filter(|p| p.status == "succeeded") {
            *totals.entry(p.currency.clone()).or_default() += p.amount - p.refunded;
        }
        if totals.is_empty() {
            return money(0, s.recent.first().map(|p| p.currency.as_str()).unwrap_or("eur"));
        }
        let mut sorted: Vec<(String, i64)> = totals.into_iter().collect();
        sorted.sort_by_key(|b| std::cmp::Reverse(b.1));
        sorted.iter().map(|(c, v)| money(*v, c)).collect::<Vec<_>>().join(" + ")
    }

    fn dashboard(p: &Payment, test: bool) -> String {
        format!("https://dashboard.stripe.com/{}payments/{}", if test { "test/" } else { "" }, p.id)
    }

    fn apply(&self, s: StripeSnapshot) -> String {
        let ok = s.today.iter().filter(|p| p.status == "succeeded").count();
        let failed = s.today.iter().filter(|p| p.status == "failed").count();
        let mut detail = format!("{}{} vandaag", plural(ok, "betaling", "betalingen"), if s.more_today { "+" } else { "" });
        if failed > 0 {
            detail.push_str(&format!(" · {failed} mislukt"));
        }
        if s.test_mode {
            detail.push_str(" · testmodus");
        }
        let items = s
            .recent
            .iter()
            .map(|p| {
                let mut subtitle = format!("{} · {}", p.status, dates::ago(p.created));
                if p.refunded > 0 {
                    subtitle.push_str(&format!(" · {} terugbetaald", money(p.refunded, &p.currency)));
                }
                let tone = match p.status.as_str() {
                    "succeeded" if p.refunded > 0 => Tone::Neutral,
                    "succeeded" => Tone::Good,
                    "failed" => Tone::Bad,
                    _ => Tone::Neutral,
                };
                ConnectorItem::new(
                    &p.id,
                    format!("{} · {}", money(p.amount, &p.currency), short(&p.who, 40)),
                    subtitle,
                    tone,
                    Some(Self::dashboard(p, s.test_mode)),
                )
            })
            .collect();
        self.base.set(ConnectorStatus::ok(format!("{} vandaag", Self::revenue(&s)), detail.clone(), items, failed > 0));
        *lock(&self.snapshot) = Some(s);
        detail
    }

    async fn overview(&self) -> CResult<String> {
        let key = self.base.key(STRIPE_KEY).filter(|_| self.base.on()).ok_or_else(|| ConnectorError::not_set_up("Stripe"))?;
        let s = self.fetch(&key, 15).await?;
        let revenue = Self::revenue(&s);
        let detail = self.apply(s.clone());
        let mut out = vec![format!("Today's revenue (net): {revenue} · {detail}"), String::new(), "Recent payments:".into()];
        if s.recent.is_empty() {
            out.push("- none".into());
        }
        for p in &s.recent {
            let mut line = format!("- {} · {} · {} · {}", money(p.amount, &p.currency), p.who, p.status, dates::short(p.created));
            if p.refunded > 0 {
                line.push_str(&format!(" · {} refunded", money(p.refunded, &p.currency)));
            }
            if let Some(f) = &p.failure {
                line.push_str(&format!(" · reason: {f}"));
            }
            line.push_str(&format!(" · {}", Self::dashboard(p, s.test_mode)));
            out.push(line);
        }
        Ok(out.join("\n"))
    }
}

#[async_trait]
impl Connector for Stripe {
    fn id(&self) -> String {
        "stripe".into()
    }
    fn title(&self) -> String {
        "Stripe".into()
    }
    fn configured(&self) -> bool {
        self.base.key(STRIPE_KEY).is_some()
    }
    fn active(&self) -> bool {
        self.configured() && self.base.on()
    }
    fn status(&self) -> ConnectorStatus {
        self.base.status()
    }
    fn refresh_interval(&self) -> u64 {
        240
    }
    async fn refresh(&self) {
        let Some(key) = self.base.key(STRIPE_KEY).filter(|_| self.base.on()) else {
            *lock(&self.snapshot) = None;
            self.base.set(ConnectorStatus::default());
            return;
        };
        self.base.loading();
        match self.fetch(&key, 5).await {
            Ok(s) => {
                self.apply(s);
            }
            Err(e) => self.base.fail(&e),
        }
    }
    fn context_lines(&self) -> Vec<String> {
        if !self.base.status().is_ok() || !self.base.on() {
            return vec![];
        }
        let Some(s) = lock(&self.snapshot).clone() else { return vec![] };
        let ok = s.today.iter().filter(|p| p.status == "succeeded").count();
        let mut lines = vec![format!(
            "Stripe{}: {} revenue today from {}{}.",
            if s.test_mode { " (test mode)" } else { "" },
            Self::revenue(&s),
            plural(ok, "payment", "payments"),
            if s.more_today { " (100+)" } else { "" }
        )];
        let failed = s.today.iter().filter(|p| p.status == "failed").count();
        if failed > 0 {
            lines.push(format!("Stripe: {} today.", plural(failed, "failed payment", "failed payments")));
        }
        for p in s.recent.iter().take(4) {
            lines.push(format!(
                "Payment: {} from {}, {}, {}",
                money(p.amount, &p.currency),
                short(&p.who, 40),
                p.status,
                dates::ago(p.created)
            ));
        }
        lines.truncate(8);
        lines
    }
    fn tools(self: Arc<Self>, _scope: &Scope) -> Vec<LoopTool> {
        let me = self.clone();
        vec![LoopTool::read(
            "stripe_payments",
            "Fetches today's revenue and the most recent payments in Stripe: amount, customer, status, and time. Read only.",
            super::schema(json!({})),
            move |_| {
                let me = me.clone();
                async move { me.overview().await.map_err(Into::into) }
            },
        )]
    }
}

// Notion

#[derive(Debug, Clone)]
struct Page {
    id: String,
    title: String,
    edited: Option<DateTime<Utc>>,
    url: Option<String>,
}

pub struct Notion {
    base: Base,
    pages: Mutex<Option<Vec<Page>>>,
}

const NOTION_TOKEN: &str = "connector.notion.token";

/// Het id uit een id of link: de laatste 32 hex-tekens (met of zonder streepjes).
pub fn notion_page_id(raw: &str) -> Option<String> {
    let hex: String = raw.to_lowercase().replace('-', "");
    let re = regex::Regex::new(r"[0-9a-f]{32}").unwrap();
    let id = re.find_iter(&hex).filter(|m| !hex[m.end()..].starts_with(|c: char| c.is_ascii_hexdigit())).last()?.as_str().to_string();
    Some(format!("{}-{}-{}-{}-{}", &id[..8], &id[8..12], &id[12..16], &id[16..20], &id[20..]))
}

impl Notion {
    pub fn new(env: Arc<Env>) -> Arc<Self> {
        Arc::new(Self { base: Base::new(env, "notion"), pages: Mutex::default() })
    }

    fn headers(token: &str) -> Vec<(&'static str, String)> {
        vec![("Authorization", format!("Bearer {token}")), ("Notion-Version", "2022-06-28".into())]
    }

    fn plain(value: &Value) -> Option<String> {
        let text: String = list(value).iter().filter_map(|t| t["plain_text"].as_str()).collect();
        (!text.is_empty()).then_some(text)
    }

    fn parse(obj: &Value) -> Option<Page> {
        let id = obj["id"].as_str()?.to_string();
        // Databases hebben "title" in de root; pagina's een eigenschap van het type "title".
        let mut title = Self::plain(&obj["title"]).unwrap_or_default();
        if title.is_empty() {
            if let Some(props) = obj["properties"].as_object() {
                if let Some(t) = props.values().find(|p| p["type"] == "title").and_then(|p| Self::plain(&p["title"])) {
                    title = t;
                }
            }
        }
        Some(Page {
            id,
            title: if title.is_empty() { "Untitled".into() } else { title },
            edited: super::date(&obj["last_edited_time"]),
            url: link(obj["url"].as_str()),
        })
    }

    async fn search(&self, token: &str, query: Option<&str>, count: usize) -> CResult<Vec<Page>> {
        let mut body = json!({"sort": {"direction": "descending", "timestamp": "last_edited_time"}, "filter": {"property": "object", "value": "page"}, "page_size": count});
        if let Some(q) = query.filter(|q| !q.is_empty()) {
            body["query"] = json!(q);
        }
        let root = self
            .base
            .env
            .http
            .json("POST", &format!("{}/v1/search", base("notion", "https://api.notion.com")), &Self::headers(token), Some(&body), "Notion")
            .await?;
        Ok(list(&root["results"]).iter().filter_map(Self::parse).collect())
    }

    fn block_text(block: &Value) -> Option<String> {
        let kind = block["type"].as_str()?;
        let content = &block[kind];
        let Some(text) = Self::plain(&content["rich_text"]) else {
            return (kind == "child_page").then(|| content["title"].as_str().map(|t| format!("[subpage] {t}"))).flatten();
        };
        Some(match kind {
            "heading_1" => format!("# {text}"),
            "heading_2" => format!("## {text}"),
            "heading_3" => format!("### {text}"),
            "bulleted_list_item" => format!("- {text}"),
            "numbered_list_item" => format!("1. {text}"),
            "to_do" => format!("{}{text}", if content["checked"] == json!(true) { "- [x] " } else { "- [ ] " }),
            "quote" | "callout" => format!("> {text}"),
            "code" => format!("```\n{text}\n```"),
            _ => text,
        })
    }

    async fn read_page(&self, raw: &str) -> CResult<String> {
        let token = self.base.key(NOTION_TOKEN).filter(|_| self.base.on()).ok_or_else(|| ConnectorError::not_set_up("Notion"))?;
        let id = notion_page_id(raw).ok_or_else(|| ConnectorError::new(format!("Invalid Notion ID or link: {raw}")))?;
        let api = base("notion", "https://api.notion.com");
        let headers = Self::headers(&token);
        let page = self.base.env.http.get(&format!("{api}/v1/pages/{id}"), &headers, "Notion").await?;
        let info = Self::parse(&page);
        let mut lines = vec![];
        let mut cursor: Option<String> = None;
        for _ in 0..5 {
            let mut query = vec![("page_size", "100".to_string())];
            if let Some(c) = &cursor {
                query.push(("start_cursor", c.clone()));
            }
            let root = self.base.env.http.get(&with_query(&format!("{api}/v1/blocks/{id}/children"), &query), &headers, "Notion").await?;
            lines.extend(list(&root["results"]).iter().filter_map(Self::block_text));
            cursor = (root["has_more"] == json!(true)).then(|| root["next_cursor"].as_str().map(str::to_string)).flatten();
            if cursor.is_none() {
                break;
            }
        }
        let mut text = lines.join("\n");
        if text.chars().count() > 15_000 {
            text = format!("{}\n… (truncated)", text.chars().take(15_000).collect::<String>());
        }
        let title = info.as_ref().map(|i| i.title.clone()).unwrap_or_else(|| "Notion page".into());
        let edited = info.as_ref().and_then(|i| i.edited).map(|e| format!(" · edited {}", dates::short(e))).unwrap_or_default();
        let mut out = vec![format!("{title}{edited}"), String::new()];
        out.push(if text.is_empty() {
            "(No text on this page, or only unsupported blocks such as databases and images.)".into()
        } else {
            text
        });
        if let Some(url) = info.and_then(|i| i.url) {
            out.push(url);
        }
        Ok(out.join("\n"))
    }

    fn apply(&self, list: Vec<Page>) {
        let detail = list
            .first()
            .map(|p| format!("Laatste: {}{}", short(&p.title, 40), p.edited.map(|e| format!(" · {}", dates::ago(e))).unwrap_or_default()))
            .unwrap_or_default();
        let items = list
            .iter()
            .map(|p| {
                ConnectorItem::new(
                    &p.id,
                    &p.title,
                    p.edited.map(|e| format!("bewerkt {}", dates::ago(e))).unwrap_or_default(),
                    Tone::Neutral,
                    p.url.clone(),
                )
            })
            .collect();
        let headline = if list.is_empty() { "Geen gedeelde pagina's".into() } else { format!("{} pagina's recent bewerkt", list.len()) };
        self.base.set(ConnectorStatus::ok(headline, detail, items, false));
        *lock(&self.pages) = Some(list);
    }

    async fn overview(&self, query: Option<String>) -> CResult<String> {
        let token = self.base.key(NOTION_TOKEN).filter(|_| self.base.on()).ok_or_else(|| ConnectorError::not_set_up("Notion"))?;
        let has_query = query.as_deref().map(|q| !q.is_empty()).unwrap_or(false);
        let list = self.search(&token, query.as_deref(), 20).await?;
        if !has_query {
            self.apply(list.iter().take(8).cloned().collect());
        }
        if list.is_empty() {
            return Ok(if has_query {
                format!("No Notion pages found for '{}'.", query.unwrap_or_default())
            } else {
                "No Notion pages shared with Nook.".into()
            });
        }
        Ok(list
            .iter()
            .map(|p| {
                let mut line = format!("- {} (id {})", p.title, p.id);
                if let Some(e) = p.edited {
                    line.push_str(&format!(" · edited {}", dates::short(e)));
                }
                if let Some(u) = &p.url {
                    line.push_str(&format!(" · {u}"));
                }
                line
            })
            .collect::<Vec<_>>()
            .join("\n"))
    }
}

#[async_trait]
impl Connector for Notion {
    fn id(&self) -> String {
        "notion".into()
    }
    fn title(&self) -> String {
        "Notion".into()
    }
    fn configured(&self) -> bool {
        self.base.key(NOTION_TOKEN).is_some()
    }
    fn active(&self) -> bool {
        self.configured() && self.base.on()
    }
    fn status(&self) -> ConnectorStatus {
        self.base.status()
    }
    async fn refresh(&self) {
        let Some(token) = self.base.key(NOTION_TOKEN).filter(|_| self.base.on()) else {
            *lock(&self.pages) = None;
            self.base.set(ConnectorStatus::default());
            return;
        };
        self.base.loading();
        match self.search(&token, None, 8).await {
            Ok(list) => self.apply(list),
            Err(e) => self.base.fail(&e),
        }
    }
    fn context_lines(&self) -> Vec<String> {
        if !self.base.status().is_ok() || !self.base.on() {
            return vec![];
        }
        let pages = lock(&self.pages).clone().unwrap_or_default();
        if pages.is_empty() {
            return vec![];
        }
        let parts: Vec<String> = pages
            .iter()
            .take(5)
            .map(|p| format!("'{}'{}", short(&p.title, 50), p.edited.map(|e| format!(" ({})", dates::ago(e))).unwrap_or_default()))
            .collect();
        vec![format!("Notion, recently edited: {}", parts.join(", "))]
    }
    fn tools(self: Arc<Self>, _scope: &Scope) -> Vec<LoopTool> {
        let (a, b) = (self.clone(), self.clone());
        vec![
            LoopTool::read(
                "notion_search",
                "Searches Notion pages shared with Nook, most recently edited first. Without a search term, returns recently edited pages with links.",
                super::schema(json!({"query": {"type": "string", "description": "Search term in page title. Optional."}})),
                move |input| {
                    let me = a.clone();
                    async move { me.overview(super::field(&input, "query")).await.map_err(Into::into) }
                },
            ),
            LoopTool::read(
                "notion_read_page",
                "Reads the text of a single Notion page (headings, paragraphs, lists, to-dos, quotes, code). Provide the ID or link from notion_search. Use this to actually read a document before summarizing or comparing it.",
                json!({"type": "object", "properties": {"page": {"type": "string", "description": "Page ID or link."}}, "required": ["page"]}),
                move |input| {
                    let me = b.clone();
                    async move { me.read_page(super::text(&input, "page")).await.map_err(Into::into) }
                },
            ),
        ]
    }
}

// Cal.com

#[derive(Debug, Clone)]
struct Booking {
    id: String,
    title: String,
    start: DateTime<Utc>,
    end: Option<DateTime<Utc>>,
    status: String,
    attendee: Option<String>,
    url: Option<String>,
}

impl Booking {
    fn needs_confirmation(&self) -> bool {
        self.status == "pending" || self.status == "unconfirmed"
    }

    fn line(&self) -> String {
        let mut text = format!("'{}'", short(&self.title, 50));
        if let Some(who) = &self.attendee {
            text.push_str(&format!(" with {who}"));
        }
        text.push_str(&format!(", {}", dates::short(self.start)));
        if self.needs_confirmation() {
            text.push_str(" (awaiting confirmation)");
        }
        text
    }
}

pub struct Calcom {
    base: Base,
    bookings: Mutex<Option<Vec<Booking>>>,
}

const CALCOM_KEY: &str = "connector.calcom.key";

impl Calcom {
    pub fn new(env: Arc<Env>) -> Arc<Self> {
        Arc::new(Self { base: Base::new(env, "calcom"), bookings: Mutex::default() })
    }

    async fn fetch(&self, key: &str, count: usize) -> CResult<Vec<Booking>> {
        let url = with_query(
            &format!("{}/v2/bookings", base("calcom", "https://api.cal.com")),
            &[("status", "upcoming".into()), ("take", count.to_string())],
        );
        let root = self
            .base
            .env
            .http
            .get(&url, &[("Authorization", format!("Bearer {key}")), ("cal-api-version", "2024-08-13".into())], "Cal.com")
            .await?;
        let mut list: Vec<Booking> = list(&root["data"])
            .iter()
            .filter_map(|b| {
                let start = super::date(&b["start"]).or_else(|| super::date(&b["startTime"]))?;
                let uid = string(&b["uid"]);
                Some(Booking {
                    id: uid.clone().or_else(|| string(&b["id"])).unwrap_or_else(|| uuid::Uuid::new_v4().to_string()),
                    title: b["title"].as_str().unwrap_or("Appointment").into(),
                    start,
                    end: super::date(&b["end"]).or_else(|| super::date(&b["endTime"])),
                    status: b["status"].as_str().unwrap_or("accepted").to_lowercase(),
                    attendee: super::list(&b["attendees"])
                        .first()
                        .and_then(|a| a["name"].as_str().or(a["email"].as_str()))
                        .map(str::to_string),
                    url: uid.map(|u| format!("https://app.cal.com/booking/{u}")),
                })
            })
            .filter(|b| b.status != "cancelled" && b.status != "rejected")
            .collect();
        list.sort_by_key(|b| b.start);
        Ok(list)
    }

    fn apply(&self, list: Vec<Booking>) {
        let today = list.iter().filter(|b| dates::is_today(b.start)).count();
        let pending = list.iter().filter(|b| b.needs_confirmation()).count();
        let headline =
            list.first().map(|n| format!("Volgende: {}", dates::short(n.start))).unwrap_or_else(|| "Geen komende boekingen".into());
        let mut detail = format!("{today} vandaag · {} komend", list.len());
        if pending > 0 {
            detail.push_str(&format!(" · {pending} te bevestigen"));
        }
        let items = list
            .iter()
            .take(8)
            .map(|b| {
                let mut subtitle = dates::short(b.start);
                if let Some(w) = &b.attendee {
                    subtitle.push_str(&format!(" · met {w}"));
                }
                if b.needs_confirmation() {
                    subtitle.push_str(" · bevestigen");
                }
                ConnectorItem::new(
                    &b.id,
                    &b.title,
                    subtitle,
                    if b.needs_confirmation() { Tone::Attention } else { Tone::Neutral },
                    b.url.clone(),
                )
            })
            .collect();
        self.base.set(ConnectorStatus::ok(headline, detail, items, pending > 0));
        *lock(&self.bookings) = Some(list);
    }

    fn entries(list: &[Booking], from: DateTime<Utc>, to: DateTime<Utc>) -> Vec<AgendaEntry> {
        list.iter()
            .filter_map(|b| {
                let end = b.end.unwrap_or(b.start + Duration::minutes(30));
                (b.start < to && end > from).then(|| AgendaEntry {
                    title: b.title.clone(),
                    start: b.start,
                    end,
                    all_day: false,
                    busy: true,
                    location: String::new(),
                    calendar: "Cal.com".into(),
                })
            })
            .collect()
    }

    async fn overview(&self) -> CResult<String> {
        let key = self.base.key(CALCOM_KEY).filter(|_| self.base.on()).ok_or_else(|| ConnectorError::not_set_up("Cal.com"))?;
        let list = self.fetch(&key, 40).await?;
        self.apply(list.clone());
        if list.is_empty() {
            return Ok("No upcoming Cal.com bookings.".into());
        }
        Ok(list
            .iter()
            .map(|b| format!("- {}{}", b.line(), b.url.as_ref().map(|u| format!(" · {u}")).unwrap_or_default()))
            .collect::<Vec<_>>()
            .join("\n"))
    }
}

#[async_trait]
impl Connector for Calcom {
    fn id(&self) -> String {
        "calcom".into()
    }
    fn title(&self) -> String {
        "Cal.com".into()
    }
    fn configured(&self) -> bool {
        self.base.key(CALCOM_KEY).is_some()
    }
    fn active(&self) -> bool {
        self.configured() && self.base.on()
    }
    fn status(&self) -> ConnectorStatus {
        self.base.status()
    }
    async fn refresh(&self) {
        let Some(key) = self.base.key(CALCOM_KEY).filter(|_| self.base.on()) else {
            *lock(&self.bookings) = None;
            self.base.set(ConnectorStatus::default());
            return;
        };
        self.base.loading();
        match self.fetch(&key, 20).await {
            Ok(list) => self.apply(list),
            Err(e) => self.base.fail(&e),
        }
    }
    fn context_lines(&self) -> Vec<String> {
        if !self.base.status().is_ok() || !self.base.on() {
            return vec![];
        }
        let Some(list) = lock(&self.bookings).clone() else { return vec![] };
        if list.is_empty() {
            return vec!["Cal.com: no upcoming bookings.".into()];
        }
        let mut lines = vec![format!("Cal.com: {}.", plural(list.len(), "upcoming booking", "upcoming bookings"))];
        lines.extend(list.iter().take(4).map(|b| format!("Booking: {}", b.line())));
        let pending = list.iter().filter(|b| b.needs_confirmation()).count();
        if pending > 0 {
            lines.push(format!("Cal.com: {} confirmation.", plural(pending, "booking awaiting", "bookings awaiting")));
        }
        lines.truncate(8);
        lines
    }
    fn tools(self: Arc<Self>, _scope: &Scope) -> Vec<LoopTool> {
        let me = self.clone();
        vec![LoopTool::read(
            "calcom_bookings",
            "Fetches upcoming Cal.com bookings for the user: title, time, attendee, status, and link.",
            super::schema(json!({})),
            move |_| {
                let me = me.clone();
                async move { me.overview().await.map_err(Into::into) }
            },
        )]
    }
    fn agenda_names(&self) -> Vec<String> {
        vec!["Cal.com bookings".into()]
    }
    async fn agenda(&self, from: DateTime<Utc>, to: DateTime<Utc>) -> Option<CResult<AgendaResult>> {
        let Some(key) = self.base.key(CALCOM_KEY) else { return Some(Err(ConnectorError::not_set_up("Cal.com"))) };
        Some(self.fetch(&key, 100).await.map(|list| AgendaResult { entries: Self::entries(&list, from, to), problems: vec![] }))
    }
    fn cached_agenda(&self) -> Vec<AgendaEntry> {
        let list = lock(&self.bookings).clone().unwrap_or_default();
        let now = Utc::now();
        Self::entries(&list, dates::start_of_day(now), now + Duration::days(7))
    }
}

// n8n

#[derive(Debug, Clone)]
struct Failure {
    id: String,
    workflow: String,
    when: Option<DateTime<Utc>>,
    url: Option<String>,
}

#[derive(Debug, Clone)]
struct N8nSnapshot {
    workflows: usize,
    active: usize,
    failures: Vec<Failure>,
}

impl N8nSnapshot {
    fn recent(&self) -> Vec<Failure> {
        let cutoff = Utc::now() - Duration::hours(24);
        self.failures.iter().filter(|f| f.when.map(|w| w > cutoff).unwrap_or(false)).cloned().collect()
    }
}

pub struct N8n {
    base: Base,
    snapshot: Mutex<Option<N8nSnapshot>>,
}

const N8N_URL: &str = "connector.n8n.url";
const N8N_KEY: &str = "connector.n8n.key";

/// "https://n8n.example.com/" of ".../api/v1" wordt "https://n8n.example.com".
pub fn n8n_base(raw: &str) -> CResult<String> {
    let mut base = raw.trim().trim_end_matches('/').to_string();
    if let Some(stripped) = base.strip_suffix("/api/v1") {
        base = stripped.to_string();
    }
    let url =
        url::Url::parse(&base).map_err(|_| ConnectorError::kind("Het n8n-adres moet met https:// beginnen.", super::ErrorKind::Config))?;
    if !(url.scheme() == "https" || url.scheme() == "http") || url.host_str().is_none() {
        return Err(ConnectorError::kind("Het n8n-adres moet met https:// beginnen.", super::ErrorKind::Config));
    }
    Ok(base)
}

impl N8n {
    pub fn new(env: Arc<Env>) -> Arc<Self> {
        Arc::new(Self { base: Base::new(env, "n8n"), snapshot: Mutex::default() })
    }

    fn credentials(&self) -> Option<(String, String)> {
        Some((self.base.key(N8N_URL)?, self.base.key(N8N_KEY)?))
    }

    async fn fetch(&self, raw: &str, key: &str, count: usize) -> CResult<N8nSnapshot> {
        let base = n8n_base(raw)?;
        let auth = [("X-N8N-API-KEY", key.to_string())];
        let workflows =
            self.base.env.http.get(&with_query(&format!("{base}/api/v1/workflows"), &[("limit", "250".into())]), &auth, "n8n").await?;
        let mut names = HashMap::new();
        let mut active = 0;
        let list_w = list(&workflows["data"]);
        for w in list_w {
            if let Some(id) = string(&w["id"]) {
                names.insert(id, w["name"].as_str().unwrap_or("Workflow").to_string());
            }
            if w["active"] == json!(true) {
                active += 1;
            }
        }
        let executions = self
            .base
            .env
            .http
            .get(
                &with_query(&format!("{base}/api/v1/executions"), &[("status", "error".into()), ("limit", count.to_string())]),
                &auth,
                "n8n",
            )
            .await?;
        let failures = list(&executions["data"])
            .iter()
            .filter_map(|e| {
                let id = string(&e["id"])?;
                let wid = string(&e["workflowId"]).unwrap_or_default();
                Some(Failure {
                    workflow: names.get(&wid).cloned().unwrap_or_else(|| {
                        if wid.is_empty() {
                            "Workflow".into()
                        } else {
                            format!("Workflow {wid}")
                        }
                    }),
                    when: super::date(&e["stoppedAt"]).or_else(|| super::date(&e["startedAt"])),
                    url: (!wid.is_empty()).then(|| format!("{base}/workflow/{wid}/executions/{id}")),
                    id,
                })
            })
            .collect();
        Ok(N8nSnapshot { workflows: list_w.len(), active, failures })
    }

    fn apply(&self, s: N8nSnapshot) {
        let recent = s.recent();
        let detail = if recent.is_empty() {
            "Geen fouten in 24 uur".to_string()
        } else {
            format!("{} in 24 uur", plural(recent.len(), "mislukte run", "mislukte runs"))
        };
        let cutoff = Utc::now() - Duration::hours(24);
        let items = s
            .failures
            .iter()
            .take(8)
            .map(|f| {
                let recent = f.when.map(|w| w > cutoff).unwrap_or(false);
                ConnectorItem::new(
                    &f.id,
                    &f.workflow,
                    format!("Mislukt{}", f.when.map(|w| format!(" · {}", dates::ago(w))).unwrap_or_default()),
                    if recent { Tone::Bad } else { Tone::Neutral },
                    f.url.clone(),
                )
            })
            .collect();
        self.base.set(ConnectorStatus::ok(format!("{} actieve workflows", s.active), detail, items, !recent.is_empty()));
        *lock(&self.snapshot) = Some(s);
    }

    async fn overview(&self) -> CResult<String> {
        let (raw, key) = self.credentials().filter(|_| self.base.on()).ok_or_else(|| ConnectorError::not_set_up("n8n"))?;
        let s = self.fetch(&raw, &key, 25).await?;
        self.apply(s.clone());
        let mut out = vec![format!("Workflows: {}, with {} active.", s.workflows, s.active), String::new(), "Recent failed runs:".into()];
        if s.failures.is_empty() {
            out.push("- none".into());
        }
        for f in &s.failures {
            let mut line = format!("- {} (run {})", f.workflow, f.id);
            if let Some(w) = f.when {
                line.push_str(&format!(" · {}", dates::short(w)));
            }
            if let Some(u) = &f.url {
                line.push_str(&format!(" · {u}"));
            }
            out.push(line);
        }
        Ok(out.join("\n"))
    }
}

#[async_trait]
impl Connector for N8n {
    fn id(&self) -> String {
        "n8n".into()
    }
    fn title(&self) -> String {
        "n8n".into()
    }
    fn configured(&self) -> bool {
        self.credentials().is_some()
    }
    fn active(&self) -> bool {
        self.configured() && self.base.on()
    }
    fn status(&self) -> ConnectorStatus {
        self.base.status()
    }
    fn refresh_interval(&self) -> u64 {
        180
    }
    async fn refresh(&self) {
        let Some((raw, key)) = self.credentials().filter(|_| self.base.on()) else {
            *lock(&self.snapshot) = None;
            self.base.set(ConnectorStatus::default());
            return;
        };
        self.base.loading();
        match self.fetch(&raw, &key, 10).await {
            Ok(s) => self.apply(s),
            Err(e) => self.base.fail(&e),
        }
    }
    fn context_lines(&self) -> Vec<String> {
        if !self.base.status().is_ok() || !self.base.on() {
            return vec![];
        }
        let Some(s) = lock(&self.snapshot).clone() else { return vec![] };
        let recent = s.recent();
        let mut lines = vec![format!(
            "n8n: {} of {} workflows active, {} in 24 hours.",
            s.active,
            s.workflows,
            plural(recent.len(), "failed run", "failed runs")
        )];
        for f in recent.iter().take(4) {
            lines.push(format!(
                "n8n run failed: '{}'{}",
                short(&f.workflow, 50),
                f.when.map(|w| format!(" ({})", dates::ago(w))).unwrap_or_default()
            ));
        }
        lines
    }
    fn tools(self: Arc<Self>, _scope: &Scope) -> Vec<LoopTool> {
        let me = self.clone();
        vec![LoopTool::read(
            "n8n_status",
            "Fetches the user's n8n workflows (active count) and recent failed runs with workflow, time, and link. Read only.",
            super::schema(json!({})),
            move |_| {
                let me = me.clone();
                async move { me.overview().await.map_err(Into::into) }
            },
        )]
    }
}

// Resend

#[derive(Debug, Clone)]
struct Domain {
    id: String,
    name: String,
    status: String,
}

#[derive(Debug, Clone)]
struct Email {
    id: String,
    to: String,
    subject: String,
    event: String,
    created: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone)]
struct ResendSnapshot {
    domains: Vec<Domain>,
    emails: Vec<Email>,
}

pub struct Resend {
    base: Base,
    snapshot: Mutex<Option<ResendSnapshot>>,
}

const RESEND_KEY: &str = "connector.resend.key";

/// Resend geeft soms "2023-04-03 22:13:42.674981+00" in plaats van ISO 8601.
pub fn resend_date(value: &Value) -> Option<DateTime<Utc>> {
    let text = value.as_str().filter(|s| !s.is_empty())?;
    if let Some(d) = dates::parse(text) {
        return Some(d);
    }
    let head: String = text.chars().take(19).collect();
    chrono::NaiveDateTime::parse_from_str(&head, "%Y-%m-%d %H:%M:%S").ok().map(|n| n.and_utc())
}

fn event_label(event: &str) -> String {
    match event {
        "complained" => "reported as spam".into(),
        "delivery_delayed" => "delayed".into(),
        "" => "unknown".into(),
        other => other.into(),
    }
}

impl Resend {
    pub fn new(env: Arc<Env>) -> Arc<Self> {
        Arc::new(Self { base: Base::new(env, "resend"), snapshot: Mutex::default() })
    }

    async fn fetch(&self, key: &str, count: usize) -> CResult<ResendSnapshot> {
        let api = base("resend", "https://api.resend.com");
        let auth = [("Authorization", format!("Bearer {key}"))];
        let domains_root = self.base.env.http.get(&format!("{api}/domains"), &auth, "Resend").await?;
        let domains = list(&domains_root["data"])
            .iter()
            .filter_map(|d| {
                Some(Domain {
                    id: string(&d["id"])?,
                    name: d["name"].as_str()?.into(),
                    status: d["status"].as_str().unwrap_or("unknown").into(),
                })
            })
            .collect();
        // De lijst met mails is optioneel: zonder die rechten toont Nook alleen domeinen.
        let emails_root = self.base.env.http.get(&format!("{api}/emails?limit={count}"), &auth, "Resend").await.unwrap_or(Value::Null);
        let emails = list(&emails_root["data"])
            .iter()
            .filter_map(|e| {
                let to = match &e["to"] {
                    Value::Array(a) => a.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(", "),
                    v => v.as_str().unwrap_or("?").into(),
                };
                Some(Email {
                    id: string(&e["id"])?,
                    to,
                    subject: e["subject"].as_str().unwrap_or("(no subject)").into(),
                    event: e["last_event"].as_str().unwrap_or("").into(),
                    created: resend_date(&e["created_at"]),
                })
            })
            .collect();
        Ok(ResendSnapshot { domains, emails })
    }

    fn apply(&self, s: ResendSnapshot) {
        let unverified: Vec<&Domain> = s.domains.iter().filter(|d| d.status != "verified").collect();
        let troubled = s.emails.iter().filter(|e| e.event == "bounced" || e.event == "complained").count();
        let headline = if let Some(first) = unverified.first() {
            format!("Domein niet klaar: {}", first.name)
        } else if s.emails.is_empty() {
            format!("{} domeinen in orde", s.domains.len())
        } else {
            format!("{} recente mails", s.emails.len())
        };
        let detail = if troubled == 0 { "Geen bounces".to_string() } else { plural(troubled, "bezorgprobleem", "bezorgproblemen") };
        let mut items: Vec<ConnectorItem> = unverified
            .iter()
            .take(3)
            .map(|d| {
                ConnectorItem::new(
                    format!("domain-{}", d.id),
                    &d.name,
                    format!("Domein · {}", d.status),
                    if d.status == "failed" { Tone::Bad } else { Tone::Attention },
                    Some(format!("https://resend.com/domains/{}", d.id)),
                )
            })
            .collect();
        let room = 8usize.saturating_sub(items.len());
        for e in s.emails.iter().take(room) {
            let tone = match e.event.as_str() {
                "delivered" | "opened" | "clicked" => Tone::Good,
                "bounced" | "complained" => Tone::Bad,
                "delivery_delayed" => Tone::Attention,
                _ => Tone::Neutral,
            };
            let subtitle = format!(
                "{} · aan {}{}",
                event_label(&e.event),
                e.to,
                e.created.map(|c| format!(" · {}", dates::ago(c))).unwrap_or_default()
            );
            items.push(ConnectorItem::new(
                format!("email-{}", e.id),
                &e.subject,
                subtitle,
                tone,
                Some(format!("https://resend.com/emails/{}", e.id)),
            ));
        }
        self.base.set(ConnectorStatus::ok(headline, detail, items, !unverified.is_empty() || troubled > 0));
        *lock(&self.snapshot) = Some(s);
    }

    async fn overview(&self) -> CResult<String> {
        let key = self.base.key(RESEND_KEY).filter(|_| self.base.on()).ok_or_else(|| ConnectorError::not_set_up("Resend"))?;
        let s = self.fetch(&key, 50).await?;
        self.apply(s.clone());
        let mut out = vec!["Domains:".to_string()];
        if s.domains.is_empty() {
            out.push("- none".into());
        }
        out.extend(s.domains.iter().map(|d| format!("- {}: {}", d.name, d.status)));
        out.push(String::new());
        out.push("Recent emails:".into());
        if s.emails.is_empty() {
            out.push("- none (or the key does not have permission to read emails)".into());
        }
        out.extend(s.emails.iter().map(|e| {
            format!(
                "- '{}' to {} · {}{}",
                e.subject,
                e.to,
                event_label(&e.event),
                e.created.map(|c| format!(" · {}", dates::short(c))).unwrap_or_default()
            )
        }));
        Ok(out.join("\n"))
    }
}

#[async_trait]
impl Connector for Resend {
    fn id(&self) -> String {
        "resend".into()
    }
    fn title(&self) -> String {
        "Resend".into()
    }
    fn configured(&self) -> bool {
        self.base.key(RESEND_KEY).is_some()
    }
    fn active(&self) -> bool {
        self.configured() && self.base.on()
    }
    fn status(&self) -> ConnectorStatus {
        self.base.status()
    }
    async fn refresh(&self) {
        let Some(key) = self.base.key(RESEND_KEY).filter(|_| self.base.on()) else {
            *lock(&self.snapshot) = None;
            self.base.set(ConnectorStatus::default());
            return;
        };
        self.base.loading();
        match self.fetch(&key, 20).await {
            Ok(s) => self.apply(s),
            Err(e) => self.base.fail(&e),
        }
    }
    fn context_lines(&self) -> Vec<String> {
        if !self.base.status().is_ok() || !self.base.on() {
            return vec![];
        }
        let Some(s) = lock(&self.snapshot).clone() else { return vec![] };
        let mut lines = vec![format!(
            "Resend: {}, {}.",
            plural(s.domains.len(), "domain", "domains"),
            plural(s.emails.len(), "recent email", "recent emails")
        )];
        for d in s.domains.iter().filter(|d| d.status != "verified").take(3) {
            lines.push(format!("Resend domain not verified: {} ({})", d.name, d.status));
        }
        for e in s.emails.iter().filter(|e| e.event == "bounced" || e.event == "complained").take(3) {
            lines.push(format!("Email {}: '{}' to {}", event_label(&e.event), short(&e.subject, 50), e.to));
        }
        if let Some(last) = s.emails.first() {
            lines.push(format!("Latest email: '{}' to {}, {}", short(&last.subject, 50), last.to, event_label(&last.event)));
        }
        lines.truncate(8);
        lines
    }
    fn tools(self: Arc<Self>, _scope: &Scope) -> Vec<LoopTool> {
        let me = self.clone();
        vec![LoopTool::read(
            "resend_overview",
            "Fetches emails recently sent via Resend (recipient, subject, delivered/bounced) and domain status. Never sends anything.",
            super::schema(json!({})),
            move |_| {
                let me = me.clone();
                async move { me.overview().await.map_err(Into::into) }
            },
        )]
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::connectors::testserver::TestServer;
    use crate::connectors::ConnectorStore;
    use crate::secrets::{MemorySecrets, SecretStore};

    #[test]
    fn notion_ids_from_links() {
        assert_eq!(
            notion_page_id("https://www.notion.so/Plan-1234567890abcdef1234567890abcdef").as_deref(),
            Some("12345678-90ab-cdef-1234-567890abcdef")
        );
        assert_eq!(notion_page_id("12345678-90ab-cdef-1234-567890abcdef").as_deref(), Some("12345678-90ab-cdef-1234-567890abcdef"));
        assert_eq!(notion_page_id("geen id"), None);
    }

    #[test]
    fn n8n_addresses_and_resend_dates() {
        assert_eq!(n8n_base("https://n8n.example.com/api/v1/").unwrap(), "https://n8n.example.com");
        assert!(n8n_base("n8n.example.com").is_err());
        assert!(resend_date(&json!("2023-04-03 22:13:42.674981+00")).is_some());
        assert!(resend_date(&json!("2023-04-03T22:13:42Z")).is_some());
    }

    // Eén test per proces-omgevingsvariabele: Stripe en Cal.com tegen een nep-API.
    #[tokio::test]
    async fn stripe_and_calcom_against_a_fake_api() {
        let now = Utc::now();
        let server = TestServer::start(vec![
            ("GET /v1/charges", 200, json!({"has_more": false, "data": [
                {"id": "ch_1", "amount": 124050, "amount_refunded": 0, "currency": "eur", "status": "succeeded", "created": now.timestamp(), "billing_details": {"name": "Acme"}},
                {"id": "ch_2", "amount": 500, "currency": "eur", "status": "failed", "created": now.timestamp(), "failure_message": "card_declined"}
            ]}).to_string()),
            ("GET /v2/bookings", 200, json!({"data": [
                {"uid": "b1", "title": "Intake", "start": (now + Duration::hours(2)).to_rfc3339(), "end": (now + Duration::hours(3)).to_rfc3339(), "status": "accepted", "attendees": [{"name": "Sanne"}]},
                {"uid": "b2", "title": "Afgezegd", "start": (now + Duration::hours(4)).to_rfc3339(), "status": "cancelled"}
            ]}).to_string()),
        ])
        .await;
        std::env::set_var("NOOK_STRIPE_API_URL", server.url(""));
        std::env::set_var("NOOK_CALCOM_API_URL", server.url(""));
        let secrets = Arc::new(MemorySecrets::default());
        secrets.write("connector.stripe.key", "rk_test_x").unwrap();
        secrets.write("connector.calcom.key", "cal_x").unwrap();
        let env = Env::new(secrets, Arc::new(ConnectorStore::in_memory()));

        let stripe = Stripe::new(env.clone());
        stripe.refresh().await;
        let s = stripe.status();
        assert_eq!(s.headline, "€ 1.240,50 vandaag");
        assert!(s.detail.contains("1 mislukt") && s.detail.contains("testmodus"));
        assert!(s.needs_attention);
        assert!(stripe.context_lines()[0].starts_with("Stripe (test mode): € 1.240,50 revenue today from 1 payment"));
        assert_eq!(server.requests()[0].header("authorization"), Some("Bearer rk_test_x"));

        let cal = Calcom::new(env.clone());
        cal.refresh().await;
        assert!(cal.status().headline.starts_with("Volgende: "));
        let result = cal.agenda(now, now + Duration::days(1)).await.unwrap().unwrap();
        assert_eq!(result.entries.len(), 1, "cancelled bookings never block");
        assert_eq!(result.entries[0].calendar, "Cal.com");
        assert_eq!(cal.cached_agenda().len(), 1);
        std::env::remove_var("NOOK_STRIPE_API_URL");
        std::env::remove_var("NOOK_CALCOM_API_URL");
    }
}
