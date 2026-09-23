import Foundation

/** Last-hit counters for the panel: last-hit attacks, confirmed kills, minions another unit took first, minions that survived our hit, the last outcome and the damage efficiency learned. */
struct FarmStatus: Equatable {
    var attempts = 0
    var kills = 0
    var lost = 0
    var survived = 0
    var last = ""
    var efficiency = 1.0
}

/** Whether a minion is attacked now: it dies to our hit, it is not low enough yet, or other damage kills it before our hit lands. */
enum LastHitVerdict: Equatable {
    case kill
    case notYet
    case lost
}

/** The last hitter's decisions, in shares of the minion's full bar so the unseen maximum health only enters through the kill threshold. */
enum LastHitPlanner {
    /** Loss share for the question whether the minion survives until impact. */
    static let pessimisticLoss = 1.25

    /** Health share left when our hit lands `impactMs` after the frame the bar was read in, counting `weight` of the current loss rate. */
    static func share(_ track: MinionTrack, impactMs: Double, weight: Double) -> Double {
        track.fraction - track.lossPerMs * impactMs * weight
    }

    /** A kill only at a health our hit kills already: other units' damage comes in lumps, so a hit sent ahead of it lands early and leaves the minion to them. */
    static func verdict(_ track: MinionTrack, impactMs: Double, killShare: Double) -> LastHitVerdict {
        guard track.fraction <= killShare else { return .notYet }
        return share(track, impactMs: impactMs, weight: pessimisticLoss) > -0.03 ? .kill : .lost
    }

    /** Share one attack removes, and where the number came from. A white bar kills at any health unless the kind has armor, which the assist leaves out; then, like the game's one-shot part (seen three frames running), the part it showed last or the part of the kinds it can be is cut by that armor after lethality and by the pixel its end is read to (an unknown normal bar counts as the sturdiest, a melee minion); with no part known a white normal bar kills at any health, a white super minion's is left to the model. Else our damage over the kind's health less the margin, the smaller of melee and caster while the kind is unknown. While the game's assist is on, a bar it still draws red is never killable at its current health. */
    static func killShare(_ track: MinionTrack, model: AttackDamageModel, rules: MinionRules, upgrades: Int, kind: MinionKind?, marginPercent: Double,
                          useGameAssist: Bool, assistActive: Bool, fittedPart: Double? = nil) -> (share: Double, source: String) {
        let armored = kind ?? (track.large ? .superMinion : .melee)
        let factor = 100 / (100 + max(0, rules.stats(armored, upgrades: upgrades).armor - model.lethality))
        let armorNote = factor < 1 ? String(format: " less %@ armor (×%.2f)", armored.rawValue, factor) : ""
        let pixel = 1 / Double(max(1, track.span))
        if useGameAssist, track.white {
            if factor >= 1 { return (.infinity, "game: white bar") }
            if let part = track.lastMark ?? fittedPart { return (part * factor - pixel, "game: white bar, one-shot part \(Int((part * 100).rounded())) %" + armorNote) }
            if !track.large { return (.infinity, "game: white bar") }
        }
        if useGameAssist, let mark = track.mark, track.markSightings >= 3 { return (mark * factor - pixel, "game: one-shot mark" + armorNote) }
        let keep = 1 - max(0, min(50, marginPercent)) / 100
        var share: Double
        var source: String
        if let kind = kind ?? (track.large ? .superMinion : nil) {
            share = model.share(kind, rules: rules, upgrades: upgrades) * keep
            source = "model: \(kind.rawValue)"
        } else {
            share = min(model.share(.melee, rules: rules, upgrades: upgrades), model.share(.caster, rules: rules, upgrades: upgrades)) * keep
            source = "model: melee or caster"
        }
        if useGameAssist, assistActive, !track.white {
            share = min(share, track.fraction - pixel)
            source += ", under the game's red bar"
        }
        return (share, source)
    }
}

/** One reading of the champion's gold from the Live Client, with the local time it arrived. */
struct GoldReading: Equatable {
    var t: Double
    var gold: Double

    /** Smallest jump between two readings that is a minion's bounty (a caster pays 14); passive income adds a fraction of a gold between polls. */
    static let minimumBounty = 8.0

    /** The biggest jump into a reading that arrived in `from...to`, nil unless it is a bounty. */
    static func bounty(_ readings: [GoldReading], from: Double, to: Double) -> Double? {
        let jumps = readings.indices.dropFirst().filter { readings[$0].t >= from && readings[$0].t <= to }.map { readings[$0].gold - readings[$0 - 1].gold }
        return jumps.max().flatMap { $0 >= minimumBounty ? $0 : nil }
    }
}

/** The kind behind the one-shot parts the game draws on normal bars: every part is our damage over a kind's health in the game's own count, so the parts fall into kinds whatever damage the model misses, under the one efficiency that explains them all. */
enum PartKinds {
    static let normal: [MinionKind] = [.caster, .melee, .siege]

