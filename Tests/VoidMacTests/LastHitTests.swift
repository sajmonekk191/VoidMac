import Testing
@testable import VoidMac

private func minion(_ fraction: Double, loss: Double = 0, white: Bool = false, mark: Double? = nil, markSightings: Int = 0) -> MinionTrack {
    var track = MinionTrack(id: 1, x: 0, y: 0, span: 120, height: 8, fraction: fraction, white: white, mark: mark, firstSeenMs: 0, lastSeenMs: 0, maxFraction: 1)
    track.lossPerMs = loss
    track.markSightings = markSightings
    return track
}

@Test func lastHitWaitsKillsOrGivesUpOnAMinion() {
    #expect(LastHitPlanner.verdict(minion(0.10), impactMs: 300, killShare: 0.12) == .kill)
    #expect(LastHitPlanner.verdict(minion(0.30), impactMs: 300, killShare: 0.12) == .notYet)
    #expect(LastHitPlanner.verdict(minion(0.13, loss: 0.0005), impactMs: 300, killShare: 0.12) == .notYet)
    #expect(LastHitPlanner.verdict(minion(0.10, loss: 0.0002), impactMs: 300, killShare: 0.12) == .kill)
    #expect(LastHitPlanner.verdict(minion(0.10, loss: 0.001), impactMs: 300, killShare: 0.12) == .lost)
    #expect(LastHitPlanner.verdict(minion(0.40, white: true), impactMs: 300, killShare: .infinity) == .kill)
}

@Test func killShareTrustsTheGameBeforeTheModel() {
    let model = AttackDamageModel(attackDamage: 60)
    func share(_ track: MinionTrack, kind: MinionKind? = nil, active: Bool = false) -> (share: Double, source: String) {
        LastHitPlanner.killShare(track, model: model, rules: .summonersRift, upgrades: 1, kind: kind, marginPercent: 5, useGameAssist: true, assistActive: active)
    }
    #expect(share(minion(0.3, white: true)).share == .infinity)
    #expect(abs(share(minion(0.3, mark: 0.18, markSightings: 3)).share - (0.18 - 1.0 / 120)) < 1e-12)
    #expect(abs(share(minion(0.3, mark: 0.18, markSightings: 1)).share - 60.0 / 465 * 0.95) < 1e-12)
    #expect(abs(share(minion(0.3), kind: .caster).share - 60.0 / 284 * 0.95) < 1e-12)
    #expect(abs(share(minion(0.1), active: true).share - (0.1 - 1.0 / 120)) < 1e-12)
    let off = LastHitPlanner.killShare(minion(0.3, white: true), model: model, rules: .summonersRift, upgrades: 1, kind: nil, marginPercent: 0, useGameAssist: false, assistActive: false)
    #expect(abs(off.share - 60.0 / 465) < 1e-12)
}

@Test func theGamesPartIsCutByTheArmorItLeavesOut() {
    let model = AttackDamageModel(attackDamage: 60)
    func share(_ track: MinionTrack, kind: MinionKind?, upgrades: Int = 20, fitted: Double? = nil) -> Double {
        LastHitPlanner.killShare(track, model: model, rules: .summonersRift, upgrades: upgrades, kind: kind, marginPercent: 0, useGameAssist: true, assistActive: true, fittedPart: fitted).share
    }
    let meleeArmor = MinionRules.summonersRift.stats(.melee, upgrades: 20).armor
    let pixel = 1.0 / 120
    #expect(abs(share(minion(0.5, mark: 0.3, markSightings: 3), kind: .melee) - (0.3 * 100 / (100 + meleeArmor) - pixel)) < 1e-12)
    #expect(abs(share(minion(0.5, mark: 0.3, markSightings: 3), kind: .caster) - (0.3 - pixel)) < 1e-12)
    #expect(abs(share(minion(0.5, mark: 0.3, markSightings: 3), kind: nil) - (0.3 * 100 / (100 + meleeArmor) - pixel)) < 1e-12)
    var white = minion(0.25, white: true)
    white.lastMark = 0.24
    #expect(abs(share(white, kind: .melee) - (0.24 * 100 / (100 + meleeArmor) - pixel)) < 1e-12)
    #expect(share(minion(0.25, white: true), kind: nil) == .infinity)
    #expect(share(minion(0.25, white: true), kind: .caster, fitted: 0.4) == .infinity)
    var caster = minion(0.24, white: true)
    caster.lastMark = 0.24
    #expect(share(caster, kind: .caster) == .infinity)
    var giant = minion(0.05, white: true)
    giant.large = true
    #expect(abs(share(giant, kind: .superMinion) - 60.0 * 0.5 / 3500) < 1e-12)
    #expect(abs(share(giant, kind: .superMinion, fitted: 0.08) - (0.04 - pixel)) < 1e-12)
}

