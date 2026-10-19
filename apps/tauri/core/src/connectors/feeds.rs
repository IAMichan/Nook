//! Andere agenda's: elke agenda met een ICS-adres (Google Agenda, Outlook, iCloud, Fastmail, Proton, werkagenda's…).
//! Het adres is geheim (wie het heeft, ziet je agenda) en staat in de kluis. Alleen lezen, alleen https (of een adres
//! op deze computer zelf).

use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use chrono::{DateTime, Duration, Utc};

use super::agenda::{AgendaEntry, AgendaResult};
use super::hub::{Connector, Env};
use super::ics::Calendar;
use super::{dates, CResult, ConnectorError, ConnectorItem, ConnectorStatus, ErrorKind, Tone};

pub const ID: &str = "icalfeeds";
pub const KEY_ACCOUNT: &str = "connector.icalfeeds.urls";
const MAX_BYTES: usize = 12_000_000;

/// Meer adressen mogen samen, gescheiden door een spatie, komma of nieuwe regel. `webcal://` is gewoon https.
pub fn urls(raw: &str) -> Vec<String> {
    let re = regex::Regex::new(r"(?i)(\S)((?:https?|webcals?)://)").unwrap();
    let spaced = re.replace_all(raw, "$1 $2");
    let mut seen = std::collections::HashSet::new();
    spaced.split(|c: char| c.is_whitespace() || c == ',').filter_map(normalized).filter(|u| seen.insert(u.clone())).collect()
}

fn normalized(text: &str) -> Option<String> {
    let mut value = super::clean(text);
    if value.is_empty() {
        return None;
    }
    let lower = value.to_lowercase();
    if lower.starts_with("webcals://") {
        value = format!("https://{}", &value[10..]);
    } else if lower.starts_with("webcal://") {
        value = format!("https://{}", &value[9..]);
    }
    let url = url::Url::parse(&value).ok()?;
    let host = url.host_str()?.to_lowercase();
    let loopback = host == "127.0.0.1" || host == "localhost" || host == "[::1]";
    (url.scheme() == "https" || (url.scheme() == "http" && loopback)).then(|| url.to_string())
}

struct Feed {
    url: String,
    name: String,
    calendar: Calendar,
}

pub struct CalendarFeeds {
    env: Arc<Env>,
    cache: Mutex<Vec<Feed>>,
    status: Mutex<ConnectorStatus>,
}

impl CalendarFeeds {
    pub fn new(env: Arc<Env>) -> Arc<Self> {
        Arc::new(Self { env, cache: Mutex::new(vec![]), status: Mutex::new(ConnectorStatus::default()) })
    }

    fn urls(&self) -> Vec<String> {
        self.env.secret(KEY_ACCOUNT).map(|raw| urls(&raw)).unwrap_or_default()
    }

    async fn download(&self, url: &str) -> CResult<Calendar> {
        let response = self
            .env
            .http
            .client
            .get(url)
            .header("Accept", "text/calendar, text/plain, */*")
            .send()
            .await
            .map_err(|e| super::network_error(e, "de agenda"))?;
        let code = response.status().as_u16();
        if !(200..300).contains(&code) {
            return Err(match code {
                401 | 403 | 404 => ConnectorError::kind(format!("Het adres werd geweigerd ({code}). Is het nog geldig?"), ErrorKind::Auth),
                429 => ConnectorError::kind("Te veel verzoeken. Nook probeert het zo opnieuw.", ErrorKind::RateLimited),
                _ => ConnectorError::new(format!("De agenda gaf een fout ({code}).")),
            });
        }
        let bytes = response.bytes().await.map_err(|e| super::network_error(e, "de agenda"))?;
        if bytes.len() > MAX_BYTES {
            return Err(ConnectorError::new("Deze agenda is te groot om te lezen."));
        }
        let text = match String::from_utf8(bytes.to_vec()) {
            Ok(t) => t,
            Err(_) => bytes.iter().map(|b| *b as char).collect(),
        };
        if !text.contains("BEGIN:VCALENDAR") {
            return Err(ConnectorError::kind("Dit adres geeft geen agenda (ICS) terug.", ErrorKind::Config));
        }
        Ok(Calendar::parse(&text))
    }

