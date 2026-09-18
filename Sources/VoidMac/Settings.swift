import Combine
import Foundation

/** Per-spell autoaim override, stored only when the user changes something. */
struct SpellOverride: Codable, Equatable {
    var enabled = true
    var targeting = "auto"
    var prediction = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        targeting = try c.decodeIfPresent(String.self, forKey: .targeting) ?? "auto"
        prediction = try c.decodeIfPresent(Bool.self, forKey: .prediction) ?? true
    }
}

/** One spell range drawn by the overlay: on/off and its "#RRGGBB" colour. */
struct SpellRangeStyle: Codable, Equatable {
    var enabled = false
    var colorHex = "#40D9FF"

    static let defaults: [String: SpellRangeStyle] = [
        "Q": SpellRangeStyle(colorHex: "#40D9FF"), "W": SpellRangeStyle(colorHex: "#9E7BFF"), "E": SpellRangeStyle(colorHex: "#59EB99"), "R": SpellRangeStyle(colorHex: "#FF5C6C"),
    ]

    init(enabled: Bool = false, colorHex: String) {
        self.enabled = enabled
        self.colorHex = colorHex
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? "#40D9FF"
    }
}

/** In-game UI layout: window offsets from the game window's top-left corner in points, popped-out and collapsed sections, HUD parts. */
struct LayoutSettings: Codable, Equatable {
    var menu: [Double]?
    var popped: [String: [Double]] = [:]
    var collapsed: [String] = []
    var hudStrip = true
    var hudTimer = true
    var hudTarget = true
    var badge = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        menu = try c.decodeIfPresent([Double].self, forKey: .menu)
        popped = try c.decodeIfPresent([String: [Double]].self, forKey: .popped) ?? [:]
        collapsed = try c.decodeIfPresent([String].self, forKey: .collapsed) ?? []
        hudStrip = try c.decodeIfPresent(Bool.self, forKey: .hudStrip) ?? true
        hudTimer = try c.decodeIfPresent(Bool.self, forKey: .hudTimer) ?? true
        hudTarget = try c.decodeIfPresent(Bool.self, forKey: .hudTarget) ?? true
        badge = try c.decodeIfPresent(Bool.self, forKey: .badge) ?? true
    }
}

struct AimSettings: Codable, Equatable {
    var enabled = false
    var keyQ: UInt16 = 12
    var keyW: UInt16 = 13
    var keyE: UInt16 = 14
    var keyR: UInt16 = 15
    var keyD: UInt16 = 2
    var keyF: UInt16 = 3
    var slotQ = true
    var slotW = true
    var slotE = true
    var slotR = true
    var slotD = true
    var slotF = true
    var vectorLength = 500.0
    var castMode = "quick"
    var targetMode = "cursor"
    var cursorRadius = 350.0
    var prediction = true
    var predictionFactor = 1.0
    var settleMs = 14
    var holdMs = 6
    var restoreMs = 10
    var rangeTolerance = 5.0
    var requireInRange = true
    var onlyWhileActivation = false
    var pxPerUnitX = 0.70
    var selfFeetOffsetY = 110.0
    var assumeCenter = true
    var ringCalibration = true
    var feetFromCentreY = 0.0
    var overrides: [String: SpellOverride] = [:]
}

/** Immutable copy of everything the engine threads need, rebuilt on the main thread after each change. */
struct EngineSettings {
    var gameBundleID = "com.riotgames.LeagueofLegends.GameClient"
    var captureMode = "window"
    var capturePoints = false
    var captureFps = 120
    var clickOffsetX = 0.0
    var clickOffsetY = 74.0
    var clickHeight = 55.0
    var identifyChampions = true
    var heightFactors: [String: Double] = [:]
    var attackMode = "click"
    var attackMoveKeyCode: UInt16 = 0
    var attackMoveClick = true
    var clickHoldMs = 6
    var clickSettleMs = 8
    var activationKeyCode: UInt16 = 49
    var attackRangeKeyCode: UInt16 = 8
    var panelKeyCode: UInt16 = 54
    var showAttackRange = false
    var drawRange = true
    var attackChampionOnly = false
    var championOnlyKeyCode: UInt16 = 39
    var championOnlyMiddleMouse = false
    var targetMode = "center"
    var moveClickMinMs = 70
    var moveClickMaxMs = 100
    var defaultWindupPercent = 15.0
    var extraWindupMs = 60
    var attackLatencyMs = 80
    var activationDelayMs = 150
    var attackOnlyInRange = true
    var attackRangeTolerance = 6.0
    var stickyTarget = true
    var holdRadius = 60.0
    var attackResets = true
    var clickJitter = 3.0
    var fleeKeyCode: UInt16 = KeyNames.none
    var helicopterKeyCode: UInt16 = KeyNames.none
    var helicopterIntervalMs = 60
    var helicopterRadius = 70.0
    var emoteOnKill = false
    var emoteKeyCode: UInt16 = 20
    var emoteCtrl = true
    var aim = AimSettings()
    var combos = ComboSettings()

