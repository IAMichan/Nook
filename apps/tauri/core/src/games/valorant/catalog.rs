//! General Valorant knowledge: agents, their abilities, and maps. This is the same for every match and never mixes
//! with what Nook remembers of the current one (that is [`super::memory`]).
//!
//! The coaching engine only works with ids and [`AbilityKind`]s, so a new agent is one entry in [`AGENTS`].

use serde::Serialize;

/// What an ability does, which decides how Nook talks about it ("trip", "flash") and what general advice fits.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum AbilityKind {
    /// Placed and triggered by walking into it (trapwires, alarmbots, nanoswarms).
    Trap,
    /// Reveals or tracks players (recon bolts, drones, cameras).
    Recon,
    Flash,
    Smoke,
    /// Area damage (mollies, grenades, explosives).
    Damage,
    /// Slows, stuns, nearsight, suppression.
    Debuff,
    Wall,
    Movement,
    Heal,
    Ultimate,
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Ability {
    pub id: &'static str,
    pub name: &'static str,
    /// The key it sits on: C, Q, E, or X.
    pub slot: &'static str,
    pub kind: AbilityKind,
    /// Other names players (and screenshots) use for it, lowercase.
    #[serde(skip)]
    pub aliases: &'static [&'static str],
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Agent {
    pub id: &'static str,
    pub name: &'static str,
    pub abilities: &'static [Ability],
}

const fn ability(id: &'static str, name: &'static str, slot: &'static str, kind: AbilityKind) -> Ability {
    Ability { id, name, slot, kind, aliases: &[] }
}

