import Foundation

struct AbilityInfo: Equatable {
    var id = ""
    var name = ""
    var level = 0
}

/** One enemy from the player list: the size-table key of its champion, its level and every name the game may print above its bar. */
struct EnemyPlayer: Equatable {
    var champion = ""
    var championName = ""
    var level = 0
    var names: [String] = []
}

struct PlayerSnapshot: Equatable {
    var connected = false
    var attackSpeed = 0.0
    var attackRange = 0.0
    var championName = ""
    var isDead = true
    var level = 0
    var moveSpeed = 0.0
    var currentHealth = 0.0
    var maxHealth = 0.0
    var abilities: [String: AbilityInfo] = [:]
    var abilityHaste = 0.0
    var resourceValue = 0.0
    var resourceMax = 0.0
    var resourceType = ""
    var summoners: [String] = []
    /** Locale-independent ids of the D and F summoner spells ("SummonerHeal"), also their Data Dragon icon names. */
    var summonerIDs: [String] = []
    var riotId = ""
    var summonerName = ""
    var kills = 0
    var enemies: [EnemyPlayer] = []
    var gameTime = 0.0
    /** Local clock of the `gameTime` reading, so the game time can be carried forward between the once-a-second polls. */
    var gameTimeAtMs = 0.0
    var mapNumber = 0
    var attackDamage = 0.0
    var lethality = 0.0
    var currentGold = 0.0
    var items: [Int] = []

    /** Game time in seconds now, carried forward from the last reading. */
    func gameTime(atMs now: Double) -> Double {
        gameTimeAtMs > 0 ? gameTime + max(0, now - gameTimeAtMs) / 1000 : gameTime
    }

    /** Summoner slot ("D" or "F") holding the spell with this id, nil when the champion does not have it. */
    func summonerSlot(of id: String) -> String? {
        summonerIDs.firstIndex(of: id).map { $0 == 0 ? "D" : "F" }
    }
}

