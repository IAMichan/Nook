import Foundation

struct CompletionEmoji: Equatable {
    var character: String
    var shortcodes: [String]
    /// Takes a skin tone.
    var toneable: Bool
}

/// Emoji by name: type `:joy` (or in Dutch `:lachen`) and Tab gives 😂. The table and search follow Typist (MIT, © 2026 Brody
/// Salvucci); the Dutch names are Nook's.
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

    /// What the picker shows for `query`: right after the colon the ones you used last and then the most used, otherwise the
    /// matches by name.
    static func choices(for query: String, recent: [String], limit: Int) -> [CompletionEmoji] {
        guard query.isEmpty else { return search(query, limit: limit) }
        let used = recent.compactMap { character in all.first { $0.character == character } }
        return Array((used + all.filter { !recent.contains($0.character) }).prefix(limit))
    }

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
    """
}
