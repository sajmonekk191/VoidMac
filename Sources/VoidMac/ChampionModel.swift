import Foundation

/** Size of one unit from the game files, in game units: mesh top above the feet (the bar frame sits a fixed screen distance above it), the file's bar height, selection cylinder and gameplay radius. */
struct ChampionModel: Equatable {
    var key = ""
    var name = ""
    var meshHeight = 214.0
    var barHeight = 100.0
    var selectionHeight = 122.0
    var selectionRadius = 100.0
    var gameplayRadius = 65.0

    var isKnown: Bool { !key.isEmpty }

    /** Height the unit really stands at in the game: the mesh file scaled by the measured factor (Ziggs is authored at less than half his in-game size). */
    var gameHeight: Double { meshHeight * (ChampionModels.measuredScales[key] ?? 1.0) }
}

/** Lookup of the generated size table by champion name in any Riot spelling. */
enum ChampionModels {
    static let dummyKey = "practicetooltargetdummy"
    static let fallback = ChampionModel()
    /** In-game height over the mesh file, measured on captured frames. */
    static let measuredScales: [String: Double] = ["ziggs": 2.4]

    static let table: [String: ChampionModel] = {
        var out: [String: ChampionModel] = [:]
        guard let data = ChampionModelData.json.data(using: .utf8), let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return out }
        for row in rows {
            guard let key = row["k"] as? String else { continue }
            var model = ChampionModel(key: key, name: (row["n"] as? String) ?? key)
            model.meshHeight = (row["h"] as? Double) ?? model.meshHeight
            model.barHeight = (row["b"] as? Double) ?? model.barHeight
            model.selectionHeight = (row["sh"] as? Double) ?? model.selectionHeight
            model.selectionRadius = (row["sr"] as? Double) ?? model.selectionRadius
            model.gameplayRadius = (row["g"] as? Double) ?? model.gameplayRadius
            out[key] = model
        }
        return out
    }()

    /** The same models keyed by the name the game displays, for units the API reports by display name ("Nunu & Willump" is the key "nunu"). */
    static let byDisplayName: [String: ChampionModel] = {
        var out: [String: ChampionModel] = [:]
        for model in table.values where !model.name.isEmpty { out[Settings.normalize(model.name)] = model }
        return out
    }()

    static func model(for name: String) -> ChampionModel? {
        let key = Settings.normalize(name)
        return table[key] ?? byDisplayName[key]
    }
}
