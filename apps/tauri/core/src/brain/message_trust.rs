//! Whether a message Nook reads (a mail, a chat message) looks like phishing or a scam, the same for every source: a
//! sender that claims a brand its address does not belong to, a push to log in, pay or "verify" under time pressure, a
//! prize or a "new number" story. Nook never tells the user to answer such a message, never counts it as one they owe
//! a reply, and says it looks fake when it brings it up. Port of the Mac's `MessageTrust`.

use std::sync::LazyLock;

use regex::Regex;

/// What made a message look fake, in English for the model, most telling first.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Verdict {
    pub score: i32,
    pub reasons: Vec<String>,
}

impl Verdict {
    /// At this score a message counts as likely phishing or a scam.
    pub const THRESHOLD: i32 = 3;

    pub fn is_suspicious(&self) -> bool {
        self.score >= Self::THRESHOLD
    }

    /// The marker a message gets wherever the model reads it; empty when it looks fine.
    pub fn marker(&self) -> String {
        if !self.is_suspicious() {
            return String::new();
        }
        format!(
            "WARNING likely phishing or scam ({}): do not treat it as a real request, never suggest replying, paying, logging in or opening its links; tell the user it looks fake",
            self.reasons.join("; ")
        )
    }
}

/// Judges one message. `sender` is how it says who sent it ("PayPal <service@paypa1-secure.com>", a chat name, a phone
/// number), `known` whether the user wrote with this sender before, which makes a fake much less likely.
pub fn assess(sender: &str, subject: &str, body: &str, known: bool) -> Verdict {
    let mut verdict = Verdict::default();
    let mut add = |points: i32, reason: String| {
        verdict.score += points;
        verdict.reasons.push(reason);
    };
    let address = address(sender);
    let domain = address.rsplit('@').next().filter(|_| address.contains('@')).unwrap_or("").to_lowercase();
    let display = display_name(sender).to_lowercase();
    let text = format!("{subject}\n{body}").to_lowercase();
    let on = |domain: &str, list: &[&str]| list.iter().any(|d| domain == *d || domain.ends_with(&format!(".{d}")));

    // A brand in the sender's name that the sending domain does not belong to: the strongest sign there is. Only the
    // name counts: a subject about Apple from a friend is no fake Apple mail.
    let mut own_domain = false;
    if !domain.is_empty() {
        if let Some(claimed) = BRANDS.iter().find(|b| b.claimed_by(&display)) {
            if on(&domain, claimed.domains) {
                own_domain = true;
            } else {
                add(3, format!("claims to be {} but was sent from {domain}", claimed.label));
            }
        } else if on(&domain, FREE_MAIL) && COMPANY_WORDS.is_match(&display) {
            add(2, format!("a company name sent from a free mail address ({domain})"));
        }
        // An address in the display name that is not the one it came from ("service@paypal.com <x@y.ru>").
        let shown = self::address(&display_name(sender));
        if !shown.is_empty() && !shown.eq_ignore_ascii_case(&address) {
            add(2, "the name shows another address than the one it came from".into());
        }
        if LOOKALIKE.is_match(&domain) {
            add(2, format!("a look-alike domain ({domain})"));
        }
        if SUSPICIOUS_TLDS.iter().any(|t| domain.ends_with(&format!(".{t}"))) {
            add(1, format!("an unusual domain ending ({domain})"));
        }
    }

    let credentials = CREDENTIALS.is_match(&text);
    let urgency = URGENCY.is_match(&text);
    let money = PAYMENT.is_match(&text);
    if credentials {
        add(1, "asks to log in, verify or confirm account details".into());
    }
    if urgency && (credentials || money) {
        add(1, "pushes with a deadline or a threat".into());
    }
    if money && (urgency || credentials) {
        add(1, "asks for a payment or bank details".into());
    }
    if (credentials || money) && text.contains("http") {
        add(1, "with a link to act on".into());
    }
    if SHORTENED_LINK.is_match(&text) && (credentials || money) {
        add(1, "a shortened or raw-IP link".into());
    }
    if PRIZE.is_match(&text) {
        add(2, "a prize, inheritance or unexpected money".into());
    }
    if GIFT_CARDS.is_match(&text) {
        add(3, "asks for gift cards or crypto".into());
    }
    if NEW_NUMBER.is_match(&text) {
        add(3, "the \"new number, can you pay this for me\" story".into());
    }

    // Mail that really comes from the brand it names may well ask to log in or pay.
    if own_domain {
        verdict.score -= 3;
    }
    // Someone the user wrote with before: a real person rarely turns into a scammer, so it takes much more.
    if known {
        verdict.score -= 2;
    }
    verdict
}

