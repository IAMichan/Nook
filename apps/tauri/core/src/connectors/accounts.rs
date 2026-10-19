//! Meer accounts bij één dienst ("GitHub · Werk"). Geen geheimen hier: die staan in de kluis onder [`ServiceAccount::key`].
//!
//! Het eerste account van een dienst heeft de id van de dienst zelf ("github"), zodat zijn sleutelnamen precies die van
//! eerdere versies zijn (`connector.github.token`): bestaande sleutels worden het hoofdaccount zonder te kopiëren.

use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use super::ConnectorStore;

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServiceAccount {
    /// "github" voor het hoofdaccount, "github.werk" voor de andere.
    pub id: String,
    pub service: String,
    pub label: String,
    /// Wie de dienst zegt dat dit is ("@michan"). Ingevuld door de koppeling, nooit getypt.
    #[serde(default)]
    pub identity: Option<String>,
}

impl ServiceAccount {
    pub fn primary(service: &str) -> Self {
        Self { id: service.into(), service: service.into(), label: String::new(), identity: None }
    }

    pub fn is_primary(&self) -> bool {
        self.id == self.service
    }

    /// Kluisnaam van één veld van dit account ("token" → "connector.github.werk.token").
    pub fn key(&self, field: &str) -> String {
        format!("connector.{}.{}", self.id, field)
    }

    /// "GitHub · Werk", of alleen "GitHub" voor één hoofdaccount zonder naam.
    pub fn title(&self, service_title: &str) -> String {
        if self.label.is_empty() {
            service_title.to_string()
        } else {
            format!("{service_title} · {}", self.label)
        }
    }

    /// Hoe het model en het plan het account noemen: de naam, anders de login.
    pub fn name(&self) -> String {
        if !self.label.is_empty() {
            return self.label.clone();
        }
        self.identity.clone().unwrap_or_else(|| self.id.clone())
    }
}

/// Alle accounts van een dienst, hoofdaccount eerst (dat bestaat altijd, ook als er niets bewaard is).
pub fn accounts(store: &ConnectorStore, service: &str) -> Vec<ServiceAccount> {
    store.read(|c| {
        let own: Vec<&ServiceAccount> = c.accounts.iter().filter(|a| a.service == service).collect();
        let primary = own.iter().find(|a| a.is_primary()).map(|a| (*a).clone()).unwrap_or_else(|| ServiceAccount::primary(service));
        let mut others: Vec<ServiceAccount> = own.into_iter().filter(|a| !a.is_primary()).cloned().collect();
        others.sort_by_key(|a| a.label.to_lowercase());
        std::iter::once(primary).chain(others).collect()
    })
}

pub fn account(store: &ConnectorStore, id: &str) -> Option<ServiceAccount> {
    let service = id.split('.').next().unwrap_or(id);
    accounts(store, service).into_iter().find(|a| a.id == id)
}

/// Nog een account bij een dienst. De id komt van de naam en is uniek binnen de dienst.
pub fn add(store: &ConnectorStore, service: &str, label: &str) -> ServiceAccount {
    let clean = label.trim();
    store.update(|c| {
        let base = slug(if clean.is_empty() { "account" } else { clean });
        let mut id = format!("{service}.{base}");
        let mut counter = 2;
        while c.accounts.iter().any(|a| a.id == id) {
            id = format!("{service}.{base}{counter}");
            counter += 1;
        }
        let label = if clean.is_empty() { format!("Account {}", counter - 1) } else { clean.to_string() };
        let account = ServiceAccount { id, service: service.into(), label, identity: None };
        c.accounts.push(account.clone());
        account
    })
}

pub fn rename(store: &ConnectorStore, id: &str, label: &str) {
    let label = label.trim().to_string();
    change(store, id, |a| a.label = label);
}

pub fn set_identity(store: &ConnectorStore, id: &str, identity: Option<String>) {
    if account(store, id).and_then(|a| a.identity) == identity {
        return;
    }
    change(store, id, |a| a.identity = identity);
}

/// Haalt een account uit de lijst (de aanroeper wist zijn geheimen). Het hoofdaccount kan niet weg, alleen leeg.
pub fn remove(store: &ConnectorStore, id: &str) {
    store.update(|c| c.accounts.retain(|a| a.id != id || a.is_primary()));
}

fn change(store: &ConnectorStore, id: &str, f: impl FnOnce(&mut ServiceAccount)) {
    store.update(|c| {
        if let Some(a) = c.accounts.iter_mut().find(|a| a.id == id) {
            f(a);
        } else if !id.contains('.') {
            // Het hoofdaccount wordt pas bewaard als er iets aan verandert.
            let mut a = ServiceAccount::primary(id);
            f(&mut a);
            c.accounts.push(a);
        }
    });
}

