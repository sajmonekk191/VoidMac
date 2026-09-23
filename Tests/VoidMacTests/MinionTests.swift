import AppKit
import Testing
@testable import VoidMac

private let ground = bgra(100, 120, 90)
private let geometry = MinionBarGeometry(frameWidth: 1920, frameHeight: 1080)
private let redRows = [bgra(0xDD, 0x54, 0x59), bgra(0xD7, 0x52, 0x56), bgra(0xAA, 0x40, 0x44), bgra(0x87, 0x35, 0x36)]
private let whiteRows = [bgra(0xD6, 0xE0, 0xE5), bgra(0xBF, 0xCA, 0xCC), bgra(0x8E, 0x98, 0x97), bgra(0x61, 0x67, 0x68)]
private let shadedRows = [bgra(0x9C, 0x04, 0x00), bgra(0x98, 0x05, 0x00), bgra(0x78, 0x07, 0x00), bgra(0x61, 0x07, 0x00)]

/** A minion bar at 1920×1080 as the game draws it (the 3600-wide anatomy halved): a dark border, dark interior edges, a four-row fill gradient from `x0 + 1` for `fill` px whose first `shaded` px use `shadedRows` (the assist's one-shot part), an optional partial pixel after it, and the dark empty part. */
private func paintMinionBar(on canvas: Canvas, x0: Int, y0: Int, fill: Int, rows: [UInt32] = redRows, edge: UInt32? = nil, shaded: Int = 0, shadedRows: [UInt32] = shadedRows,
                            width: Int = geometry.interiorWidth, empty: UInt32 = bgra(0x18, 0x15, 0x15)) {
    canvas.fill(x: x0 - 1, y: y0 - 1, width: width + 2, height: rows.count + 4, color: bgra(0x15, 0x13, 0x13))
    canvas.fill(x: x0, y: y0, width: width, height: rows.count + 2, color: bgra(0x0F, 0x0E, 0x10))
    for (index, color) in rows.enumerated() {
        canvas.fill(x: x0 + 1, y: y0 + 1 + index, width: width - 2, height: 1, color: empty)
        if fill > 0 { canvas.fill(x: x0 + 1, y: y0 + 1 + index, width: fill, height: 1, color: color) }
        if shaded > 0 { canvas.fill(x: x0 + 1, y: y0 + 1 + index, width: shaded, height: 1, color: shadedRows[index]) }
        if let edge { canvas.set(x0 + 1 + fill, y0 + 1 + index, edge) }
    }
}

private func scan(_ canvas: Canvas, white: Bool = false) -> [MinionHit] {
    MinionBars.scan(canvas.frame, rect: PixelRect(x: 0, y: 0, width: canvas.width, height: canvas.height), geometry: geometry, white: white)
}

@Test func minionBarGeometryFollowsTheSmallerScale() {
    let retina = MinionBarGeometry(frameWidth: 3600, frameHeight: 2144)
    #expect(retina.interiorWidth == 122 && retina.span == 120 && retina.bandHeight == 8)
    #expect(MinionBarGeometry(frameWidth: 3600, frameHeight: 2338).interiorWidth == 122)
    #expect(geometry.interiorWidth == 65 && geometry.bandHeight == 4 && geometry.rowStride == 3)
}

@Test func findsAFullMinionBar() throws {
    let canvas = Canvas(width: 400, height: 200, color: ground)
    paintMinionBar(on: canvas, x0: 100, y0: 60, fill: geometry.span)
    let hit = try #require(scan(canvas).first)
    #expect(hit.x == 101 && hit.y == 61 && hit.height == 4 && hit.span == geometry.span)
    #expect(hit.fill == Double(geometry.span) && !hit.white && hit.mark == nil)
}

@Test func measuresAPartialBarToAFractionOfAPixel() throws {
    let canvas = Canvas(width: 400, height: 200, color: ground)
    paintMinionBar(on: canvas, x0: 100, y0: 60, fill: 20, edge: bgra(0x4F, 0x28, 0x2A))
    let hit = try #require(scan(canvas).first)
    #expect(abs(hit.fill - 20.28) < 0.05)
    #expect(abs(hit.fraction - 20.28 / Double(geometry.span)) < 0.001)
}

@Test func findsANearlyEmptyBar() throws {
    let canvas = Canvas(width: 400, height: 200, color: ground)
    paintMinionBar(on: canvas, x0: 150, y0: 90, fill: 2)
    let hit = try #require(scan(canvas).first)
    #expect(hit.fill == 2 && hit.x == 151)
}

