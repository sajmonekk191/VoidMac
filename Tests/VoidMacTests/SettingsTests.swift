import Foundation
import Testing
@testable import VoidMac

private func decode(_ json: String) -> EngineSettings? {
    Settings.decode(Data(json.utf8))
}

@Test func defaultsSurviveARoundTrip() throws {
    let data = try JSONEncoder().encode(EngineSettings())
    #expect(Settings.decode(data) == EngineSettings())
}

@Test func storedKeysStayCompatible() throws {
    let data = try JSONEncoder().encode(EngineSettings())
    let keys = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any]).keys.sorted()
    #expect(keys == [
        "activationDelayMs", "activationKeyCode", "aim", "attackChampionOnly", "attackLatencyMs", "attackMode", "attackMoveClick", "attackMoveKeyCode",
        "attackOnlyInRange", "attackRangeKeyCode", "attackRangeTolerance", "attackResets", "captureFps", "captureMode", "capturePoints", "championOnlyKeyCode",
        "championOnlyMiddleMouse", "clickHeight", "clickHoldMs", "clickJitter", "clickOffsetX", "clickOffsetY", "clickSettleMs", "combos", "defaultWindupPercent",
        "drawRange", "emoteCtrl", "emoteKeyCode", "emoteOnKill", "extraWindupMs", "gameBundleID", "heightFactors", "helicopterIntervalMs", "helicopterKeyCode",
        "helicopterRadius", "holdRadius", "identifyChampions", "lastChampion", "layout", "moveClickMaxMs", "moveClickMinMs", "panelKeyCode", "rangeColorHex",
        "rangeRainbow", "showAttackRange", "spellRanges", "stickyTarget", "targetMode", "waveclearKeyCode",
    ])
}

@Test func missingKeysAndNullsTakeTheirDefaults() throws {
    let values = try #require(decode(#"{"captureFps": null, "aim": {"enabled": true}, "layout": {"menu": null}}"#))
    #expect(values.captureFps == 120)
    #expect(values.aim.enabled && values.aim.keyQ == 12)
    #expect(values.layout.menu == nil)
}

@Test func brokenGroupFallsBackAlone() throws {
    let values = try #require(decode(#"{"aim": {"enabled": "yes"}, "captureFps": 30}"#))
    #expect(values.aim == AimSettings())
    #expect(values.captureFps == 30)
    #expect(decode(#"{"captureFps": "fast"}"#) == nil)
}

@Test func unknownChoiceDecodesToItsFallback() throws {
    let values = try #require(decode(#"{"attackMode": "teleport", "targetMode": "lowest", "aim": {"castMode": "?"}}"#))
    #expect(values.attackMode == .click)
    #expect(values.targetMode == .lowest)
    #expect(values.aim.castMode == .quick)
    let step = try JSONDecoder().decode(ComboStep.self, from: Data(#"{"slot": "E", "aim": "sideways"}"#.utf8))
    #expect(step.aim == .untargeted)
}

@Test func choicesKeepTheirStoredSpelling() throws {
    var values = EngineSettings()
    values.attackMode = .attackMove
    values.combos.champions["ashe"] = ChampionCombo(steps: [ComboStep(slot: "Q", aim: .untargeted)])
    let json = String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
    #expect(json.contains(#""attackMode":"attackmove""#))
    #expect(json.contains(#""aim":"self""#))
}

@Test func legacyOverlayCalibrationMovesIntoAim() throws {
    let values = try #require(decode(#"{"overlay": {"pxPerUnitX": 0.9, "assumeCenter": false}}"#))
    #expect(values.aim.pxPerUnitX == 0.9)
    #expect(!values.aim.assumeCenter)
}

@Test func implausibleLearnedHeightsAreDropped() throws {
    let values = try #require(decode(#"{"heightFactors": {"ziggs": 2.5, "ashe": 0.1, "lucian": 1.05}}"#))
    #expect(values.heightFactors == ["ziggs": 2.5, "lucian": 1.05])
}

@Test func storeWritesThroughAndRefreshesTheEngineSnapshot() {
    let settings = Settings()
    settings.aim.enabled = true
    settings.captureFps = 48
    settings.heightFactors["ashe"] = 1.1
    #expect(settings.engine.aim.enabled)
    #expect(settings.engine.captureFps == 48)
    #expect(settings.values.heightFactors["ashe"] == 1.1)
}

@Test func resetKeepsOnlyTheLastChampion() {
    let settings = Settings()
    settings.lastChampion = "Ashe"
    settings.captureFps = 30
    settings.combos.enabled = true
    settings.reset()
    var expected = EngineSettings()
    expected.lastChampion = "Ashe"
    #expect(settings.values == expected)
    #expect(settings.engine == expected)
}

@Test func calibrationWriteBackIsRoundedAndBounded() {
    let settings = Settings()
    settings.learnCalibration(kxRef: 0.63214, barToFeetRef: 250, feetFromCentreYRef: 3.4)
    #expect(settings.aim.pxPerUnitX == 0.632)
    #expect(settings.aim.selfFeetOffsetY == 200)
    #expect(settings.aim.feetFromCentreY == 3)
    settings.learnCalibration(kxRef: 2, barToFeetRef: 90, feetFromCentreYRef: 0)
    #expect(settings.aim.pxPerUnitX == 0.632)
}

@Test func windupFollowsTheWikiFormula() {
    let cfg = EngineSettings()
    let unknown = cfg.windupMs(for: "Nobody", attackSpeed: 0.625)
    #expect(abs(unknown - (0.15 / 0.625 * 1000 + 60)) < 1e-9)
    #expect(cfg.windupMs(for: "Nobody", attackSpeed: 1.25) < unknown)
}

@Test func championKeysNormalizeInAnySpelling() {
    #expect(Settings.normalize("Cho'Gath") == "chogath")
    #expect(Settings.normalize("Nunu & Willump") == "nunuwillump")
    #expect(Settings.normalize("Jarvan IV") == "jarvaniv")
    #expect(Settings.normalize("Ëlise") == "ëlise")
    #expect(Settings.normalize("") == "")
}
