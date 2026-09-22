import CoreGraphics
import Testing
@testable import VoidMac

private let ground = bgra(100, 120, 90)
private let border = bgra(20, 20, 20)
private let white = bgra(255, 255, 255)

/** An enemy (red) or own (green) champion bar at 1920×1080: dark frame and outline, level box with a digit, fill from `x`. */
private func paintBar(on canvas: Canvas, x: Int, top: Int, fill: Int, color: UInt32, box: UInt32) {
    canvas.fill(x: x - 2, y: top - 2, width: 104, height: 12, color: border)
    canvas.fill(x: x - 26, y: top - 3, width: 22, height: 14, color: box)
    for (dx, dy) in [(8, 0), (9, 0), (8, 3), (9, 3), (8, 6), (9, 6), (10, 1), (10, 2), (10, 4), (10, 5)] { canvas.set(x - 24 + dx, top + dy, white) }
    canvas.fill(x: x, y: top, width: fill, height: 8, color: color)
}

private let config = EngineSettings().detectionConfig(frameWidth: 1920, frameHeight: 1080)
private let scanRect = PixelRect(x: 0, y: 0, width: 1920, height: 1080 * 85 / 100)

@Test func findsEnemyBarWithItsFill() {
    let canvas = Canvas(width: 1920, height: 1080, color: ground)
    paintBar(on: canvas, x: 400, top: 300, fill: 60, color: bgra(0xB0, 0x18, 0x18), box: bgra(40, 12, 12))
    let scan = PixelSearch.scan(canvas.frame, rect: scanRect, config: config)
    #expect(scan.enemies == [PixelHit(x: 400, y: 300, width: config.barWidth, height: 8, fill: 60)])
    #expect(scan.own.isEmpty)
}

@Test func findsOwnGreenBar() {
    let canvas = Canvas(width: 1920, height: 1080, color: ground)
    paintBar(on: canvas, x: 900, top: 500, fill: 80, color: bgra(0x20, 0xC0, 0x20), box: bgra(10, 40, 70))
    let scan = PixelSearch.scan(canvas.frame, rect: scanRect, config: config)
    #expect(scan.own == [PixelHit(x: 900, y: 500, width: config.barWidth, height: 8, fill: 80)])
    #expect(scan.enemies.isEmpty)
}

@Test func ignoresRedWithoutTheBarStructure() {
    let canvas = Canvas(width: 1920, height: 1080, color: ground)
    canvas.fill(x: 300, y: 200, width: 400, height: 60, color: bgra(0xB0, 0x18, 0x18))
    #expect(PixelSearch.scan(canvas.frame, rect: scanRect, config: config).enemies.isEmpty)
}

@Test func fitsRangeRingAndItsScale() {
    let canvas = Canvas(width: 1920, height: 1080, color: bgra(60, 70, 50))
    let centre = CGPoint(x: 960, y: 560), a = 300.0, b = 246.0
    for y in 250...850 {
        for x in 600...1320 {
            let r = hypot((Double(x) - centre.x) / a, (Double(y) - centre.y) / b)
            if abs(r - 1) * a < 2 { canvas.set(x, y, white) }
        }
    }
    var generator = SeededGenerator(state: 7)
    let ring = RangeRingDetector.detect(frame: canvas.frame, origin: centre, expectedA: a, ringUnits: 565, screenCentre: CGPoint(x: 960, y: 540), now: 0, using: &generator)
    #expect(ring != nil)
    if let ring {
        #expect(abs(ring.a - a) < 2)
        #expect(abs(ring.b - b) < 2)
        #expect(hypot(ring.centre.x - centre.x, ring.centre.y - centre.y) < 2)
        #expect(ring.inliers >= 60)
    }
}

@Test func fitEllipseRecoversExactPoints() throws {
    let points = (0..<24).map { i -> CGPoint in
        let angle = Double(i) / 24 * 2 * .pi
        return CGPoint(x: 500 + 200 * cos(angle), y: 300 + 160 * sin(angle))
    }
    let fit = try #require(RangeRingDetector.fitEllipse(points))
    #expect(abs(fit.centre.x - 500) < 1e-6 && abs(fit.centre.y - 300) < 1e-6)
    #expect(abs(fit.a - 200) < 1e-6 && abs(fit.b - 160) < 1e-6)
}

@Test func groundFlowRecoversCameraPan() throws {
    var generator = SeededGenerator(state: 42)
    let canvas = Canvas(width: 1920, height: 1080, color: 0)
    for y in 0..<1080 {
        for x in 0..<1920 { canvas.set(x, y, bgra(Int.random(in: 0...255, using: &generator), Int.random(in: 0...255, using: &generator), 40)) }
    }
    let patches = Vision.flowPatches(of: canvas.frame)
    let still = try #require(Vision.groundShift(from: patches, in: canvas.frame))
    #expect(still.dx == 0 && still.dy == 0 && still.patches == 8)
    let panned = canvas.translated(dx: 6, dy: -4)
    let shift = try #require(Vision.groundShift(from: patches, in: panned.frame))
    #expect(shift.dx == 6 && shift.dy == -4 && shift.patches == 8)
}

@Test func regressionFitMeasuresLinearMotion() {
    let line = stride(from: 0.0, through: 100, by: 10).map { TrackSample(t: $0, x: 2 + 0.5 * $0, y: 3 - 0.25 * $0) }
    let fit = Vision.regressionFit(line)
    #expect(abs(fit.vx - 0.5) < 1e-12 && abs(fit.vy + 0.25) < 1e-12)
    #expect(fit.confidence == 1)
    let tooShort = Vision.regressionFit(Array(line.prefix(2)))
    #expect(tooShort.vx == 0 && tooShort.vy == 0 && tooShort.confidence == 0)
    let zigzag = line.enumerated().map { TrackSample(t: $1.t, x: $1.x + ($0 % 2 == 0 ? 30 : -30), y: $1.y) }
    #expect(Vision.regressionFit(zigzag).confidence < 0.5)
}

@Test func groundProjectionRoundTrips() {
    let projection = GroundProjection(frameWidth: 1920, frameHeight: 1080, kx: 0.7, c: 0.7 * GroundProjection.perspectivePerScale / 1080,
                                      feet: CGPoint(x: 960, y: 560), barToFeet: 110)
    for point in [CGPoint(x: 960, y: 540), CGPoint(x: 200, y: 150), CGPoint(x: 1700, y: 950), CGPoint(x: 1000, y: 300)] {
        let back = projection.screen(projection.ground(point))
        #expect(abs(back.x - point.x) < 1e-9 && abs(back.y - point.y) < 1e-9)
    }
    let a = CGPoint(x: 700, y: 400), b = CGPoint(x: 1200, y: 800)
    #expect(abs(projection.units(a, b) - projection.units(b, a)) < 1e-9)
    #expect(projection.scale(at: CGPoint(x: 960, y: 200)) < 1 && projection.scale(at: CGPoint(x: 960, y: 900)) > 1)
    let right = projection.offset(CGPoint(x: 960, y: 540), unitX: 100, unitZ: 0)
    #expect(abs(right.x - (960 + 70)) < 1e-9 && abs(right.y - 540) < 1e-9)
}
