import Foundation

/** The attack order over enemy champions: the user's list first, most wanted first, then every other champion by class (marksmen, then mages and assassins, fighters, supports, tanks); a unit whose name is not read yet comes last. */
enum TargetPriority {
    static let unknownRank = 10_000

    /** Sort key of a champion, lower is attacked first. */
    static func rank(of champion: String, order: [String]) -> Int {
        let key = Settings.normalize(champion)
        guard !key.isEmpty else { return unknownRank }
        if let index = order.firstIndex(of: key) { return index }
        let priority = ChampionCombat.traits(for: key)?.defaultPriority ?? 1
        return 1000 + (5 - priority) * 10
    }

    /** The champions in attack order, ties kept in the order given. */
    static func ordered(_ champions: [String], order: [String]) -> [String] {
        champions.enumerated().sorted { a, b in
            let ra = rank(of: a.element, order: order), rb = rank(of: b.element, order: order)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    /** The stored order after the user rearranged this match's champions: they go first in their new order, everyone stored before keeps their place behind them. */
    static func reorder(_ match: [String], stored: [String]) -> [String] {
        let keys = match.map(Settings.normalize)
        return keys + stored.filter { !keys.contains($0) }
    }
}