/// Het account waar de gebruiker of het model naar verwijst: op id, naam of identiteit, hoofdletterongevoelig.
pub fn find<'a>(reference: &str, candidates: &'a [ServiceAccount]) -> Option<&'a ServiceAccount> {
    let needle = reference.trim().to_lowercase();
    let needle = needle.trim_matches('@');
    if needle.is_empty() {
        return None;
    }
    candidates
        .iter()
        .find(|a| a.id.to_lowercase() == needle)
        .or_else(|| candidates.iter().find(|a| a.label.to_lowercase() == needle))
        .or_else(|| candidates.iter().find(|a| a.identity.as_deref().unwrap_or("").to_lowercase().trim_matches('@') == needle))
}

/// "Zakelijk Account!" → "zakelijk-account", "Café" → "cafe".
pub fn slug(text: &str) -> String {
    let folded: String = text.to_lowercase().chars().map(fold).collect();
    let mapped: String = folded.chars().map(|c| if c.is_alphanumeric() { c } else { '-' }).collect();
    let collapsed = mapped.split('-').filter(|p| !p.is_empty()).collect::<Vec<_>>().join("-");
    if collapsed.is_empty() {
        "account".into()
    } else {
        collapsed.chars().take(24).collect()
    }
}

fn fold(c: char) -> char {
    match c {
        'à' | 'á' | 'â' | 'ã' | 'ä' | 'å' => 'a',
        'ç' => 'c',
        'è' | 'é' | 'ê' | 'ë' => 'e',
        'ì' | 'í' | 'î' | 'ï' => 'i',
        'ñ' => 'n',
        'ò' | 'ó' | 'ô' | 'õ' | 'ö' | 'ø' => 'o',
        'ù' | 'ú' | 'û' | 'ü' => 'u',
        'ý' | 'ÿ' => 'y',
        other => other,
    }
}

/// Met meer accounts krijgt elke tool een veld `account` (verplicht voor acties), zodat een plan nooit op een
/// geraden account draait.
pub fn with_account(schema: &Value, names: &[String], required: bool, service: &str) -> Value {
    if names.len() < 2 {
        return schema.clone();
    }
    let mut copy = schema.clone();
    let description = format!(
        "Which {service} account: {}. Pick the one that has access to the repository; ask the user if unclear.",
        names.join(" or ")
    );
    if let Some(props) = copy.get_mut("properties").and_then(Value::as_object_mut) {
        props.insert("account".into(), json!({"type": "string", "enum": names, "description": description}));
    }
    if required {
        let mut req: Vec<Value> = copy.get("required").and_then(Value::as_array).cloned().unwrap_or_default();
        req.push(json!("account"));
        copy["required"] = Value::Array(req);
    }
    copy
}

/// Een tool met een veld `account` biedt alleen de accounts die deze chat mag. Blijft er één over, dan verdwijnt het
/// veld en wordt dat account ingevuld; blijft er geen over, dan valt de tool weg (`None`).
pub fn restrict_schema(schema: &Value, allowed: &[String]) -> Option<(Value, Option<String>)> {
    let Some(names) = schema.pointer("/properties/account/enum").and_then(Value::as_array) else {
        return Some((schema.clone(), None));
    };
    let names: Vec<String> = names.iter().filter_map(|n| n.as_str().map(str::to_string)).collect();
    let kept: Vec<String> = names.iter().filter(|n| allowed.iter().any(|a| a.eq_ignore_ascii_case(n))).cloned().collect();
    if kept.is_empty() {
        return None;
    }
    if kept.len() == names.len() {
        return Some((schema.clone(), None));
    }
    let mut copy = schema.clone();
    if kept.len() == 1 {
        if let Some(props) = copy.get_mut("properties").and_then(Value::as_object_mut) {
            props.remove("account");
        }
        if let Some(req) = copy.get_mut("required").and_then(Value::as_array_mut) {
            req.retain(|r| r != "account");
        }
        return Some((copy, Some(kept[0].clone())));
    }
    copy["properties"]["account"]["enum"] = json!(kept);
    Some((copy, None))
}

/// De namen (zoals het model ze ziet) van de accounts die een chat mag gebruiken.
pub fn allowed_names(all: &[ServiceAccount], excluded: &BTreeSet<String>) -> Vec<String> {
    all.iter().filter(|a| !excluded.contains(&a.id)).map(ServiceAccount::name).collect()
}

