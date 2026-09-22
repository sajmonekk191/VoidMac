import Testing
@testable import VoidMac

@Test func castFitsTheGapWithItsOverrun() {
    #expect(AttackTiming.castFits(slackMs: 200, castMs: 250))
    #expect(!AttackTiming.castFits(slackMs: 140, castMs: 250))
    #expect(AttackTiming.castFits(slackMs: 250, castMs: 250, overrunMs: 0))
    #expect(!AttackTiming.castFits(slackMs: 249, castMs: 250, overrunMs: 0))
    #expect(!AttackTiming.castFits(slackMs: 250 + AttackTiming.castWindowMs + 1, castMs: 250))
}

@Test func attackStartIsCappedByTheWindupBuffer() {
    #expect(AttackTiming.attackStart(clickStart: 1000, motionMs: 900, bufferMs: 60) == 1000)
    #expect(AttackTiming.attackStart(clickStart: 1000, motionMs: 1030, bufferMs: 60) == 1030)
    #expect(AttackTiming.attackStart(clickStart: 1000, motionMs: 1500, bufferMs: 60) == 1060)
    #expect(AttackTiming.didHit(bestFill: 40, fillAtClick: 41))
    #expect(!AttackTiming.didHit(bestFill: 41, fillAtClick: 41))
}

@Test func bodyLearnerProbesEveryFourthAttack() {
    let learner = BodyLearner()
    let probes = (1...8).map { _ in learner.clickDepth(champion: "ashe", prior: 200, known: false, fraction: 0.45).probe }
    #expect(probes == [false, false, false, true, false, false, false, true])
    #expect(learner.height(champion: "ashe", prior: 200, known: false) == 200)
}

@Test func bodyLearnerShrinksOnRepeatedMissesButKeepsItsFloor() throws {
    let learner = BodyLearner()
    _ = learner.clickDepth(champion: "ashe", prior: 200, known: false, fraction: 0.45)
    #expect(learner.record(champion: "ashe", depth: 100, hit: true) == nil)
    #expect(learner.record(champion: "ashe", depth: 150, hit: false) == nil)
    let moved = try #require(learner.record(champion: "ashe", depth: 150, hit: false))
    #expect(moved.height == 140)
    #expect(moved.height >= 200 * BodyLearner.floorOfPrior)
    _ = learner.record(champion: "ashe", depth: 400, hit: true)
    #expect(learner.height(champion: "ashe", prior: 200, known: false) <= 200)
}

@Test func nameSimilarityAndMatching() throws {
    #expect(NameReader.similarity("ashe", "ashe") == 1)
    #expect(NameReader.similarity("choGath", "chogathxx") == 1 - 3.0 / 9)
    #expect(NameReader.similarity("kayle", "kaylemain") == 0.85)
    let enemies = [EnemyPlayer(champion: "chogath", championName: "Cho'Gath", level: 12, names: ["Cho'Gath", "BigBoy"]),
                   EnemyPlayer(champion: "annie", championName: "Annie", level: 9, names: ["Annie", "Tibbers4Life"])]
    #expect(try #require(NameReader.match(name: "Target Dummy", level: 1, enemies: enemies)).via == "dummy")
    #expect(try #require(NameReader.match(name: "BigBoy", level: 0, enemies: enemies)).player.champion == "chogath")
    #expect(try #require(NameReader.match(name: "", level: 9, enemies: enemies)).player.champion == "annie")
    #expect(NameReader.match(name: "", level: 5, enemies: enemies) == nil)
}

@Test func castLockTrustsOnlyAgreeingHudReadings() {
    let spec = Spells.spec(champion: "Lucian", slot: "Q")
    let engine = ComboEngine()
    let table = (spec?.castLock ?? 0.25) * 1000
    #expect(engine.castLockMs(slot: "Q", spec: spec) == table)
    for ms in [410.0, 420, 400] { engine.recordObservedLock(slot: "Q", ms: ms) }
    #expect(engine.castLockMs(slot: "Q", spec: spec) == table)
    engine.recordObservedLock(slot: "Q", ms: 30)
    engine.recordObservedLock(slot: "Q", ms: 415)
    #expect(engine.castLockMs(slot: "Q", spec: spec) == min(max(60, 415 - 100), table + 400))
}

@Test func hudStatusFormatsOnlyWhenShown() {
    #expect(HudStatus(message: "HUD: icons located (83 px, match 0.71)").text == "HUD: icons located (83 px, match 0.71)")
    let readings = [HudReading(slot: "Q", ready: true, gold: 0.953), HudReading(slot: "E", ready: false, gold: 0.1)]
    #expect(HudStatus(message: "ignored", readings: readings).text == "HUD: Q ✓ 0.95  E ✗ 0.10")
}