const fn aka(id: &'static str, name: &'static str, slot: &'static str, kind: AbilityKind, aliases: &'static [&'static str]) -> Ability {
    Ability { id, name, slot, kind, aliases }
}

use AbilityKind::*;

pub const AGENTS: &[Agent] = &[
    Agent {
        id: "astra",
        name: "Astra",
        abilities: &[
            ability("gravity-well", "Gravity Well", "C", Debuff),
            ability("nova-pulse", "Nova Pulse", "Q", Debuff),
            ability("nebula", "Nebula", "E", Smoke),
            ability("cosmic-divide", "Cosmic Divide", "X", Ultimate),
        ],
    },
    Agent {
        id: "breach",
        name: "Breach",
        abilities: &[
            ability("aftershock", "Aftershock", "C", Damage),
            ability("flashpoint", "Flashpoint", "Q", Flash),
            ability("fault-line", "Fault Line", "E", Debuff),
            ability("rolling-thunder", "Rolling Thunder", "X", Ultimate),
        ],
    },
    Agent {
        id: "brimstone",
        name: "Brimstone",
        abilities: &[
            ability("stim-beacon", "Stim Beacon", "C", Movement),
            aka("incendiary", "Incendiary", "Q", Damage, &["molly"]),
            ability("sky-smoke", "Sky Smoke", "E", Smoke),
            ability("orbital-strike", "Orbital Strike", "X", Ultimate),
        ],
    },
    Agent {
        id: "chamber",
        name: "Chamber",
        abilities: &[
            ability("trademark", "Trademark", "C", Trap),
            ability("headhunter", "Headhunter", "Q", Damage),
            ability("rendezvous", "Rendezvous", "E", Movement),
            ability("tour-de-force", "Tour De Force", "X", Ultimate),
        ],
    },
    Agent {
        id: "clove",
        name: "Clove",
        abilities: &[
            ability("pick-me-up", "Pick-Me-Up", "C", Heal),
            ability("meddle", "Meddle", "Q", Debuff),
            ability("ruse", "Ruse", "E", Smoke),
            ability("not-dead-yet", "Not Dead Yet", "X", Ultimate),
        ],
    },
    Agent {
        id: "cypher",
        name: "Cypher",
        abilities: &[
            aka("trapwire", "Trapwire", "C", Trap, &["tripwire", "trip", "trip wire", "wire"]),
            aka("cyber-cage", "Cyber Cage", "Q", Smoke, &["cage"]),
            aka("spycam", "Spycam", "E", Recon, &["camera", "cam", "spy cam"]),
            ability("neural-theft", "Neural Theft", "X", Ultimate),
        ],
    },
    Agent {
        id: "deadlock",
        name: "Deadlock",
        abilities: &[
            ability("gravnet", "GravNet", "C", Debuff),
            ability("sonic-sensor", "Sonic Sensor", "Q", Trap),
            ability("barrier-mesh", "Barrier Mesh", "E", Wall),
            ability("annihilation", "Annihilation", "X", Ultimate),
        ],
    },
    Agent {
        id: "fade",
        name: "Fade",
        abilities: &[
            ability("prowler", "Prowler", "C", Recon),
            ability("seize", "Seize", "Q", Debuff),
            ability("haunt", "Haunt", "E", Recon),
            ability("nightfall", "Nightfall", "X", Ultimate),
        ],
    },
    Agent {
        id: "gekko",
        name: "Gekko",
        abilities: &[
            ability("mosh-pit", "Mosh Pit", "C", Damage),
            ability("wingman", "Wingman", "Q", Debuff),
            ability("dizzy", "Dizzy", "E", Flash),
            ability("thrash", "Thrash", "X", Ultimate),
        ],
    },
    Agent {
        id: "harbor",
        name: "Harbor",
        abilities: &[
            ability("cascade", "Cascade", "C", Wall),
            ability("cove", "Cove", "Q", Smoke),
            ability("high-tide", "High Tide", "E", Wall),
            ability("reckoning", "Reckoning", "X", Ultimate),
        ],
    },
    Agent {
        id: "iso",
        name: "Iso",
        abilities: &[
            ability("contingency", "Contingency", "C", Wall),
            ability("undercut", "Undercut", "Q", Debuff),
            ability("double-tap", "Double Tap", "E", Heal),
            ability("kill-contract", "Kill Contract", "X", Ultimate),
        ],
    },
    Agent {
        id: "jett",
        name: "Jett",
        abilities: &[
            ability("cloudburst", "Cloudburst", "C", Smoke),
            ability("updraft", "Updraft", "Q", Movement),
            aka("tailwind", "Tailwind", "E", Movement, &["dash"]),
            ability("blade-storm", "Blade Storm", "X", Ultimate),
        ],
    },
    Agent {
        id: "kayo",
        name: "KAY/O",
        abilities: &[
            aka("fragment", "FRAG/ment", "C", Damage, &["frag"]),
            aka("flashdrive", "FLASH/drive", "Q", Flash, &["flash"]),
            aka("zeropoint", "ZERO/point", "E", Recon, &["knife", "suppression knife"]),
            aka("nullcmd", "NULL/cmd", "X", Ultimate, &["null cmd"]),
        ],
    },
    Agent {
        id: "killjoy",
        name: "Killjoy",
        abilities: &[
            aka("nanoswarm", "Nanoswarm", "C", Trap, &["swarm"]),
            aka("alarmbot", "ALARMBOT", "Q", Trap, &["alarm bot", "alarm"]),
            ability("turret", "Turret", "E", Recon),
            ability("lockdown", "Lockdown", "X", Ultimate),
        ],
    },
    Agent {
        id: "neon",
        name: "Neon",
        abilities: &[
            ability("fast-lane", "Fast Lane", "C", Wall),
            ability("relay-bolt", "Relay Bolt", "Q", Debuff),
            ability("high-gear", "High Gear", "E", Movement),
            ability("overdrive", "Overdrive", "X", Ultimate),
        ],
    },
    Agent {
        id: "omen",
        name: "Omen",
        abilities: &[
            ability("shrouded-step", "Shrouded Step", "C", Movement),
            ability("paranoia", "Paranoia", "Q", Flash),
            ability("dark-cover", "Dark Cover", "E", Smoke),
            ability("from-the-shadows", "From the Shadows", "X", Ultimate),
        ],
    },
    Agent {
        id: "phoenix",
        name: "Phoenix",
        abilities: &[
            ability("blaze", "Blaze", "C", Wall),
            aka("curveball", "Curveball", "Q", Flash, &["flash"]),
            aka("hot-hands", "Hot Hands", "E", Damage, &["molly"]),
            ability("run-it-back", "Run it Back", "X", Ultimate),
        ],
    },
    Agent {
        id: "raze",
        name: "Raze",
        abilities: &[
            ability("boom-bot", "Boom Bot", "C", Recon),
            aka("blast-pack", "Blast Pack", "Q", Movement, &["satchel"]),
            aka("paint-shells", "Paint Shells", "E", Damage, &["nade", "grenade"]),
            ability("showstopper", "Showstopper", "X", Ultimate),
        ],
    },
    Agent {
        id: "reyna",
        name: "Reyna",
        abilities: &[
            ability("leer", "Leer", "C", Flash),
            ability("devour", "Devour", "Q", Heal),
            ability("dismiss", "Dismiss", "E", Movement),
            ability("empress", "Empress", "X", Ultimate),
        ],
    },
    Agent {
        id: "sage",
        name: "Sage",
        abilities: &[
            aka("barrier-orb", "Barrier Orb", "C", Wall, &["wall"]),
            aka("slow-orb", "Slow Orb", "Q", Debuff, &["slow"]),
            ability("healing-orb", "Healing Orb", "E", Heal),
            ability("resurrection", "Resurrection", "X", Ultimate),
        ],
    },
    Agent {
        id: "skye",
        name: "Skye",
        abilities: &[
            ability("regrowth", "Regrowth", "C", Heal),
            aka("trailblazer", "Trailblazer", "Q", Recon, &["dog", "tasmanian tiger"]),
            aka("guiding-light", "Guiding Light", "E", Flash, &["flash", "bird", "hawk"]),
            ability("seekers", "Seekers", "X", Ultimate),
        ],
    },
    Agent {
        id: "sova",
        name: "Sova",
        abilities: &[
            aka("owl-drone", "Owl Drone", "C", Recon, &["drone"]),
            ability("shock-bolt", "Shock Bolt", "Q", Damage),
            aka("recon-bolt", "Recon Bolt", "E", Recon, &["recon", "dart"]),
            ability("hunters-fury", "Hunter's Fury", "X", Ultimate),
        ],
    },
    Agent {
        id: "tejo",
        name: "Tejo",
        abilities: &[
            ability("stealth-drone", "Stealth Drone", "C", Recon),
            ability("special-delivery", "Special Delivery", "Q", Debuff),
            ability("guided-salvo", "Guided Salvo", "E", Damage),
            ability("armageddon", "Armageddon", "X", Ultimate),
        ],
    },
    Agent {
        id: "veto",
        name: "Veto",
        abilities: &[
            ability("crosscut", "Crosscut", "C", Movement),
            ability("chokehold", "Chokehold", "Q", Trap),
            ability("interceptor", "Interceptor", "E", Wall),
            ability("evolution", "Evolution", "X", Ultimate),
        ],
    },
    Agent {
        id: "viper",
        name: "Viper",
        abilities: &[
            aka("snake-bite", "Snake Bite", "C", Damage, &["molly"]),
            ability("poison-cloud", "Poison Cloud", "Q", Smoke),
            aka("toxic-screen", "Toxic Screen", "E", Wall, &["wall"]),
            ability("vipers-pit", "Viper's Pit", "X", Ultimate),
        ],
    },
    Agent {
        id: "vyse",
        name: "Vyse",
        abilities: &[
            ability("razorvine", "Razorvine", "C", Trap),
            ability("shear", "Shear", "Q", Trap),
            ability("arc-rose", "Arc Rose", "E", Flash),
            ability("steel-garden", "Steel Garden", "X", Ultimate),
        ],
    },
    Agent {
        id: "waylay",
        name: "Waylay",
        abilities: &[
            ability("saturate", "Saturate", "C", Debuff),
            ability("lightspeed", "Lightspeed", "Q", Movement),
            ability("refract", "Refract", "E", Movement),
            ability("convergent-paths", "Convergent Paths", "X", Ultimate),
        ],
    },
    Agent {
        id: "yoru",
        name: "Yoru",
        abilities: &[
            ability("fakeout", "Fakeout", "C", Recon),
            aka("blindside", "Blindside", "Q", Flash, &["flash"]),
            aka("gatecrash", "Gatecrash", "E", Movement, &["tp", "teleport"]),
            ability("dimensional-drift", "Dimensional Drift", "X", Ultimate),
        ],
    },
];

pub const MAPS: &[&str] =
    &["Abyss", "Ascent", "Bind", "Breeze", "Corrode", "Fracture", "Haven", "Icebox", "Lotus", "Pearl", "Split", "Sunset"];

/// Letters and digits only, lowercase: "KAY/O" and "kayo" are the same, so are "Hunter's Fury" and "hunters fury".
fn squash(text: &str) -> String {
    text.chars().filter(|c| c.is_alphanumeric()).flat_map(char::to_lowercase).collect()
}

pub fn agent(name_or_id: &str) -> Option<&'static Agent> {
    let key = squash(name_or_id);
    if key.is_empty() {
        return None;
    }
    AGENTS.iter().find(|a| squash(a.id) == key || squash(a.name) == key)
}