@Test func readsTheAssistsOneShotPartAtTheStartOfTheFill() throws {
    let canvas = Canvas(width: 400, height: 200, color: ground)
    paintMinionBar(on: canvas, x0: 100, y0: 60, fill: 40, shaded: 12)
    let hit = try #require(scan(canvas).first)
    #expect(hit.x == 101 && hit.fill == 40 && hit.mark == 12 && !hit.white)
    let brighter = Canvas(width: 400, height: 200, color: ground)
    paintMinionBar(on: brighter, x0: 100, y0: 60, fill: 50, shaded: 20, shadedRows: [bgra(0xA8, 0x28, 0x24), bgra(0xA2, 0x26, 0x22), bgra(0x86, 0x20, 0x1C), bgra(0x6C, 0x1A, 0x16)])
    let lit = try #require(scan(brighter).first)
    #expect(lit.x == 101 && lit.fill == 50 && lit.mark == 20)
    let full = Canvas(width: 400, height: 200, color: ground)
    paintMinionBar(on: full, x0: 100, y0: 60, fill: geometry.span, shaded: 30)
    #expect(try #require(scan(full).first).mark == 30)
    let cannon = Canvas(width: 400, height: 200, color: ground)
    paintMinionBar(on: cannon, x0: 100, y0: 60, fill: 45, shaded: 3)
    let sturdy = try #require(scan(cannon).first)
    #expect(sturdy.x == 101 && sturdy.fill == 45 && sturdy.mark == 3)
}

@Test func assistedBarsStayFoundUnderASpellsGlow() throws {
    let marked = Canvas(width: 400, height: 200, color: ground)
    paintMinionBar(on: marked, x0: 100, y0: 60, fill: 40, shaded: 12, empty: bgra(0x00, 0x4B, 0x61))
    #expect(try #require(scan(marked).first).mark == 12)
    let white = Canvas(width: 400, height: 200, color: ground)
    paintMinionBar(on: white, x0: 100, y0: 60, fill: 9, rows: whiteRows, empty: bgra(0x5F, 0x65, 0x65))
    #expect(scan(white, white: true).map(\.x) == [101])
    let plain = Canvas(width: 400, height: 200, color: ground)
    paintMinionBar(on: plain, x0: 100, y0: 60, fill: 40, empty: bgra(0x00, 0x4B, 0x61))
    #expect(scan(plain).isEmpty)
}

/** A recorded game frame in the regression fixtures, which stay out of git because they show the player's name. */
private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Tools/hud-regression-check/fixtures/\(name)")
}

