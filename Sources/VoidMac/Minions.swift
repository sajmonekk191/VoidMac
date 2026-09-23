import Foundation

/** Lane minion types; the game draws the same bar over every one of them, so the type is inferred, never seen. */
enum MinionKind: String, CaseIterable {
    case caster, melee, siege
    case superMinion = "super"
}

/** A minion's health and armor at one upgrade count. */
struct MinionStats: Equatable {
    var maxHealth: Double
    var armor: Double
}

/** Lane minion rules of one map: Summoner's Rift after V26.09, or the Howling Abyss (ARAM), whose upgrades come every 50 s on higher base health. */
enum MinionRules: Equatable {
    case summonersRift, howlingAbyss

    init(mapNumber: Int) {
        self = mapNumber == 12 ? .howlingAbyss : .summonersRift
    }

    /** Upgrades carried by minions spawned at `gameTime` seconds: one with the first wave, one more every upgrade period. */
    func upgrades(at gameTime: Double) -> Int {
        let (first, period): (Double, Double) = self == .howlingAbyss ? (50, 50) : (30, 90)
        return gameTime < first ? 0 : 1 + Int((gameTime - first) / period)
    }

    func stats(_ kind: MinionKind, upgrades: Int) -> MinionStats {
        let x = Double(max(0, upgrades))
        let aram = self == .howlingAbyss
        switch kind {
        case .caster:
            return MinionStats(maxHealth: min(600, (aram ? 290 : 275) + 9 * x), armor: 0)
        case .melee:
            let armor = upgrades >= 6 ? min(20, 0.0425 * (x - 6) * (x - 5)) : 0
            return MinionStats(maxHealth: min(1550, (aram ? 455 : 430) + 35 * x), armor: armor)
        case .siege:
            return MinionStats(maxHealth: min(5850, (aram ? 805 : 750) + 85 * x), armor: 0)
        case .superMinion:
            return MinionStats(maxHealth: min(7500, 1500 + 100 * x), armor: aram ? 60 : 100)
        }
    }
}

/** Our basic attack against minions: total AD plus the unique 5 bonus damage of Doran's Shield, Doran's Ring or Tear, reduced by the minion's armor after lethality, scaled by the ARAM balance factor and the efficiency learned from our own hits. */
struct AttackDamageModel: Equatable {
    var attackDamage = 0.0
    var bonusVsMinions = 0.0
    var lethality = 0.0
    var damageDealt = 1.0
    var efficiency = 1.0

    static let helpingHandItems: Set<Int> = [1054, 1056, 3070]

    /** Damage of one basic attack against a minion with `armor`. */
    func damage(armor: Double) -> Double {
        let effectiveArmor = max(0, armor - lethality)
        return (attackDamage + bonusVsMinions) * 100 / (100 + effectiveArmor) * damageDealt * efficiency
    }

    /** Health share one attack removes from a minion of this kind. */
    func share(_ kind: MinionKind, rules: MinionRules, upgrades: Int) -> Double {
        let stats = rules.stats(kind, upgrades: upgrades)
        return damage(armor: stats.armor) / stats.maxHealth
    }
}
