import Foundation

/// British or American spelling: a suggestion follows the one the user writes ("colour" in a text with "favourite", "color"
/// in one with "favorite"), never mixes the two. Decided per kind of difference, since they do not always go together: Oxford
/// spelling writes "organize" next to "colour".
enum CompletionSpelling {
    enum Variant: String, Equatable { case british, american }

    /// The kinds of difference, each decided on its own evidence.
    enum Family: String, CaseIterable {
        /// organise, analyse / organize, analyze
        case ise
        /// colour, favourite / color, favorite
        case our
        /// centre, theatre / center, theater
        case re
        /// travelled, cancelling / traveled, canceling
        case doubledL
        /// defence, catalogue, grey, aluminium and other single words
        case other
    }

    /// What the user writes, per family. A family without its own evidence follows the others, except `ise`: "-ize" is
    /// British too (Oxford), so "colour" says nothing about it.
    struct Habit: Equatable {
        var families: [Family: Variant] = [:]

        var isEmpty: Bool { families.isEmpty }

        func variant(for family: Family) -> Variant? {
            if let own = families[family] { return own }
            guard family != .ise else { return nil }
            let others = Set(families.filter { $0.key != .ise }.values)
            return others.count == 1 ? others.first : nil
        }

        /// This habit, with `fallback` for the families it says nothing about (the field first, then earlier writing).
        func filling(from fallback: Habit) -> Habit {
            Habit(families: families.merging(fallback.families) { own, _ in own })
        }
    }

    /// One word in both spellings (lowercased) and its family.
    struct Pair: Equatable {
        var british: String
        var american: String
        var family: Family
    }

    /// The habit `text` shows: per family, the variant it uses when it uses only one of them.
    static func habit(in text: String) -> Habit {
        habit(words: words(in: text).map { ($0.lowercased(), 1) })
    }

    /// The same from counted words (the vocabulary of the user's writing samples): per family, the variant written clearly
    /// more often.
    static func habit(words: some Sequence<(String, Int)>) -> Habit {
        var counts: [Family: (british: Int, american: Int)] = [:]
        for (word, count) in words {
            guard let (pair, variant) = lookup[word] else { continue }
            var tally = counts[pair.family] ?? (0, 0)
            if variant == .british { tally.british += count } else { tally.american += count }
            counts[pair.family] = tally
        }
        var habit = Habit()
        for (family, tally) in counts {
            if tally.british > 0, tally.american * 4 <= tally.british { habit.families[family] = .british }
            else if tally.american > 0, tally.british * 4 <= tally.american { habit.families[family] = .american }
        }
        return habit
    }

    /// `suggestion` in the user's spelling. `before` is the text it goes behind: a word the suggestion finishes ("colo" +
    /// "ur") is judged whole, and left alone when what is typed already says otherwise.
    static func apply(_ habit: Habit, to suggestion: String, before: String) -> String {
        guard !habit.isEmpty, !suggestion.isEmpty else { return suggestion }
        let typed = String(before.reversed().prefix { $0.isLetter }.reversed())
        var result = ""
        var word = ""
        var first = true
        func flush() {
            guard !word.isEmpty else { return }
            if first, !typed.isEmpty {
                // The word started before the cursor: convert it whole, and keep only what comes after the typed part.
                let converted = convert(typed + word, habit: habit)
                result += converted.lowercased().hasPrefix(typed.lowercased()) ? String(converted.dropFirst(typed.count)) : word
            } else {
                result += convert(word, habit: habit)
            }
            word = ""
            first = false
        }
        for character in suggestion {
            if character.isLetter {
                word.append(character)
            } else {
                flush()
                first = false
                result.append(character)
            }
        }
        flush()
        return result
    }

    /// One word in the habit's spelling, in the same case ("Colour" → "Color", "COLOUR" → "COLOR").
    static func convert(_ word: String, habit: Habit) -> String {
        guard let (pair, variant) = lookup[word.lowercased()], let wanted = habit.variant(for: pair.family), wanted != variant else { return word }
        let target = wanted == .british ? pair.british : pair.american
        if word == word.uppercased(), word.count > 1 { return target.uppercased() }
        if word.first?.isUppercase == true { return target.prefix(1).uppercased() + target.dropFirst() }
        return target
    }

    private static func words(in text: String) -> [String] {
        text.split { !$0.isLetter }.map(String.init)
    }

    // MARK: The table

