import Foundation

/** One health reading: when it was true and the share of maximum health. */
struct HealthReading: Equatable {
    var t: Double
    var share: Double
}

/** When Heal or Barrier goes out: the health share, carried forward over the reading's age and the cast at the current loss (at most 10 % of maximum health), at or under the threshold while health is being lost. */
enum DefenseTrigger {
    /** How far past the reading's age the loss is carried: key post and one game frame. */
    static let lookaheadMs = 60.0
    static let maxProjectedLoss = 0.10

    /** Health share lost per ms over the readings of the last `windowMs`: the fall from the highest reading to the last one, zero when health did not fall. */
    static func lossPerMs(_ readings: [HealthReading], now: Double, windowMs: Double = 1500) -> Double {
        let recent = readings.filter { now - $0.t <= windowMs }
        guard let last = recent.last, let peak = recent.max(by: { $0.share < $1.share }), last.t - peak.t >= 100, peak.share > last.share else { return 0 }
        return (peak.share - last.share) / (last.t - peak.t)
    }

    /** Health share expected `lookaheadMs` after `now` from a reading taken at `readingMs`. */
    static func projected(share: Double, readingMs: Double, lossPerMs: Double, now: Double) -> Double {
        share - min(maxProjectedLoss, lossPerMs * max(0, now - readingMs + lookaheadMs))
    }

    /** True when health fell by at least 3 % of its maximum within the last two seconds. */
    static func takingDamage(_ readings: [HealthReading], now: Double) -> Bool {
        let recent = readings.filter { now - $0.t <= 2000 }
        guard let last = recent.last, let peak = recent.map(\.share).max() else { return false }
        return peak - last.share >= 0.03
    }
}

/** Auto Heal/Barrier, checked on every scanned frame from the Live Client's health (the own bar on screen shrinks under a shield, so it is not used): the spell goes out only when the HUD shows it ready, or cannot tell and 5 s passed since the last try, and never while the menu is open. */
final class AutoDefense: @unchecked Sendable {
    let settings: Settings
    let live: LiveClient
    let game: GameSession
    /** True while the orbwalker is paused by the open menu. */
    var paused: () -> Bool = { false }

    private let queue = DispatchQueue(label: "voidmac.defense", qos: .userInteractive)
    private let lock = NSLock()
    private var readings: [HealthReading] = []
    private var lastReadingMs = -1e9
    private var lastCastMs = -1e9
    private var casts = 0
    private var statusStorage = "off"

    /** Barrier goes first when a champion carries both: it stops a burst the moment it lands. */
    static let spells = ["SummonerBarrier", "SummonerHeal"]

    init(settings: Settings, live: LiveClient, game: GameSession) {
        self.settings = settings
        self.live = live
        self.game = game
    }

    /** One line for the panel: which spell is watched, its HUD state, the health and the casts so far. */
    var status: String { lock.withLock { statusStorage } }

    /** The HUD slots the vision must read for this: the slot holding Barrier or Heal while the feature is on. */
    func watchedSlots() -> [String] {
        guard settings.engine.defense.autoSummoner else { return [] }
        let snap = live.snapshot
        return Self.spells.compactMap { snap.summonerSlot(of: $0) }.prefix(1).map { $0 }
    }

    func observe(_ vis: VisionSnapshot) {
        let cfg = settings.engine
        guard cfg.defense.autoSummoner else { return setStatus("off") }
        let snap = live.snapshot
        guard let spell = Self.spells.first(where: { snap.summonerSlot(of: $0) != nil }), let slot = snap.summonerSlot(of: spell) else {
            return setStatus("no Heal or Barrier on D/F")
        }
        let name = spell == "SummonerHeal" ? "Heal" : "Barrier"
        guard snap.connected, !snap.isDead, snap.maxHealth > 0 else { return setStatus("\(name) on \(slot): waiting for the champion") }
        let now = nowMs()
        let readingMs = now - min(live.ageMs, 5000)
        let share = max(0, min(1, snap.currentHealth / snap.maxHealth))
        if readingMs > lastReadingMs + 1 {
            lastReadingMs = readingMs
            readings.append(HealthReading(t: readingMs, share: share))
            readings.removeAll { now - $0.t > 3000 }
        }
        let loss = DefenseTrigger.lossPerMs(readings, now: now)
        let projected = DefenseTrigger.projected(share: share, readingMs: readingMs, lossPerMs: loss, now: now)
        let ready = vis.abilityReady[slot]
        let readyText = ready.map { $0 ? "ready" : "on cooldown" } ?? "HUD not read yet"
        setStatus("\(name) on \(slot): \(readyText), health \(Int((share * 100).rounded())) %" + (casts > 0 ? ", cast \(casts)×" : ""))
        let damaged = DefenseTrigger.takingDamage(readings, now: now)
        guard projected <= cfg.defense.healthPercent / 100, damaged || !cfg.defense.onlyWhenDamaged, ready != false, !paused(), game.isFocused,
              now - lastCastMs >= (ready == true ? 1500 : 5000) else { return }
        lastCastMs = now
        casts += 1
        let key = cfg.aimKey(for: slot)
        let holdMs = max(4, cfg.aim.holdMs)
        queue.async {
            Input.key(key, down: true)
            spinMs(holdMs)
            Input.key(key, down: false)
        }
        Log.info("auto \(name) (\(slot), key \(KeyNames.name(key))): health \(Int((share * 100).rounded())) % (\(Int(now - readingMs)) ms old), \(Int((projected * 100).rounded())) % when cast at the current loss of \(Int((loss * 100_000).rounded())) %/s; HUD \(readyText)")
    }

    private func setStatus(_ text: String) {
        lock.withLock { statusStorage = text }
    }
}
