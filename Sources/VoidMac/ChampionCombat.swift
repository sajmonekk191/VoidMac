import Foundation

/** What the attack model needs from a champion: ranged or melee, basic-attack missile speed, class and the ARAM damage-dealt factor. */
struct ChampionTraits: Equatable {
    var ranged = true
    var missileSpeed = 0.0
    var role = ""
    var aramDamageDealt = 1.0

    /** Units per second the basic attack flies at the current attack range (Kayle, Jayce, Nidalee and Elise change it): the table's speed, 2000 when it has none, infinite in melee range. */
    func projectileSpeed(attackRange: Double) -> Double {
        attackRange > 250 ? (missileSpeed > 0 ? missileSpeed : 2000) : .infinity
    }

    /** Built-in target priority by class, 5 = attack first (LeagueSharp's TargetSelector convention). */
    var defaultPriority: Int {
        switch role {
        case "Marksman": return 5
        case "Mage", "Assassin": return 4
        case "Fighter": return 3
        case "Support": return 2
        default: return 1
        }
    }
}

/** Lookup of the generated combat table by champion name in any Riot spelling. */
enum ChampionCombat {
    static let table: [String: ChampionTraits] = {
        var out: [String: ChampionTraits] = [:]
        guard let data = ChampionCombatData.json.data(using: .utf8), let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return out }
        for row in rows {
            guard let key = row["k"] as? String else { continue }
            out[key] = ChampionTraits(ranged: (row["r"] as? Int) == 1, missileSpeed: (row["m"] as? Double) ?? 0, role: (row["t"] as? String) ?? "",
                                      aramDamageDealt: (row["a"] as? Double) ?? 1)
        }
        return out
    }()

    static func traits(for champion: String) -> ChampionTraits? {
        let key = Settings.normalize(champion)
        return table[key] ?? ChampionModels.model(for: champion).flatMap { table[$0.key] }
    }
}