/// De accounts in de volgorde waarin Nook ze voor een repository van `owner` probeert: eerst het account dat die
/// eigenaar is, dan het hoofdaccount, dan de rest. Het eerste account met toegang wint (een lid van een organisatie
/// dus ook), zoals `GitHubConnector.tokens` op de Mac.
pub fn ordered_for_owner(mut list: Vec<ServiceAccount>, owner: &str) -> Vec<ServiceAccount> {
    let owner = owner.trim().trim_start_matches('@').to_lowercase();
    let rank = |a: &ServiceAccount| {
        let login = a.identity.as_deref().unwrap_or_default().trim().trim_start_matches('@').to_lowercase();
        if !owner.is_empty() && login == owner {
            0
        } else if a.is_primary() {
            1
        } else {
            2
        }
    };
    list.sort_by_key(rank);
    list
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_owner_goes_first_then_the_main_account() {
        let main = ServiceAccount { identity: Some("@michan".into()), ..ServiceAccount::primary("github") };
        let work =
            ServiceAccount { id: "github.werk".into(), service: "github".into(), label: "Werk".into(), identity: Some("@m-acme".into()) };
        let club = ServiceAccount { id: "github.club".into(), service: "github".into(), label: "Club".into(), identity: None };
        let list = vec![main.clone(), work.clone(), club.clone()];
        let ids = |l: Vec<ServiceAccount>| l.into_iter().map(|a| a.id).collect::<Vec<_>>();
        assert_eq!(ids(ordered_for_owner(list.clone(), "M-Acme")), ["github.werk", "github", "github.club"]);
        // Een organisatie: niemand is eigenaar, dus het hoofdaccount eerst en dan de rest op volgorde.
        assert_eq!(ids(ordered_for_owner(list.clone(), "acme-corp")), ["github", "github.werk", "github.club"]);
        assert_eq!(ids(ordered_for_owner(vec![club, work, main], "")), ["github", "github.club", "github.werk"]);
    }

    #[test]
    fn primary_account_uses_the_original_key_names() {
        let store = ConnectorStore::in_memory();
        let list = accounts(&store, "github");
        assert_eq!(list.len(), 1);
        assert!(list[0].is_primary());
        assert_eq!(list[0].key("token"), "connector.github.token");
    }

    #[test]
    fn added_accounts_get_their_own_keys() {
        let store = ConnectorStore::in_memory();
        let work = add(&store, "github", "Werk");
        let second = add(&store, "github", "Werk");
        assert_eq!(work.id, "github.werk");
        assert_eq!(second.id, "github.werk2");
        assert_eq!(work.key("token"), "connector.github.werk.token");
        assert_eq!(accounts(&store, "github").iter().map(|a| a.id.as_str()).collect::<Vec<_>>(), ["github", "github.werk", "github.werk2"]);
        assert_eq!(accounts(&store, "notion").len(), 1);
    }

    #[test]
    fn primary_cannot_be_removed() {
        let store = ConnectorStore::in_memory();
        let work = add(&store, "github", "Werk");
        remove(&store, "github");
        remove(&store, &work.id);
        assert_eq!(accounts(&store, "github").iter().map(|a| a.id.as_str()).collect::<Vec<_>>(), ["github"]);
    }

    #[test]
    fn rename_and_identity() {
        let store = ConnectorStore::in_memory();
        rename(&store, "github", "Persoonlijk");
        set_identity(&store, "github", Some("@michan".into()));
        let primary = &accounts(&store, "github")[0];
        assert_eq!(primary.label, "Persoonlijk");
        assert_eq!(primary.identity.as_deref(), Some("@michan"));
        assert_eq!(primary.title("GitHub"), "GitHub · Persoonlijk");
    }

    #[test]
    fn match_by_id_label_or_identity() {
        let store = ConnectorStore::in_memory();
        let work = add(&store, "github", "Werk");
        set_identity(&store, &work.id, Some("@acme-dev".into()));
        let all = accounts(&store, "github");
        assert_eq!(find("werk", &all).map(|a| a.id.as_str()), Some("github.werk"));
        assert_eq!(find("github.werk", &all).map(|a| a.id.as_str()), Some("github.werk"));
        assert_eq!(find("acme-dev", &all).map(|a| a.id.as_str()), Some("github.werk"));
        assert!(find("private", &all).is_none());
    }

    #[test]
    fn slugs() {
        assert_eq!(slug("Zakelijk Account!"), "zakelijk-account");
        assert_eq!(slug("Café"), "cafe");
        assert_eq!(slug("***"), "account");
    }

    #[test]
    fn restricting_accounts_per_chat() {
        let schema = json!({"type": "object", "properties": {"repo": {"type": "string"}}, "required": ["repo"]});
        let names = vec!["Persoonlijk".to_string(), "Werk".to_string()];
        let both = with_account(&schema, &names, true, "GitHub");
        assert_eq!(both["required"], json!(["repo", "account"]));
        let (one, only) = restrict_schema(&both, &["Werk".into()]).unwrap();
        assert_eq!(only.as_deref(), Some("Werk"));
        assert!(one.pointer("/properties/account").is_none());
        assert_eq!(one["required"], json!(["repo"]));
        assert!(restrict_schema(&both, &[]).is_none(), "no account left: no tool");
        let (same, none) = restrict_schema(&both, &names).unwrap();
        assert_eq!(same, both);
        assert!(none.is_none());
        assert_eq!(with_account(&schema, &names[..1], true, "GitHub"), schema, "one account: no field");
    }
}
