import CoreGraphics
import Foundation

struct TrackSample: Equatable {
    var t: Double
    var x: Double
    var y: Double
}

struct EnemyTrack: Identifiable, Equatable {
    let id: Int
    var x: Double
    var y: Double
    var width: Int
    var height: Int
    var fill: Int
    var vx = 0.0
    var vy = 0.0
    var stepSpeed = 0.0
    var confidence = 0.0
    var sightings = 1
    var firstSeenMs: Double
    var lastSeenMs: Double
    /** True once the bar was seen with health in it; a box that never fills is a stack counter or another HUD mark, not a unit. */
    var everFilled = false
    var history: [TrackSample] = []
    /** Size-table key of the recognised champion ("" until the name above the bar is read). */
    var champion = ""
    var level = 0
    var identity = ""

    var centerX: Double { x + Double(width) / 2 }
    var fillRatio: Double { width > 0 ? min(1, Double(fill) / Double(width)) : 0 }
    var trackedMs: Double { (history.last?.t ?? lastSeenMs) - (history.first?.t ?? lastSeenMs) }
}

struct VisionSnapshot: Equatable {
    var enemies: [EnemyTrack] = []
    var selfBar: PixelHit?
    var selfSeenMs = -1e9
    var frameWidth = 0
    var frameHeight = 0
    /** The window rect these pixels were captured from, so a click is never converted through a newer one. */
    var windowFrame = CGRect.zero
    var atMs = 0.0
    var frameMs = 0.0
    var scanMicros = 0.0
    var groundVx = 0.0
    var groundVy = 0.0
    var flowPatches = 0
    var flowMs = -1e9
    var motionMs = -1e9
    var cameraLocked = true
    var abilityReady: [String: Bool] = [:]
    var hudText = ""
    var projection: GroundProjection?
    var rangeText = ""

    /** Own champion's feet in frame px: from the range ring when fresh, else the own bar plus the learned bar-to-feet distance, else the screen centre when allowed. */
    func selfPoint(cfg: EngineSettings) -> CGPoint? {
        let sx = Double(frameWidth) / 1920, sy = Double(frameHeight) / 1080
        if let projection, projection.feetFresh { return projection.feet }
        if let bar = selfBar, atMs - selfSeenMs < 1000 {
            return CGPoint(x: Double(bar.x) + Double(bar.width) * 0.4 + cfg.clickOffsetX * sx, y: Double(bar.y) + (projection?.barToFeet ?? cfg.aim.selfFeetOffsetY * sy))
        }
        guard cfg.aim.assumeCenter, frameWidth > 0 else { return nil }
        if let rest = projection?.feetFromCentre { return CGPoint(x: Double(frameWidth) / 2 + rest.x, y: Double(frameHeight) / 2 + rest.y) }
        return CGPoint(x: Double(frameWidth) / 2, y: Double(frameHeight) / 2 + 40 * sy)
    }

    /** Size-table entry of a track's recognised champion, the default body when the table does not know it, nil only for an unidentified unit. */
    func model(_ enemy: EnemyTrack) -> ChampionModel? {
        guard !enemy.champion.isEmpty else { return nil }
        return ChampionModels.table[enemy.champion] ?? ChampionModels.fallback
    }

    /** In-game height of a tracked enemy in units: the table's mesh height scaled by the measured or learned factor for that champion. */
    func height(_ enemy: EnemyTrack, cfg: EngineSettings) -> Double {
        guard let model = model(enemy) else { return ChampionModels.fallback.meshHeight }
        if let learned = cfg.heightFactors[enemy.champion] { return model.meshHeight * learned }
        return model.gameHeight
    }

    /** Ground point of a tracked enemy in frame px: its bar top, the bar-to-head offset and the projected height of its champion (`height` overrides the table, a Lucian-sized unit when unknown). */
    func feetPoint(_ enemy: EnemyTrack, cfg: EngineSettings, height: Double? = nil) -> CGPoint {
        let sx = Double(frameWidth) / 1920
        let barTop = CGPoint(x: enemy.x + Double(enemy.width) * 0.4 + cfg.clickOffsetX * sx, y: enemy.y)
        guard let projection else { return targetPoint(enemy, cfg: cfg) }
        return projection.feet(barTop: barTop, meshHeight: height ?? self.height(enemy, cfg: cfg))
    }

    /** Where to click a tracked enemy, in frame px: the model stands 0.4 of the bar width from the fill start; a recognised champion is clicked `depth` units below its head (default: the chest by `clickHeight`), an unknown unit a fixed distance below its bar top. */
    func targetPoint(_ enemy: EnemyTrack, cfg: EngineSettings, height: Double? = nil, depth: Double? = nil) -> CGPoint {
        let sx = Double(frameWidth) / 1920, sy = Double(frameHeight) / 1080
        let x = enemy.x + Double(enemy.width) * 0.4 + cfg.clickOffsetX * sx
        if let projection, model(enemy) != nil {
            let tall = height ?? self.height(enemy, cfg: cfg)
            let below = depth ?? tall * (1 - cfg.clickHeight / 100)
            let feet = projection.feet(barTop: CGPoint(x: x, y: enemy.y), meshHeight: tall)
            return CGPoint(x: x, y: feet.y - projection.rise(max(0, tall - below), at: feet))
        }
        return CGPoint(x: x, y: enemy.y + cfg.clickOffsetY * sy)
    }

    /** Enemy velocity in the world, on screen px/ms: its screen velocity minus the motion of the ground (camera). */
    func worldVelocity(_ enemy: EnemyTrack) -> CGPoint {
        CGPoint(x: enemy.vx - groundVx, y: enemy.vy - groundVy)
    }
}
