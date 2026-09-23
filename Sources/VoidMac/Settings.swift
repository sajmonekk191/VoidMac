import Combine
import Foundation

/** A choice stored as its raw string; a string this build does not know (an older or hand-edited file) decodes to `fallback` instead of failing the whole file. */
protocol SettingChoice: RawRepresentable, Codable, CaseIterable, Hashable where RawValue == String {
    static var fallback: Self { get }
}

extension SettingChoice {
    init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .fallback
    }
}

/** How the orbwalker delivers an attack: the cursor jumps onto the target, or the attack-move key fires at the cursor. */
enum AttackMode: String, SettingChoice {
    case click
    case attackMove = "attackmove"

    static let fallback = AttackMode.click
}

/** Which enemy in reach the orbwalker attacks; `priority` follows the user's champion order. */
enum TargetMode: String, SettingChoice {
    case center, lowest, cursor, priority

    static let fallback = TargetMode.center
}

/** Which enemy the autoaim picks; `priority` follows the user's champion order. */
enum AimTargetMode: String, SettingChoice {
    case cursor, nearest, lowest, priority

    static let fallback = AimTargetMode.cursor
}

/** Last hitting: the key that farms (kites to the cursor and gives minions only the killing blow), farming from the orbwalker while no champion is in reach, reading the game's Last Hit Assist, the share of our damage held back and the marker over killable minions. */
struct LastHitSettings: Codable, Equatable {
    var keyCode: UInt16 = 7
    var whileOrbwalking = false
    var useGameAssist = true
    var marginPercent = 4.0
    var drawKillable = true
    var showRange = false
}

/** Auto Heal/Barrier: cast when health falls to the threshold, optionally only while it is being lost. */
struct DefenseSettings: Codable, Equatable {
    var autoSummoner = true
    var healthPercent = 20.0
    var onlyWhenDamaged = true
}

/** How a spell key reaches the game: quick cast, or the key and then a left click. */
enum CastMode: String, SettingChoice {
    case quick, normal

    static let fallback = CastMode.quick
}

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
    var castMode = CastMode.quick
    var targetMode = AimTargetMode.cursor
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

/** Every persisted setting as one value, the single source of truth: the UI edits it through `Settings`, engine threads read a snapshot of it. */
struct EngineSettings: Codable, Equatable {
    var gameBundleID = "com.riotgames.LeagueofLegends.GameClient"
    var captureMode = CaptureMode.window
    var capturePoints = false
    var captureFps = 120
    var clickOffsetX = 0.0
    var clickOffsetY = 74.0
    var clickHeight = 55.0
    var identifyChampions = true
    var heightFactors: [String: Double] = [:]
    var attackMode = AttackMode.click
    var attackMoveKeyCode: UInt16 = 0
    var attackMoveClick = true
    var clickHoldMs = 6
    var clickSettleMs = 8
    var activationKeyCode: UInt16 = 49
    var attackRangeKeyCode: UInt16 = 8
    var panelKeyCode: UInt16 = 54
    var showAttackRange = false
    var drawRange = true
    var rangeColorHex = "#FF9926"
    var rangeRainbow = false
    var spellRanges = SpellRangeStyle.defaults
    var attackChampionOnly = false
    var championOnlyKeyCode: UInt16 = 39
    var championOnlyMiddleMouse = false
    var targetMode = TargetMode.center
    /** Champion keys in the order they are attacked, most wanted first; champions not listed follow by class. */
    var targetPriority: [String] = []
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
    var waveclearKeyCode: UInt16 = 9
    var waveclearShowRange = false
    var helicopterKeyCode: UInt16 = KeyNames.none
    var helicopterIntervalMs = 60
    var helicopterRadius = 70.0
    var emoteOnKill = false
    var emoteKeyCode: UInt16 = 20
    var emoteCtrl = true
    var aim = AimSettings()
    var combos = ComboSettings()
    var lastHit = LastHitSettings()
    var defense = DefenseSettings()
    var layout = LayoutSettings()
    var lastChampion = ""

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

/** The settings store: `settings.x` reads and writes `values.x`, engine threads read the `engine` snapshot, which every change refreshes synchronously. */
@dynamicMemberLookup
final class Settings: ObservableObject, @unchecked Sendable {
    @Published var values: EngineSettings {
        didSet { engineLock.withLock { engineSnapshot = values } }
    }

    private let engineLock = NSLock()
    private var engineSnapshot: EngineSettings

    init(values: EngineSettings = EngineSettings()) {
        self.values = values
        engineSnapshot = values
    }

    subscript<Value>(dynamicMember keyPath: WritableKeyPath<EngineSettings, Value>) -> Value {
        get { values[keyPath: keyPath] }
        set { values[keyPath: keyPath] = newValue }
    }

    /** Thread-safe snapshot for engine threads. */
    var engine: EngineSettings { engineLock.withLock { engineSnapshot } }