    /** Each kind's part now under the efficiency (0.4 to 2.5 of the model's unarmored shares) whose kinds explain the parts best, each miss counted up to 40 % and the efficiency nearest 1 among equals; the best efficiency sits where some part meets some kind exactly, so only those points are tried. Empty without parts. */
    static func fit(_ parts: [Double], shares: [MinionKind: Double]) -> [MinionKind: Double] {
        let kinds = normal.compactMap { kind in shares[kind].flatMap { $0 > 0 ? (kind, log($0)) : nil } }
        let logParts = Set(parts.filter { $0 > 0 }).map { log($0) }
        guard !kinds.isEmpty, !logParts.isEmpty else { return [:] }
        let cap = log(1.4)
        func cost(_ logEfficiency: Double) -> Double {
            logParts.reduce(0.0) { sum, part in sum + min(cap, kinds.map { abs(part - $0.1 - logEfficiency) }.min() ?? cap) }
        }
        var best = (logEfficiency: 0.0, cost: cost(0))
        for part in logParts {
            for kind in kinds where abs(part - kind.1) <= log(2.5) {
                let candidate = part - kind.1, value = cost(candidate)
                if value < best.cost - 1e-9 || (abs(value - best.cost) <= 1e-9 && abs(candidate) < abs(best.logEfficiency)) { best = (candidate, value) }
            }
        }
        return Dictionary(uniqueKeysWithValues: kinds.map { ($0.0, exp($0.1 + best.logEfficiency)) })
    }

    /** The kind whose fitted part is nearest to `part`. */
    static func kind(of part: Double, partOf: [MinionKind: Double]) -> MinionKind? {
        guard part > 0 else { return nil }
        return partOf.filter { $0.value > 0 }.min { abs(log(part / $0.value)) < abs(log(part / $1.value)) }?.key
    }
}

/** What our own hits taught during one game: the kind of each minion we hit without killing it (its bar dropped by our damage over its health), and how our real damage compares with the model. */
final class LastHitLearner {
    private(set) var efficiency = 1.0
    private var drops: [(drop: Double, shares: [MinionKind: Double])] = []
    private var kinds: [Int: MinionKind] = [:]
    private static let tolerance = log(1.4)

    func kind(of trackID: Int) -> MinionKind? {
        kinds[trackID]
    }

    /** Learns from the drop our hit caused on a track, given each kind's share at the model's full damage: the efficiency that explains the last 15 drops best, then this minion's kind under it; nil when no kind explains the drop within 40 %. */
    @discardableResult
    func learn(trackID: Int, drop: Double, shares: [MinionKind: Double]) -> (kind: MinionKind, ratio: Double)? {
        guard drop > 0, shares.values.contains(where: { $0 > 0 && abs(log(drop / $0)) <= 2 * Self.tolerance }) else { return nil }
        drops = Array((drops + [(drop, shares)]).suffix(15))
        if drops.count >= 3 { efficiency = Self.bestEfficiency(drops) }
        guard let nearest = Self.nearest(drop, shares, efficiency: efficiency), abs(log(drop / (nearest.share * efficiency))) <= Self.tolerance else { return nil }
        kinds[trackID] = nearest.kind
        return (nearest.kind, drop / nearest.share)
    }

    func reset() {
        efficiency = 1
        drops = []
        kinds = [:]
    }

    /** The kind whose share at `efficiency` is nearest to the drop, with its share at the model's full damage. */
    private static func nearest(_ drop: Double, _ shares: [MinionKind: Double], efficiency: Double) -> (kind: MinionKind, share: Double)? {
        shares.filter { $0.value > 0 }.min { abs(log(drop / ($0.value * efficiency))) < abs(log(drop / ($1.value * efficiency))) }.map { ($0.key, $0.value) }
    }

    /** The efficiency in 0.6...1.4 under which the drops, each read as its nearest kind, miss least (a miss counts at most 40 %, so a critical strike cannot pull it), the one nearest 1 among equals: one kind alone cannot tell a strong caster from a weak melee, the mix can. */
    private static func bestEfficiency(_ drops: [(drop: Double, shares: [MinionKind: Double])]) -> Double {
        var best = (efficiency: 1.0, cost: Double.infinity)
        for step in [0] + (1...40).flatMap({ [$0, -$0] }) {
            let efficiency = 1 + Double(step) / 100
            let cost = drops.reduce(0.0) { sum, entry in
                sum + min(tolerance, nearest(entry.drop, entry.shares, efficiency: efficiency).map { abs(log(entry.drop / ($0.share * efficiency))) } ?? tolerance)
            }
            if cost < best.cost - 1e-9 { best = (efficiency, cost) }
        }
        return best.efficiency
    }

    /** The share our hit cut from a bar that outlived it: the biggest fall between two readings from 150 ms before to 250 ms after the predicted impact, between the medians of the last three readings before it and the first three after it within 50 ms; nil when no fall reaches two pixels. */
    static func hitDrop(_ samples: [HealthSample], impactMs: Double, span: Int) -> Double? {
        var step: Int?
        var biggest = 2 / Double(max(1, span))
        for index in samples.indices.dropFirst() where samples[index].t >= impactMs - 150 && samples[index].t <= impactMs + 250 {
            let fall = samples[index - 1].fraction - samples[index].fraction
            if fall >= biggest {
                biggest = fall
                step = index
            }
        }
        guard let step else { return nil }
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        let before = samples[max(0, step - 3)..<step].filter { $0.t >= samples[step - 1].t - 50 }.map(\.fraction)
        let after = samples[step..<min(samples.count, step + 3)].filter { $0.t <= samples[step].t + 50 }.map(\.fraction)
        return median(before) - median(after)
    }
}