/// The ability of `agent` named `name` (its id, name, or an alias such as "tripwire" for Trapwire).
pub fn ability_of(agent: &'static Agent, name: &str) -> Option<&'static Ability> {
    let key = squash(name);
    if key.is_empty() {
        return None;
    }
    agent.abilities.iter().find(|a| squash(a.id) == key || squash(a.name) == key || a.aliases.iter().any(|alias| squash(alias) == key))
}

pub fn map(name: &str) -> Option<&'static str> {
    let key = squash(name);
    MAPS.iter().copied().find(|m| squash(m) == key)
}

/// The agent and ability names for display, from their ids. Falls back to the id itself.
pub fn names(agent_id: &str, ability_id: &str) -> (String, String) {
    match agent(agent_id) {
        Some(a) => (a.name.to_string(), ability_of(a, ability_id).map(|b| b.name.to_string()).unwrap_or_else(|| ability_id.into())),
        None => (agent_id.into(), ability_id.into()),
    }
}

pub fn kind_of(agent_id: &str, ability_id: &str) -> Option<AbilityKind> {
    agent(agent_id).and_then(|a| ability_of(a, ability_id)).map(|b| b.kind)
}

/// A place on the map as a key, so "B Main", "b-main", "Main B" and "B site main" are the same place.
pub fn location_key(location: &str) -> String {
    const FILLER: &[&str] = &["the", "site", "near", "at", "in", "on", "area", "entrance", "door", "corner", "of"];
    let lower = location.to_lowercase();
    let mut words: Vec<String> = lower
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| !w.is_empty() && !FILLER.contains(w))
        .map(|w| match w {
            "middle" => "mid".to_string(),
            other => other.to_string(),
        })
        .collect();
    words.sort();
    words.dedup();
    words.join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_agent_has_four_abilities_with_unique_ids() {
        let mut ids = std::collections::HashSet::new();
        for a in AGENTS {
            assert!(ids.insert(a.id), "duplicate agent {}", a.id);
            assert_eq!(a.abilities.len(), 4, "{}", a.name);
            let slots: Vec<_> = a.abilities.iter().map(|b| b.slot).collect();
            assert_eq!(slots, ["C", "Q", "E", "X"], "{}", a.name);
        }
    }

    #[test]
    fn resolves_names_and_aliases() {
        let cypher = agent("Cypher").unwrap();
        assert_eq!(ability_of(cypher, "Tripwire").unwrap().id, "trapwire");
        assert_eq!(ability_of(cypher, "spy cam").unwrap().id, "spycam");
        assert_eq!(agent("kay/o").unwrap().id, "kayo");
        assert_eq!(ability_of(agent("sova").unwrap(), "Hunter's Fury").unwrap().id, "hunters-fury");
        assert!(ability_of(cypher, "Guiding Light").is_none());
        assert_eq!(map("sunset"), Some("Sunset"));
    }

    #[test]
    fn the_same_place_written_differently_is_one_key() {
        assert_eq!(location_key("B Main"), "b main");
        assert_eq!(location_key("Main B"), "b main");
        assert_eq!(location_key("b-main entrance"), "b main");
        assert_eq!(location_key("Middle"), location_key("mid"));
        assert_ne!(location_key("A Main"), location_key("B Main"));
    }
}