    /** The user's combo for a champion, else the built-in one. */
    func combo(for champion: String) -> ChampionCombo {
        combos.champions[Settings.normalize(champion)] ?? ChampionCombos.combo(for: champion)
    }

    /** Official windup data for a champion in any Riot spelling. */
    func windupSpec(for champion: String) -> WindupSpec {
        ChampionWindups.table[Settings.normalize(champion)] ?? WindupSpec(percent: defaultWindupPercent, modifier: 1, baseAttackSpeed: 0.625)
    }

    func windup(for champion: String) -> Double {
        windupSpec(for: champion).percent
    }

    /** Milliseconds from the attack command until the attack is committed, using the wiki formula plus the safety buffer. */
    func windupMs(for champion: String, attackSpeed: Double) -> Double {
        let spec = windupSpec(for: champion)
        let percent = spec.percent / 100
        let baseWindup = percent / max(0.1, spec.baseAttackSpeed)
        let current = percent / max(0.1, attackSpeed)
        let seconds = baseWindup + spec.modifier * (current - baseWindup)
        return max(0, seconds) * 1000 + Double(extraWindupMs)
    }

    /** Champion bar size limits scaled to the captured frame (reference 1920x1080). */
    func detectionConfig(frameWidth: Int, frameHeight: Int) -> DetectionConfig {
        let sx = Double(frameWidth) / 1920
        let sy = Double(frameHeight) / 1080
        let minHeight = max(4, Int(6 * sy))
        return DetectionConfig(minHeight: minHeight,
                               maxHeight: max(10, Int(Double(minHeight) * 2.2)),
                               maxRun: max(40, Int(125 * sx)),
                               barWidth: max(40, Int(100 * sy)),
                               boxWidth: max(10, Int(20 * sx)),
                               minFrameWidth: max(35, Int(70 * sx)),
                               rowStride: max(2, minHeight * 3 / 4))
    }

    func aimKey(for slot: String) -> UInt16 {
        switch slot {
        case "Q": return aim.keyQ
        case "W": return aim.keyW
        case "E": return aim.keyE
        case "R": return aim.keyR
        case "D": return aim.keyD
        default: return aim.keyF
        }
    }

    func aimSlotEnabled(_ slot: String) -> Bool {
        switch slot {
        case "Q": return aim.slotQ
        case "W": return aim.slotW
        case "E": return aim.slotE
        case "R": return aim.slotR
        case "D": return aim.slotD
        default: return aim.slotF
        }
    }

    /** Ability slot bound to a physical key, or nil. */
    func abilitySlot(for keyCode: UInt16) -> String? {
        for slot in ["Q", "W", "E", "R"] where aimKey(for: slot) == keyCode { return slot }
        return nil
    }

    /** Effective targeting of a spell after the user's override; nil when the spell is unknown and not overridden. */
    func aimTargeting(for spec: SpellSpec?) -> SpellTargeting? {
        let override = spec.flatMap { aim.overrides[$0.id.lowercased()] }
        if let override, override.targeting != "auto" { return SpellTargeting(rawValue: override.targeting) }
        return spec?.targetingType
    }

    func aimEnabled(for spec: SpellSpec) -> Bool {
        aim.overrides[spec.id.lowercased()]?.enabled ?? true
    }

    func aimPrediction(for spec: SpellSpec) -> Bool {
        aim.prediction && (aim.overrides[spec.id.lowercased()]?.prediction ?? true)
    }
}

