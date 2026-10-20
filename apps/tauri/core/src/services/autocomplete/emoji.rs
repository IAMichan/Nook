//! Emoji by name: type `:` at the start of a word for the picker, or `:joy` (in Dutch `:lachen`) to search. Ported from
//! `CompletionEmoji.swift`, with the Mac's suggestions that fit the text before the colon (keywords in en/nl/de/fr/es,
//! no model). Also the picker's state and layout, and the emoji the user took (only the emoji and a count, never text).

use std::collections::BTreeMap;
use std::sync::LazyLock;

use serde::{Deserialize, Serialize};

/// Emoji per row in the picker; 1–9 picks in the row with the selection.
pub const COLUMNS: usize = 9;
/// Rows the picker shows.
pub const ROWS: usize = 4;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Emoji {
    pub character: String,
    pub shortcodes: Vec<String>,
    /// Takes a skin tone.
    pub toneable: bool,
}

pub static ALL: LazyLock<Vec<Emoji>> = LazyLock::new(|| {
    TABLE
        .lines()
        .filter_map(|line| {
            let mut parts = line.split(' ').filter(|p| !p.is_empty());
            let first = parts.next()?;
            let shortcodes: Vec<String> = parts.map(str::to_string).collect();
            if shortcodes.is_empty() {
                return None;
            }
            let toneable = first.ends_with('*');
            Some(Emoji { character: first.trim_end_matches('*').to_string(), shortcodes, toneable })
        })
        .collect()
});

/// The name being typed at the end of `text`, without the colon; empty right after the colon. The colon must start a
/// word, so times (10:30), links and "Note:" do not count.
pub fn query(text: &str) -> Option<String> {
    let mut query = String::new();
    let mut chars = text.chars().rev().peekable();
    while let Some(c) = chars.next() {
        if c == ':' {
            return match chars.peek() {
                None => Some(query.chars().rev().collect()),
                Some(before) if before.is_whitespace() => Some(query.chars().rev().collect()),
                _ => None,
            };
        }
        if !(c.is_ascii_alphanumeric() || "_+-".contains(c)) || query.chars().count() >= 30 {
            return None;
        }
        query.push(c);
    }
    None
}

/// Exact matches, then names starting with it, then names containing it; most used first within each.
pub fn search(query: &str, limit: usize) -> Vec<&'static Emoji> {
    let needle = query.to_lowercase();
    if needle.is_empty() {
        return vec![];
    }
    let (mut exact, mut prefix, mut contains) = (vec![], vec![], vec![]);
    for emoji in ALL.iter() {
        if emoji.shortcodes.contains(&needle) {
            exact.push(emoji);
        } else if emoji.shortcodes.iter().any(|s| s.starts_with(&needle)) {
            prefix.push(emoji);
        } else if needle.chars().count() >= 3 && emoji.shortcodes.iter().any(|s| s.contains(&needle)) {
            contains.push(emoji);
        }
    }
    exact.into_iter().chain(prefix).chain(contains).take(limit).collect()
}

fn find(character: &str) -> Option<&'static Emoji> {
    ALL.iter().find(|e| e.character == character)
}

fn rank(character: &str) -> usize {
    ALL.iter().position(|e| e.character == character).unwrap_or(usize::MAX)
}

/// A word fits a topic word when it is that word, or (from four letters) starts with it: "feestje" fits "feest".
fn matches(word: &str, key: &str) -> bool {
    word == key || (key.chars().count() >= 4 && word.starts_with(key))
}

/// Per emoji the words that call for it: its names (whole words, not codes like "+1" or "x") and its topics.
static TOPIC_INDEX: LazyLock<Vec<(&'static str, Vec<String>)>> = LazyLock::new(|| {
    ALL.iter()
        .map(|emoji| {
            let mut words: Vec<String> =
                emoji.shortcodes.iter().filter(|s| s.chars().count() >= 3 && s.chars().all(char::is_alphabetic)).cloned().collect();
            if let Some((_, topics)) = TOPICS.iter().find(|(c, _)| *c == emoji.character) {
                words.extend(topics.iter().map(|t| t.to_string()));
            }
            (emoji.character.as_str(), words)
        })
        .collect()
});

