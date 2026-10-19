//! Waar de companion-server zijn sessies vandaan haalt: de agents en de werkruimte van de app. Op de Mac is dat
//! `WorkspaceManager`; hier een trait die de app invult, zodat de server zelf niets van agents hoeft te weten.

use async_trait::async_trait;

use super::models::SessionDigest;

/// Een sessie zoals de backend hem geeft. De teksten mogen lang zijn: de server knipt ze met
/// [`CompanionPolicy::excerpt`](super::models::CompanionPolicy::excerpt), sorteert op `updated` en stuurt er hoogstens 25.
#[derive(Debug, Clone, PartialEq)]
pub struct BackendSession {
    /// `items` bevat elke wachtende goedkeuring (`kind = approval`) en vraag (`kind = question`):
    /// - goedkeuring: `title` = samenvatting, `detail` = toolnaam, `can_allow` =
    ///   `CompanionPolicy::can_allow(tool, command_is_safe)` (een commando met `CommandRisk` beoordeeld), `options` leeg;
    /// - vraag: `title` = de (eerste) vraag, `detail` = de kop, `can_allow` = er is precies één vraag,
    ///   `options` = de labels van de keuzes (alleen bij één vraag).
    pub digest: SessionDigest,
    /// De sessie is bezig: een bericht gaat dan in de wachtrij in plaats van meteen.
    pub active: bool,
    /// Ids van vragen die ook een eigen antwoord accepteren (`allowsOther` op de Mac).
    pub free_answers: Vec<String>,
}

/// Wat de companion met de sessies mag. Elke methode krijgt ids die de server al heeft gecontroleerd tegen
/// [`CompanionBackend::sessions`]; een fout is een korte Nederlandse tekst.
#[async_trait]
pub trait CompanionBackend: Send + Sync {
    /// Alle sessies die niet gearchiveerd zijn.
    async fn sessions(&self) -> Vec<BackendSession>;
    /// Een goedkeuring toestaan of weigeren.
    async fn decide(&self, session: &str, item: &str, allow: bool) -> Result<(), String>;
    /// Een vraag met één onderdeel beantwoorden (een van de opties, of een eigen antwoord als dat mag).
    async fn answer(&self, session: &str, item: &str, text: &str) -> Result<(), String>;
    /// Een bericht van jou aan de agent: meteen als de sessie rust, anders in de wachtrij.
    async fn send(&self, session: &str, text: &str) -> Result<(), String>;
    async fn stop(&self, session: &str) -> Result<(), String>;
}

/// Zolang de app nog geen agents heeft: geen sessies, en elke actie zegt dat.
pub struct NoSessions;

#[async_trait]
impl CompanionBackend for NoSessions {
    async fn sessions(&self) -> Vec<BackendSession> {
        Vec::new()
    }
    async fn decide(&self, _: &str, _: &str, _: bool) -> Result<(), String> {
        Err("Geen sessies".into())
    }
    async fn answer(&self, _: &str, _: &str, _: &str) -> Result<(), String> {
        Err("Geen sessies".into())
    }
    async fn send(&self, _: &str, _: &str) -> Result<(), String> {
        Err("Geen sessies".into())
    }
    async fn stop(&self, _: &str) -> Result<(), String> {
        Err("Geen sessies".into())
    }
}