    /** Write-back of a champion's learned in-game height factor (main thread). */
    func learnHeight(champion: String, factor: Double) {
        guard Settings.plausibleHeightFactor(factor, champion: champion), values.heightFactors[champion] != factor else { return }
        values.heightFactors[champion] = factor
    }

    /** A learned body between 0.7 and 2.6 of the mesh in the size table; anything outside came from misses that had another cause and is thrown away. */
    static func plausibleHeightFactor(_ factor: Double, champion: String = "") -> Bool {
        factor >= BodyLearner.floorOfPrior && factor <= BodyLearner.ceilingOfPrior * (ChampionModels.measuredScales[champion] ?? 1)
    }

    /** Write-back of what the range ring measured, so the next game starts calibrated (main thread). */
    func learnCalibration(kxRef: Double, barToFeetRef: Double, feetFromCentreYRef: Double) {
        guard kxRef > 0.3, kxRef < 1.3 else { return }
        var aim = values.aim
        aim.pxPerUnitX = (kxRef * 1000).rounded() / 1000
        aim.selfFeetOffsetY = max(40, min(200, barToFeetRef.rounded()))
        aim.feetFromCentreY = feetFromCentreYRef.rounded()
        guard aim != values.aim else { return }
        values.aim = aim
    }

    /** Back to the defaults, keeping only the champion last picked out of game. */
    func reset() {
        var fresh = EngineSettings()
        fresh.lastChampion = values.lastChampion
        values = fresh
    }

    static let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("VoidMac/config.json")
    }()

    static func load() -> Settings {
        var loaded: EngineSettings?
        if let data = try? Data(contentsOf: fileURL) {
            loaded = decode(data)
            if loaded == nil { Log.warn("config unreadable, starting with defaults: \(fileURL.path)") }
        }
        let settings = Settings(values: loaded ?? EngineSettings())
        settings.save()
        return settings
    }

    /** A stored config laid over the defaults: missing keys and nulls take their default, a nested group that no longer decodes falls back to its defaults as a whole, the old `overlay` calibration moves into `aim`, and implausible learned heights are dropped; nil when the file does not decode at all. */
    static func decode(_ data: Data) -> EngineSettings? {
        guard var stored = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let defaultData = try? JSONEncoder().encode(EngineSettings()),
              let defaults = (try? JSONSerialization.jsonObject(with: defaultData)) as? [String: Any] else { return nil }
        if let overlay = stored["overlay"] as? [String: Any] {
            var aim = (stored["aim"] as? [String: Any]) ?? [:]
            for key in ["pxPerUnitX", "selfFeetOffsetY", "assumeCenter"] where aim[key] == nil {
                if let value = overlay[key] { aim[key] = value }
            }
            stored["aim"] = aim
        }
        var merged = merge(defaults, withoutNulls(stored))
        let groups: [(key: String, type: any Decodable.Type)] = [("aim", AimSettings.self), ("combos", ComboSettings.self), ("lastHit", LastHitSettings.self),
                                                                 ("defense", DefenseSettings.self), ("layout", LayoutSettings.self)]
        for group in groups where !decodes(merged[group.key], as: group.type) { merged[group.key] = defaults[group.key] }
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged), var values = try? JSONDecoder().decode(EngineSettings.self, from: mergedData) else { return nil }
        values.heightFactors = values.heightFactors.filter { plausibleHeightFactor($0.value, champion: $0.key) }
        return values
    }

    private static func decodes(_ value: Any?, as type: any Decodable.Type) -> Bool {
        guard let value, JSONSerialization.isValidJSONObject([value]), let data = try? JSONSerialization.data(withJSONObject: [value]) else { return false }
        func attempt<T: Decodable>(_: T.Type) -> Bool { (try? JSONDecoder().decode([T].self, from: data)) != nil }
        return attempt(type)
    }

    private static func withoutNulls(_ dictionary: [String: Any]) -> [String: Any] {
        dictionary.compactMapValues { value in
            if value is NSNull { return nil }
            if let nested = value as? [String: Any] { return withoutNulls(nested) }
            return value
        }
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
        guard let data = try? encoder.encode(values) else { return }
        try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    /** Table key of a champion name in any Riot spelling: its letters, lowercased; ASCII names skip the Unicode path, which gives them the same result six times slower. */
    static func normalize(_ name: String) -> String {
        var letters: [UInt8] = []
        letters.reserveCapacity(name.utf8.count)
        for byte in name.utf8 {
            guard byte < 0x80 else { return String(name.lowercased().filter { $0.isLetter }) }
            if byte >= 0x61 && byte <= 0x7A { letters.append(byte) } else if byte >= 0x41 && byte <= 0x5A { letters.append(byte | 0x20) }
        }
        return String(decoding: letters, as: UTF8.self)
    }
}