/// Emoji that fit the last sentences of `text`, best first: a word that names one, or starts like one of its topic
/// words ("verjaardag" for 🎂, "bedankt" for 🙏). Words nearer the end count more.
pub fn contextual(text: &str, limit: usize) -> Vec<&'static Emoji> {
    let count = text.chars().count();
    let tail: String = text.chars().skip(count.saturating_sub(300)).collect::<String>().to_lowercase();
    let words: Vec<&str> = tail.split(|c: char| !c.is_alphanumeric()).filter(|w| w.chars().count() >= 2).collect();
    let mut scores: BTreeMap<&'static str, f64> = BTreeMap::new();
    for (offset, word) in words.iter().rev().enumerate().take(40) {
        let weight = 1.0 / (1.0 + offset as f64 / 8.0);
        for (character, keys) in TOPIC_INDEX.iter() {
            if keys.iter().any(|k| matches(word, k)) {
                *scores.entry(character).or_default() += weight;
            }
        }
    }
    let mut ranked: Vec<(&str, f64)> = scores.into_iter().collect();
    ranked.sort_by(|a, b| b.1.total_cmp(&a.1).then_with(|| rank(a.0).cmp(&rank(b.0))));
    ranked.into_iter().take(limit).filter_map(|(c, _)| find(c)).collect()
}

/// What the picker shows for `query`: right after the colon the ones that fit what was just written (`context`), then
/// the ones used last, then the ones used most, then the common ones; otherwise the matches by name, those that fit the
/// context first.
pub fn choices(query: &str, usage: &EmojiUsage, limit: usize, context: &str) -> Vec<&'static Emoji> {
    let fitting = contextual(context, 9);
    if !query.is_empty() {
        let found = search(query, limit);
        let (first, rest): (Vec<_>, Vec<_>) = found.into_iter().partition(|e| fitting.contains(e));
        return first.into_iter().chain(rest).collect();
    }
    let mut result: Vec<&'static Emoji> = Vec::new();
    let used = usage.recent.iter().chain(usage.most_used().iter()).filter_map(|c| find(c)).collect::<Vec<_>>();
    for emoji in fitting.into_iter().chain(used).chain(ALL.iter()) {
        if !result.contains(&emoji) {
            result.push(emoji);
            if result.len() == limit {
                break;
            }
        }
    }
    result
}

/// The emoji with a skin tone: 0 for the default, 1…5 light to dark.
pub fn render(emoji: &Emoji, tone: u8) -> String {
    if !emoji.toneable || !(1..=5).contains(&tone) {
        return emoji.character.clone();
    }
    let mut chars = emoji.character.chars();
    let Some(first) = chars.next() else { return emoji.character.clone() };
    let modifier = char::from_u32(0x1F3FA + tone as u32).unwrap_or('\u{1F3FB}');
    // A variation selector right after the base goes; the rest (joined sequences) stays.
    let rest: String = chars.skip_while(|c| *c == '\u{FE0F}').collect();
    format!("{first}{modifier}{rest}")
}

/// The emoji the user took: the last ones and a count per emoji. Only emoji, never the text around them.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct EmojiUsage {
    /// Last used first (without skin tone), at most 16.
    pub recent: Vec<String>,
    pub counts: BTreeMap<String, u32>,
}

impl EmojiUsage {
    pub fn record(&mut self, character: &str) {
        self.recent.retain(|c| c != character);
        self.recent.insert(0, character.to_string());
        self.recent.truncate(16);
        *self.counts.entry(character.to_string()).or_default() += 1;
    }

    /// The emoji used most, most first.
    pub fn most_used(&self) -> Vec<String> {
        let mut list: Vec<(&String, &u32)> = self.counts.iter().collect();
        list.sort_by(|a, b| b.1.cmp(a.1).then_with(|| a.0.cmp(b.0)));
        list.into_iter().take(COLUMNS * ROWS).map(|(c, _)| c.clone()).collect()
    }
}