    fn host(url: &str) -> String {
        url::Url::parse(url).ok().and_then(|u| u.host_str().map(str::to_string)).unwrap_or_else(|| "Agenda".into())
    }

    /// Haalt alle adressen op. Een adres dat niet lukt, houdt zijn vorige versie; het adres zelf komt nooit in een fout.
    async fn fetch_all(&self) -> (Vec<Feed>, Vec<String>) {
        let mut ok = vec![];
        let mut errors = vec![];
        for url in self.urls() {
            match self.download(&url).await {
                Ok(calendar) => {
                    let name = calendar.name.clone().filter(|n| !n.is_empty()).unwrap_or_else(|| Self::host(&url));
                    ok.push(Feed { url, name, calendar });
                }
                Err(e) => {
                    let mut cache = self.cache.lock().unwrap_or_else(|e| e.into_inner());
                    let label = cache.iter().find(|f| f.url == url).map(|f| f.name.clone()).unwrap_or_else(|| Self::host(&url));
                    errors.push(format!("{label}: {}", e.message));
                    if let Some(pos) = cache.iter().position(|f| f.url == url) {
                        ok.push(cache.remove(pos));
                    }
                }
            }
        }
        (ok, errors)
    }

    fn upcoming(&self, days: i64) -> Vec<AgendaEntry> {
        let now = Utc::now();
        let start = dates::start_of_day(now);
        let end = now + Duration::days(days);
        let cache = self.cache.lock().unwrap_or_else(|e| e.into_inner());
        let mut list: Vec<AgendaEntry> = cache.iter().flat_map(|f| f.calendar.entries(start, end, &f.name)).collect();
        list.sort_by_key(|e| e.start);
        list
    }

    fn apply(&self, errors: &[String]) {
        let now = Utc::now();
        let list: Vec<AgendaEntry> = self.upcoming(7).into_iter().filter(|e| e.end > now).collect();
        let count = self.cache.lock().unwrap_or_else(|e| e.into_inner()).len();
        let today = list.iter().filter(|e| dates::is_today(e.start)).count();
        let status = if count == 0 && !errors.is_empty() {
            ConnectorStatus { state: super::ConnectorState::Error(errors.join(" · ")), ..Default::default() }
        } else {
            let mut detail = format!("{count} agenda's");
            if !errors.is_empty() {
                detail.push_str(&format!(" · {}", errors.join(" · ")));
            }
            let headline = if today == 0 { "Vandaag niets meer".to_string() } else { format!("{today} afspraken vandaag") };
            let items = list
                .iter()
                .take(5)
                .map(|e| {
                    ConnectorItem::new(
                        format!("{}-{}-{}", e.calendar, e.start.timestamp(), e.title),
                        &e.title,
                        format!("{} · {}", dates::short(e.start), e.calendar),
                        Tone::Neutral,
                        None,
                    )
                })
                .collect();
            ConnectorStatus::ok(headline, detail, items, false)
        };
        *self.status.lock().unwrap_or_else(|e| e.into_inner()) = status;
    }
}

#[async_trait]
impl Connector for CalendarFeeds {
    fn id(&self) -> String {
        ID.into()
    }

    fn title(&self) -> String {
        "Andere agenda's".into()
    }

    fn configured(&self) -> bool {
        !self.urls().is_empty()
    }

    fn active(&self) -> bool {
        self.configured() && self.env.store.is_on(ID)
    }

