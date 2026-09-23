import Testing
@testable import VoidMac

private func readings(_ values: [(Double, Double)]) -> [HealthReading] {
    values.map { HealthReading(t: $0.0, share: $0.1) }
}

@Test func healthLossIsTheFallFromThePeak() {
    #expect(abs(DefenseTrigger.lossPerMs(readings([(0, 0.8), (200, 0.6), (400, 0.4)]), now: 400) - 0.001) < 1e-12)
    #expect(DefenseTrigger.lossPerMs(readings([(0, 0.4), (200, 0.6)]), now: 200) == 0)
    #expect(DefenseTrigger.lossPerMs(readings([(0, 0.8), (50, 0.5)]), now: 50) == 0)
    #expect(abs(DefenseTrigger.lossPerMs(readings([(0, 0.9), (3000, 0.5), (3200, 0.3)]), now: 3200) - 0.001) < 1e-12)
}

@Test func projectedHealthCarriesTheLossForwardUpToACap() {
    #expect(abs(DefenseTrigger.projected(share: 0.4, readingMs: 400, lossPerMs: 0.0005, now: 420) - (0.4 - 0.0005 * 80)) < 1e-12)
    #expect(abs(DefenseTrigger.projected(share: 0.4, readingMs: 400, lossPerMs: 0.01, now: 420) - 0.3) < 1e-12)
    #expect(DefenseTrigger.projected(share: 0.4, readingMs: 400, lossPerMs: 0, now: 420) == 0.4)
}

@Test func takingDamageNeedsThreePercentWithinTwoSeconds() {
    #expect(DefenseTrigger.takingDamage(readings([(0, 0.50), (500, 0.46)]), now: 500))
    #expect(!DefenseTrigger.takingDamage(readings([(0, 0.50), (500, 0.48)]), now: 500))
    #expect(!DefenseTrigger.takingDamage(readings([(0, 0.90), (2500, 0.20), (2600, 0.20)]), now: 2600))
}

@Test func summonerSpellsAreReadFromTheirLocaleFreeIDs() {
    let player: [String: Any] = ["summonerSpells": [
        "summonerSpellOne": ["displayName": "Léčení", "rawDisplayName": "GeneratedTip_SummonerSpell_SummonerHeal_DisplayName"],
        "summonerSpellTwo": ["displayName": "Trest", "rawDisplayName": "GeneratedTip_SummonerSpell_S5_SummonerSmiteDuel_DisplayName"],
    ]]
    #expect(LiveClient.summonerIDs(of: player) == ["SummonerHeal", "S5_SummonerSmiteDuel"])
    #expect(LiveClient.summonerIDs(of: nil).isEmpty)
    var snap = PlayerSnapshot()
    snap.summonerIDs = ["SummonerFlash", "SummonerBarrier"]
    #expect(snap.summonerSlot(of: "SummonerBarrier") == "F" && snap.summonerSlot(of: "SummonerFlash") == "D" && snap.summonerSlot(of: "SummonerHeal") == nil)
}

@Test func gameTimeIsCarriedForwardBetweenPolls() {
    var snap = PlayerSnapshot()
    snap.gameTime = 600
    #expect(snap.gameTime(atMs: 5000) == 600)
    snap.gameTimeAtMs = 1000
    #expect(snap.gameTime(atMs: 3500) == 602.5)
}