/// The picker on screen: what was typed after the colon, the choices and the selection.
#[derive(Debug, Clone, PartialEq)]
pub struct Picker {
    pub query: String,
    pub choices: Vec<&'static Emoji>,
    pub selected: usize,
    /// The text before the colon, for the emoji that fit it. In memory only.
    pub context: String,
}

impl Picker {
    /// `None` when no emoji has that name: a colon with nothing behind it is just a colon.
    pub fn open(query: &str, context: &str, usage: &EmojiUsage) -> Option<Self> {
        let choices = choices(query, usage, COLUMNS * ROWS, context);
        (!choices.is_empty()).then(|| Self { query: query.into(), choices, selected: 0, context: context.into() })
    }

    /// Typing on in the name, or Delete: the choices again, without reading the field. `false` closes the picker.
    pub fn retype(&mut self, query: String, usage: &EmojiUsage) -> bool {
        if query.chars().count() > 30 {
            return false;
        }
        let choices = choices(&query, usage, COLUMNS * ROWS, &self.context);
        if choices.is_empty() {
            return false;
        }
        self.query = query;
        self.choices = choices;
        self.selected = 0;
        true
    }

    /// Arrow keys: one to the side, a row up or down, within the choices.
    pub fn step(&mut self, dx: i32, dy: i32) {
        let target = self.selected as i64 + dx as i64 + dy as i64 * COLUMNS as i64;
        self.selected = target.clamp(0, self.choices.len().saturating_sub(1) as i64) as usize;
    }

    /// The emoji numbered `number` (1–9) in the row with the selection.
    pub fn numbered(&self, number: usize) -> Option<usize> {
        if !(1..=COLUMNS).contains(&number) {
            return None;
        }
        let index = self.selected / COLUMNS * COLUMNS + number - 1;
        (index < self.choices.len()).then_some(index)
    }

    /// Return takes the selection once two letters are typed, so ":D" and Return still sends the message.
    pub fn return_takes(&self) -> bool {
        self.query.chars().count() >= 2
    }
}

/// The picker card's geometry, in logical pixels: the window and the hit test of a click both use it.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PickerLayout {
    pub cell: f64,
    pub padding: f64,
    pub footer: f64,
    pub columns: usize,
    pub rows: usize,
}

impl PickerLayout {
    pub fn new(count: usize) -> Self {
        Self { cell: 34.0, padding: 8.0, footer: 26.0, columns: COLUMNS, rows: count.div_ceil(COLUMNS).clamp(1, ROWS) }
    }

    pub fn width(&self) -> f64 {
        self.padding * 2.0 + self.cell * self.columns as f64
    }

    pub fn height(&self) -> f64 {
        self.padding * 2.0 + self.cell * self.rows as f64 + self.footer
    }