final class Settings: ObservableObject, Codable, @unchecked Sendable {
    @Published var gameBundleID = "com.riotgames.LeagueofLegends.GameClient"
    @Published var captureMode = "window"
    @Published var capturePoints = false
    @Published var captureFps = 120
    @Published var clickOffsetX = 0.0
    @Published var clickOffsetY = 74.0
    @Published var clickHeight = 55.0
    @Published var identifyChampions = true
    @Published var heightFactors: [String: Double] = [:]
    @Published var attackMode = "click"
    @Published var attackMoveKeyCode: UInt16 = 0
    @Published var attackMoveClick = true
    @Published var clickHoldMs = 6
    @Published var clickSettleMs = 8
    @Published var activationKeyCode: UInt16 = 49
    @Published var attackRangeKeyCode: UInt16 = 8
    @Published var panelKeyCode: UInt16 = 54
    @Published var showAttackRange = false
    @Published var drawRange = true
    @Published var rangeColorHex = "#FF9926"
    @Published var rangeRainbow = false
    @Published var spellRanges = SpellRangeStyle.defaults
    @Published var attackChampionOnly = false
    @Published var championOnlyKeyCode: UInt16 = 39
    @Published var championOnlyMiddleMouse = false
    @Published var targetMode = "center"
    @Published var moveClickMinMs = 70
    @Published var moveClickMaxMs = 100
    @Published var defaultWindupPercent = 15.0
    @Published var extraWindupMs = 60
    @Published var attackLatencyMs = 80
    @Published var activationDelayMs = 150
    @Published var attackOnlyInRange = true
    @Published var attackRangeTolerance = 6.0
    @Published var stickyTarget = true
    @Published var holdRadius = 60.0
    @Published var attackResets = true
    @Published var clickJitter = 3.0
    @Published var fleeKeyCode: UInt16 = KeyNames.none
    @Published var helicopterKeyCode: UInt16 = KeyNames.none
    @Published var helicopterIntervalMs = 60
    @Published var helicopterRadius = 70.0
    @Published var emoteOnKill = false
    @Published var emoteKeyCode: UInt16 = 20
    @Published var emoteCtrl = true
    @Published var aim = AimSettings()
    @Published var combos = ComboSettings()
    @Published var layout = LayoutSettings()
    @Published var lastChampion = ""

    private let engineLock = NSLock()
    private var engineSnapshot = EngineSettings()

    /** Thread-safe snapshot for engine threads; refreshed on the main thread after every change. */
    var engine: EngineSettings { engineLock.withLock { engineSnapshot } }

    /** Write-back of a champion's learned in-game height factor (main thread). */
    func learnHeight(champion: String, factor: Double) {
        guard Settings.plausibleHeightFactor(factor, champion: champion), heightFactors[champion] != factor else { return }
        heightFactors[champion] = factor
    }

    /** A learned body between 0.7 and 2.6 of the mesh in the size table; anything outside came from misses that had another cause and is thrown away. */
    static func plausibleHeightFactor(_ factor: Double, champion: String = "") -> Bool {
        factor >= BodyLearner.floorOfPrior && factor <= BodyLearner.ceilingOfPrior * (ChampionModels.measuredScales[champion] ?? 1)
    }

    /** Write-back of what the range ring measured, so the next game starts calibrated (main thread). */
    func learnCalibration(kxRef: Double, barToFeetRef: Double, feetFromCentreYRef: Double) {
        guard kxRef > 0.3, kxRef < 1.3 else { return }
        let kx = (kxRef * 1000).rounded() / 1000
        let feet = max(40, min(200, barToFeetRef.rounded()))
        let centreY = feetFromCentreYRef.rounded()
        guard kx != aim.pxPerUnitX || feet != aim.selfFeetOffsetY || centreY != aim.feetFromCentreY else { return }
        aim.pxPerUnitX = kx
        aim.selfFeetOffsetY = feet
        aim.feetFromCentreY = centreY
    }

    init() {}