/** Polls Riot's Live Client Data API on localhost: the active player 20x per second (50x under half health, for the auto Heal/Barrier), the player list four times per second, events and game stats once per second. */
final class LiveClient: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let base = URL(string: "https://127.0.0.1:2999/liveclientdata/")!
    private let lock = NSLock()
    private var current = PlayerSnapshot()
    private var updatedAtMs = 0.0
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.8
        config.httpAdditionalHeaders = ["User-Agent": "VoidMac"]
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    var snapshot: PlayerSnapshot { lock.withLock { current } }

    /** Milliseconds since the last poll that reached the API; infinite before the first one. */
    var ageMs: Double { lock.withLock { updatedAtMs > 0 ? nowMs() - updatedAtMs : .infinity } }

    func start() {
        let thread = Thread { self.loop() }
        thread.name = "liveclient"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func loop() {
        var lastPlayerList = -1e9
        var lastEvents = -1e9
        var lastSuccess = -1e9
        while true {
            var next = snapshot
            if let active = fetchJSON("activeplayer") as? [String: Any],
               let stats = active["championStats"] as? [String: Any] {
                lastSuccess = nowMs()
                next.connected = true
                Self.apply(active: active, stats: stats, to: &next)
                if nowMs() - lastPlayerList > 250, let list = fetchJSON("playerlist") as? [[String: Any]] {
                    lastPlayerList = nowMs()
                    let me = Self.findSelf(in: list, active: active)
                    next.championName = Self.championName(of: me)
                    next.isDead = (me?["isDead"] as? Bool) ?? true
                    next.summoners = Self.summonerSpells(of: me)
                    next.summonerIDs = Self.summonerIDs(of: me)
                    next.enemies = Self.enemies(in: list, me: me)
                    next.items = ((me?["items"] as? [[String: Any]]) ?? []).compactMap { ($0["itemID"] as? Int) ?? ($0["itemID"] as? Double).map(Int.init) }
                }
                if nowMs() - lastEvents > 1000, let events = (fetchJSON("eventdata") as? [String: Any])?["Events"] as? [[String: Any]] {
                    lastEvents = nowMs()
                    if let stats = fetchJSON("gamestats") as? [String: Any] {
                        next.gameTime = (stats["gameTime"] as? Double) ?? next.gameTime
                        next.gameTimeAtMs = nowMs()
                        next.mapNumber = (stats["mapNumber"] as? Int) ?? Int((stats["mapNumber"] as? Double) ?? 0)
                    }
                    let names = Set([next.summonerName, next.riotId, String(next.riotId.split(separator: "#").first ?? "")].filter { !$0.isEmpty })
                    next.kills = events.filter { ($0["EventName"] as? String) == "ChampionKill" && names.contains(($0["KillerName"] as? String) ?? "") }.count
                }
            } else if nowMs() - lastSuccess > 3000 {
                next = PlayerSnapshot()
            }
            lock.withLock {
                current = next
                if next.connected { updatedAtMs = nowMs() }
            }
            let lowHealth = !next.isDead && next.maxHealth > 0 && next.currentHealth < next.maxHealth / 2
            sleepMs(next.connected ? (lowHealth ? 20 : 50) : 500)
        }
    }

    private static func apply(active: [String: Any], stats: [String: Any], to next: inout PlayerSnapshot) {
        func number(_ key: String) -> Double { (stats[key] as? Double) ?? 0 }
        next.attackSpeed = number("attackSpeed")
        next.attackRange = number("attackRange")
        next.moveSpeed = number("moveSpeed")
        next.currentHealth = number("currentHealth")
        next.maxHealth = number("maxHealth")
        next.abilityHaste = number("abilityHaste")
        next.resourceValue = number("resourceValue")
        next.resourceMax = number("resourceMax")
        next.resourceType = (stats["resourceType"] as? String) ?? ""
        next.attackDamage = number("attackDamage")
        next.lethality = max(number("physicalLethality"), number("armorPenetrationFlat"))
        next.currentGold = (active["currentGold"] as? Double) ?? 0
        next.level = (active["level"] as? Int) ?? Int((active["level"] as? Double) ?? 0)
        next.riotId = (active["riotId"] as? String) ?? ""
        next.summonerName = (active["summonerName"] as? String) ?? ""
        if let abilities = active["abilities"] as? [String: Any] {
            var parsed: [String: AbilityInfo] = [:]
            for (slot, value) in abilities {
                guard let dict = value as? [String: Any] else { continue }
                parsed[slot] = AbilityInfo(id: (dict["id"] as? String) ?? "", name: (dict["displayName"] as? String) ?? "",
                                           level: (dict["abilityLevel"] as? Int) ?? Int((dict["abilityLevel"] as? Double) ?? 0))
            }
            next.abilities = parsed
        }
    }

    private static func findSelf(in list: [[String: Any]], active: [String: Any]) -> [String: Any]? {
        let riotId = active["riotId"] as? String
        let summoner = active["summonerName"] as? String
        return list.first { riotId != nil && ($0["riotId"] as? String) == riotId }
            ?? list.first { summoner != nil && ($0["summonerName"] as? String) == summoner }
            ?? list.first
    }

    private static func summonerSpells(of player: [String: Any]?) -> [String] {
        guard let spells = player?["summonerSpells"] as? [String: Any] else { return [] }
        return ["summonerSpellOne", "summonerSpellTwo"].map { ((spells[$0] as? [String: Any])?["displayName"] as? String) ?? "" }
    }

    /** The spell ids inside "GeneratedTip_SummonerSpell_<id>_DisplayName", which stay English in every client language. */
    static func summonerIDs(of player: [String: Any]?) -> [String] {
        guard let spells = player?["summonerSpells"] as? [String: Any] else { return [] }
        return ["summonerSpellOne", "summonerSpellTwo"].map { slot in
            let raw = ((spells[slot] as? [String: Any])?["rawDisplayName"] as? String) ?? ""
            guard let start = raw.range(of: "SummonerSpell_"), let end = raw.range(of: "_DisplayName", options: .backwards), start.upperBound <= end.lowerBound else { return "" }
            return String(raw[start.upperBound..<end.lowerBound])
        }
    }

    /** Players on the other team with the names shown above their bars (Riot ID game name, summoner name, champion name). */
    private static func enemies(in list: [[String: Any]], me: [String: Any]?) -> [EnemyPlayer] {
        let myTeam = (me?["team"] as? String) ?? ""
        return list.compactMap { player in
            guard let team = player["team"] as? String, team != myTeam else { return nil }
            let champion = championName(of: player)
            guard !champion.isEmpty else { return nil }
            let display = (player["championName"] as? String) ?? champion
            let level = (player["level"] as? Int) ?? Int((player["level"] as? Double) ?? 0)
            let riotName = (player["riotIdGameName"] as? String) ?? String(((player["riotId"] as? String) ?? "").split(separator: "#").first ?? "")
            let names = [riotName, (player["summonerName"] as? String) ?? "", display, champion].filter { !$0.isEmpty }
            return EnemyPlayer(champion: Settings.normalize(champion), championName: display, level: level, names: Array(Set(names)).sorted())
        }
    }

    /** Internal champion name inside a loc key, nil when the key has none of the shapes Riot uses. */
    private static func championInside(_ key: String) -> String? {
        if let range = key.range(of: "game_character_skin_displayname_") {
            let rest = key[range.upperBound...].split(separator: "_")
            return rest.count >= 2 ? rest.dropLast().joined(separator: "_") : rest.first.map(String.init)
        }
        if let range = key.range(of: "game_character_displayname_") { return String(key[range.upperBound...]) }
        if key.hasPrefix("Character_"), key.hasSuffix("_Name") { return String(key.dropFirst(10).dropLast(5)) }
        return nil
    }

    /** Champion of a player as the size table spells it: the internal name from rawChampionName or rawSkinName (Riot writes Seraphine and Aatrox as "Character_<name>_Name"), else the display name, which is localised. */
    private static func championName(of player: [String: Any]?) -> String {
        var candidates = ["rawChampionName", "rawSkinName"].compactMap { (player?[$0] as? String).flatMap(championInside) }
        if let display = player?["championName"] as? String, !display.isEmpty { candidates.append(display) }
        for candidate in candidates where !candidate.isEmpty {
            if let model = ChampionModels.model(for: candidate) { return model.key }
        }
        return candidates.first ?? ""
    }

    private func fetchJSON(_ path: String) -> Any? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Any?
        let task = session.dataTask(with: base.appendingPathComponent(path)) { data, _, _ in
            if let data { result = try? JSONSerialization.jsonObject(with: data) }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        return result
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
