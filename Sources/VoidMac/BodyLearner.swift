import Foundation

/** Learns how far below its head a champion's body reaches, in units, from attack outcomes: a hit proves the body reaches the clicked depth, two misses at one depth put the feet above it; every fourth attack probes deeper until the two bracket the feet, then the click stays on the chest of the learned body. */
final class BodyLearner {
    private struct State {
        var prior: Double
        var deepestHit = 0.0
        var shallowestMiss = Double.infinity
        var misses: [Int: Int] = [:]
        var attacks = 0
        var probes = 0
        var settled = false
    }

    private var states: [String: State] = [:]

    private func state(_ champion: String, prior: Double, known: Bool) -> State {
        if let existing = states[champion] { return existing }
        var fresh = State(prior: prior)
        fresh.settled = known
        states[champion] = fresh
        return fresh
    }

    /** The body never shrinks under 0.7 of the size table: misses have many other causes (a shield, a step aside, a minion in the way) and two of them must not bury the click in the champion's head. */
    static let floorOfPrior = 0.7

    /** And never past this much of it: a body cannot reach below its own model, and a bar that drops for someone else's damage reads as a hit, so without this each one ratchets the click deeper until it lands under the champion. */
    static let ceilingOfPrior = 1.15

    private static func estimate(_ s: State) -> Double {
        if s.shallowestMiss.isFinite { return min(s.prior, max(s.prior * floorOfPrior, max(s.deepestHit, (s.deepestHit + s.shallowestMiss) / 2))) }
        return s.prior
    }

    /** Head-to-feet height estimate in units; `known` marks a factor already learned in an earlier game. */
    func height(champion: String, prior: Double, known: Bool) -> Double {
        Self.estimate(state(champion, prior: prior, known: known))
    }

    /** Depth below the head to click now, in units, and whether it is a probe toward the feet. */
    func clickDepth(champion: String, prior: Double, known: Bool, fraction: Double) -> (depth: Double, probe: Bool) {
        var s = state(champion, prior: prior, known: known)
        s.attacks += 1
        let height = Self.estimate(s)
        let probeNow = s.settled ? s.attacks % 25 == 0 : s.attacks % 4 == 0
        if probeNow { s.probes += 1 }
        states[champion] = s
        if probeNow {
            if s.settled { return (height * 0.9, true) }
            if s.deepestHit > 0, s.shallowestMiss.isFinite { return ((s.deepestHit + s.shallowestMiss) / 2, true) }
            return (min(height, max(s.deepestHit * 1.3, s.deepestHit + 40, height * 0.85)), true)
        }
        var depth = fraction * height
        if s.deepestHit > 0, !s.settled { depth = min(depth, s.deepestHit + 20) }
        return (depth, false)
    }

    /** Records the outcome of a click at `depth`; returns the estimate with a note when it moved or settled. */
    func record(champion: String, depth: Double, hit: Bool) -> (height: Double, settled: Bool, note: String)? {
        guard var s = states[champion] else { return nil }
        defer { states[champion] = s }
        let before = Self.estimate(s)
        if hit {
            s.deepestHit = min(s.prior * Self.ceilingOfPrior, max(s.deepestHit, depth))
            if depth >= s.shallowestMiss {
                s.shallowestMiss = .infinity
                s.misses = [:]
            }
        } else {
            let bucket = Int((depth / 10).rounded())
            s.misses[bucket, default: 0] += 1
            if s.misses[bucket, default: 0] >= 2, depth > s.deepestHit, depth < s.shallowestMiss {
                s.shallowestMiss = depth
                if s.settled {
                    s.settled = false
                    s.probes = 0
                }
            }
        }
        let after = Self.estimate(s)
        var note: String?
        if !s.settled, s.shallowestMiss.isFinite && s.shallowestMiss - s.deepestHit <= max(40, 0.25 * after) || s.probes >= 12 {
            s.settled = true
            note = String(format: "settled, the feet are %.0f u below the head", after)
        } else if abs(after - before) >= 10 {
            note = String(format: "%@ at %.0f u, feet now estimated %.0f u below the head", hit ? "hit" : "two misses", depth, after)
        }
        return note.map { (after, s.settled, $0) }
    }
}
