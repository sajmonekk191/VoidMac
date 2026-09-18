import CoreGraphics
import Foundation

struct AimPlan {
    let slot: String
    let keyCode: UInt16
    let spec: SpellSpec?
    let targeting: SpellTargeting
    let point: CGPoint
    var secondPoint: CGPoint?
    let targetPx: CGPoint
    let predictedPx: CGPoint
    let enemyID: Int
    let predictedMs: Double
    let distanceUnits: Double
    let castMode: String
    let createdMs: Double
}

struct AimStatus: Equatable {
    var lastSlot = ""
    var lastMs = 0.0
    var lastText = ""
    var casts = 0
    var passThroughs = 0
    var lastPassThrough = ""
}

/** Decides inside the event tap whether a spell key is aimed, and builds the cast plan from the vision tracks. */
final class Autoaim: @unchecked Sendable {
    let settings: Settings
    let live: LiveClient
    let game: GameSession
    let vision: Vision
    private let lock = NSLock()
    private var pending: AimPlan?
    private var swallowed = Set<UInt16>()
    private var keyStateFalseSince: [UInt16: Double] = [:]
    private var statusStorage = AimStatus()
    private var lastPassThroughLogMs = 0.0
    var canAim: () -> Bool = { false }

    init(settings: Settings, live: LiveClient, game: GameSession, vision: Vision) {
        self.settings = settings
        self.live = live
        self.game = game
        self.vision = vision
    }

    var status: AimStatus { lock.withLock { statusStorage } }

    /** Tap-thread decision: swallow the physical key when a plan could be made, otherwise let the game have it. */
    func intercept(keyCode: UInt16, down: Bool, isRepeat: Bool) -> Bool {
        let cfg = settings.engine
        guard cfg.aim.enabled, let slot = slot(for: keyCode, cfg: cfg) else { return false }
        if !down { return lock.withLock { swallowed.remove(keyCode) != nil } }
        if isRepeat { return lock.withLock { swallowed.contains(keyCode) } }
        guard canAim() else { return false }
        if cfg.aim.onlyWhileActivation && !Input.isKeyDown(cfg.activationKeyCode) { return false }
        var reason = ""
        guard let plan = makePlan(slot: slot, keyCode: keyCode, cfg: cfg, reason: &reason) else {
            passThrough(slot: slot, reason: reason)
            return false
        }
        lock.withLock {
            pending = plan
            swallowed.insert(keyCode)
            keyStateFalseSince[keyCode] = nil
        }
        return true
    }

    /** True while the swallowed spell key is still physically held (tap state, with the HID key state as a 150 ms safety net). */
    func isPhysicallyHeld(_ keyCode: UInt16) -> Bool {
        let raw = CGEventSource.keyState(.hidSystemState, key: CGKeyCode(keyCode))
        let now = nowMs()
        return lock.withLock {
            guard swallowed.contains(keyCode) else { return false }
            if raw {
                keyStateFalseSince[keyCode] = nil
                return true
            }
            if keyStateFalseSince[keyCode] == nil { keyStateFalseSince[keyCode] = now }
            if now - keyStateFalseSince[keyCode]! > 150 {
                swallowed.remove(keyCode)
                return false
            }
            return true
        }
    }

    func takePending() -> AimPlan? {
        lock.withLock {
            let plan = pending
            pending = nil
            return plan
        }
    }

    func record(slot: String, text: String) {
        lock.withLock {
            statusStorage.lastSlot = slot
            statusStorage.lastMs = nowMs()
            statusStorage.lastText = text
            statusStorage.casts += 1
        }
    }

    private func passThrough(slot: String, reason: String) {
        let now = nowMs()
        let shouldLog: Bool = lock.withLock {
            statusStorage.passThroughs += 1
            statusStorage.lastPassThrough = "\(slot): \(reason)"
            let log = now - lastPassThroughLogMs > 500
            if log { lastPassThroughLogMs = now }
            return log
        }
        if shouldLog { Log.info("aim \(slot) passed to the game: \(reason)") }
    }

    private func slot(for keyCode: UInt16, cfg: EngineSettings) -> String? {
        for slot in ["Q", "W", "E", "R", "D", "F"] where cfg.aimKey(for: slot) == keyCode && cfg.aimSlotEnabled(slot) { return slot }
        return nil
    }

