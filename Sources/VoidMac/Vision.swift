import CoreGraphics
import Foundation

struct FlowPatch {
    var x: Int
    var y: Int
    var size: Int
    var step: Int
    var data: [UInt8]
    var deviation: Int

    var textured: Bool { deviation >= 2 }
}

/** Scans every captured frame once and tracks enemy bars, the own bar and the camera motion for the orbwalker and the autoaim. */
final class Vision: @unchecked Sendable {
    let game: GameSession
    let settings: Settings
    private let fresh = NSCondition()
    private let lock = NSLock()
    private var snapshot = VisionSnapshot()
    private var tracks: [EnemyTrack] = []
    private var unknownChampions: Set<String> = []
    private var nextID = 1
    private var lastScannedFrameMs = 0.0
    private var flowPrevious: [FlowPatch] = []
    private var flowPreviousMs = 0.0
    private var groundPath: [TrackSample] = []
    private var groundX = 0.0
    private var groundY = 0.0
    private var selfBar: PixelHit?
    private var selfSeenMs = -1e9
    private var flowMs = -1e9
    private var motionMs = -1e9
    private var recordName: String?
    private var trackingResumeMs = 0.0
    private var ring: RangeRing?
    private var lastRingTryMs = -1e9
    private var lastFrameSize = (width: 0, height: 0)
    private var lastKx = 0.0
    private var ringFeet: CGPoint?
    private var barToFeet = 0.0
    private var feetFromCentre: CGPoint?
    private var lastRangeLogMs = -1e9
    private var lastLearnMs = -1e9
    /** Attack range from the Live Client: the ring is drawn at attack range plus the champion's gameplay radius. */
    var attackRange: () -> Double = { 0 }
    /** Calibration write-back: px per unit at 1920 wide, bar-to-feet and feet below the screen centre at 1080 high. */
    var learned: (Double, Double, Double) -> Void = { _, _, _ in }
    let hud = AbilityHud()
    let names = NameReader()
    /** Enemy champions in the match from the Live Client; none means the practice tool, whose bars all belong to target dummies. */
    var enemyPlayers: () -> [EnemyPlayer] = { [] }
    var ownChampion: () -> String = { "" }
    var gameTime: () -> Double = { 0 }
    var isWanted: () -> Bool = { false }
    /** The orbwalker asks for ground motion while it kites, so it can see the champion stop for an attack windup. */
    var motionWanted: () -> Bool = { false }
    /** Current champion and its Q/W/E/R icon files, so the HUD reader knows what to look for. */
    var abilityIcons: () -> (champion: String, files: [String: String]) = { ("", [:]) }

    init(game: GameSession, settings: Settings) {
        self.game = game
        self.settings = settings
    }

    var latest: VisionSnapshot { fresh.withLock { snapshot } }

    /** The first snapshot newer than `after`, or the current one when none arrives within maxMs. */
    func waitForFresh(after stamp: Double, maxMs: Int) -> VisionSnapshot {
        let deadline = Date(timeIntervalSinceNow: Double(maxMs) / 1000)
        fresh.lock()
        defer { fresh.unlock() }
        while snapshot.atMs <= stamp, fresh.wait(until: deadline) {}
        return snapshot
    }

    /** Saves the next scanned frame as `<name>.png` for offline tuning, off the hot threads. */
    func requestRecord(_ name: String) {
        lock.withLock { recordName = name }
    }

    /** Drops the enemy tracks and the ground flow for frames captured before `ms`: the camera is moving, so nothing seen until then is where it was. */
    func suspendTracking(until ms: Double) {
        lock.withLock { trackingResumeMs = ms }
    }