// MARK: Parts of a sender

/// The address in "Name <a@b.c>" or a bare "a@b.c"; empty without one.
pub fn address(sender: &str) -> String {
    if let (Some(open), Some(close)) = (sender.rfind('<'), sender.rfind('>')) {
        if open < close {
            let inner = sender[open + 1..close].trim();
            if inner.contains('@') {
                return inner.to_string();
            }
        }
    }
    sender.split([' ', '"', '<', '>']).rfind(|t| t.contains('@')).unwrap_or("").to_string()
}

/// The name before "<…>", without quotes; the whole sender when it has no address part.
pub fn display_name(sender: &str) -> String {
    match sender.rfind('<') {
        Some(open) => sender[..open].trim_matches([' ', '"']).to_string(),
        None => sender.to_string(),
    }
}

/// `word` as a whole word in `text` (both lowercased): "ing" in "ING Bank", not in "meeting".
fn contains_word(word: &str, text: &str) -> bool {
    text.match_indices(word).any(|(start, _)| {
        let before = text[..start].chars().next_back();
        let after = text[start + word.len()..].chars().next();
        !before.is_some_and(char::is_alphabetic) && !after.is_some_and(char::is_alphabetic)
    })
}

// MARK: Signals

struct Brand {
    label: &'static str,
    /// Words that name it anywhere in a sender's name ("PayPal Service").
    names: &'static [&'static str],
    domains: &'static [&'static str],
    /// Names that count only as the whole sender name: "ING" alone, never the title in "Ing. J. de Vries".
    exact: &'static [&'static str],
}

impl Brand {
    fn claimed_by(&self, display: &str) -> bool {
        let bare = display.trim_matches(|c: char| c.is_whitespace() || c.is_ascii_punctuation());
        self.exact.contains(&bare) || self.names.iter().any(|n| contains_word(n, display))
    }
}