    /** Targeted summoner spells on D/F become unit-targeted specs; everything else on those keys passes through. */
    static func summonerSpec(_ name: String, slot: String) -> SpellSpec? {
        let lower = name.lowercased()
        let range: Double
        if lower.contains("ignite") { range = 600 } else if lower.contains("exhaust") { range = 650 } else { return nil }
        return SpellSpec(id: "summoner\(slot)\(lower)", champion: "", championName: "", slot: slot, name: name, image: lower.contains("ignite") ? "SummonerDot.png" : "SummonerExhaust.png",
                         cooldown: [], cost: [], maxRank: 1, ddRange: [range], targeting: "unit", range: range, width: 0, radius: 0, coneAngle: 0, speed: 0, castTime: 0, castLock: 0)
    }

    func makePlan(slot: String, keyCode: UInt16, cfg: EngineSettings, lockedEnemyID: Int? = nil, reason: inout String) -> AimPlan? {
        let snap = live.snapshot
        let spec: SpellSpec?
        if slot == "D" || slot == "F" {
            let name = snap.summoners.count == 2 ? snap.summoners[slot == "D" ? 0 : 1] : ""
            spec = Self.summonerSpec(name, slot: slot)
            if spec == nil {
                reason = "summoner \(name.isEmpty ? "?" : name) is not targeted"
                return nil
            }
        } else {
            spec = Spells.resolve(abilityID: snap.abilities[slot]?.id ?? "", champion: snap.championName, slot: slot)
        }
        guard let targeting = cfg.aimTargeting(for: spec), targeting.aimable || targeting == .vector else {
            reason = "spell \(spec?.name ?? snap.abilities[slot]?.id ?? "?") is not aimed (\((spec.map { cfg.aimTargeting(for: $0) } ?? nil)?.label ?? "unknown type"))"
            return nil
        }
        if let spec, !cfg.aimEnabled(for: spec) {
            reason = "aiming is off for \(spec.name)"
            return nil
        }
        let vis = vision.latest
        let now = nowMs()
        guard vis.frameWidth > 0, vis.frameHeight > 0, now - vis.atMs < 150, let projection = vis.projection else {
            reason = "vision has no fresh frame"
            return nil
        }
        let windowFrame = vis.windowFrame.width > 0 ? vis.windowFrame : game.capture.windowFrame
        guard windowFrame.width > 0 else {
            reason = "game window has no size"
            return nil
        }
        let pxToPtX = windowFrame.width / Double(vis.frameWidth)
        let pxToPtY = windowFrame.height / Double(vis.frameHeight)
        let sx = Double(vis.frameWidth) / 1920
        let fresh = vis.enemies.filter { now - $0.lastSeenMs < 120 }
        guard !fresh.isEmpty else {
            reason = "no enemy champion in view"
            return nil
        }
        let selfPoint = vis.selfPoint(cfg: cfg)
        let anchor = selfPoint ?? CGPoint(x: Double(vis.frameWidth) / 2, y: Double(vis.frameHeight) / 2)
        let cursor = Input.mousePosition()
        let cursorPx = CGPoint(x: (cursor.x - windowFrame.minX) / pxToPtX, y: (cursor.y - windowFrame.minY) / pxToPtY)
        func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
        func units(_ a: CGPoint, _ b: CGPoint) -> Double { projection.units(a, b) }
        let nearestToSelf = fresh.min { distance(vis.targetPoint($0, cfg: cfg), anchor) < distance(vis.targetPoint($1, cfg: cfg), anchor) }
        var chosen: EnemyTrack?
        if let lockedEnemyID, let locked = fresh.first(where: { $0.id == lockedEnemyID }) {
            chosen = locked
        } else {
            switch cfg.aim.targetMode {
            case "lowest":
                chosen = fresh.min { $0.fillRatio < $1.fillRatio }
            case "nearest":
                chosen = nearestToSelf
            default:
                let nearCursor = fresh.min { distance(vis.targetPoint($0, cfg: cfg), cursorPx) < distance(vis.targetPoint($1, cfg: cfg), cursorPx) }
                if let nearCursor, distance(vis.targetPoint(nearCursor, cfg: cfg), cursorPx) <= cfg.aim.cursorRadius * sx {
                    chosen = nearCursor
                } else {
                    chosen = nearestToSelf
                }
            }
        }
        guard let enemy = chosen else {
            reason = "could not pick a target"
            return nil
        }
        let targetPx = vis.targetPoint(enemy, cfg: cfg)
        var distanceUnits = selfPoint.map { units(targetPx, $0) } ?? 0
        if let spec, spec.range > 0, !spec.isGlobal, cfg.aim.requireInRange, selfPoint != nil,
           distanceUnits > spec.range * (1 + cfg.aim.rangeTolerance / 100) {
            reason = "target \(Int(distanceUnits)) units away, \(spec.name) range is \(Int(spec.range))"
            return nil
        }
        var predicted = targetPx
        var predictedMs = 0.0
        var velocity = vis.worldVelocity(enemy)
        if let spec, cfg.aimPrediction(for: spec), targeting != .unit, enemy.sightings >= 5, enemy.trackedMs >= 80 {
            let speed = hypot(velocity.x, velocity.y)
            let cap = 0.5 * sx
            if speed > cap {
                velocity.x *= cap / speed
                velocity.y *= cap / speed
            }
            if speed >= 0.08 * sx {
                let factor = cfg.aim.predictionFactor * (0.5 + 0.5 * enemy.confidence)
                for _ in 0..<2 {
                    let travelMs = spec.speed > 0 ? distanceUnits / spec.speed * 1000 : 0
                    predictedMs = min(1500, (spec.castTime * 1000 + travelMs + Double(cfg.aim.settleMs)) * factor)
                    predicted = CGPoint(x: targetPx.x + velocity.x * predictedMs, y: targetPx.y + velocity.y * predictedMs)
                    if let selfPoint { distanceUnits = units(predicted, selfPoint) }
                }
                predicted.x = max(0, min(Double(vis.frameWidth - 1), predicted.x))
                predicted.y = max(0, min(Double(vis.frameHeight - 1), predicted.y))
            }
        }
        let point = CGPoint(x: windowFrame.minX + predicted.x * pxToPtX, y: windowFrame.minY + predicted.y * pxToPtY)
        var plan = AimPlan(slot: slot, keyCode: keyCode, spec: spec, targeting: targeting, point: point, targetPx: targetPx, predictedPx: predicted,
                           enemyID: enemy.id, predictedMs: predictedMs, distanceUnits: distanceUnits, castMode: cfg.aim.castMode, createdMs: now)
        if targeting == .vector {
            let speed = hypot(velocity.x, velocity.y)
            var dir = speed >= 0.08 * sx ? CGPoint(x: velocity.x / speed, y: velocity.y / speed) : CGPoint(x: -(targetPx.y - anchor.y), y: targetPx.x - anchor.x)
            let length = hypot(dir.x, dir.y)
            if length > 0 { dir = CGPoint(x: dir.x / length, y: dir.y / length) }
            let half = cfg.aim.vectorLength / 2
            let g0 = projection.ground(predicted), g1 = projection.ground(CGPoint(x: predicted.x + dir.x * 100, y: predicted.y + dir.y * 100))
            let groundLength = max(1e-6, hypot(g1.x - g0.x, g1.y - g0.y))
            let ux = (g1.x - g0.x) / groundLength, uz = (g1.y - g0.y) / groundLength
            let a = projection.offset(predicted, unitX: -ux * half, unitZ: -uz * half)
            let b = projection.offset(predicted, unitX: ux * half, unitZ: uz * half)
            plan = AimPlan(slot: slot, keyCode: keyCode, spec: spec, targeting: targeting,
                           point: CGPoint(x: windowFrame.minX + a.x * pxToPtX, y: windowFrame.minY + a.y * pxToPtY),
                           secondPoint: CGPoint(x: windowFrame.minX + b.x * pxToPtX, y: windowFrame.minY + b.y * pxToPtY),
                           targetPx: targetPx, predictedPx: predicted, enemyID: enemy.id, predictedMs: predictedMs, distanceUnits: distanceUnits,
                           castMode: cfg.aim.castMode, createdMs: now)
        }
        return plan
    }
}