    private enum Keys: String, CodingKey {
        case gameBundleID, captureMode, capturePoints, captureFps, clickOffsetX, clickOffsetY, clickHeight, identifyChampions, heightFactors, attackMode, attackMoveKeyCode, attackMoveClick
        case clickHoldMs, clickSettleMs, activationKeyCode, attackRangeKeyCode, panelKeyCode
        case showAttackRange, drawRange, rangeColorHex, rangeRainbow, spellRanges, attackChampionOnly, championOnlyKeyCode, championOnlyMiddleMouse, targetMode
        case moveClickMinMs, moveClickMaxMs, defaultWindupPercent, extraWindupMs, attackLatencyMs, activationDelayMs, aim, lastChampion
        case attackOnlyInRange, attackRangeTolerance, stickyTarget, holdRadius, attackResets, clickJitter, fleeKeyCode
        case helicopterKeyCode, helicopterIntervalMs, helicopterRadius, emoteOnKill, emoteKeyCode, emoteCtrl, combos, layout
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        gameBundleID = try c.decodeIfPresent(String.self, forKey: .gameBundleID) ?? gameBundleID
        captureMode = try c.decodeIfPresent(String.self, forKey: .captureMode) ?? captureMode
        capturePoints = try c.decodeIfPresent(Bool.self, forKey: .capturePoints) ?? capturePoints
        captureFps = try c.decodeIfPresent(Int.self, forKey: .captureFps) ?? captureFps
        clickOffsetX = try c.decodeIfPresent(Double.self, forKey: .clickOffsetX) ?? clickOffsetX
        clickOffsetY = try c.decodeIfPresent(Double.self, forKey: .clickOffsetY) ?? clickOffsetY
        clickHeight = try c.decodeIfPresent(Double.self, forKey: .clickHeight) ?? clickHeight
        identifyChampions = try c.decodeIfPresent(Bool.self, forKey: .identifyChampions) ?? identifyChampions
        heightFactors = (try c.decodeIfPresent([String: Double].self, forKey: .heightFactors) ?? heightFactors).filter { Settings.plausibleHeightFactor($0.value, champion: $0.key) }
        attackMode = try c.decodeIfPresent(String.self, forKey: .attackMode) ?? attackMode
        attackMoveKeyCode = try c.decodeIfPresent(UInt16.self, forKey: .attackMoveKeyCode) ?? attackMoveKeyCode
        attackMoveClick = try c.decodeIfPresent(Bool.self, forKey: .attackMoveClick) ?? attackMoveClick
        clickHoldMs = try c.decodeIfPresent(Int.self, forKey: .clickHoldMs) ?? clickHoldMs
        clickSettleMs = try c.decodeIfPresent(Int.self, forKey: .clickSettleMs) ?? clickSettleMs
        activationKeyCode = try c.decodeIfPresent(UInt16.self, forKey: .activationKeyCode) ?? activationKeyCode
        attackRangeKeyCode = try c.decodeIfPresent(UInt16.self, forKey: .attackRangeKeyCode) ?? attackRangeKeyCode
        panelKeyCode = try c.decodeIfPresent(UInt16.self, forKey: .panelKeyCode) ?? panelKeyCode
        showAttackRange = try c.decodeIfPresent(Bool.self, forKey: .showAttackRange) ?? showAttackRange
        drawRange = try c.decodeIfPresent(Bool.self, forKey: .drawRange) ?? drawRange
        rangeColorHex = try c.decodeIfPresent(String.self, forKey: .rangeColorHex) ?? rangeColorHex
        rangeRainbow = try c.decodeIfPresent(Bool.self, forKey: .rangeRainbow) ?? rangeRainbow
        for (slot, style) in try c.decodeIfPresent([String: SpellRangeStyle].self, forKey: .spellRanges) ?? [:] { spellRanges[slot] = style }
        attackChampionOnly = try c.decodeIfPresent(Bool.self, forKey: .attackChampionOnly) ?? attackChampionOnly
        championOnlyKeyCode = try c.decodeIfPresent(UInt16.self, forKey: .championOnlyKeyCode) ?? championOnlyKeyCode
        championOnlyMiddleMouse = try c.decodeIfPresent(Bool.self, forKey: .championOnlyMiddleMouse) ?? championOnlyMiddleMouse
        targetMode = try c.decodeIfPresent(String.self, forKey: .targetMode) ?? targetMode
        moveClickMinMs = try c.decodeIfPresent(Int.self, forKey: .moveClickMinMs) ?? moveClickMinMs
        moveClickMaxMs = try c.decodeIfPresent(Int.self, forKey: .moveClickMaxMs) ?? moveClickMaxMs
        defaultWindupPercent = try c.decodeIfPresent(Double.self, forKey: .defaultWindupPercent) ?? defaultWindupPercent
        extraWindupMs = try c.decodeIfPresent(Int.self, forKey: .extraWindupMs) ?? extraWindupMs
        attackLatencyMs = try c.decodeIfPresent(Int.self, forKey: .attackLatencyMs) ?? attackLatencyMs
        activationDelayMs = try c.decodeIfPresent(Int.self, forKey: .activationDelayMs) ?? activationDelayMs
        attackOnlyInRange = try c.decodeIfPresent(Bool.self, forKey: .attackOnlyInRange) ?? attackOnlyInRange
        attackRangeTolerance = try c.decodeIfPresent(Double.self, forKey: .attackRangeTolerance) ?? attackRangeTolerance
        stickyTarget = try c.decodeIfPresent(Bool.self, forKey: .stickyTarget) ?? stickyTarget
        holdRadius = try c.decodeIfPresent(Double.self, forKey: .holdRadius) ?? holdRadius
        attackResets = try c.decodeIfPresent(Bool.self, forKey: .attackResets) ?? attackResets
        clickJitter = try c.decodeIfPresent(Double.self, forKey: .clickJitter) ?? clickJitter
        fleeKeyCode = try c.decodeIfPresent(UInt16.self, forKey: .fleeKeyCode) ?? fleeKeyCode
        helicopterKeyCode = try c.decodeIfPresent(UInt16.self, forKey: .helicopterKeyCode) ?? helicopterKeyCode
        helicopterIntervalMs = try c.decodeIfPresent(Int.self, forKey: .helicopterIntervalMs) ?? helicopterIntervalMs
        helicopterRadius = try c.decodeIfPresent(Double.self, forKey: .helicopterRadius) ?? helicopterRadius
        emoteOnKill = try c.decodeIfPresent(Bool.self, forKey: .emoteOnKill) ?? emoteOnKill
        emoteKeyCode = try c.decodeIfPresent(UInt16.self, forKey: .emoteKeyCode) ?? emoteKeyCode
        emoteCtrl = try c.decodeIfPresent(Bool.self, forKey: .emoteCtrl) ?? emoteCtrl
        aim = (try? c.decodeIfPresent(AimSettings.self, forKey: .aim)) ?? aim
        combos = (try? c.decodeIfPresent(ComboSettings.self, forKey: .combos)) ?? combos
        layout = (try? c.decodeIfPresent(LayoutSettings.self, forKey: .layout)) ?? layout
        lastChampion = try c.decodeIfPresent(String.self, forKey: .lastChampion) ?? lastChampion
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(gameBundleID, forKey: .gameBundleID)
        try c.encode(captureMode, forKey: .captureMode)
        try c.encode(capturePoints, forKey: .capturePoints)
        try c.encode(captureFps, forKey: .captureFps)
        try c.encode(clickOffsetX, forKey: .clickOffsetX)
        try c.encode(clickOffsetY, forKey: .clickOffsetY)
        try c.encode(clickHeight, forKey: .clickHeight)
        try c.encode(identifyChampions, forKey: .identifyChampions)
        try c.encode(heightFactors, forKey: .heightFactors)
        try c.encode(attackMode, forKey: .attackMode)
        try c.encode(attackMoveKeyCode, forKey: .attackMoveKeyCode)
        try c.encode(attackMoveClick, forKey: .attackMoveClick)
        try c.encode(clickHoldMs, forKey: .clickHoldMs)
        try c.encode(clickSettleMs, forKey: .clickSettleMs)
        try c.encode(activationKeyCode, forKey: .activationKeyCode)
        try c.encode(attackRangeKeyCode, forKey: .attackRangeKeyCode)
        try c.encode(panelKeyCode, forKey: .panelKeyCode)
        try c.encode(showAttackRange, forKey: .showAttackRange)
        try c.encode(drawRange, forKey: .drawRange)
        try c.encode(rangeColorHex, forKey: .rangeColorHex)
        try c.encode(rangeRainbow, forKey: .rangeRainbow)
        try c.encode(spellRanges, forKey: .spellRanges)
        try c.encode(attackChampionOnly, forKey: .attackChampionOnly)
        try c.encode(championOnlyKeyCode, forKey: .championOnlyKeyCode)
        try c.encode(championOnlyMiddleMouse, forKey: .championOnlyMiddleMouse)
        try c.encode(targetMode, forKey: .targetMode)
        try c.encode(moveClickMinMs, forKey: .moveClickMinMs)
        try c.encode(moveClickMaxMs, forKey: .moveClickMaxMs)
        try c.encode(defaultWindupPercent, forKey: .defaultWindupPercent)
        try c.encode(extraWindupMs, forKey: .extraWindupMs)
        try c.encode(attackLatencyMs, forKey: .attackLatencyMs)
        try c.encode(activationDelayMs, forKey: .activationDelayMs)
        try c.encode(attackOnlyInRange, forKey: .attackOnlyInRange)
        try c.encode(attackRangeTolerance, forKey: .attackRangeTolerance)
        try c.encode(stickyTarget, forKey: .stickyTarget)
        try c.encode(holdRadius, forKey: .holdRadius)
        try c.encode(attackResets, forKey: .attackResets)
        try c.encode(clickJitter, forKey: .clickJitter)
        try c.encode(fleeKeyCode, forKey: .fleeKeyCode)
        try c.encode(helicopterKeyCode, forKey: .helicopterKeyCode)
        try c.encode(helicopterIntervalMs, forKey: .helicopterIntervalMs)
        try c.encode(helicopterRadius, forKey: .helicopterRadius)
        try c.encode(emoteOnKill, forKey: .emoteOnKill)
        try c.encode(emoteKeyCode, forKey: .emoteKeyCode)
        try c.encode(emoteCtrl, forKey: .emoteCtrl)
        try c.encode(aim, forKey: .aim)
        try c.encode(combos, forKey: .combos)
        try c.encode(layout, forKey: .layout)
        try c.encode(lastChampion, forKey: .lastChampion)
    }

