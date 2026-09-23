import AppKit
import Foundation

/** SplitMix64, so the ring detector's RANSAC draws the same samples on every run. */
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/** Decodes a recorded PNG into the BGRA layout ScreenCaptureKit delivers. */
func load(_ url: URL) -> Frame? {
    guard let image = NSImage(contentsOf: url), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let width = cg.width, height = cg.height, bytesPerRow = width * 4
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: bytesPerRow * height, alignment: 64)
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    guard let context = CGContext(data: buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info.rawValue) else { return nil }
    context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
    return Frame(base: UnsafeRawPointer(buffer), width: width, height: height, bytesPerRow: bytesPerRow)
}

/** Copy of the frame with its content moved by (dx, dy) px, edges clamped: a camera pan with a known answer. */
func translated(_ frame: Frame, dx: Int, dy: Int) -> Frame {
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: frame.bytesPerRow * frame.height, alignment: 64)
    for y in 0..<frame.height {
        let source = frame.base + min(frame.height - 1, max(0, y - dy)) * frame.bytesPerRow
        let target = buffer + y * frame.bytesPerRow
        for x in 0..<frame.width {
            target.storeBytes(of: source.load(fromByteOffset: min(frame.width - 1, max(0, x - dx)) * 4, as: UInt32.self), toByteOffset: x * 4, as: UInt32.self)
        }
    }
    return Frame(base: UnsafeRawPointer(buffer), width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow)
}

/** Minimum and median wall time of `body` in microseconds. */
func measure(_ iterations: Int, _ body: () -> Void) -> (min: Double, median: Double) {
    body()
    var samples: [Double] = []
    samples.reserveCapacity(iterations)
    for _ in 0..<iterations {
        let started = DispatchTime.now().uptimeNanoseconds
        body()
        samples.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1000)
    }
    samples.sort()
    return (samples[0], samples[samples.count / 2])
}

func describe(_ hits: [PixelHit]) -> String {
    hits.map { "(\($0.x),\($0.y),\($0.width),\($0.height),\($0.fill))" }.joined()
}

func describe(_ hits: [MinionHit]) -> String {
    hits.map { "(\($0.x),\($0.y),\($0.height),\(String(format: "%.2f", $0.fill))\($0.white ? ",white" : "")\($0.mark.map { String(format: ",mark %.1f", $0) } ?? ""))" }.joined()
}

func describe(_ ring: RangeRing?) -> String {
    guard let ring else { return "nil" }
    return "centre \(ring.centre.x),\(ring.centre.y) a \(ring.a) b \(ring.b) inliers \(ring.inliers)/\(ring.candidates) kx \(ring.kx) feet \(ring.feet.x),\(ring.feet.y)"
}

let arguments = CommandLine.arguments
func argument(_ name: String) -> String? {
    arguments.firstIndex(of: name).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
}
let iterations = Int(argument("--iterations") ?? "") ?? 25
let home = FileManager.default.homeDirectoryForCurrentUser
let here = URL(fileURLWithPath: arguments[0]).deletingLastPathComponent()
let folders = [home.appendingPathComponent("Library/Logs/VoidMac-frames"), URL(fileURLWithPath: argument("--fixtures") ?? here.path)]
var seen = Set<String>()
let files = folders.flatMap { folder in
    ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "png" }
}.sorted { $0.lastPathComponent < $1.lastPathComponent }.filter { seen.insert($0.lastPathComponent).inserted }

let cfg = EngineSettings()
if let first = files.first, let frame = load(first) {
    let config = cfg.detectionConfig(frameWidth: frame.width, frameHeight: frame.height)
    let warmUntil = DispatchTime.now().uptimeNanoseconds + 700_000_000
    while DispatchTime.now().uptimeNanoseconds < warmUntil { _ = PixelSearch.scan(frame, rect: PixelRect(x: 0, y: 0, width: frame.width, height: frame.height), config: config) }
    UnsafeMutableRawPointer(mutating: frame.base).deallocate()
}