/** A recorded game frame drawn into a canvas in the layout ScreenCaptureKit delivers. */
private func recordedFrame(_ name: String) -> Canvas? {
    guard let image = NSImage(contentsOf: fixture(name))?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let canvas = Canvas(width: image.width, height: image.height, color: 0)
    let info = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    guard let context = CGContext(data: UnsafeMutableRawPointer(mutating: canvas.frame.base), width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return canvas
}

@Test(.enabled(if: FileManager.default.fileExists(atPath: fixture("lasthit-assist-janna-2026-09-23T08-33-51Z.png").path)))
func readsEveryAssistedBarOfARecordedGame() throws {
    let canvas = try #require(recordedFrame("lasthit-assist-janna-2026-09-23T08-33-51Z.png"))
    let hits = Vision.scanMinions(canvas.frame, geometry: MinionBarGeometry(frameWidth: canvas.width, frameHeight: canvas.height), white: true, followed: [])
    #expect(hits.count == 6)
    #expect(hits.compactMap(\.mark).sorted() == [46, 46, 46, 76, 76, 76])
    #expect(hits.filter { $0.mark == 76 }.allSatisfy { $0.fill == 120 })
}

@Test func findsTheAssistsWhiteBarWhereTheRedOneWas() throws {
    let canvas = Canvas(width: 400, height: 200, color: ground)
    paintMinionBar(on: canvas, x0: 100, y0: 60, fill: 9, rows: whiteRows)
    #expect(scan(canvas).isEmpty)
    #expect(scan(canvas, white: true).map(\.x) == [101])
    let hit = try #require(MinionBars.whiteBars(canvas.frame, at: [(x: 103, y: 62)], geometry: geometry).first)
    #expect(hit.white && hit.fill == 9 && hit.x == 101 && hit.y == 61 && hit.height == 4)
    #expect(MinionBars.whiteBars(canvas.frame, at: [(x: 250, y: 150)], geometry: geometry).isEmpty)
    let followed = Vision.scanMinions(canvas.frame, geometry: geometry, white: false, followed: [(x: 101, y: 61)])
    #expect(followed.count == 1 && followed[0].white)
}

@Test func readsTheSuperMinionsWiderBar() throws {
    let healthy = Canvas(width: 400, height: 200, color: ground)
    paintMinionBar(on: healthy, x0: 100, y0: 60, fill: 80, width: geometry.largeInteriorWidth)
    let full = try #require(scan(healthy).first)
    #expect(full.large && full.span == geometry.largeSpan && full.fill == 80 && full.x == 101)
    let hurt = Canvas(width: 400, height: 200, color: ground)
    paintMinionBar(on: hurt, x0: 100, y0: 60, fill: 20, width: geometry.largeInteriorWidth)
    let low = try #require(scan(hurt).first)
    #expect(low.large && low.fill == 20)
    let river = Canvas(width: 400, height: 200, color: bgra(0x12, 0x28, 0x1F))
    paintMinionBar(on: river, x0: 100, y0: 60, fill: geometry.span)
    let normal = try #require(scan(river).first)
    #expect(!normal.large && normal.span == geometry.span && normal.fill == Double(geometry.span))
}

@Test func whiteTextIsNoWhiteBar() {
    let canvas = Canvas(width: 400, height: 200, color: ground)
    paintMinionBar(on: canvas, x0: 100, y0: 60, fill: 9, rows: [bgra(0xC0, 0xC0, 0xC0), bgra(0xF9, 0xF9, 0xF9), bgra(0xFF, 0xFF, 0xFF), bgra(0xC6, 0xC6, 0xC6)])
    #expect(scan(canvas, white: true).isEmpty)
}

@Test func textAcrossABarIsNoOneShotMark() {
    let canvas = Canvas(width: 400, height: 200, color: ground)
    paintMinionBar(on: canvas, x0: 100, y0: 60, fill: geometry.span)
    canvas.fill(x: 108, y: 54, width: 2, height: 16, color: bgra(0xE8, 0xE8, 0xE8))
    #expect(scan(canvas).allSatisfy { $0.mark == nil })
}

@Test func rejectsWhatIsNotAMinionBar() {
    let text = Canvas(width: 400, height: 200, color: ground)
    paintMinionBar(on: text, x0: 100, y0: 60, fill: 30, rows: Array(repeating: redRows[0], count: 4))
    #expect(scan(text).isEmpty)
    let tall = Canvas(width: 400, height: 200, color: ground)
    paintMinionBar(on: tall, x0: 100, y0: 60, fill: 30, rows: redRows + redRows + redRows)
    #expect(scan(tall).isEmpty)
    let lit = Canvas(width: 400, height: 200, color: ground)
    paintMinionBar(on: lit, x0: 100, y0: 60, fill: 30)
    lit.fill(x: 131, y: 61, width: 60, height: 4, color: bgra(0x70, 0x70, 0x70))
    #expect(scan(lit).isEmpty)
}

private func bar(_ x: Int, _ y: Int, _ fill: Double, white: Bool = false) -> MinionHit {
    MinionHit(x: x, y: y, span: geometry.span, height: 4, fill: fill, white: white)
}

@Test func trackerFollowsMovingBarsAndNeverGivesHealthBack() {
    var nextID = 1
    var tracks = MinionTracker.update([], with: [bar(100, 100, 50), bar(140, 100, 20)], geometry: geometry, now: 0, nextID: &nextID).tracks
    #expect(tracks.map(\.id) == [1, 2] && nextID == 3)
    tracks = MinionTracker.update(tracks, with: [bar(146, 101, 19), bar(106, 101, 48)], geometry: geometry, now: 8, nextID: &nextID).tracks
    #expect(tracks.first { $0.id == 1 }?.x == 106 && tracks.first { $0.id == 2 }?.x == 146)
    let refilled = MinionTracker.update(tracks, with: [bar(150, 101, 40)], geometry: geometry, now: 16, nextID: &nextID).tracks
    #expect(refilled.first { $0.x == 150 }?.id == 3 && refilled.first { $0.id == 2 }?.x == 146)
    let later = MinionTracker.update(refilled, with: [], geometry: geometry, now: 400, nextID: &nextID).tracks
    #expect(later.isEmpty)
}

@Test func trackerKeepsABarsWidth() {
    var nextID = 1
    let tracks = MinionTracker.update([], with: [bar(100, 100, 30)], geometry: geometry, now: 0, nextID: &nextID).tracks
    var wide = bar(101, 100, 20)
    wide.large = true
    wide.span = geometry.largeSpan
    let next = MinionTracker.update(tracks, with: [wide], geometry: geometry, now: 16, nextID: &nextID).tracks
    #expect(next.count == 2 && next.contains { $0.large && $0.id == 2 } && next.contains { !$0.large && $0.id == 1 })
}

@Test func trackerFollowsABarIntoWhiteAndStartsWhiteOnesOfItsOwn() {
    var nextID = 1
    let tracks = MinionTracker.update([], with: [bar(100, 100, 30)], geometry: geometry, now: 0, nextID: &nextID).tracks
    let burst = MinionTracker.update(tracks, with: [bar(103, 101, 9, white: true)], geometry: geometry, now: 16, nextID: &nextID)
    #expect(burst.assist != nil && burst.tracks.count == 1 && burst.tracks[0].white && burst.tracks[0].id == 1)
    let text = MinionHit(x: 200, y: 40, span: geometry.span, height: 7, fill: 20, white: true)
    let seen = MinionTracker.update([], with: [bar(300, 50, 9, white: true), bar(200, 150, 2, white: true), text], geometry: geometry, now: 0, nextID: &nextID)
    #expect(seen.tracks.count == 1 && seen.tracks[0].x == 300 && seen.tracks[0].white && seen.tracks[0].confirmed && seen.assist != nil)
}

@Test func trackerMeasuresTheLossAndConfirmsRealMinions() {
    var nextID = 1
    var tracks: [MinionTrack] = []
    for (index, fill) in [30.0, 30, 27, 27, 24, 24, 21].enumerated() {
        tracks = MinionTracker.update(tracks, with: [bar(100, 100, fill)], geometry: geometry, now: Double(index) * 100, nextID: &nextID).tracks
    }
    let minion = tracks[0]
    #expect(minion.sightings == 7 && minion.confirmed)
    #expect(abs(minion.lossPerMs - 9 / Double(geometry.span) / 600) < 1e-9)
    var static_: [MinionTrack] = []
    for index in 0..<8 { static_ = MinionTracker.update(static_, with: [bar(300, 50, 2)], geometry: geometry, now: Double(index) * 8, nextID: &nextID).tracks }
    #expect(!static_[0].confirmed)
}

@Test func lossRateSumsMinionHitsAndLeavesOutBurstsAndNoise() {
    let steps = [(0.0, 0.60), (100, 0.60), (200, 0.55), (300, 0.55), (400, 0.50)].map { HealthSample(t: $0.0, fraction: $0.1) }
    #expect(abs(MinionTrack.lossRate(steps, span: 120) - 0.10 / 400) < 1e-12)
    let burst = [(0.0, 0.90), (150, 0.40), (300, 0.35)].map { HealthSample(t: $0.0, fraction: $0.1) }
    #expect(abs(MinionTrack.lossRate(burst, span: 120) - 0.05 / 300) < 1e-12)
    let jitter = [(0.0, 0.500), (100, 0.498), (200, 0.501), (300, 0.499)].map { HealthSample(t: $0.0, fraction: $0.1) }
    #expect(MinionTrack.lossRate(jitter, span: 120) == 0)
    #expect(MinionTrack.lossRate(Array(steps.prefix(2)), span: 120) == 0)
}

@Test func minionHealthFollowsTheWikiUpgrades() {
    let rift = MinionRules.summonersRift
    #expect(rift.upgrades(at: 29) == 0 && rift.upgrades(at: 30) == 1 && rift.upgrades(at: 119) == 1 && rift.upgrades(at: 120) == 2)
    #expect(rift.stats(.melee, upgrades: 1) == MinionStats(maxHealth: 465, armor: 0))
    #expect(rift.stats(.caster, upgrades: 1).maxHealth == 284)
    #expect(rift.stats(.siege, upgrades: 1).maxHealth == 835)
    #expect(rift.stats(.superMinion, upgrades: 1) == MinionStats(maxHealth: 1600, armor: 100))
    let late = rift.stats(.melee, upgrades: 20)
    #expect(late.maxHealth == 1130 && abs(late.armor - 8.925) < 1e-9)
    #expect(rift.stats(.melee, upgrades: 60) == MinionStats(maxHealth: 1550, armor: 20))
    #expect(rift.stats(.caster, upgrades: 60).maxHealth == 600)
    let aram = MinionRules(mapNumber: 12)
    #expect(aram == .howlingAbyss && aram.upgrades(at: 49) == 0 && aram.upgrades(at: 100) == 2)
    #expect(aram.stats(.melee, upgrades: 0).maxHealth == 455 && aram.stats(.superMinion, upgrades: 0).armor == 60)
}

@Test func attackDamageAgainstMinionsCountsArmorLethalityAndItems() {
    let model = AttackDamageModel(attackDamage: 100, bonusVsMinions: 5, lethality: 10, damageDealt: 1, efficiency: 1)
    #expect(abs(model.damage(armor: 20) - 105 * 100 / 110) < 1e-9)
    #expect(model.damage(armor: 5) == 105)
    #expect(abs(model.share(.caster, rules: .summonersRift, upgrades: 1) - 105.0 / 284) < 1e-12)
    #expect(AttackDamageModel.helpingHandItems.contains(1054) && AttackDamageModel.helpingHandItems.contains(3070))
}
