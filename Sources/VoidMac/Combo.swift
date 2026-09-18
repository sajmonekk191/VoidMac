import Foundation

/** One ability in a champion combo: cast at the target, in the cursor's direction (dashes), or without aiming (self-casts). */
struct ComboStep: Codable, Equatable, Identifiable {
    var slot: String
    var enabled = true
    var aim = "target"

    var id: String { slot }

    init(slot: String, enabled: Bool = true, aim: String = "target") {
        self.slot = slot
        self.enabled = enabled
        self.aim = aim
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slot = try c.decodeIfPresent(String.self, forKey: .slot) ?? "Q"
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        aim = try c.decodeIfPresent(String.self, forKey: .aim) ?? "target"
    }
}

struct ChampionCombo: Codable, Equatable {
    var steps: [ComboStep] = []
}

/** Combos: abilities that reset the attack timer go right after a confirmed attack; the others are timed to end just when the next attack is due (default) or go right after the attack too. */
struct ComboSettings: Codable, Equatable {
    var enabled = false
    var oneAbilityPerAttack = true
    var castBeforeAttack = true
    var ignoreCooldowns = false
    var neverDelayAttack = false
    var champions: [String: ChampionCombo] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        oneAbilityPerAttack = try c.decodeIfPresent(Bool.self, forKey: .oneAbilityPerAttack) ?? true
        castBeforeAttack = try c.decodeIfPresent(Bool.self, forKey: .castBeforeAttack) ?? true
        ignoreCooldowns = try c.decodeIfPresent(Bool.self, forKey: .ignoreCooldowns) ?? false
        neverDelayAttack = try c.decodeIfPresent(Bool.self, forKey: .neverDelayAttack) ?? false
        champions = try c.decodeIfPresent([String: ChampionCombo].self, forKey: .champions) ?? [:]
    }
}

/** Built-in combos keyed by normalized champion name; other champions get their spells listed with every step off. */
enum ChampionCombos {
    static let defaults: [String: ChampionCombo] = [
        "lucian": ChampionCombo(steps: [ComboStep(slot: "Q"), ComboStep(slot: "W"), ComboStep(slot: "E", aim: "cursor"), ComboStep(slot: "R", enabled: false)]),
    ]

    static func combo(for champion: String) -> ChampionCombo {
        if let known = defaults[Settings.normalize(champion)] { return known }
        let steps = ["Q", "W", "E", "R"].map { slot -> ComboStep in
            let targeting = Spells.spec(champion: champion, slot: slot)?.targetingType ?? .unknown
            return ComboStep(slot: slot, enabled: false, aim: targeting == .none ? "self" : "target")
        }
        return ChampionCombo(steps: steps)
    }
}

struct ComboStatus: Equatable {
    var lastText = ""
    var casts = 0
    var readiness: [String: String] = [:]
    var castLocks: [String: String] = [:]
}