var golden: [String] = []
var minionGolden: [String] = []
var assistGolden: [String] = []
var scanTimes: [Double] = []
var minionTimes: [Double] = []
var assistTimes: [Double] = []
var flowTimes: [Double] = []
var ringTimes: [Double] = []
var cropTimes: [Double] = []

for (index, url) in files.enumerated() {
    guard let frame = load(url) else {
        print("skip \(url.lastPathComponent): unreadable")
        continue
    }
    defer { UnsafeMutableRawPointer(mutating: frame.base).deallocate() }
    let name = url.lastPathComponent
    let config = cfg.detectionConfig(frameWidth: frame.width, frameHeight: frame.height)
    let rect = PixelRect(x: 0, y: 0, width: frame.width, height: frame.height * 85 / 100)
    let scan = PixelSearch.scan(frame, rect: rect, config: config, limit: 24)
    golden.append("scan \(name) enemies \(describe(scan.enemies)) own \(describe(scan.own))")
    scanTimes.append(measure(iterations) { _ = PixelSearch.scan(frame, rect: rect, config: config, limit: 24) }.median)
    if arguments.contains("--verbose") { print(String(format: "%8.1f µs  %@", scanTimes[scanTimes.count - 1], name)) }

    let minionGeometry = MinionBarGeometry(frameWidth: frame.width, frameHeight: frame.height)
    minionGolden.append("minions \(name) " + describe(Vision.scanMinions(frame, geometry: minionGeometry, white: false, followed: [])))
    minionTimes.append(measure(iterations) { _ = Vision.scanMinions(frame, geometry: minionGeometry, white: false, followed: []) }.median)
    assistGolden.append("minions+white \(name) " + describe(Vision.scanMinions(frame, geometry: minionGeometry, white: true, followed: [])))
    assistTimes.append(measure(iterations) { _ = Vision.scanMinions(frame, geometry: minionGeometry, white: true, followed: []) }.median)

    let patches = Vision.flowPatches(of: frame)
    let panned = translated(frame, dx: 8, dy: -6)
    defer { UnsafeMutableRawPointer(mutating: panned.base).deallocate() }
    let still = Vision.groundShift(from: patches, in: frame).map { "\($0.dx),\($0.dy),\($0.patches)" } ?? "nil"
    let moved = Vision.groundShift(from: patches, in: panned).map { "\($0.dx),\($0.dy),\($0.patches)" } ?? "nil"
    golden.append("flow \(name) still \(still) panned \(moved)")
    flowTimes.append(measure(iterations) { _ = Vision.groundShift(from: patches, in: panned) }.median)

    let sx = Double(frame.width) / 1920, sy = Double(frame.height) / 1080
    let centre = CGPoint(x: Double(frame.width) / 2, y: Double(frame.height) / 2)
    let own = scan.own.min { hypot(Double($0.x) - centre.x, Double($0.y) - centre.y) < hypot(Double($1.x) - centre.x, Double($1.y) - centre.y) }
    let origin = own.map { CGPoint(x: Double($0.x) + Double($0.width) * 0.4, y: Double($0.y) + 200 * sy) } ?? centre
    for ringUnits in [615.0, 665.0, 740.0] {
        let expectedA = 0.63 * sx * ringUnits
        var generator = SeededGenerator(state: UInt64(index * 1000) + UInt64(ringUnits))
        let ring = RangeRingDetector.detect(frame: frame, origin: origin, expectedA: expectedA, ringUnits: ringUnits, screenCentre: centre, now: 0, using: &generator)
        golden.append("ring \(name) units \(Int(ringUnits)) \(describe(ring))")
    }
    ringTimes.append(measure(iterations) {
        var generator = SeededGenerator(state: UInt64(index))
        _ = RangeRingDetector.detect(frame: frame, origin: origin, expectedA: 0.63 * sx * 665, ringUnits: 665, screenCentre: centre, now: 0, using: &generator)
    }.median)

    if let hit = scan.enemies.first {
        let x0 = hit.x - config.boxWidth * 3, y0 = hit.y - Int(34 * sy)
        let width = max(config.barWidth, hit.width) + config.boxWidth * 3, height = hit.y - y0 + hit.height + Int(6 * sy)
        cropTimes.append(measure(iterations) { _ = FrameDump.crop(frame, x: x0, y: y0, width: width, height: height) }.median)
    }
}