    /// Every pair, each word in all the forms that are written (organise, organised, organising, organisation…).
    static let pairs: [Pair] = {
        var pairs: [Pair] = []
        func add(_ british: String, _ american: String, _ family: Family) {
            pairs.append(Pair(british: british, american: american, family: family))
        }
        // -ise / -ize: only stems where both are words; "advertise", "surprise", "exercise" are -ise everywhere.
        let iseStems = [
            "organ", "real", "recogn", "apolog", "summar", "special", "emphas", "critic", "author", "minim", "maxim",
            "optim", "util", "categor", "character", "standard", "custom", "final", "visual", "memor", "modern", "normal",
            "personal", "general", "central", "capital", "digit", "familiar", "harmon", "jeopard", "legal", "local", "material",
            "mobil", "neutral", "global", "priorit", "symbol", "synchron", "sympath", "theor", "agon", "anonym", "fantas",
            "fertil", "galvan", "hospital", "ideal", "immun", "industrial", "initial", "internal", "liberal",
            "monopol", "moral", "patron", "polar", "popular", "rational", "revolution", "scrutin", "steril", "stabil", "subsid",
            "terror", "tranquil", "vandal", "victim", "colon", "democrat", "econom", "energ", "equal", "eulog", "random", "minimal", "commercial", "hypothes",
        ]
        for stem in iseStems {
            for (b, a) in [("ise", "ize"), ("ises", "izes"), ("ised", "ized"), ("ising", "izing"), ("isation", "ization"),
                           ("isations", "izations"), ("iser", "izer"), ("isers", "izers")] {
                add(stem + b, stem + a, .ise)
            }
        }
        for stem in ["analy", "paraly", "cataly", "electroly"] {
            for (b, a) in [("se", "ze"), ("ses", "zes"), ("sed", "zed"), ("sing", "zing"), ("ser", "zer")] { add(stem + b, stem + a, .ise) }
        }
        // -our / -or
        let ourStems = [
            "colo", "flavo", "favo", "hono", "humo", "labo", "neighbo", "behavio", "harbo", "rumo", "vapo", "vigo", "endeavo", "savo",
            "odo", "armo", "splendo", "parlo",
        ]
        for stem in ourStems {
            for suffix in ["", "s", "ed", "ing", "ful", "fully", "less", "able", "ite", "ites", "hood", "hoods", "al", "ally", "y"] {
                add(stem + "ur" + suffix, stem + "r" + suffix, .our)
            }
        }
        // -re / -er
        for stem in ["cent", "theat", "fib", "lit", "calib", "somb", "spect", "lust", "sab", "manoeuv", "meag", "sepulch"] {
            let american = stem == "manoeuv" ? "maneuv" : stem
            add(stem + "re", american + "er", .re)
            add(stem + "res", american + "ers", .re)
            if ["cent", "manoeuv"].contains(stem) {
                add(stem + "red", american + "ered", .re)
                add(stem + "ring", american + "ering", .re)
            }
        }
        // Doubled l before -ed, -ing, -er
        for stem in ["travel", "cancel", "model", "label", "level", "signal", "fuel", "marvel", "counsel", "dial", "total",
                     "quarrel", "channel", "funnel", "tunnel", "shovel", "snorkel", "unravel", "panel", "rival", "duel", "pedal"] {
            for (b, a) in [("led", "ed"), ("ling", "ing"), ("ler", "er"), ("lers", "ers")] {
                add(stem + b, stem + a, .doubledL)
            }
        }
        // Single words
        for (b, a) in [
            ("defence", "defense"), ("defences", "defenses"), ("offence", "offense"), ("offences", "offenses"),
            ("pretence", "pretense"), ("catalogue", "catalog"), ("catalogues", "catalogs"), ("catalogued", "cataloged"),
            ("analogue", "analog"), ("grey", "gray"), ("greys", "grays"), ("greyish", "grayish"), ("aluminium", "aluminum"),
            ("jewellery", "jewelry"), ("jeweller", "jeweler"), ("jewellers", "jewelers"), ("mould", "mold"), ("moulds", "molds"),
            ("plough", "plow"), ("sceptical", "skeptical"), ("sceptic", "skeptic"), ("sceptics", "skeptics"),
            ("paediatric", "pediatric"), ("encyclopaedia", "encyclopedia"), ("enrolment", "enrollment"),
            ("fulfilment", "fulfillment"), ("skilful", "skillful"), ("wilful", "willful"), ("instalment", "installment"),
            ("instalments", "installments"), ("pyjamas", "pajamas"), ("cosy", "cozy"), ("moustache", "mustache"),
            ("artefact", "artifact"), ("artefacts", "artifacts"), ("woollen", "woolen"), ("ageing", "aging"),
        ] {
            // Not here: pairs whose American spelling is another word in British too (cheque/check, storey/story,
            // programme/program, draught/draft, kerb/curb, licence/license).
            add(b, a, .other)
        }
        return pairs
    }()

    /// Every spelling of every pair, with the pair and which variant it is.
    private static let lookup: [String: (Pair, Variant)] = {
        var lookup: [String: (Pair, Variant)] = [:]
        for pair in pairs where pair.british != pair.american {
            lookup[pair.british] = (pair, .british)
            lookup[pair.american] = (pair, .american)
        }
        return lookup
    }()
}
