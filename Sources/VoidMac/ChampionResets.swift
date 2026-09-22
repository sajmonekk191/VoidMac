import Foundation

/** Abilities that reset the basic-attack timer (LeagueSharp AttackResets list, refreshed for current champions), keyed by normalized champion name. */
enum ChampionResets {
    static let table: [String: Set<String>] = [
        "blitzcrank": ["E"], "briar": ["W"], "camille": ["Q"], "darius": ["W"], "drmundo": ["E"], "ekko": ["E"], "fiora": ["E"], "fizz": ["W"],
        "garen": ["Q"], "illaoi": ["W"], "jax": ["W"], "jayce": ["W"], "kassadin": ["W"], "kayle": ["E"], "leona": ["Q"], "lucian": ["E"], "nasus": ["Q"],
        "nidalee": ["Q"], "reksai": ["Q"], "renekton": ["W"], "rengar": ["Q"], "riven": ["Q"], "shyvana": ["Q"], "trundle": ["Q"],
        "udyr": ["Q", "W", "E", "R"], "vayne": ["Q"], "vi": ["E"], "volibear": ["W"], "monkeyking": ["Q"], "wukong": ["Q"], "xinzhao": ["Q"], "yorick": ["Q"],
    ]

    static func resets(champion: String, slot: String) -> Bool {
        table[Settings.normalize(champion)]?.contains(slot) ?? false
    }
}