var hudReadTimes: [Double] = []
var hudLocateMs: [Double] = []
let asheIcons = ["Q": "AsheQ.png", "W": "Volley.png", "E": "AsheSpiritOfTheHawk.png", "R": "EnchantedCrystalArrow.png"]
let hudSlots = ["Q", "W", "E", "R"]
for name in ["notarget-2026-09-18T13-48-08Z.png", "miss-2026-09-18T13-59-19Z-21.png"] {
    guard let anchor = load(URL(fileURLWithPath: argument("--fixtures") ?? here.path).appendingPathComponent(name)) else { continue }
    defer { UnsafeMutableRawPointer(mutating: anchor.base).deallocate() }
    let hud = AbilityHud()
    let initial = hud.statusText
    let started = DispatchTime.now().uptimeNanoseconds
    _ = hud.read(frame: anchor, champion: "Ashe", icons: asheIcons, slots: hudSlots)
    while hud.statusText == initial, DispatchTime.now().uptimeNanoseconds - started < 30_000_000_000 { usleep(2000) }
    hudLocateMs.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
    let ready = hud.read(frame: anchor, champion: "Ashe", icons: asheIcons, slots: hudSlots)
    golden.append("hud \(name) \(hud.statusText.hasPrefix("HUD: icons not") ? "not located" : "located") ready \(hudSlots.map { "\($0)=\(ready[$0].map { $0 ? "1" : "0" } ?? "?")" }.joined(separator: " "))")
    hudReadTimes.append(measure(iterations * 4) { _ = hud.read(frame: anchor, champion: "Ashe", icons: asheIcons, slots: hudSlots) }.median)
}

func summary(_ label: String, _ values: [Double]) {
    guard !values.isEmpty else { return }
    let sorted = values.sorted()
    let mean = values.reduce(0, +) / Double(values.count)
    print(String(format: "%-28@ frames %3d   median %8.1f µs   mean %8.1f µs   worst %8.1f µs", label as NSString, values.count, sorted[sorted.count / 2], mean, sorted[sorted.count - 1]))
}

golden += minionGolden + assistGolden

print("vision-bench: \(files.count) frames, \(iterations) timed runs each (median per frame, then across frames)")
summary("PixelSearch.scan", scanTimes)
summary("minion bars (while farming)", minionTimes)
summary("minion bars, game assist on", assistTimes)
summary("ground flow (8 patches)", flowTimes)
summary("RangeRingDetector.detect", ringTimes)
summary("name crop (vision thread)", cropTimes)
summary("AbilityHud.read", hudReadTimes)
if !hudLocateMs.isEmpty { print(String(format: "%-28@ frames %3d   median %8.1f ms (background queue)", "AbilityHud icon locate" as NSString, hudLocateMs.count, hudLocateMs.sorted()[hudLocateMs.count / 2])) }

let output = golden.joined(separator: "\n") + "\n"
if let path = argument("--write") {
    try? output.write(toFile: path, atomically: true, encoding: .utf8)
    print("golden output written to \(path) (\(golden.count) lines)")
}
if let path = argument("--check") {
    guard let expected = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("FAIL: cannot read \(path)")
        exit(2)
    }
    let want = expected.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    let differences = zip(want, golden).filter { $0 != $1 }
    if want.count != golden.count || !differences.isEmpty {
        print("FAIL: \(differences.count) of \(golden.count) results differ from \(path) (expected \(want.count) lines)")
        for (old, new) in differences.prefix(10) { print("  was: \(old)\n  now: \(new)") }
        exit(1)
    }
    print("PASS: all \(golden.count) detection results identical to \(path)")
}