@Test func partsSortIntoKindsWhateverDamageTheModelMisses() throws {
    let shares: [MinionKind: Double] = [.caster: 0.20, .melee: 0.125, .siege: 0.06]
    let partOf = PartKinds.fit([0.36, 0.36, 0.225, 0.108, 0.225], shares: shares)
    let caster = try #require(partOf[.caster]), siege = try #require(partOf[.siege])
    #expect(abs(caster - 0.36) < 1e-9 && abs(siege - 0.108) < 1e-9)
    #expect(PartKinds.kind(of: 0.23, partOf: partOf) == .melee && PartKinds.kind(of: 0.11, partOf: partOf) == .siege && PartKinds.kind(of: 0.37, partOf: partOf) == .caster)
    #expect(PartKinds.fit([], shares: shares).isEmpty)
}

@Test func learnerNamesTheKindFromOurHitAndCalibratesTheDamage() throws {
    let learner = LastHitLearner()
    let shares: [MinionKind: Double] = [.caster: 0.25, .melee: 0.12, .siege: 0.06, .superMinion: 0.02]
    let first = try #require(learner.learn(trackID: 7, drop: 0.13, shares: shares))
    #expect(first.kind == .melee && learner.kind(of: 7) == .melee)
    #expect(learner.learn(trackID: 8, drop: 0.6, shares: shares) == nil)
    #expect(learner.efficiency == 1)
    learner.learn(trackID: 9, drop: 0.055, shares: shares)
    learner.learn(trackID: 10, drop: 0.27, shares: shares)
    #expect(learner.kind(of: 9) == .siege && learner.kind(of: 10) == .caster)
    #expect(abs(learner.efficiency - 1.08) < 1e-9)
    learner.reset()
    #expect(learner.efficiency == 1 && learner.kind(of: 7) == nil)
}

@Test func learnerTellsAStrongHitOnAMeleeFromAWeakOneOnACaster() {
    let learner = LastHitLearner()
    let shares: [MinionKind: Double] = [.caster: 60.0 / 284, .melee: 60.0 / 465, .siege: 60.0 / 835, .superMinion: 30.0 / 1600]
    let melee = 1.3 * 60 / 465, caster = 1.3 * 60 / 284
    learner.learn(trackID: 1, drop: melee, shares: shares)
    #expect(learner.kind(of: 1) == .caster)
    learner.learn(trackID: 2, drop: caster, shares: shares)
    learner.learn(trackID: 3, drop: melee, shares: shares)
    #expect(abs(learner.efficiency - 1.3) < 1e-9 && learner.kind(of: 3) == .melee && learner.kind(of: 2) == .caster)
}

@Test func hitDropIsTheStepOurHitCutNotTheDamageAroundIt() {
    var samples: [HealthSample] = []
    for index in 0...80 {
        let t = Double(index) * 8
        samples.append(HealthSample(t: t, fraction: (t < 308 ? 0.50 : t < 500 ? 0.30 : 0.26) + (index % 2 == 0 ? 0.001 : -0.001)))
    }
    #expect(abs((LastHitLearner.hitDrop(samples, impactMs: 330, span: 120) ?? 0) - 0.20) < 0.003)
    #expect(abs((LastHitLearner.hitDrop(samples, impactMs: 190, span: 120) ?? 0) - 0.20) < 0.003)
    #expect(LastHitLearner.hitDrop(samples.map { HealthSample(t: $0.t, fraction: 0.4) }, impactMs: 330, span: 120) == nil)
}

@Test func aKillIsTheBountyPaidAroundTheImpact() {
    let readings = [(0.0, 500.0), (50, 500.1), (100, 500.2), (150, 521.2), (200, 521.3), (900, 535.4)].map { GoldReading(t: $0.0, gold: $0.1) }
    #expect(GoldReading.bounty(readings, from: 0, to: 400).map { abs($0 - 21) < 1e-9 } == true)
    #expect(GoldReading.bounty(readings, from: 160, to: 800) == nil)
    #expect(GoldReading.bounty(readings, from: 850, to: 950).map { abs($0 - 14.1) < 1e-9 } == true)
}
