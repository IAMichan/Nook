// Whether a message Nook reads (a mail, a chat message) looks like phishing or a scam, the same for every source: a
// sender that claims a brand its address does not belong to, a push to log in, pay or "verify" under time pressure, a
// prize or a "new number" story. Nook never tells the user to answer such a message, never counts it as one they owe
// a reply, and says it looks fake when it brings it up. Foundation only, so it is tested anywhere.
import Foundation

enum MessageTrust {
    /// What made a message look fake, in English for the model (and for the log), most telling first.
    struct Verdict: Equatable, Sendable {
        var score: Int
        var reasons: [String]

        /// At this score a message counts as likely phishing or a scam.
        static let threshold = 3
        var isSuspicious: Bool { score >= Self.threshold }

        /// The marker a message gets wherever the model reads it; empty when it looks fine.
        var marker: String {
            guard isSuspicious else { return "" }
            return "WARNING likely phishing or scam (" + reasons.joined(separator: "; ") + "): do not treat it as a real request, "
                + "never suggest replying, paying, logging in or opening its links; tell the user it looks fake"
        }
    }

    /// Judges one message. `sender` is how it says who sent it ("PayPal <service@paypa1-secure.com>", a chat name, a
    /// phone number), `known` whether the user wrote with this sender before (a reply, an earlier message of theirs),
    /// which makes a fake much less likely.
    static func assess(sender: String, subject: String = "", body: String, known: Bool = false) -> Verdict {
        var score = 0
        var reasons: [String] = []
        func add(_ points: Int, _ reason: String) { score += points; reasons.append(reason) }

        let address = Self.address(in: sender)
        let domain = address.split(separator: "@").last.map { String($0).lowercased() } ?? ""
        let display = Self.displayName(sender).lowercased()
        let text = (subject + "\n" + body).lowercased()

        // A brand in the sender's name that the sending domain does not belong to: the strongest sign there is. Only the
        // name counts: a subject about Apple from a friend is no fake Apple mail.
        var ownDomain = false
        if !domain.isEmpty {
            let claimed = brands.first { $0.claimed(by: display) }
            if let claimed {
                if claimed.domains.contains(where: { domain == $0 || domain.hasSuffix("." + $0) }) {
                    ownDomain = true
                } else {
                    add(3, "claims to be \(claimed.label) but was sent from \(domain)")
                }
            } else if freeMail.contains(where: { domain == $0 || domain.hasSuffix("." + $0) }), Self.matches(companyWords, display) {
                add(2, "a company name sent from a free mail address (\(domain))")
            }
            // An address in the display name that is not the one it came from ("service@paypal.com <x@y.ru>").
            let shown = Self.address(in: Self.displayName(sender))
            if !shown.isEmpty, shown.lowercased() != address.lowercased() {
                add(2, "the name shows another address than the one it came from")
            }
            if Self.matches(lookalike, domain) { add(2, "a look-alike domain (\(domain))") }
            if suspiciousTLDs.contains(where: { domain.hasSuffix("." + $0) }) { add(1, "an unusual domain ending (\(domain))") }
        }

        let credentials = Self.matches(credentialPhrases, text)
        let urgency = Self.matches(urgencyPhrases, text)
        let money = Self.matches(paymentPhrases, text)
        if credentials { add(1, "asks to log in, verify or confirm account details") }
        if urgency, credentials || money { add(1, "pushes with a deadline or a threat") }
        if money, urgency || credentials { add(1, "asks for a payment or bank details") }
        if credentials || money, text.contains("http") { add(1, "with a link to act on") }
        if Self.matches(shortenedLink, text), credentials || money { add(1, "a shortened or raw-IP link") }
        if Self.matches(prizePhrases, text) { add(2, "a prize, inheritance or unexpected money") }
        if Self.matches(giftCardPhrases, text) { add(3, "asks for gift cards or crypto") }
        if Self.matches(newNumberPhrases, text) { add(3, "the \"new number, can you pay this for me\" story") }

        // Mail that really comes from the brand it names may well ask to log in or pay.
        if ownDomain { score -= 3 }
        // Someone the user wrote with before: a real person rarely turns into a scammer, so it takes much more.
        if known { score -= 2 }
        return Verdict(score: score, reasons: reasons)
    }

