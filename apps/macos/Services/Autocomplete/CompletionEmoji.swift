import Foundation

struct CompletionEmoji: Equatable {
    var character: String
    var shortcodes: [String]
    /// Takes a skin tone.
    var toneable: Bool
}

/// Emoji by name: type `:` for the picker, or `:joy` (or in Dutch `:lachen`) to search it.
enum CompletionEmojiCatalog {
    /// The name being typed at the end of `text`, without the colon; empty right after the colon. The colon must start a
    /// word, so times (10:30), links and "Note:" do not count.
    static func query(in text: String) -> String? {
        var query = ""
        for character in text.reversed() {
            if character == ":" {
                let beforeColon = text.dropLast(query.count + 1).last
                guard beforeColon == nil || beforeColon!.isWhitespace else { return nil }
                return String(query.reversed())
            }
            guard character.isASCII, character.isLetter || character.isNumber || "_+-".contains(character), query.count < 30 else { return nil }
            query.append(character)
        }
        return nil
    }

    /// Exact matches, then names starting with it, then names containing it; most used first within each.
    static func search(_ query: String, limit: Int = 5) -> [CompletionEmoji] {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return [] }
        var exact: [CompletionEmoji] = [], prefix: [CompletionEmoji] = [], contains: [CompletionEmoji] = []
        for emoji in all {
            if emoji.shortcodes.contains(needle) { exact.append(emoji) }
            else if emoji.shortcodes.contains(where: { $0.hasPrefix(needle) }) { prefix.append(emoji) }
            else if needle.count >= 3, emoji.shortcodes.contains(where: { $0.contains(needle) }) { contains.append(emoji) }
        }
        return Array((exact + prefix + contains).prefix(limit))
    }

    /// What the picker shows for `query`: right after the colon the ones that fit what was just written (`context`), then the
    /// ones you used last and the most used; otherwise the matches by name, those that fit the context first.
    static func choices(for query: String, recent: [String], limit: Int, context: String = "") -> [CompletionEmoji] {
        let fitting = contextual(for: context)
        guard query.isEmpty else {
            let matches = search(query, limit: limit)
            return matches.filter { fitting.contains($0) } + matches.filter { !fitting.contains($0) }
        }
        let used = recent.compactMap { character in all.first { $0.character == character } }
        var result: [CompletionEmoji] = []
        for emoji in fitting + used + all where !result.contains(emoji) {
            result.append(emoji)
            if result.count == limit { break }
        }
        return result
    }

    /// Emoji that fit the last sentences of `text`, best first: a word that names one, or starts like one of the words in
    /// `topics` ("verjaardag" for 🎂, "bedankt" for 🙏). Words nearer the end count more.
    static func contextual(for text: String, limit: Int = 9) -> [CompletionEmoji] {
        let words = text.suffix(300).lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init).filter { $0.count >= 2 }
        guard !words.isEmpty else { return [] }
        var scores: [String: Double] = [:]
        for (offset, word) in words.reversed().enumerated() where offset < 40 {
            let weight = 1 / (1 + Double(offset) / 8)
            for (character, keys) in topicIndex where keys.contains(where: { matches(word, $0) }) {
                scores[character, default: 0] += weight
            }
        }
        let ranked = scores.sorted { $0.value != $1.value ? $0.value > $1.value : rank($0.key) < rank($1.key) }
        return ranked.prefix(limit).compactMap { entry in all.first { $0.character == entry.key } }
    }

    /// A word fits a topic word when it is that word, or (from four letters) starts with it: "feestje" fits "feest".
    private static func matches(_ word: String, _ key: String) -> Bool {
        word == key || (key.count >= 4 && word.hasPrefix(key))
    }

    private static func rank(_ character: String) -> Int { all.firstIndex { $0.character == character } ?? .max }

    /// Per emoji the words that call for it: its names (whole words, not codes like "+1" or "x") and its `topics`.
    private static let topicIndex: [(String, [String])] = all.map { emoji in
        let names = emoji.shortcodes.filter { $0.count >= 3 && $0.allSatisfy(\.isLetter) }
        return (emoji.character, names + (topics[emoji.character] ?? []))
    }

    /// Words, or the start of words, in English, Dutch, German, French and Spanish that make an emoji likely.
    private static let topics: [String: [String]] = [
        "😂": ["haha", "hihi", "lol", "grappig", "funny", "hilarious", "lustig", "drôle", "gracioso", "jaja", "mdr"],
        "❤️": ["love", "lieve", "schat", "liebe", "amour", "amor", "miss"],
        "🥰": ["lief", "schatje", "cute", "sweet", "süß", "mignon"],
        "👍": ["oké", "goed", "prima", "sure", "deal", "klopt", "akkoord", "gut", "accord", "vale", "bueno"],
        "😭": ["huil", "verdriet", "cry", "tears", "weinen", "pleur", "llor"],
        "🙏": ["bedankt", "dank", "thank", "thanks", "thx", "merci", "danke", "gracias", "please", "alsjeblieft", "bitte"],
        "🎉": ["feest", "gefeliciteerd", "felicit", "congrat", "gratul", "party", "fiesta", "fête", "félicit", "hoera", "geslaagd", "gelukt"],
        "🥳": ["feest", "party", "jarig", "fiesta"],
        "🎂": ["verjaardag", "jarig", "birthday", "geburtstag", "anniversaire", "cumpleaños", "taart", "cake"],
        "🎁": ["cadeau", "gift", "present", "geschenk", "regalo", "kado"],
        "😅": ["oeps", "oops", "sorry", "pardon", "excuse", "ups", "perdón"],
        "🤔": ["denk", "think", "vraag", "misschien", "maybe", "vielleicht", "peut", "quizás", "hmm", "twijfel"],
        "😴": ["slaap", "moe", "sleep", "tired", "müde", "fatigué", "sueño", "cansad", "welterusten", "night", "nacht", "nuit"],
        "🌙": ["welterusten", "goodnight", "nacht", "night", "nuit", "noche"],
        "☀️": ["zon", "sun", "zomer", "summer", "sommer", "soleil", "sol", "verano", "warm"],
        "🌧️": ["regen", "rain", "pluie", "lluvia"],
        "☔": ["regen", "rain", "pluie", "lluvia", "paraplu"],
        "❄️": ["sneeuw", "snow", "schnee", "neige", "nieve", "koud", "cold", "kalt", "froid", "frío", "winter"],
        "☕": ["koffie", "coffee", "kaffee", "café", "ochtend", "morning", "morgen", "matin", "mañana"],
        "🍺": ["bier", "beer", "biertje", "bière", "cerveza", "borrel", "kroeg", "pub"],
        "🍻": ["proost", "cheers", "borrel", "prost", "santé", "salud"],
        "🍷": ["wijn", "wine", "wein", "vin", "vino"],
        "🍕": ["pizza"],
        "🍔": ["burger", "eten", "food", "essen", "manger", "comida", "lunch", "dinner", "diner", "honger", "hungry"],
        "🍽️": ["eten", "dinner", "diner", "lunch", "essen", "manger", "comer", "restaurant"],
        "💪": ["sterk", "strong", "sport", "gym", "train", "succes", "kracht", "fit", "stark", "fuerte"],
        "🤞": ["succes", "hopelijk", "hope", "hoop", "luck", "glück", "chance", "suerte", "duim"],
        "🍀": ["succes", "luck", "glück", "chance", "suerte"],
        "👋": ["hoi", "hallo", "hello", "hey", "hi", "doei", "bye", "dag", "tschüss", "salut", "bonjour", "hola", "adiós", "groet"],
        "😘": ["kus", "kiss", "kuss", "bisou", "beso", "xx", "xxx"],
        "🤗": ["knuffel", "hug", "umarm", "câlin", "abrazo"],
        "😡": ["boos", "kwaad", "angry", "woedend", "wütend", "fâché", "enfadad", "irritant"],
        "😢": ["jammer", "sad", "verdrietig", "traurig", "triste", "pity", "dommage", "lástima", "helaas", "unfortunately", "leider"],
        "😱": ["schrik", "eng", "scary", "omg", "help", "hilfe", "aide", "ayuda"],
        "😮": ["wow", "really", "serieus", "wirklich", "vraiment", "verdad"],
        "🔥": ["vet", "lit", "heet", "hot", "geweldig", "awesome", "super", "toll", "génial", "genial", "fire"],
        "✨": ["mooi", "beautiful", "prachtig", "schön", "beau", "belle", "bonit", "hermos", "magic"],
        "😍": ["mooi", "prachtig", "beautiful", "gorgeous", "schön", "magnifique", "precios"],
        "✅": ["klaar", "done", "gedaan", "fertig", "fini", "hecho", "listo", "afgerond", "check", "geregeld", "opgelost", "fixed"],
        "❌": ["nee", "nein", "cancel", "annul", "fout", "wrong", "falsch", "faux"],
        "⚠️": ["opgelet", "warning", "achtung", "attention", "cuidado", "risico", "risk"],
        "🚀": ["launch", "live", "release", "lancering", "deploy", "start", "gestart", "lanc", "snel", "fast"],
        "💻": ["computer", "laptop", "code"],
        "📅": ["afspraak", "meeting", "vergadering", "agenda", "morgen", "maandag", "dinsdag", "woensdag", "donderdag", "vrijdag", "monday", "tuesday", "wednesday", "thursday", "friday", "termin", "réunion", "reunión", "datum", "date"],
        "⏰": ["late", "deadline", "spät", "zeit", "retard", "tarde", "snel", "haast"],
        "📞": ["bel", "call", "telefoon", "phone", "anruf", "appel", "llam"],
        "📧": ["mail", "email", "inbox", "correo", "courriel"],
        "💡": ["idee", "idea", "tip", "slim", "smart", "idée", "einfall"],
        "💰": ["geld", "money", "betaal", "pay", "prijs", "price", "kosten", "cost", "euro", "dollar", "salaris", "argent", "dinero"],
        "🏆": ["gewonnen", "won", "winner", "kampioen", "champion", "gewinn", "gagn", "ganad", "prijs"],
        "🏠": ["thuis", "home", "huis", "house", "zuhause", "maison", "casa"],
        "✈️": ["vakantie", "holiday", "vacation", "vlucht", "flight", "reis", "travel", "urlaub", "vacances", "vacaciones", "vuelo", "flug"],
        "🚗": ["auto", "car", "rijden", "drive", "fahr", "voiture", "coche", "traffic"],
        "🐶": ["hond", "dog", "puppy", "hund", "chien", "perro"],
        "🐱": ["kat", "cat", "poes", "katze", "gato"],
        "🎶": ["muziek", "music", "song", "liedje", "concert", "musik", "musique", "música", "festival"],
        "⚽": ["voetbal", "football", "soccer", "fußball", "foot", "fútbol", "wedstrijd", "match"],
        "📚": ["studie", "study", "leren", "school", "boek", "book", "tentamen", "exam", "lernen", "étud", "estudi", "libro", "buch", "livre"],
        "🤒": ["ziek", "sick", "griep", "krank", "malade", "enferm", "koorts", "fever"],
        "😎": ["cool", "chill", "relax", "nice", "lekker"],
        "👀": ["kijk", "look", "zien", "check", "schau", "regarde", "mira"],
        "🙈": ["oeps", "schaam", "embarrass", "gênant", "peinlich"],
        "💯": ["helemaal", "absoluut", "absolutely", "exactly", "precies", "totally", "genau", "exactement", "exacto"],
        "👏": ["bravo", "knap", "applaus", "chapeau", "top"],
        "🌹": ["valentijn", "valentine", "roos", "rose", "rosa"],
        "🎄": ["kerst", "christmas", "xmas", "weihnacht", "noël", "navidad"],
        "🎃": ["halloween"],
        "🥂": ["proost", "cheers", "nieuwjaar", "champagne", "toast", "jubileum"],
    ]

    /// - Parameter tone: 0 for the default, 1…5 light to dark.
    static func render(_ emoji: CompletionEmoji, skinTone tone: Int) -> String {
        guard emoji.toneable, (1...5).contains(tone), let modifier = Unicode.Scalar(0x1F3FA + tone),
              let first = emoji.character.unicodeScalars.first else { return emoji.character }
        var scalars = String.UnicodeScalarView()
        scalars.append(first)
        scalars.append(modifier)
        // A variation selector right after the base goes; the rest (joined sequences) stays.
        scalars.append(contentsOf: emoji.character.unicodeScalars.dropFirst().drop { $0.value == 0xFE0F })
        return String(scalars)
    }

    static let all: [CompletionEmoji] = table.split(separator: "\n").compactMap { line in
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let toneable = parts[0].hasSuffix("*")
        return CompletionEmoji(character: toneable ? String(parts[0].dropLast()) : String(parts[0]),
                               shortcodes: parts.dropFirst().map(String.init), toneable: toneable)
    }

    /// `emoji[*] name [other names…]`; `*` marks emoji that take a skin tone. Most used first.
    private static let table = """
    😂 joy laughing_crying lachen lachtranen
    ❤️ heart red_heart love hart liefde
    🤣 rofl rolling_on_the_floor_laughing
    👍* thumbsup +1 thumbs_up yes duim duimpje top
    😭 sob crying_loudly huilen janken
    🙏* pray thanks please folded_hands dankjewel alsjeblieft bidden
    😘 kissing_heart kiss kus kusje
    🥰 smiling_face_with_hearts in_love
    😍 heart_eyes verliefd
    😊 blush smile_blush blozen
    🎉 tada party celebrate feest hoera gefeliciteerd
    😁 grin beaming grijns
    💕 two_hearts
    🥺 pleading puppy_eyes
    😅 sweat_smile phew pfoe
    🔥 fire lit vuur
    ☺️ relaxed
    🤦* facepalm zucht
    ♥️ hearts
    🤷* shrug geenidee schouderophalen
    🙄 roll_eyes eyeroll ogenrollen
    😆 laughing satisfied
    🤗 hugs hugging knuffel
    😉 wink knipoog
    🎂 birthday cake verjaardag taart jarig
    🤔 thinking think hmm denken nadenken
    👏* clap applause applaus klappen
    🙂 slightly_smiling_face slight_smile
    😳 flushed
    🥳 partying_face party_face feestje
    😎 sunglasses cool zonnebril
    👌* ok_hand okay perfect oke prima
    💜 purple_heart
    😔 pensive
    💪* muscle strong flex sterk spierballen
    ✨ sparkles glitter
    💖 sparkling_heart
    👀 eyes look ogen kijken
    😋 yum
    😏 smirk
    😢 cry sad verdrietig
    👉* point_right wijsrechts
    💗 heartpulse
    😩 weary
    💯 100 hundred honderd
    🌹 rose roos
    💞 revolving_hearts
    🎈 balloon ballon
    💙 blue_heart
    😃 smiley
    😡 rage angry_red boos woedend
    💐 bouquet flowers bloemen
    😜 stuck_out_tongue_winking_eye
    🙈 see_no_evil aapje
    🤞* crossed_fingers fingers_crossed duimen succes
    😄 smile glimlach
    🤤 drooling_face drool
    🙌* raised_hands hooray joepie
    🤪 zany_face crazy
    ❣️ heavy_heart_exclamation
    😀 grinning
    💋 kiss_mark lips
    💀 skull dead doodgelachen
    👇* point_down
    💔 broken_heart
    😌 relieved
    💓 heartbeat
    🤩 star_struck starstruck
    🙃 upside_down upside_down_face
    😬 grimacing
    😱 scream schrik
    😴 sleeping zzz_face slapen
    🤭 hand_over_mouth giggle
    😐 neutral_face
    🌞 sun_with_face
    😒 unamused
    😇 innocent angel
    🌸 cherry_blossom
    😈 smiling_imp devil
    🎶 notes music
    ✌️* v peace victory
    🎊 confetti_ball
    🥵 hot_face
    😞 disappointed
    💚 green_heart
    ☀️ sunny sun zon zonnig
    🖤 black_heart
    💰 moneybag money geld
    😚 kissing_closed_eyes
    👑 crown
    🎁 gift present cadeau
    💥 boom collision
    🙋* raising_hand
    ☹️ frowning_face
    😑 expressionless
    🥴 woozy_face
    👈* point_left
    💩 poop hankey
    ✅ white_check_mark check done vinkje klaar
    👋* wave hello bye zwaaien hoi doei
    🤮 vomiting_face
    😤 triumph huff
    🤢 nauseated_face
    🌟 star2 glowing_star
    ❗ exclamation
    😥 disappointed_relieved
    🌈 rainbow regenboog
    💛 yellow_heart
    😝 stuck_out_tongue_closed_eyes
    😫 tired_face
    😲 astonished
    🖕* middle_finger
    ‼️ bangbang
    🔴 red_circle
    🌻 sunflower zonnebloem
    🤯 exploding_head mind_blown
    💃* dancer
    👊* punch fist_bump facepunch
    🤬 cursing_face
    🏃* runner running
    😕 confused
    ⚡ zap lightning
    ☕ coffee koffie
    🍀 four_leaf_clover luck
    💦 sweat_drops
    ⭐ star ster
    🦋 butterfly
    🤨 raised_eyebrow
    🌺 hibiscus
    😹 joy_cat
    🤘* metal rock_on
    🌷 tulip
    💝 gift_heart
    💤 zzz
    🤝 handshake deal handdruk
    🐰 rabbit bunny
    😓 sweat
    💘 cupid
    🍻 beers cheers
    😟 worried
    😣 persevere
    🧐 monocle_face
    😠 angry
    🤠 cowboy
    😻 heart_eyes_cat
    🌙 crescent_moon moon
    😛 stuck_out_tongue
    🤙* call_me shaka
    🙊 speak_no_evil
    🧡 orange_heart
    🤡 clown
    🤫 shushing_face shh
    🌼 blossom
    🥂 clinking_glasses toast champagne_glasses
    😷 mask
    🤓 nerd
    🥶 cold_face
    😶 no_mouth
    😖 confounded
    🎵 musical_note
    🚶* walking
    😙 kissing_smiling_eyes
    🍆 eggplant
    🤑 money_mouth
    😗 kissing
    🐶 dog puppy hond
    🍓 strawberry
    👅 tongue
    👄 mouth
    🌿 herb
    ⚠️ warning waarschuwing let_op
    📣 mega megaphone
    🍑 peach
    🤧 sneezing_face
    🍁 maple_leaf
    👻 ghost
    🍒 cherries
    😮 open_mouth wow
    🚀 rocket ship launch raket
    🍕 pizza
    🍺 beer bier
    🍷 wine wine_glass
    🍔 hamburger burger
    🌮 taco
    🍰 cake_slice gebak
    🍎 apple
    🐱 cat kitty kat poes
    🦄 unicorn
    🐛 bug
    🌍 earth_africa earth globe
    🌊 ocean wave_water
    ❄️ snowflake snow
    ☔ umbrella rain
    ⏰ alarm_clock wekker
    ⏳ hourglass
    📅 calendar date agenda kalender
    📌 pushpin pin
    📎 paperclip
    📝 memo note pencil
    📧 email e-mail mail
    📞 phone telephone telefoon
    💻 computer laptop
    📱 iphone mobile
    🔒 lock
    🔑 key
    🔍 mag search
    💡 bulb idea idee lampje
    🔧 wrench fix
    🛠️ tools hammer_and_wrench
    ⚙️ gear settings
    📈 chart_with_upwards_trend chart_up
    📉 chart_with_downwards_trend chart_down
    📊 bar_chart
    💵 dollar
    💳 credit_card
    🏆 trophy beker prijs
    🥇 first_place gold_medal
    🎯 dart target bullseye doel roos
    🎮 video_game gaming
    🎧 headphones
    📷 camera
    🎬 clapper movie
    📚 books boeken
    ✏️ pencil2
    ✈️ airplane plane vliegtuig
    🚗 car auto
    🏠 house home huis thuis
    🏢 office
    ❌ x cross_mark no kruis nee
    ❓ question vraag
    ➡️ arrow_right
    ⬅️ arrow_left
    ⬆️ arrow_up
    ⬇️ arrow_down
    🔗 link
    ♻️ recycle
    🆗 ok
    🆕 new
    🔔 bell
    🚨 rotating_light alert siren
    🚧 construction wip
    🐢 turtle slow
    🐍 snake
    🐳 whale
    🦊 fox
    🐻 bear
    🐼 panda
    🐸 frog
    🐵 monkey_face monkey
    🦁 lion
    🐷 pig
    🐔 chicken
    🐧 penguin
    🤖 robot
    👽 alien
    👶* baby
    🧠 brain brein hersenen
    👁️ eye
    🦷 tooth
    🫶* heart_hands
    🫡 saluting_face salute
    🫠 melting_face
    🥹 face_holding_back_tears
    🫣 peeking_eye
    🤌* pinched_fingers
    ✍️* writing_hand
    🤏* pinching_hand
    👎* thumbsdown -1 thumbs_down
    ✊* fist
    🖐️* raised_hand_with_fingers_splayed hand
    ☝️* point_up
    🌧️ cloud_with_rain rainy
    🍽️ plate_with_cutlery
    ⚽ soccer football voetbal
    🤒 thermometer_face sick ziek
    🎄 christmas_tree kerstboom
    🎃 jack_o_lantern pumpkin pompoen
    """
}