    /// The choice under a point inside the card (logical pixels from its top left).
    pub fn hit(&self, x: f64, y: f64, count: usize) -> Option<usize> {
        let (gx, gy) = (x - self.padding, y - self.padding);
        if gx < 0.0 || gy < 0.0 {
            return None;
        }
        let (column, row) = ((gx / self.cell) as usize, (gy / self.cell) as usize);
        if column >= self.columns || row >= self.rows {
            return None;
        }
        let index = row * self.columns + column;
        (index < count).then_some(index)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn table_loads() {
        assert!(ALL.len() > 250);
        let thumbs = find("👍").unwrap();
        assert!(thumbs.toneable);
        assert!(thumbs.shortcodes.contains(&"duim".to_string()));
        assert!(!find("😂").unwrap().toneable);
    }

    #[test]
    fn finds_query_at_word_start() {
        assert_eq!(query("Hoi :"), Some(String::new()));
        assert_eq!(query(":lach"), Some("lach".into()));
        assert_eq!(query("ok :+1"), Some("+1".into()));
        assert_eq!(query("at 10:30"), None);
        assert_eq!(query("Note:"), None);
        assert_eq!(query("Note: x"), None);
        assert_eq!(query("https://x"), None);
        assert_eq!(query("plain"), None);
    }

    #[test]
    fn searches_dutch_and_english() {
        assert_eq!(search("joy", 5)[0].character, "😂");
        assert_eq!(search("lachen", 5)[0].character, "😂");
        assert_eq!(search("heart", 5)[0].character, "❤️");
        assert!(search("lach", 5).iter().any(|e| e.character == "😂"));
        // "art" only matches inside names from three letters.
        assert!(!search("ar", 36).iter().any(|e| e.character == "❤️"));
        assert!(search("", 5).is_empty());
    }

    #[test]
    fn fits_the_text() {
        let fit = contextual("Gefeliciteerd met je verjaardag!", 9);
        assert_eq!(fit[0].character, "🎂");
        assert!(fit.iter().any(|e| e.character == "🎉"));
        assert_eq!(contextual("Bedankt voor je hulp", 9)[0].character, "🙏");
        assert!(contextual("", 9).is_empty());
    }

    #[test]
    fn choices_order() {
        let mut usage = EmojiUsage::default();
        usage.record("🐢");
        let list = choices("", &usage, 36, "");
        assert_eq!(list[0].character, "🐢");
        assert_eq!(list[1].character, "😂");
        let list = choices("", &usage, 36, "Fijne verjaardag");
        assert_eq!(list[0].character, "🎂");
        let list = choices("cake", &usage, 36, "Fijne verjaardag");
        assert_eq!(list[0].character, "🎂");
        assert_eq!(list.len(), list.iter().map(|e| &e.character).collect::<std::collections::BTreeSet<_>>().len());
    }

    #[test]
    fn usage_counts_only_emoji() {
        let mut usage = EmojiUsage::default();
        for c in ["😂", "👍", "😂"] {
            usage.record(c);
        }
        assert_eq!(usage.recent, vec!["😂", "👍"]);
        assert_eq!(usage.most_used(), vec!["😂", "👍"]);
        let json = serde_json::to_string(&usage).unwrap();
        let back: EmojiUsage = serde_json::from_str(&json).unwrap();
        assert_eq!(back, usage);
    }

    #[test]
    fn skin_tones() {
        let thumbs = find("👍").unwrap();
        assert_eq!(render(thumbs, 0), "👍");
        assert_eq!(render(thumbs, 3), "👍\u{1F3FD}");
        assert_eq!(render(find("✌️").unwrap(), 1), "✌\u{1F3FB}");
        assert_eq!(render(find("😂").unwrap(), 3), "😂");
    }

    #[test]
    fn picker_keys() {
        let usage = EmojiUsage::default();
        let mut picker = Picker::open("", "", &usage).unwrap();
        assert_eq!(picker.choices.len(), 36);
        picker.step(1, 1);
        assert_eq!(picker.selected, 10);
        picker.step(-20, 0);
        assert_eq!(picker.selected, 0);
        picker.step(0, 1);
        assert_eq!(picker.numbered(3), Some(11));
        assert_eq!(picker.numbered(0), None);
        assert!(!picker.return_takes());
        assert!(picker.retype("he".into(), &usage));
        assert!(picker.return_takes());
        assert_eq!(picker.selected, 0);
        assert!(!picker.retype("zzzzqqq".into(), &usage));
        assert!(Picker::open("zzzzqqq", "", &usage).is_none());
    }

    #[test]
    fn layout_hits() {
        let layout = PickerLayout::new(36);
        assert_eq!(layout.rows, 4);
        assert_eq!(layout.hit(8.0 + 34.0 * 2.5, 8.0 + 34.0 * 1.5, 36), Some(11));
        assert_eq!(layout.hit(2.0, 2.0, 36), None);
        assert_eq!(layout.hit(8.0 + 34.0 * 8.5, 8.0 + 1.0, 5), None);
        assert_eq!(PickerLayout::new(3).rows, 1);
        assert!(layout.height() > layout.cell * 4.0);
    }
}

/// `emoji[*] name [other names…]`; `*` marks emoji that take a skin tone. Most used first (from the Mac).
const TABLE: &str = "\
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
";

/// Words, or the start of words, in English, Dutch, German, French and Spanish that make an emoji likely.
const TOPICS: &[(&str, &[&str])] = &[
    ("😂", &["haha", "hihi", "lol", "grappig", "funny", "hilarious", "lustig", "drôle", "gracioso", "jaja", "mdr"]),
    ("❤️", &["love", "lieve", "schat", "liebe", "amour", "amor", "miss"]),
    ("🥰", &["lief", "schatje", "cute", "sweet", "süß", "mignon"]),
    ("👍", &["oké", "goed", "prima", "sure", "deal", "klopt", "akkoord", "gut", "accord", "vale", "bueno"]),
    ("😭", &["huil", "verdriet", "cry", "tears", "weinen", "pleur", "llor"]),
    ("🙏", &["bedankt", "dank", "thank", "thanks", "thx", "merci", "danke", "gracias", "please", "alsjeblieft", "bitte"]),
    (
        "🎉",
        &["feest", "gefeliciteerd", "felicit", "congrat", "gratul", "party", "fiesta", "fête", "félicit", "hoera", "geslaagd", "gelukt"],
    ),
    ("🥳", &["feest", "party", "jarig", "fiesta"]),
    ("🎂", &["verjaardag", "jarig", "birthday", "geburtstag", "anniversaire", "cumpleaños", "taart", "cake"]),
    ("🎁", &["cadeau", "gift", "present", "geschenk", "regalo", "kado"]),
    ("😅", &["oeps", "oops", "sorry", "pardon", "excuse", "ups", "perdón"]),
    ("🤔", &["denk", "think", "vraag", "misschien", "maybe", "vielleicht", "peut", "quizás", "hmm", "twijfel"]),
    ("😴", &["slaap", "moe", "sleep", "tired", "müde", "fatigué", "sueño", "cansad", "welterusten", "night", "nacht", "nuit"]),
    ("🌙", &["welterusten", "goodnight", "nacht", "night", "nuit", "noche"]),
    ("☀️", &["zon", "sun", "zomer", "summer", "sommer", "soleil", "sol", "verano", "warm"]),
    ("🌧️", &["regen", "rain", "pluie", "lluvia"]),
    ("☔", &["regen", "rain", "pluie", "lluvia", "paraplu"]),
    ("❄️", &["sneeuw", "snow", "schnee", "neige", "nieve", "koud", "cold", "kalt", "froid", "frío", "winter"]),
    ("☕", &["koffie", "coffee", "kaffee", "café", "ochtend", "morning", "morgen", "matin", "mañana"]),
    ("🍺", &["bier", "beer", "biertje", "bière", "cerveza", "borrel", "kroeg", "pub"]),
    ("🍻", &["proost", "cheers", "borrel", "prost", "santé", "salud"]),
    ("🍷", &["wijn", "wine", "wein", "vin", "vino"]),
    ("🍕", &["pizza"]),
    ("🍔", &["burger", "eten", "food", "essen", "manger", "comida", "lunch", "dinner", "diner", "honger", "hungry"]),
    ("🍽️", &["eten", "dinner", "diner", "lunch", "essen", "manger", "comer", "restaurant"]),
    ("💪", &["sterk", "strong", "sport", "gym", "train", "succes", "kracht", "fit", "stark", "fuerte"]),
    ("🤞", &["succes", "hopelijk", "hope", "hoop", "luck", "glück", "chance", "suerte", "duim"]),
    ("🍀", &["succes", "luck", "glück", "chance", "suerte"]),
    ("👋", &["hoi", "hallo", "hello", "hey", "hi", "doei", "bye", "dag", "tschüss", "salut", "bonjour", "hola", "adiós", "groet"]),
    ("😘", &["kus", "kiss", "kuss", "bisou", "beso", "xx", "xxx"]),
    ("🤗", &["knuffel", "hug", "umarm", "câlin", "abrazo"]),
    ("😡", &["boos", "kwaad", "angry", "woedend", "wütend", "fâché", "enfadad", "irritant"]),
    ("😢", &["jammer", "sad", "verdrietig", "traurig", "triste", "pity", "dommage", "lástima", "helaas", "unfortunately", "leider"]),
    ("😱", &["schrik", "eng", "scary", "omg", "help", "hilfe", "aide", "ayuda"]),
    ("😮", &["wow", "really", "serieus", "wirklich", "vraiment", "verdad"]),
    ("🔥", &["vet", "lit", "heet", "hot", "geweldig", "awesome", "super", "toll", "génial", "genial", "fire"]),
    ("✨", &["mooi", "beautiful", "prachtig", "schön", "beau", "belle", "bonit", "hermos", "magic"]),
    ("😍", &["mooi", "prachtig", "beautiful", "gorgeous", "schön", "magnifique", "precios"]),
    ("✅", &["klaar", "done", "gedaan", "fertig", "fini", "hecho", "listo", "afgerond", "check", "geregeld", "opgelost", "fixed"]),
    ("❌", &["nee", "nein", "cancel", "annul", "fout", "wrong", "falsch", "faux"]),
    ("⚠️", &["opgelet", "warning", "achtung", "attention", "cuidado", "risico", "risk"]),
    ("🚀", &["launch", "live", "release", "lancering", "deploy", "start", "gestart", "lanc", "snel", "fast"]),
    ("💻", &["computer", "laptop", "code"]),
    (
        "📅",
        &[
            "afspraak",
            "meeting",
            "vergadering",
            "agenda",
            "morgen",
            "maandag",
            "dinsdag",
            "woensdag",
            "donderdag",
            "vrijdag",
            "monday",
            "tuesday",
            "wednesday",
            "thursday",
            "friday",
            "termin",
            "réunion",
            "reunión",
            "datum",
            "date",
        ],
    ),
    ("⏰", &["late", "deadline", "spät", "zeit", "retard", "tarde", "snel", "haast"]),
    ("📞", &["bel", "call", "telefoon", "phone", "anruf", "appel", "llam"]),
    ("📧", &["mail", "email", "inbox", "correo", "courriel"]),
    ("💡", &["idee", "idea", "tip", "slim", "smart", "idée", "einfall"]),
    ("💰", &["geld", "money", "betaal", "pay", "prijs", "price", "kosten", "cost", "euro", "dollar", "salaris", "argent", "dinero"]),
    ("🏆", &["gewonnen", "won", "winner", "kampioen", "champion", "gewinn", "gagn", "ganad", "prijs"]),
    ("🏠", &["thuis", "home", "huis", "house", "zuhause", "maison", "casa"]),
    ("✈️", &["vakantie", "holiday", "vacation", "vlucht", "flight", "reis", "travel", "urlaub", "vacances", "vacaciones", "vuelo", "flug"]),
    ("🚗", &["auto", "car", "rijden", "drive", "fahr", "voiture", "coche", "traffic"]),
    ("🐶", &["hond", "dog", "puppy", "hund", "chien", "perro"]),
    ("🐱", &["kat", "cat", "poes", "katze", "gato"]),
    ("🎶", &["muziek", "music", "song", "liedje", "concert", "musik", "musique", "música", "festival"]),
    ("⚽", &["voetbal", "football", "soccer", "fußball", "foot", "fútbol", "wedstrijd", "match"]),
    (
        "📚",
        &["studie", "study", "leren", "school", "boek", "book", "tentamen", "exam", "lernen", "étud", "estudi", "libro", "buch", "livre"],
    ),
    ("🤒", &["ziek", "sick", "griep", "krank", "malade", "enferm", "koorts", "fever"]),
    ("😎", &["cool", "chill", "relax", "nice", "lekker"]),
    ("👀", &["kijk", "look", "zien", "check", "schau", "regarde", "mira"]),
    ("🙈", &["oeps", "schaam", "embarrass", "gênant", "peinlich"]),
    ("💯", &["helemaal", "absoluut", "absolutely", "exactly", "precies", "totally", "genau", "exactement", "exacto"]),
    ("👏", &["bravo", "knap", "applaus", "chapeau", "top"]),
    ("🌹", &["valentijn", "valentine", "roos", "rose", "rosa"]),
    ("🎄", &["kerst", "christmas", "xmas", "weihnacht", "noël", "navidad"]),
    ("🎃", &["halloween"]),
    ("🥂", &["proost", "cheers", "nieuwjaar", "champagne", "toast", "jubileum"]),
];