    static let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("VoidMac/config.json")
    }()

    static func load() -> Settings {
        var loaded: Settings?
        if let data = try? Data(contentsOf: fileURL) {
            loaded = mergedWithDefaults(data).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) }
            if loaded == nil { Log.warn("config unreadable, starting with defaults: \(fileURL.path)") }
        }
        let s = loaded ?? Settings()
        s.save()
        s.refreshEngine()
        return s
    }

    /** Stored JSON laid over the defaults (old overlay calibration moves into aim), so nested groups survive newly added keys. */
    private static func mergedWithDefaults(_ data: Data) -> Data? {
        guard var stored = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let defaultData = try? JSONEncoder().encode(Settings()),
              let defaults = (try? JSONSerialization.jsonObject(with: defaultData)) as? [String: Any] else { return nil }
        if let overlay = stored["overlay"] as? [String: Any] {
            var aim = (stored["aim"] as? [String: Any]) ?? [:]
            for key in ["pxPerUnitX", "selfFeetOffsetY", "assumeCenter"] where aim[key] == nil {
                if let value = overlay[key] { aim[key] = value }
            }
            stored["aim"] = aim
        }
        return try? JSONSerialization.data(withJSONObject: merge(defaults, stored))
    }

    private static func merge(_ base: [String: Any], _ override: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in override {
            if let baseDict = base[key] as? [String: Any], let dict = value as? [String: Any] {
                result[key] = merge(baseDict, dict)
            } else {
                result[key] = value
            }
        }
        return result
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL)
    }

    func reset() {
        let fresh = Settings()
        guard let data = try? JSONEncoder().encode(fresh), let copy = try? JSONDecoder().decode(Settings.self, from: data) else { return }
        gameBundleID = copy.gameBundleID
        captureMode = copy.captureMode
        capturePoints = copy.capturePoints
        captureFps = copy.captureFps
        clickOffsetX = copy.clickOffsetX
        clickOffsetY = copy.clickOffsetY
        clickHeight = copy.clickHeight
        identifyChampions = copy.identifyChampions
        heightFactors = copy.heightFactors
        attackMode = copy.attackMode
        attackMoveKeyCode = copy.attackMoveKeyCode
        attackMoveClick = copy.attackMoveClick
        clickHoldMs = copy.clickHoldMs
        clickSettleMs = copy.clickSettleMs
        activationKeyCode = copy.activationKeyCode
        attackRangeKeyCode = copy.attackRangeKeyCode
        panelKeyCode = copy.panelKeyCode
        showAttackRange = copy.showAttackRange
        drawRange = copy.drawRange
        rangeColorHex = copy.rangeColorHex
        rangeRainbow = copy.rangeRainbow
        spellRanges = copy.spellRanges
        attackChampionOnly = copy.attackChampionOnly
        championOnlyKeyCode = copy.championOnlyKeyCode
        championOnlyMiddleMouse = copy.championOnlyMiddleMouse
        targetMode = copy.targetMode
        moveClickMinMs = copy.moveClickMinMs
        moveClickMaxMs = copy.moveClickMaxMs
        defaultWindupPercent = copy.defaultWindupPercent
        extraWindupMs = copy.extraWindupMs
        attackLatencyMs = copy.attackLatencyMs
        activationDelayMs = copy.activationDelayMs
        attackOnlyInRange = copy.attackOnlyInRange
        attackRangeTolerance = copy.attackRangeTolerance
        stickyTarget = copy.stickyTarget
        holdRadius = copy.holdRadius
        attackResets = copy.attackResets
        clickJitter = copy.clickJitter
        fleeKeyCode = copy.fleeKeyCode
        helicopterKeyCode = copy.helicopterKeyCode
        helicopterIntervalMs = copy.helicopterIntervalMs
        helicopterRadius = copy.helicopterRadius
        emoteOnKill = copy.emoteOnKill
        emoteKeyCode = copy.emoteKeyCode
        emoteCtrl = copy.emoteCtrl
        aim = copy.aim
        combos = copy.combos
        layout = copy.layout
        refreshEngine()
    }

    /** Rebuilds the engine snapshot from the current values; call on the main thread after changes. */
    func refreshEngine() {
        var e = EngineSettings()
        e.gameBundleID = gameBundleID
        e.captureMode = captureMode
        e.capturePoints = capturePoints
        e.captureFps = captureFps
        e.clickOffsetX = clickOffsetX
        e.clickOffsetY = clickOffsetY
        e.clickHeight = clickHeight
        e.identifyChampions = identifyChampions
        e.heightFactors = heightFactors
        e.attackMode = attackMode
        e.attackMoveKeyCode = attackMoveKeyCode
        e.attackMoveClick = attackMoveClick
        e.clickHoldMs = clickHoldMs
        e.clickSettleMs = clickSettleMs
        e.activationKeyCode = activationKeyCode
        e.attackRangeKeyCode = attackRangeKeyCode
        e.panelKeyCode = panelKeyCode
        e.showAttackRange = showAttackRange
        e.drawRange = drawRange
        e.attackChampionOnly = attackChampionOnly
        e.championOnlyKeyCode = championOnlyKeyCode
        e.championOnlyMiddleMouse = championOnlyMiddleMouse
        e.targetMode = targetMode
        e.moveClickMinMs = moveClickMinMs
        e.moveClickMaxMs = moveClickMaxMs
        e.defaultWindupPercent = defaultWindupPercent
        e.extraWindupMs = extraWindupMs
        e.attackLatencyMs = attackLatencyMs
        e.activationDelayMs = activationDelayMs
        e.attackOnlyInRange = attackOnlyInRange
        e.attackRangeTolerance = attackRangeTolerance
        e.stickyTarget = stickyTarget
        e.holdRadius = holdRadius
        e.attackResets = attackResets
        e.clickJitter = clickJitter
        e.fleeKeyCode = fleeKeyCode
        e.helicopterKeyCode = helicopterKeyCode
        e.helicopterIntervalMs = helicopterIntervalMs
        e.helicopterRadius = helicopterRadius
        e.emoteOnKill = emoteOnKill
        e.emoteKeyCode = emoteKeyCode
        e.emoteCtrl = emoteCtrl
        e.aim = aim
        e.combos = combos
        engineLock.withLock { engineSnapshot = e }
    }

    static func normalize(_ name: String) -> String {
        String(name.lowercased().filter { $0.isLetter })
    }
}