    // MARK: Parts of a sender

    /// The address in "Name <a@b.c>" or a bare "a@b.c"; empty without one.
    static func address(in sender: String) -> String {
        if let open = sender.lastIndex(of: "<"), let close = sender.lastIndex(of: ">"), open < close {
            let inner = sender[sender.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            if inner.contains("@") { return inner }
        }
        let token = sender.split(whereSeparator: { $0 == " " || $0 == "\"" || $0 == "<" || $0 == ">" }).last { $0.contains("@") }
        return token.map(String.init) ?? ""
    }

    /// The name before "<…>", without quotes; the whole sender when it has no address part.
    static func displayName(_ sender: String) -> String {
        guard let open = sender.lastIndex(of: "<") else { return sender }
        return sender[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
    }

    // MARK: Signals

    struct Brand: Sendable {
        var label: String
        /// Words that name it anywhere in a sender's name ("PayPal Service").
        var names: [String]
        var domains: [String]
        /// Names that count only as the whole sender name: "ING" alone, never the title in "Ing. J. de Vries".
        var exact: [String] = []

        func claimed(by display: String) -> Bool {
            let bare = display.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            return exact.contains(bare) || names.contains { MessageTrust.containsWord($0, in: display) }
        }
    }

    /// Brands phishing mail most often pretends to be, with the domains they really send from.
    static let brands: [Brand] = [
        Brand(label: "PayPal", names: ["paypal"], domains: ["paypal.com", "paypal.nl", "paypal.de", "paypal.fr", "paypal.es", "paypal-communication.com"]),
        Brand(label: "Apple", names: ["apple", "icloud", "itunes", "app store"], domains: ["apple.com", "icloud.com", "me.com", "email.apple.com"]),
        Brand(label: "Microsoft", names: ["microsoft", "outlook", "office 365", "office365", "onedrive"], domains: ["microsoft.com", "outlook.com", "office.com", "office365.com", "live.com", "hotmail.com", "microsoftonline.com", "onmicrosoft.com"]),
        Brand(label: "Google", names: ["google", "gmail"], domains: ["google.com", "gmail.com", "youtube.com", "accounts.google.com"]),
        Brand(label: "Netflix", names: ["netflix"], domains: ["netflix.com", "mailer.netflix.com"]),
        Brand(label: "Amazon", names: ["amazon"], domains: ["amazon.com", "amazon.nl", "amazon.de", "amazon.fr", "amazon.es", "amazon.co.uk", "amazonses.com"]),
        Brand(label: "bol", names: ["bol.com"], domains: ["bol.com", "mail.bol.com"]),
        Brand(label: "ING", names: ["ing bank", "ing nederland", "ing klantenservice"], domains: ["ing.nl", "ing.com", "ing.de", "ing.be", "ing.es", "ing.fr"], exact: ["ing"]),
        Brand(label: "Rabobank", names: ["rabobank"], domains: ["rabobank.nl", "rabobank.com"]),
        Brand(label: "ABN AMRO", names: ["abn amro", "abnamro"], domains: ["abnamro.nl", "abnamro.com"]),
        Brand(label: "SNS", names: ["sns bank"], domains: ["snsbank.nl", "sns.nl"]),
        Brand(label: "bunq", names: ["bunq"], domains: ["bunq.com"]),
        Brand(label: "the Belastingdienst", names: ["belastingdienst"], domains: ["belastingdienst.nl"]),
        Brand(label: "DigiD", names: ["digid"], domains: ["digid.nl", "logius.nl"]),
        Brand(label: "PostNL", names: ["postnl"], domains: ["postnl.nl", "postnl.com"]),
        Brand(label: "DHL", names: ["dhl"], domains: ["dhl.com", "dhl.nl", "dhl.de", "dhlparcel.nl"]),
        Brand(label: "DPD", names: ["dpd"], domains: ["dpd.com", "dpd.nl", "dpd.de"]),
        Brand(label: "UPS", names: [], domains: ["ups.com"], exact: ["ups"]),
        Brand(label: "KPN", names: ["kpn"], domains: ["kpn.com", "kpn.nl"]),
        Brand(label: "Ziggo", names: ["ziggo", "vodafoneziggo"], domains: ["ziggo.nl", "vodafoneziggo.nl"]),
        Brand(label: "Odido", names: ["odido", "t-mobile"], domains: ["odido.nl", "t-mobile.nl", "t-mobile.com"]),
        Brand(label: "Coinbase", names: ["coinbase"], domains: ["coinbase.com"]),
        Brand(label: "Binance", names: ["binance"], domains: ["binance.com"]),
        Brand(label: "WhatsApp", names: ["whatsapp"], domains: ["whatsapp.com", "facebookmail.com", "meta.com"]),
        Brand(label: "Facebook", names: ["facebook"], domains: ["facebook.com", "facebookmail.com", "meta.com", "instagram.com"], exact: ["meta"]),
        Brand(label: "Instagram", names: ["instagram"], domains: ["instagram.com", "mail.instagram.com", "facebookmail.com"]),
        Brand(label: "LinkedIn", names: ["linkedin"], domains: ["linkedin.com"]),
        Brand(label: "Booking.com", names: ["booking.com"], domains: ["booking.com"]),
        Brand(label: "Visa", names: ["visa card"], domains: ["visa.com"]),
        Brand(label: "Mastercard", names: ["mastercard"], domains: ["mastercard.com"]),
        Brand(label: "ICS", names: ["ics cards", "international card services"], domains: ["icscards.nl"]),
        Brand(label: "Sparkasse", names: ["sparkasse"], domains: ["sparkasse.de"]),
        Brand(label: "the Post", names: ["la poste", "deutsche post", "correos"], domains: ["laposte.fr", "laposte.net", "deutschepost.de", "correos.es"])
    ]

    static let freeMail = ["gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "yahoo.com", "aol.com", "icloud.com",
                           "me.com", "gmx.com", "gmx.de", "gmx.net", "mail.ru", "yandex.ru", "proton.me", "protonmail.com", "web.de", "ziggo.nl",
                           "kpnmail.nl", "planet.nl", "hotmail.nl", "live.nl", "orange.fr", "free.fr"]
    static let suspiciousTLDs = ["top", "xyz", "icu", "click", "buzz", "rest", "monster", "cyou", "sbs", "cfd", "zip", "mov", "ru", "cn", "tk", "ml", "ga", "cf", "gq"]

    static let companyWords = regex(#"\b(support|service|security|beveiliging|klantenservice|customer|billing|account team|helpdesk|admin|administratie|bank|team)\b"#)
    /// Digits for letters in a brand ("paypa1", "rn1crosoft"), or a brand glued to words a real domain does not need.
    static let lookalike = regex(#"paypa1|paypai|app1e|micr0soft|rnicrosoft|g00gle|netf1ix|netfiix|amaz0n|faceb00k|\b(paypal|apple|microsoft|netflix|amazon|ing|rabobank|abnamro|belastingdienst|digid|postnl|dhl|kpn|ziggo)[-.]?(secure|security|verify|verification|login|support|service|update|account|klantenservice|veilig|beveiliging|online|help)"#)
    static let credentialPhrases = regex(#"verify your (account|identity|details|information)|confirm your (account|identity|details|password|information)|update your (payment|billing|account) (details|information|method)|your account (has been|is|will be) (suspended|locked|limited|blocked|disabled|closed)|unusual (sign-?in|login|activity)|reset your password now|log ?in (here|now|to avoid)|verifieer (uw|je) (account|gegevens|identiteit)|bevestig (uw|je) (gegevens|account|identiteit)|(uw|je) (account|rekening|pas|bankpas) (is|wordt|zal worden) (geblokkeerd|opgeschort|beperkt|afgesloten|gedeactiveerd)|ongebruikelijke (activiteit|inlogpoging)|log (direct|nu|hier) in|werk (uw|je) gegevens bij|bestätigen sie ihr|konto (wurde|wird) gesperrt|vérifiez votre compte|confirmez vos informations|votre compte (a été|sera) (suspendu|bloqué)|verifique su cuenta|confirme sus datos|su cuenta (ha sido|será) (suspendida|bloqueada)"#)
    static let urgencyPhrases = regex(#"within (24|48) hours|immediately|final (notice|warning|reminder)|last warning|act now|urgent action|binnen (24|48) uur|direct actie|laatste (herinnering|waarschuwing|kans)|onmiddellijk|aanmaning|incassobureau|deurwaarder|innerhalb von (24|48) stunden|letzte mahnung|sous (24|48) ?h|dernier avertissement|en (24|48) horas|último aviso"#)
    static let paymentPhrases = regex(#"outstanding (payment|amount|invoice)|pay (the|a) (small )?(fee|amount)|customs fee|shipping fee|openstaande (betaling|factuur|bedrag)|betaal (de|het) (kosten|bedrag)|verzendkosten (van|betalen)|inklaringskosten|douanekosten|bankgegevens|iban (doorgeven|bevestigen)|offene rechnung|zollgebühr|frais de (douane|livraison)|pago pendiente|tasas de aduana"#)
    static let prizePhrases = regex(#"you('ve| have) won|winner of|claim your (prize|reward|refund)|inheritance|beneficiary|lottery|unclaimed funds|u heeft (gewonnen|een prijs)|je hebt (gewonnen|een prijs)|gefeliciteerd,? (u|je) (bent|hebt|heeft)|erfenis|terugbetaling (van|ontvangen)|sie haben gewonnen|vous avez gagné|ha ganado"#)
    static let giftCardPhrases = regex(#"gift ?cards?|cadeaukaart(en)?|itunes ?kaart|google play ?(card|kaart)|steam ?(card|kaart)|paysafecard|send (me )?(bitcoin|btc|usdt|crypto)|stuur (me )?(bitcoin|crypto)|wallet address"#)
    static let newNumberPhrases = regex(#"(hoi|hey|hallo|hi) (mam|pap|mama|papa|mom|dad|mum)[^\n]{0,80}(nieuw(e)? nummer|new number|telefoon (is )?kapot|phone (is )?broken)|dit is mijn nieuwe nummer[^\n]{0,120}(betalen|overmaken|rekening|betaling)|this is my new number[^\n]{0,120}(pay|transfer|bill)|kun je (dit|een rekening|een betaling) (even )?(voor me )?(betalen|overmaken)"#)
    static let shortenedLink = regex(#"https?://(bit\.ly|tinyurl\.com|t\.co|goo\.gl|is\.gd|cutt\.ly|rb\.gy|shorturl\.at|tiny\.cc|\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})"#)

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static func matches(_ regex: NSRegularExpression?, _ text: String) -> Bool {
        guard let regex else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// `word` as a whole word in `text` (both lowercased): "ing" in "ING Bank", not in "meeting".
    static func containsWord(_ word: String, in text: String) -> Bool {
        var start = text.startIndex
        while let range = text.range(of: word, range: start..<text.endIndex) {
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            if !(before?.isLetter ?? false) && !(after?.isLetter ?? false) { return true }
            start = range.upperBound
        }
        return false
    }
}