    fn status(&self) -> ConnectorStatus {
        self.status.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    fn refresh_interval(&self) -> u64 {
        600
    }

    async fn refresh(&self) {
        if !self.active() {
            self.cache.lock().unwrap_or_else(|e| e.into_inner()).clear();
            *self.status.lock().unwrap_or_else(|e| e.into_inner()) = ConnectorStatus::default();
            return;
        }
        {
            let mut status = self.status.lock().unwrap_or_else(|e| e.into_inner());
            if status.updated.is_none() {
                status.state = super::ConnectorState::Loading;
            }
        }
        let (ok, errors) = self.fetch_all().await;
        *self.cache.lock().unwrap_or_else(|e| e.into_inner()) = ok;
        self.apply(&errors);
    }

    fn agenda_names(&self) -> Vec<String> {
        let mut names: Vec<String> =
            self.cache.lock().unwrap_or_else(|e| e.into_inner()).iter().map(|f| format!("{} (ICS)", f.name)).collect();
        names.sort();
        if names.is_empty() && self.active() {
            names.push("Andere agenda's (ICS)".into());
        }
        names
    }

    async fn agenda(&self, from: DateTime<Utc>, to: DateTime<Utc>) -> Option<CResult<AgendaResult>> {
        if !self.active() {
            return Some(Err(ConnectorError::not_set_up("Andere agenda's")));
        }
        let (ok, errors) = self.fetch_all().await;
        if ok.is_empty() && !errors.is_empty() {
            return Some(Err(ConnectorError::new(errors.join(" · "))));
        }
        let mut entries: Vec<AgendaEntry> = ok.iter().flat_map(|f| f.calendar.entries(from, to, &f.name)).collect();
        entries.sort_by_key(|e| e.start);
        *self.cache.lock().unwrap_or_else(|e| e.into_inner()) = ok;
        self.apply(&errors);
        Some(Ok(AgendaResult { entries, problems: errors }))
    }

    fn cached_agenda(&self) -> Vec<AgendaEntry> {
        if !self.status().is_ok() {
            return vec![];
        }
        self.upcoming(7).into_iter().take(25).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::connectors::testserver::TestServer;
    use crate::connectors::ConnectorStore;
    use crate::secrets::{MemorySecrets, SecretStore};

    #[test]
    fn splits_and_normalizes_addresses() {
        let list = urls("webcal://p01-caldav.icloud.com/x.ics,https://calendar.google.com/a/basic.icshttps://outlook.office365.com/b.ics\nhttp://evil.example.com/c.ics");
        assert_eq!(
            list,
            ["https://p01-caldav.icloud.com/x.ics", "https://calendar.google.com/a/basic.ics", "https://outlook.office365.com/b.ics"]
        );
        assert_eq!(urls("http://127.0.0.1:8123/werk.ics"), ["http://127.0.0.1:8123/werk.ics"]);
        assert!(urls("niet een adres").is_empty());
    }

    #[tokio::test]
    async fn reads_feeds_and_hides_the_address_in_errors() {
        let server = TestServer::start(vec![
            ("/werk.ics", 200, "BEGIN:VCALENDAR\r\nX-WR-CALNAME:Werk\r\nBEGIN:VEVENT\r\nUID:1\r\nSUMMARY:Tandarts\r\nDTSTART:20261013T110000Z\r\nDTEND:20261013T120000Z\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n".into()),
            ("/kapot.ics", 404, String::new()),
        ])
        .await;
        let secrets = Arc::new(MemorySecrets::default());
        secrets.write(KEY_ACCOUNT, &format!("{} {}", server.url("/werk.ics"), server.url("/kapot.ics"))).unwrap();
        let feeds = CalendarFeeds::new(Env::new(secrets, Arc::new(ConnectorStore::in_memory())));
        assert!(feeds.active());
        let from = dates::parse("2026-10-13").unwrap();
        let result = feeds.agenda(from, from + Duration::days(1)).await.unwrap().unwrap();
        assert_eq!(result.entries.len(), 1);
        assert_eq!(result.entries[0].calendar, "Werk");
        assert_eq!(result.problems.len(), 1);
        assert!(result.problems[0].starts_with("127.0.0.1: Het adres werd geweigerd (404)"));
        assert!(!result.problems[0].contains("kapot"), "the secret address never shows");
        assert_eq!(feeds.agenda_names(), ["Werk (ICS)"]);
    }
}