/** Estimates ability readiness from our own casts (cooldown per rank and ability haste), the ability level and the resource from the Live Client API. */
final class ComboEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var castAtMs: [String: Double] = [:]
    private var observedLockMs: [String: Double] = [:]
    private var observedCount: [String: Int] = [:]
    /** The last few HUD flips per slot, kept to see whether they agree before any of them is believed. */
    private var observedSamples: [String: [Double]] = [:]
    private var castsStorage = 0
    private var lastTextStorage = ""

    /** The ability's own cooldown at this rank and ability haste, zero when the spell has none. */
    func fullCooldownMs(slot: String, spec: SpellSpec?, snap: PlayerSnapshot) -> Double {
        guard let spec, !spec.cooldown.isEmpty else { return 0 }
        let rank = max(1, min(spec.cooldown.count, snap.abilities[slot]?.level ?? 1))
        return spec.cooldown[rank - 1] / (1 + snap.abilityHaste / 100) * 1000 + spec.castTime * 1000
    }

    /** Milliseconds until the slot is off cooldown, zero when ready. */
    func cooldownRemainingMs(slot: String, spec: SpellSpec?, snap: PlayerSnapshot) -> Double {
        guard spec != nil, let castAt = lock.withLock({ castAtMs[slot] }) else { return 0 }
        return max(0, castAt + fullCooldownMs(slot: slot, spec: spec, snap: snap) - nowMs())
    }

    /** Nil when the ability can be cast now, otherwise the reason in the panel's words; the HUD icon state outranks the cooldown estimate. */
    func blocker(slot: String, spec: SpellSpec?, snap: PlayerSnapshot, hud: [String: Bool] = [:], ignoreCooldowns: Bool = false) -> String? {
        guard let spec else { return "spell not in the table" }
        let level = snap.abilities[slot]?.level ?? 0
        guard level >= 1 else { return "not learned" }
        if let seen = hud[slot] {
            if !seen { return "CD (HUD)" }
        } else if !ignoreCooldowns {
            let remaining = cooldownRemainingMs(slot: slot, spec: spec, snap: snap)
            if remaining > 0 { return String(format: "CD %.1f s (estimate)", remaining / 1000) }
        }
        let cost = spec.cost.isEmpty ? 0 : spec.cost[max(0, min(spec.cost.count, level) - 1)]
        if cost > 0, snap.resourceValue < cost { return "not enough \(snap.resourceType.lowercased()) (\(Int(snap.resourceValue))/\(Int(cost)))" }
        return nil
    }

    /** Milliseconds since we cast the slot ourselves, or nil. */
    func sinceCastMs(slot: String) -> Double? {
        lock.withLock { castAtMs[slot].map { nowMs() - $0 } }
    }

    /** How long the champion is locked after the key press: the HUD flip minus its ~100 ms input and display lag, but only while the last four flips agree within 120 ms; a cast lock is a fixed property of the spell, so a scattered reading (an icon that darkens when a charge is spent, not when the cast ends) is thrown away and the data table is used. */
    func castLockMs(slot: String, spec: SpellSpec?) -> Double {
        let data = (spec?.castLock ?? 0.25) * 1000
        let steady: Double? = lock.withLock {
            let recent = (observedSamples[slot] ?? []).suffix(4).sorted()
            guard recent.count == 4, let lowest = recent.first, let highest = recent.last, highest - lowest <= 120 else { return nil }
            return recent[2]
        }
        guard let steady else { return data }
        return min(max(60, steady - 100), data + 400)
    }

    /** Key press → HUD icon dark; kept as a running average once it looks like a real cast (80 ms to 3 s). */
    func recordObservedLock(slot: String, ms: Double) {
        guard ms >= 80, ms <= 3000 else { return }
        lock.withLock {
            observedSamples[slot] = ((observedSamples[slot] ?? []) + [ms]).suffix(6).map { $0 }
            let count = observedCount[slot] ?? 0
            observedLockMs[slot] = count == 0 ? ms : (observedLockMs[slot] ?? ms) * 0.6 + ms * 0.4
            observedCount[slot] = count + 1
        }
    }

    func markCast(slot: String, text: String) {
        lock.withLock {
            castAtMs[slot] = nowMs()
            castsStorage += 1
            lastTextStorage = text
        }
    }

    /** A manual key press counts as a cast only when the estimate says the ability was ready, so a press during cooldown cannot extend it. */
    func notePress(slot: String, spec: SpellSpec?, snap: PlayerSnapshot) {
        guard blocker(slot: slot, spec: spec, snap: snap) == nil else { return }
        lock.withLock { castAtMs[slot] = nowMs() }
    }

    /** Readiness and cast locks of the enabled slots only; nothing else is read or reported. */
    func status(snap: PlayerSnapshot, hud: [String: Bool], ignoreCooldowns: Bool, slots: [String]) -> ComboStatus {
        var readiness: [String: String] = [:]
        for slot in slots {
            let spec = Spells.resolve(abilityID: snap.abilities[slot]?.id ?? "", champion: snap.championName, slot: slot)
            let blocked = blocker(slot: slot, spec: spec, snap: snap, hud: hud, ignoreCooldowns: ignoreCooldowns)
            readiness[slot] = blocked.map { $0.hasPrefix("CD") ? "On CD" : $0 } ?? "Ready"
        }
        var locks: [String: String] = [:]
        for slot in slots {
            let spec = Spells.resolve(abilityID: snap.abilities[slot]?.id ?? "", champion: snap.championName, slot: slot)
            let observed = lock.withLock { (observedCount[slot] ?? 0) >= 1 ? observedLockMs[slot] : nil }
            locks[slot] = String(format: "%.2f s", castLockMs(slot: slot, spec: spec) / 1000) + (observed.map { String(format: " (HUD %.2f)", $0 / 1000) } ?? "")
        }
        return lock.withLock { ComboStatus(lastText: lastTextStorage, casts: castsStorage, readiness: readiness, castLocks: locks) }
    }
}