    func start() {
        let thread = Thread {
            makeCurrentThreadRealtime(periodMs: 8, computationMs: 3)
            self.loop()
        }
        thread.name = "vision"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func loop() {
        while true {
            guard isWanted(), game.capture.isRunning else {
                fresh.withLock {
                    if !snapshot.enemies.isEmpty || snapshot.selfBar != nil { snapshot = VisionSnapshot() }
                }
                tracks = []
                flowPrevious = []
                groundPath = []
                selfBar = nil
                sleepMs(40)
                continue
            }
            guard game.capture.waitForFrame(after: lastScannedFrameMs, timeoutMs: 200) else { continue }
            lastScannedFrameMs = game.capture.lastFrameAtMs
            scan(frameMs: lastScannedFrameMs)
        }
    }

    private func scan(frameMs: Double) {
        let cfg = settings.engine
        let started = DispatchTime.now().uptimeNanoseconds
        let now = nowMs()
        let (record, suspended): (String?, Bool) = lock.withLock {
            let name = recordName
            recordName = nil
            return (name, frameMs < trackingResumeMs)
        }
        let icons = abilityIcons()
        let attackRange = attackRange()
        let enemies = enemyPlayers()
        var crop: (hit: PixelHit, job: (image: CGImage, fillX: Double, fillY: Double))?
        let comboSlots = cfg.combos.enabled ? cfg.combo(for: icons.champion).steps.filter { $0.enabled }.map { $0.slot } : []
        let result: (scan: ScanResult, width: Int, height: Int, flow: (dx: Double, dy: Double, patches: Int)?, ready: [String: Bool], ring: RangeRing?)? = game.capture.withLatestFrame { frame in
            let config = cfg.detectionConfig(frameWidth: frame.width, frameHeight: frame.height)
            let rect = PixelRect(x: 0, y: 0, width: frame.width, height: frame.height * 85 / 100)
            let scan = PixelSearch.scan(frame, rect: rect, config: config, limit: 24)
            if cfg.identifyChampions, !suspended, !enemies.isEmpty {
                for hit in scan.enemies where crop == nil {
                    guard let track = nearestTrack(to: hit, frameWidth: frame.width, now: now), names.wants(track.id, now: now),
                          let job = nameCrop(frame, hit: hit, config: config) else { continue }
                    crop = (hit, job)
                }
            }
            let flow = !suspended && (motionWanted() || (cfg.aim.enabled && cfg.aim.prediction)) ? measureGroundFlow(frame: frame, now: now) : nil
            let ready = comboSlots.isEmpty ? [:] : hud.read(frame: frame, champion: icons.champion, icons: icons.files, slots: comboSlots)
            var ring: RangeRing?
            if cfg.aim.ringCalibration, now - lastRingTryMs >= 200 {
                lastRingTryMs = now
                ring = detectRing(frame: frame, scan: scan, cfg: cfg, attackRange: attackRange, now: now)
            }
            if let record { FrameDump.saveAsync(frame, name: record) }
            return (scan, frame.width, frame.height, flow, ready, ring)
        }
        guard let result else { return }
        if result.width != lastFrameSize.width || result.height != lastFrameSize.height {
            if lastFrameSize.width > 0 { Log.info("frame size changed \(lastFrameSize.width)x\(lastFrameSize.height) -> \(result.width)x\(result.height): tracks and range calibration reset") }
            lastFrameSize = (result.width, result.height)
            tracks = []
            flowPrevious = []
            selfBar = nil
            ring = nil
            ringFeet = nil
            lastKx = 0
            barToFeet = 0
            feetFromCentre = nil
        }
        let micros = Double(DispatchTime.now().uptimeNanoseconds - started) / 1000
        let sx = Double(result.width) / 1920
        if suspended {
            tracks = []
            flowPrevious = []
        }
        var updated: [EnemyTrack] = []
        var remaining = tracks
        for hit in result.scan.enemies where !suspended {
            let cx = Double(hit.x) + Double(hit.width) / 2
            let cy = Double(hit.y)
            var bestIndex = -1
            var bestDistance = Double.infinity
            for (index, track) in remaining.enumerated() {
                let reach = min(400, 140 + 0.3 * (now - track.lastSeenMs)) * sx
                let dx = track.centerX - cx, dy = track.y - cy
                let d = dx * dx + dy * dy
                if d < reach * reach, d < bestDistance {
                    bestDistance = d
                    bestIndex = index
                }
            }
            if bestIndex >= 0 {
                var track = remaining.remove(at: bestIndex)
                track.x = Double(hit.x)
                track.y = cy
                track.width = hit.width
                track.height = hit.height
                track.fill = hit.fill
                if hit.fill > 0 { track.everFilled = true }
                track.sightings += 1
                if let previous = track.history.last, now - previous.t > 0 {
                    track.stepSpeed = hypot(cx - previous.x, cy - previous.y) / (now - previous.t)
                }
                track.lastSeenMs = now
                track.history.append(TrackSample(t: now, x: cx, y: cy))
                track.history.removeAll { now - $0.t > 160 }
                if track.history.count > 24 { track.history.removeFirst(track.history.count - 24) }
                let fit = Self.regressionFit(track.history)
                track.vx = fit.vx
                track.vy = fit.vy
                track.confidence = fit.confidence
                updated.append(track)
            } else {
                var track = EnemyTrack(id: nextID, x: Double(hit.x), y: cy, width: hit.width, height: hit.height, fill: hit.fill, firstSeenMs: now, lastSeenMs: now)
                track.everFilled = hit.fill > 0
                track.history = [TrackSample(t: now, x: cx, y: cy)]
                updated.append(track)
                nextID += 1
            }
        }
        for track in remaining where now - track.lastSeenMs < 1500 { updated.append(track) }
        if let crop, let track = updated.first(where: { Int($0.x) == crop.hit.x && Int($0.y) == crop.hit.y && $0.lastSeenMs == now }) {
            names.submit(NameReader.Job(trackID: track.id, image: crop.job.image, fillX: crop.job.fillX, fillY: crop.job.fillY, atMs: now))
        }
        for index in updated.indices {
            if enemies.isEmpty {
                updated[index].champion = ChampionModels.dummyKey
                updated[index].identity = "dummy"
            } else if let identity = names.identity(for: updated[index].id) {
                let previous = updated[index].champion
                updated[index].champion = identity.champion
                updated[index].level = identity.level
                updated[index].identity = identity.text
                if !previous.isEmpty, !identity.champion.isEmpty, previous != identity.champion {
                    let others = updated.enumerated().filter { $0.offset != index }
                        .map { "#\($0.element.id)(\(Int($0.element.centerX)),\(Int($0.element.y)))\($0.element.champion.isEmpty ? "" : " " + $0.element.champion)" }
                    Log.info("track #\(updated[index].id) identity \(previous) -> \(identity.champion) at (\(Int(updated[index].centerX)), \(Int(updated[index].y))), seen \(updated[index].sightings)x; others: \(others.isEmpty ? "none" : others.joined(separator: " "))")
                }
                if !identity.champion.isEmpty, ChampionModels.table[identity.champion] == nil, unknownChampions.insert(identity.champion).inserted {
                    Log.warn("champion key \"\(identity.champion)\" (\(identity.text)) is not in the size table: clicking the default body until it is learned")
                }
            }
        }
        names.keep(Set(updated.map(\.id)))
        tracks = updated
        let center = (x: Double(result.width) / 2, y: Double(result.height) / 2)
        if let own = result.scan.own.min(by: { hypot(Double($0.x) - center.x, Double($0.y) - center.y) < hypot(Double($1.x) - center.x, Double($1.y) - center.y) }) {
            selfBar = own
            selfSeenMs = now
        }
        if let hit = result.ring {
            ring = hit
            lastKx = lastKx > 0 ? lastKx * 0.7 + hit.kx * 0.3 : hit.kx
            let smoothed = ringFeet.map { CGPoint(x: $0.x * 0.7 + hit.feet.x * 0.3, y: $0.y * 0.7 + hit.feet.y * 0.3) } ?? hit.feet
            ringFeet = smoothed
            if let bar = selfBar, now - selfSeenMs < 100 {
                let measured = smoothed.y - Double(bar.y)
                barToFeet = barToFeet > 0 ? barToFeet * 0.9 + measured * 0.1 : measured
            }
            feetFromCentre = CGPoint(x: smoothed.x - center.x, y: smoothed.y - center.y)
        }
        let projection = makeProjection(cfg: cfg, width: result.width, height: result.height, attackRange: attackRange, now: now)
        var groundVelocity = CGPoint.zero
        var patches = 0
        if let flow = result.flow {
            flowMs = now
            if abs(flow.dx) >= 1 || abs(flow.dy) >= 1 { motionMs = now }
            groundX += flow.dx
            groundY += flow.dy
            groundPath.append(TrackSample(t: now, x: groundX, y: groundY))
            groundPath.removeAll { now - $0.t > 140 }
            groundVelocity = Self.regressionVelocity(groundPath)
            patches = flow.patches
        } else {
            groundPath.removeAll()
        }
        var published = VisionSnapshot(enemies: updated, selfBar: selfBar, selfSeenMs: selfSeenMs, frameWidth: result.width, frameHeight: result.height,
                                       atMs: now, frameMs: frameMs, scanMicros: micros, groundVx: groundVelocity.x, groundVy: groundVelocity.y, flowPatches: patches)
        published.flowMs = flowMs
        published.motionMs = motionMs
        published.abilityReady = result.ready
        published.hudText = hud.statusText
        published.projection = projection
        published.windowFrame = game.capture.windowFrame
        if let feet = published.selfPoint(cfg: cfg), now - selfSeenMs < 1000 || projection.feetFresh {
            published.cameraLocked = abs(feet.x - Double(result.width) / 2) <= 70 * sx && abs(feet.y - Double(result.height) / 2) <= 90 * Double(result.height) / 1080
        }
        published.rangeText = rangeText(projection)
        reportRange(projection, attackRange: attackRange, now: now)
        fresh.lock()
        snapshot = published
        fresh.broadcast()
        fresh.unlock()
    }

    /** The track a scan hit will be matched to: the nearest one within the matching reach. */
    private func nearestTrack(to hit: PixelHit, frameWidth: Int, now: Double) -> EnemyTrack? {
        let sx = Double(frameWidth) / 1920
        let cx = Double(hit.x) + Double(hit.width) / 2, cy = Double(hit.y)
        return tracks.filter { track in
            let reach = min(400, 140 + 0.3 * (now - track.lastSeenMs)) * sx
            return hypot(track.centerX - cx, track.y - cy) < reach
        }.min { hypot($0.centerX - cx, $0.y - cy) < hypot($1.centerX - cx, $1.y - cy) }
    }

    /** Crop of the level box, the fill and the name plate above an enemy bar for the text recogniser, doubled at 1× capture. */
    private func nameCrop(_ frame: Frame, hit: PixelHit, config: DetectionConfig, enlarge: Bool = false) -> (image: CGImage, fillX: Double, fillY: Double)? {
        let sy = Double(frame.height) / 1080
        let x0 = hit.x - config.boxWidth * 3, y0 = hit.y - Int(34 * sy)
        let scale = frame.width < 3000 || enlarge ? 2 : 1
        guard let image = FrameDump.crop(frame, x: x0, y: y0, width: max(config.barWidth, hit.width) + config.boxWidth * 3, height: hit.y - y0 + hit.height + Int(6 * sy), scale: scale) else { return nil }
        return (image, Double((hit.x - max(0, x0)) * scale), Double((hit.y - max(0, y0)) * scale))
    }

    /** Tries the ring around the best guess of the feet: the last ring, else the own bar plus the learned offset, else the last feet position; a ring far from the expected attack ring size is another indicator and is ignored. */
    private func detectRing(frame: Frame, scan: ScanResult, cfg: EngineSettings, attackRange: Double, now: Double) -> RangeRing? {
        let sx = Double(frame.width) / 1920, sy = Double(frame.height) / 1080
        let centre = CGPoint(x: Double(frame.width) / 2, y: Double(frame.height) / 2)
        var origin = centre
        if let ring, now - ring.atMs < 5000 {
            origin = ring.feet
        } else if let own = scan.own.min(by: { hypot(Double($0.x) - centre.x, Double($0.y) - centre.y) < hypot(Double($1.x) - centre.x, Double($1.y) - centre.y) }) {
            origin = CGPoint(x: Double(own.x) + Double(own.width) * 0.4, y: Double(own.y) + (barToFeet > 0 ? barToFeet : cfg.aim.selfFeetOffsetY * sy))
        } else if let rest = feetFromCentre {
            origin = CGPoint(x: centre.x + rest.x, y: centre.y + rest.y)
        }
        let ringUnits = max(150, attackRange) + GroundProjection.gameplayRadius
        let expectedA = (lastKx > 0 ? lastKx : cfg.aim.pxPerUnitX * sx) * ringUnits
        guard let hit = RangeRingDetector.detect(frame: frame, origin: origin, expectedA: expectedA, ringUnits: ringUnits, screenCentre: centre, now: now) else { return nil }
        return abs(hit.a - expectedA) <= 0.3 * expectedA ? hit : nil
    }

    private func ownMeshHeight() -> Double {
        (ChampionModels.model(for: ownChampion()) ?? ChampionModels.fallback).meshHeight
    }

    /** Scale from the ring (drawn at attack range + gameplay radius, smoothed over fits), perspective tied to it by the camera constant, feet from the ring when fresh, else from the own bar; without a fresh ring the champion's shift above or below its calibrated screen position gives the terrain height, which rescales the last value. */
    private func makeProjection(cfg: EngineSettings, width: Int, height: Int, attackRange: Double, now: Double) -> GroundProjection {
        let sx = Double(width) / 1920, sy = Double(height) / 1080
        let centre = CGPoint(x: Double(width) / 2, y: Double(height) / 2)
        if feetFromCentre == nil, cfg.aim.feetFromCentreY != 0 { feetFromCentre = CGPoint(x: 0, y: cfg.aim.feetFromCentreY * sy) }
        var kx = lastKx > 0 ? lastKx : cfg.aim.pxPerUnitX * sx
        let windowWidth = game.capture.windowFrame.width
        let frame = GroundProjection.barAboveHeadPt * (windowWidth > 0 ? Double(width) / windowWidth : sx)
        let offset = barToFeet > 0 ? barToFeet : cfg.aim.selfFeetOffsetY * sy
        var source = lastKx > 0 ? "last ring" : "settings"
        let ringFresh = ring.map { now - $0.atMs < 3000 } ?? false
        if ringFresh {
            source = "ring"
        } else if motionWanted(), let bar = selfBar, now - selfSeenMs < 200, let rest = feetFromCentre {
            let shift = (centre.y + rest.y) - (Double(bar.y) + offset)
            let h = max(-250, min(250, shift / (kx * GroundProjection.pitchCos)))
            let c = kx * GroundProjection.perspectivePerScale / Double(height)
            kx *= 1 / max(0.5, 1 - h * c / (GroundProjection.pitchCos * GroundProjection.pitchSin))
            source += String(format: ", terrain %+.0f u", h)
        }
        let c = kx * GroundProjection.perspectivePerScale / Double(height)
        var feet = CGPoint(x: centre.x, y: centre.y + 40 * sy)
        var feetFresh = false
        if let ring, now - ring.atMs < 1000, let ringFeet {
            feet = ringFeet
            feetFresh = true
        } else if let bar = selfBar, now - selfSeenMs < 1000 {
            feet = CGPoint(x: Double(bar.x) + Double(bar.width) * 0.4, y: Double(bar.y) + offset)
        } else if let rest = feetFromCentre {
            feet = CGPoint(x: centre.x + rest.x, y: centre.y + rest.y)
        }
        var projection = GroundProjection(frameWidth: width, frameHeight: height, kx: kx, c: c, feet: feet, feetFresh: feetFresh, feetFromCentre: feetFromCentre, barToFeet: offset, source: source)
        projection.barFrameOffset = frame
        return projection
    }

    private func rangeText(_ p: GroundProjection) -> String {
        let sx = Double(p.frameWidth) / 1920
        guard let ring else { return String(format: "Range ring not found yet (turn on Show Range), scale %.3f px/u from settings", p.kx / sx) }
        return String(format: "Ring %.0f×%.0f px, %d/%d points, ", ring.a, ring.b, ring.inliers, ring.candidates) + p.source
            + String(format: "; feet %.0f px below the bar; ring = attack range + 65; %.3f px/u at 1920, perspective %.2e", p.barToFeet, p.kx / sx, p.c)
    }

    /** Logs the calibration every 30 s while the ring is seen and hands the values to the settings every 20 s. */
    private func reportRange(_ p: GroundProjection, attackRange: Double, now: Double) {
        guard let ring, now - ring.atMs < 1000, attackRange > 0 else { return }
        let sx = Double(p.frameWidth) / 1920, sy = Double(p.frameHeight) / 1080
        if now - lastLearnMs > 20000 {
            lastLearnMs = now
            learned(p.kx / sx, p.barToFeet / sy, (feetFromCentre?.y ?? 0) / sy)
        }
        guard now - lastRangeLogMs > 30000 else { return }
        lastRangeLogMs = now
        let reach = GroundProjection.reach(attackRange: attackRange)
        let right = p.offset(p.feet, unitX: reach, unitZ: 0).x - p.feet.x
        let up = p.feet.y - p.offset(p.feet, unitX: 0, unitZ: reach).y
        let down = p.offset(p.feet, unitX: 0, unitZ: -reach).y - p.feet.y
        let own = ChampionModels.model(for: ownChampion()) ?? ChampionModels.fallback
        Log.info("range: \(rangeText(p)); feet (\(Int(p.feet.x)), \(Int(p.feet.y))); reach \(Int(reach)) u = \(Int(right)) px right, \(Int(up)) px up, \(Int(down)) px down")
        Log.info(String(format: "own bar: fill top %.0f px above the ring feet; %@ mesh %.0f u = %.0f px here plus %.0f px bar-to-head = %.0f px", p.barToFeet, own.isKnown ? own.name : "(fallback)", own.meshHeight, p.rise(own.meshHeight, at: p.feet), p.barFrameOffset, p.barFrameOffset + p.rise(own.meshHeight, at: p.feet)))
    }

    /** Least-squares slope of the samples in px per ms; zero until the samples span at least 40 ms. */
    static func regressionVelocity(_ samples: [TrackSample]) -> CGPoint {
        let fit = regressionFit(samples)
        return CGPoint(x: fit.vx, y: fit.vy)
    }

    /** Linear fit of the path: velocity in px/ms and how straight the recent motion was (1 = perfectly linear, 0 = noise or turning). */
    static func regressionFit(_ samples: [TrackSample]) -> (vx: Double, vy: Double, confidence: Double) {
        guard samples.count >= 3, let first = samples.first, let last = samples.last, last.t - first.t >= 40 else { return (0, 0, 0) }
        let n = Double(samples.count)
        let meanT = samples.reduce(0) { $0 + $1.t } / n
        let meanX = samples.reduce(0) { $0 + $1.x } / n
        let meanY = samples.reduce(0) { $0 + $1.y } / n
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for s in samples {
            let dt = s.t - meanT
            sxx += dt * dt
            sxy += dt * (s.x - meanX)
            syy += dt * (s.y - meanY)
        }
        guard sxx > 0 else { return (0, 0, 0) }
        let vx = sxy / sxx, vy = syy / sxx
        var residual = 0.0, total = 0.0
        for s in samples {
            let dt = s.t - meanT
            let ex = s.x - (meanX + vx * dt), ey = s.y - (meanY + vy * dt)
            residual += ex * ex + ey * ey
            total += (s.x - meanX) * (s.x - meanX) + (s.y - meanY) * (s.y - meanY)
        }
        let confidence = total > 1 ? max(0, min(1, 1 - residual / total)) : 0
        return (vx, vy, confidence)
    }

    /** Screen shift of the ground since the previous frame (median of the patch matches). */
    private func measureGroundFlow(frame: Frame, now: Double) -> (dx: Double, dy: Double, patches: Int)? {
        let current = Self.flowPatches(of: frame)
        defer {
            flowPrevious = current
            flowPreviousMs = now
        }
        guard now - flowPreviousMs < 200 else { return nil }
        return Self.groundShift(from: flowPrevious, in: frame)
    }

    /** Eight fixed ground patches (green channel, sampled every `step` px so 2x frames cost the same) around, but not on, the champion. */
    static func flowPatches(of frame: Frame) -> [FlowPatch] {
        let step = max(1, frame.width / 1920)
        let size = 20
        let anchors: [(Double, Double)] = [(0.22, 0.42), (0.78, 0.42), (0.22, 0.66), (0.78, 0.66), (0.40, 0.26), (0.60, 0.26), (0.40, 0.74), (0.60, 0.74)]
        return anchors.map { ax, ay in
            extractPatch(frame, x: Int(Double(frame.width) * ax) - size * step / 2, y: Int(Double(frame.height) * ay) - size * step / 2, size: size, step: step)
        }
    }

    /** Where the previous patches ended up in this frame: median shift in px and how many patches agreed. */
    static func groundShift(from previous: [FlowPatch], in frame: Frame) -> (dx: Double, dy: Double, patches: Int)? {
        let current = flowPatches(of: frame)
        guard previous.count == current.count else { return nil }
        var dxs: [Int] = []
        var dys: [Int] = []
        for (index, patch) in previous.enumerated() where patch.textured && patch.x == current[index].x && patch.y == current[index].y && patch.step == current[index].step {
            guard let match = bestMatch(frame, patch: patch, search: 10) else { continue }
            dxs.append(match.dx)
            dys.append(match.dy)
        }
        guard dxs.count >= 2 else { return nil }
        return (Double(median(dxs)), Double(median(dys)), dxs.count)
    }

    static func extractPatch(_ frame: Frame, x: Int, y: Int, size: Int, step: Int) -> FlowPatch {
        var data = [UInt8](repeating: 0, count: size * size)
        var sum = 0
        for row in 0..<size {
            let base = frame.base + (y + row * step) * frame.bytesPerRow + x * 4 + 1
            for col in 0..<size {
                let value = base.load(fromByteOffset: col * step * 4, as: UInt8.self)
                data[row * size + col] = value
                sum += Int(value)
            }
        }
        let mean = sum / max(1, size * size)
        var deviation = 0
        for value in data { deviation += abs(Int(value) - mean) }
        return FlowPatch(x: x, y: y, size: size, step: step, data: data, deviation: deviation / max(1, size * size))
    }

    /** Offset (in px) inside ±search samples where the frame matches the patch best, rejected when the match is weak or the peak is flat. */
    static func bestMatch(_ frame: Frame, patch: FlowPatch, search: Int) -> (dx: Int, dy: Int, error: Int)? {
        let size = patch.size
        let area = size * size
        var best = Int.max
        var bestDx = 0
        var bestDy = 0
        for dy in -search...search {
            for dx in -search...search {
                let value = sad(frame, patch: patch, dx: dx, dy: dy, limit: best)
                if value < best {
                    best = value
                    bestDx = dx
                    bestDy = dy
                }
            }
        }
        guard best <= 10 * area, abs(bestDx) < search, abs(bestDy) < search else { return nil }
        let margin = 3 * area / 2
        for (ox, oy) in [(3, 0), (-3, 0), (0, 3), (0, -3)] {
            guard sad(frame, patch: patch, dx: bestDx + ox, dy: bestDy + oy, limit: best + margin) >= best + margin else { return nil }
        }
        return (bestDx * patch.step, bestDy * patch.step, best / area)
    }

    /** Sum of absolute differences of the patch at a sample offset, stopping early once it exceeds the limit. */
    private static func sad(_ frame: Frame, patch: FlowPatch, dx: Int, dy: Int, limit: Int) -> Int {
        let size = patch.size, step = patch.step
        let x0 = patch.x + dx * step, y0 = patch.y + dy * step
        guard x0 >= 0, y0 >= 0, x0 + size * step < frame.width, y0 + size * step < frame.height else { return Int.max }
        var total = 0
        patch.data.withUnsafeBufferPointer { reference in
            var row = 0
            while row < size, total < limit {
                let base = frame.base + (y0 + row * step) * frame.bytesPerRow + x0 * 4 + 1
                let refRow = row * size
                for col in 0..<size {
                    total += abs(Int(base.load(fromByteOffset: col * step * 4, as: UInt8.self)) - Int(reference[refRow + col]))
                }
                row += 1
            }
        }
        return total
    }

    private static func median(_ values: [Int]) -> Int {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