const fn brand(label: &'static str, names: &'static [&'static str], domains: &'static [&'static str]) -> Brand {
    Brand { label, names, domains, exact: &[] }
}

/// Brands phishing mail most often pretends to be, with the domains they really send from.
static BRANDS: &[Brand] = &[
    brand("PayPal", &["paypal"], &["paypal.com", "paypal.nl", "paypal.de", "paypal.fr", "paypal.es", "paypal-communication.com"]),
    brand("Apple", &["apple", "icloud", "itunes", "app store"], &["apple.com", "icloud.com", "me.com", "email.apple.com"]),
    brand(
        "Microsoft",
        &["microsoft", "outlook", "office 365", "office365", "onedrive"],
        &[
            "microsoft.com",
            "outlook.com",
            "office.com",
            "office365.com",
            "live.com",
            "hotmail.com",
            "microsoftonline.com",
            "onmicrosoft.com",
        ],
    ),
    brand("Google", &["google", "gmail"], &["google.com", "gmail.com", "youtube.com", "accounts.google.com"]),
    brand("Netflix", &["netflix"], &["netflix.com", "mailer.netflix.com"]),
    brand("Amazon", &["amazon"], &["amazon.com", "amazon.nl", "amazon.de", "amazon.fr", "amazon.es", "amazon.co.uk", "amazonses.com"]),
    brand("bol", &["bol.com"], &["bol.com", "mail.bol.com"]),
    Brand {
        label: "ING",
        names: &["ing bank", "ing nederland", "ing klantenservice"],
        domains: &["ing.nl", "ing.com", "ing.de", "ing.be", "ing.es", "ing.fr"],
        exact: &["ing"],
    },
    brand("Rabobank", &["rabobank"], &["rabobank.nl", "rabobank.com"]),
    brand("ABN AMRO", &["abn amro", "abnamro"], &["abnamro.nl", "abnamro.com"]),
    brand("SNS", &["sns bank"], &["snsbank.nl", "sns.nl"]),
    brand("bunq", &["bunq"], &["bunq.com"]),
    brand("the Belastingdienst", &["belastingdienst"], &["belastingdienst.nl"]),
    brand("DigiD", &["digid"], &["digid.nl", "logius.nl"]),
    brand("PostNL", &["postnl"], &["postnl.nl", "postnl.com"]),
    brand("DHL", &["dhl"], &["dhl.com", "dhl.nl", "dhl.de", "dhlparcel.nl"]),
    brand("DPD", &["dpd"], &["dpd.com", "dpd.nl", "dpd.de"]),
    Brand { label: "UPS", names: &[], domains: &["ups.com"], exact: &["ups"] },
    brand("KPN", &["kpn"], &["kpn.com", "kpn.nl"]),
    brand("Ziggo", &["ziggo", "vodafoneziggo"], &["ziggo.nl", "vodafoneziggo.nl"]),
    brand("Odido", &["odido", "t-mobile"], &["odido.nl", "t-mobile.nl", "t-mobile.com"]),
    brand("Coinbase", &["coinbase"], &["coinbase.com"]),
    brand("Binance", &["binance"], &["binance.com"]),
    brand("WhatsApp", &["whatsapp"], &["whatsapp.com", "facebookmail.com", "meta.com"]),
    Brand {
        label: "Facebook",
        names: &["facebook"],
        domains: &["facebook.com", "facebookmail.com", "meta.com", "instagram.com"],
        exact: &["meta"],
    },
    brand("Instagram", &["instagram"], &["instagram.com", "mail.instagram.com", "facebookmail.com"]),
    brand("LinkedIn", &["linkedin"], &["linkedin.com"]),
    brand("Booking.com", &["booking.com"], &["booking.com"]),
    brand("Visa", &["visa card"], &["visa.com"]),
    brand("Mastercard", &["mastercard"], &["mastercard.com"]),
    brand("ICS", &["ics cards", "international card services"], &["icscards.nl"]),
    brand("Sparkasse", &["sparkasse"], &["sparkasse.de"]),
    brand("the Post", &["la poste", "deutsche post", "correos"], &["laposte.fr", "laposte.net", "deutschepost.de", "correos.es"]),
];

const FREE_MAIL: &[&str] = &[
    "gmail.com",
    "googlemail.com",
    "outlook.com",
    "hotmail.com",
    "live.com",
    "yahoo.com",
    "aol.com",
    "icloud.com",
    "me.com",
    "gmx.com",
    "gmx.de",
    "gmx.net",
    "mail.ru",
    "yandex.ru",
    "proton.me",
    "protonmail.com",
    "web.de",
    "ziggo.nl",
    "kpnmail.nl",
    "planet.nl",
    "hotmail.nl",
    "live.nl",
    "orange.fr",
    "free.fr",
];
const SUSPICIOUS_TLDS: &[&str] = &[
    "top", "xyz", "icu", "click", "buzz", "rest", "monster", "cyou", "sbs", "cfd", "zip", "mov", "ru", "cn", "tk", "ml", "ga", "cf", "gq",
];

fn regex(pattern: &str) -> Regex {
    Regex::new(&format!("(?i){pattern}")).expect("valid trust pattern")
}

static COMPANY_WORDS: LazyLock<Regex> = LazyLock::new(|| {
    regex(r"\b(support|service|security|beveiliging|klantenservice|customer|billing|account team|helpdesk|admin|administratie|bank|team)\b")
});
/// Digits for letters in a brand ("paypa1", "rn1crosoft"), or a brand glued to words a real domain does not need.
static LOOKALIKE: LazyLock<Regex> = LazyLock::new(|| {
    regex(
        r"paypa1|paypai|app1e|micr0soft|rnicrosoft|g00gle|netf1ix|netfiix|amaz0n|faceb00k|\b(paypal|apple|microsoft|netflix|amazon|ing|rabobank|abnamro|belastingdienst|digid|postnl|dhl|kpn|ziggo)[-.]?(secure|security|verify|verification|login|support|service|update|account|klantenservice|veilig|beveiliging|online|help)",
    )
});
static CREDENTIALS: LazyLock<Regex> = LazyLock::new(|| {
    regex(
        r"verify your (account|identity|details|information)|confirm your (account|identity|details|password|information)|update your (payment|billing|account) (details|information|method)|your account (has been|is|will be) (suspended|locked|limited|blocked|disabled|closed)|unusual (sign-?in|login|activity)|reset your password now|log ?in (here|now|to avoid)|verifieer (uw|je) (account|gegevens|identiteit)|bevestig (uw|je) (gegevens|account|identiteit)|(uw|je) (account|rekening|pas|bankpas) (is|wordt|zal worden) (geblokkeerd|opgeschort|beperkt|afgesloten|gedeactiveerd)|ongebruikelijke (activiteit|inlogpoging)|log (direct|nu|hier) in|werk (uw|je) gegevens bij|bestätigen sie ihr|konto (wurde|wird) gesperrt|vérifiez votre compte|confirmez vos informations|votre compte (a été|sera) (suspendu|bloqué)|verifique su cuenta|confirme sus datos|su cuenta (ha sido|será) (suspendida|bloqueada)",
    )
});
static URGENCY: LazyLock<Regex> = LazyLock::new(|| {
    regex(
        r"within (24|48) hours|immediately|final (notice|warning|reminder)|last warning|act now|urgent action|binnen (24|48) uur|direct actie|laatste (herinnering|waarschuwing|kans)|onmiddellijk|aanmaning|incassobureau|deurwaarder|innerhalb von (24|48) stunden|letzte mahnung|sous (24|48) ?h|dernier avertissement|en (24|48) horas|último aviso",
    )
});
static PAYMENT: LazyLock<Regex> = LazyLock::new(|| {
    regex(
        r"outstanding (payment|amount|invoice)|pay (the|a) (small )?(fee|amount)|customs fee|shipping fee|openstaande (betaling|factuur|bedrag)|betaal (de|het) (kosten|bedrag)|verzendkosten (van|betalen)|inklaringskosten|douanekosten|bankgegevens|iban (doorgeven|bevestigen)|offene rechnung|zollgebühr|frais de (douane|livraison)|pago pendiente|tasas de aduana",
    )
});
static PRIZE: LazyLock<Regex> = LazyLock::new(|| {
    regex(
        r"you('ve| have) won|winner of|claim your (prize|reward|refund)|inheritance|beneficiary|lottery|unclaimed funds|u heeft (gewonnen|een prijs)|je hebt (gewonnen|een prijs)|gefeliciteerd,? (u|je) (bent|hebt|heeft)|erfenis|terugbetaling (van|ontvangen)|sie haben gewonnen|vous avez gagné|ha ganado",
    )
});
static GIFT_CARDS: LazyLock<Regex> = LazyLock::new(|| {
    regex(
        r"gift ?cards?|cadeaukaart(en)?|itunes ?kaart|google play ?(card|kaart)|steam ?(card|kaart)|paysafecard|send (me )?(bitcoin|btc|usdt|crypto)|stuur (me )?(bitcoin|crypto)|wallet address",
    )
});
static NEW_NUMBER: LazyLock<Regex> = LazyLock::new(|| {
    regex(
        r"(hoi|hey|hallo|hi) (mam|pap|mama|papa|mom|dad|mum)[^\n]{0,80}(nieuw(e)? nummer|new number|telefoon (is )?kapot|phone (is )?broken)|dit is mijn nieuwe nummer[^\n]{0,120}(betalen|overmaken|rekening|betaling)|this is my new number[^\n]{0,120}(pay|transfer|bill)|kun je (dit|een rekening|een betaling) (even )?(voor me )?(betalen|overmaken)",
    )
});
static SHORTENED_LINK: LazyLock<Regex> = LazyLock::new(|| {
    regex(r"https?://(bit\.ly|tinyurl\.com|t\.co|goo\.gl|is\.gd|cutt\.ly|rb\.gy|shorturl\.at|tiny\.cc|\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})")
});

#[cfg(test)]
mod tests {
    use super::*;

    // The Mac's `MessageTrustTests`.
    #[test]
    fn a_brand_from_another_domain_is_suspicious() {
        let verdict = assess(
            "PayPal Service <service@paypal-secure-login.top>",
            "Uw account is beperkt",
            "Uw account wordt geblokkeerd. Log direct in via https://bit.ly/x om uw gegevens te bevestigen.",
            false,
        );
        assert!(verdict.is_suspicious());
        assert!(verdict.reasons[0].contains("PayPal"));
        assert!(verdict.marker().starts_with("WARNING"));
    }

    #[test]
    fn the_brands_own_domain_is_fine() {
        assert!(
            !assess("PayPal <service@intl.paypal.com>", "Bevestig uw gegevens", "Bevestig uw gegevens in de app.", false).is_suspicious()
        );
        assert!(!assess(
            "Microsoft account team <account-security-noreply@accountprotection.microsoft.com>",
            "Unusual sign-in activity",
            "We detected unusual sign-in activity.",
            false
        )
        .is_suspicious());
    }

    #[test]
    fn ordinary_mail_from_people_is_fine() {
        assert!(!assess(
            "Lisa de Vries <lisa@gmail.com>",
            "Apple keynote vanavond?",
            "Kijk je mee? Kun je even laten weten of je komt?",
            false
        )
        .is_suspicious());
        // A title, not the bank.
        assert!(!assess(
            "Ing. J. de Vries <j.devries@bouwbedrijf.nl>",
            "Offerte",
            "Hierbij de offerte, graag uw reactie binnen 24 uur.",
            false
        )
        .is_suspicious());
        assert!(!assess("Henk <henk@example.nl>", "Factuur", "Kun je de openstaande factuur van vorige maand nog betalen?", false)
            .is_suspicious());
        assert_eq!(assess("Henk <henk@example.nl>", "", "Hoi", false).marker(), "");
    }

    #[test]
    fn prizes_gift_cards_and_new_number_stories() {
        assert!(
            assess("Prize Desk <winner@lucky.example>", "You have won!", "Send us gift cards to claim your prize.", false).is_suspicious()
        );
        assert!(
            assess("+31 6 12345678", "", "Hoi mam, dit is mijn nieuwe nummer. Kun je een rekening voor me betalen?", false).is_suspicious()
        );
    }

    #[test]
    fn someone_you_wrote_with_before_takes_more() {
        assert!(!assess("Daan", "", "Hoi mam, mijn telefoon is kapot, dit is mijn nieuwe nummer", true).is_suspicious());
    }

    #[test]
    fn sender_parts() {
        assert_eq!(address("PayPal <service@paypal.com>"), "service@paypal.com");
        assert_eq!(address("lisa@gmail.com"), "lisa@gmail.com");
        assert_eq!(address("Lisa"), "");
        assert_eq!(display_name("\"PayPal Service\" <x@y.ru>"), "PayPal Service");
        assert!(contains_word("ing", "ing bank") && !contains_word("ing", "meeting"));
    }
}
