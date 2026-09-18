import Foundation

enum SpellTargeting: String, Codable, CaseIterable {
    case direction, location, cone, unit, vector, none, unknown

    var label: String {
        switch self {
        case .direction: return "directional skillshot"
        case .location: return "ground targeted"
        case .cone: return "cone"
        case .unit: return "targeted"
        case .vector: return "vector (drag)"
        case .none: return "no aiming"
        case .unknown: return "unknown"
        }
    }

    var aimable: Bool {
        switch self {
        case .direction, .location, .cone, .unit: return true
        default: return false
        }
    }
}

/** Geometry of one champion spell from Data Dragon and CommunityDragon (see Tools/generate_spells.py). */
struct SpellSpec: Codable, Identifiable, Equatable {
    var id: String
    var champion: String
    var championName: String
    var slot: String
    var name: String
    var image: String
    var cooldown: [Double]
    var cost: [Double]
    var maxRank: Int
    var ddRange: [Double]
    var targeting: String
    var range: Double
    var width: Double
    var radius: Double
    var coneAngle: Double
    var speed: Double
    var castTime: Double
    var castLock: Double

    var targetingType: SpellTargeting { SpellTargeting(rawValue: targeting) ?? .unknown }
    var isGlobal: Bool { range >= 20000 }

    var rangeText: String {
        if range <= 0 { return "–" }
        return isGlobal ? "global" : "\(Int(range))"
    }

    var cooldownText: String {
        cooldown.isEmpty ? "–" : cooldown.map { $0 == $0.rounded() ? "\(Int($0))" : String(format: "%.1f", $0) }.joined(separator: "/")
    }

    var costText: String {
        guard let top = cost.max(), top > 0 else { return "free" }
        return Set(cost).count == 1 ? "\(Int(top))" : cost.map { "\(Int($0))" }.joined(separator: "/")
    }
}

/** Lookup over the generated spell table by spell id or champion + slot. */
enum Spells {
    private struct Payload: Codable {
        var version: String
        var spells: [SpellSpec]
    }

    static let all: [SpellSpec] = {
        guard let data = SpellData.json.data(using: .utf8), let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            Log.warn("spell table failed to decode")
            return []
        }
        return payload.spells
    }()

    static let byID: [String: SpellSpec] = Dictionary(all.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })

    static let byChampion: [String: [SpellSpec]] = {
        var table: [String: [SpellSpec]] = [:]
        for spec in all { table[Settings.normalize(spec.champion), default: []].append(spec) }
        for (key, specs) in table { table[key] = specs.sorted { slotOrder($0.slot) < slotOrder($1.slot) } }
        return table
    }()

    static let champions: [(id: String, name: String)] = {
        var seen = Set<String>()
        return all.compactMap { seen.insert($0.champion).inserted ? ($0.champion, $0.championName) : nil }.sorted { $0.name < $1.name }
    }()

    static func spec(id: String) -> SpellSpec? {
        byID[id.lowercased()]
    }

    static func spec(champion: String, slot: String) -> SpellSpec? {
        byChampion[Settings.normalize(champion)]?.first { $0.slot == slot }
    }

    /** Spell for a live ability id, falling back to the champion's table entry when the id belongs to a transformed form. */
    static func resolve(abilityID: String, champion: String, slot: String) -> SpellSpec? {
        spec(id: abilityID) ?? spec(champion: champion, slot: slot)
    }

    static func slotOrder(_ slot: String) -> Int {
        ["Q": 0, "W": 1, "E": 2, "R": 3][slot] ?? 9
    }
}
