import AppKit
import Foundation

struct Frame { let base: UnsafeRawPointer; let width: Int; let height: Int; let bytesPerRow: Int }

enum Log {
    static func info(_ m: String) { print("      \(m)") }
    static func warn(_ m: String) { print("      \(m)") }
    static func error(_ m: String) { print("      \(m)") }
}

enum Settings { static let fileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VoidMac/config.json") }

enum SpellData { static let version = "16.18.1" }

/** Virtual clock so the reader's 5 s re-validation gate can be stepped without waiting. */
enum Clock { nonisolated(unsafe) static var ms: Double = 0 }

func nowMs() -> Double { Clock.ms }

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let fixtures = root.appendingPathComponent("fixtures")
let dumps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/VoidMac-frames")
let champion = "Ashe"
let iconFiles = ["Q": "AsheQ.png", "W": "Volley.png", "E": "AsheSpiritOfTheHawk.png", "R": "EnchantedCrystalArrow.png"]
let slots = ["Q", "W", "E", "R"]
let anchorName = "notarget-2026-09-18T13-48-08Z.png"
let qRect = (x: 1450, y: 2140, size: 80)

let expectations: [(file: String, note: String, ready: [String: Bool])] = [
    ("refused-2026-09-18T13-58-58Z-Q.png", "game refused a Q press here", ["Q": false, "W": true, "E": true, "R": true]),
    ("frame-2026-09-18T13-59-37Z-hit-1238-1043.png", "Focus gauge part way up", ["Q": false, "W": true, "E": true, "R": true]),
    ("miss-2026-09-18T13-59-19Z-21.png", "Focus full, Q castable", ["Q": true, "W": true, "E": true, "R": true]),
    (anchorName, "Focus full, Q castable", ["Q": true, "W": true, "E": true, "R": true]),
    ("frame-2026-09-18T14-22-19Z-hit-1556-1131.png", "early game, only Q leveled: the other borders are dark", ["Q": true, "W": false, "E": false, "R": false]),
    ("miss-2026-09-18T14-21-50Z-6.png", "early game, every border dark", ["Q": false, "W": false, "E": false, "R": false]),
]

/** The fixture copy of a dumped frame, taken from the log folder the first time it is needed. */
func fixture(_ name: String) -> String {
    let local = fixtures.appendingPathComponent(name)
    guard !FileManager.default.fileExists(atPath: local.path) else { return local.path }
    try? FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
    guard (try? FileManager.default.copyItem(at: dumps.appendingPathComponent(name), to: local)) != nil else {
        print("FAIL: fixture \(name) is missing and no longer in \(dumps.path)")
        exit(2)
    }
    return local.path
}

func load(_ path: String) -> Frame? {
    guard let image = NSImage(contentsOfFile: path), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let width = cg.width, height = cg.height, bytesPerRow = width * 4
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: bytesPerRow * height, alignment: 64)
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    guard let ctx = CGContext(data: buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info.rawValue) else { return nil }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
    return Frame(base: UnsafeRawPointer(buffer), width: width, height: height, bytesPerRow: bytesPerRow)
}

/** Paints the Q icon flat so its art stops matching the reference while the other three still do. */
func blankQ(_ frame: Frame) {
    let base = UnsafeMutableRawPointer(mutating: frame.base)
    for py in qRect.y..<min(frame.height, qRect.y + qRect.size) {
        let row = base + py * frame.bytesPerRow
        for px in qRect.x..<min(frame.width, qRect.x + qRect.size) {
            row.storeBytes(of: UInt32(0xFF40_4040), toByteOffset: px * 4, as: UInt32.self)
        }
    }
}

/** Paints an icon and the space around it black, so no frame line of any colour is left to find. */
func paintBlack(_ frame: Frame, slot: Int) {
    let base = UnsafeMutableRawPointer(mutating: frame.base)
    let left = max(0, qRect.x + slot * 103 - 6)
    let right = min(frame.width, qRect.x + slot * 103 + qRect.size + 18)
    let top = max(0, qRect.y - 6)
    let bottom = min(frame.height, qRect.y + qRect.size + 18)
    for py in top..<bottom {
        let row = base + py * frame.bytesPerRow
        for px in left..<right { row.storeBytes(of: UInt32(0xFF00_0000), toByteOffset: px * 4, as: UInt32.self) }
    }
}

func mark(_ value: Bool?) -> String { value == nil ? "no reading" : (value! ? "castable" : "not castable") }

let hud = AbilityHud()
var failures: [String] = []

print("HUD reader regression check — champion \(champion), frames 3600x2338")
print("locating icons on \(anchorName)")
guard let anchor = load(fixture(anchorName)) else {
    print("FAIL: cannot read the anchor fixture")
    exit(2)
}
_ = hud.read(frame: anchor, champion: champion, icons: iconFiles, slots: slots)
for _ in 0..<100 where hud.statusText.contains("not located") || hud.statusText.contains("not found") {
    usleep(100_000)
    Clock.ms += 2000
    _ = hud.read(frame: anchor, champion: champion, icons: iconFiles, slots: slots)
}
guard !hud.statusText.contains("not located"), !hud.statusText.contains("not found") else {
    print("FAIL: the icons never located on the anchor frame (\(hud.statusText))")
    exit(1)
}

print("asserting every enabled slot gets a verdict, and that verdict matches the labelled frame")
for expectation in expectations {
    guard let frame = load(fixture(expectation.file)) else {
        failures.append("\(expectation.file): cannot be read")
        continue
    }
    Clock.ms += 6000
    let got = hud.read(frame: frame, champion: champion, icons: iconFiles, slots: slots)
    var shown: [String] = []
    for slot in slots {
        let want = expectation.ready[slot]!
        shown.append("\(slot) \(got[slot] == nil ? "?" : (got[slot]! ? "✓" : "✗"))")
        if got[slot] != want {
            failures.append("\(expectation.file) \(slot): expected \(mark(want)), got \(mark(got[slot]))")
        }
    }
    print("  \(shown.joined(separator: " "))  \(expectation.file) — \(expectation.note)")
}

print("asserting a border that is neither gold nor grey still produces a verdict")
if let dark = load(fixture(anchorName)) {
    paintBlack(dark, slot: 1)
    Clock.ms += 6000
    let got = hud.read(frame: dark, champion: champion, icons: iconFiles, slots: slots)
    if got["W"] == nil {
        failures.append("W painted black: no reading at all; a border with no frame line must read as not castable, otherwise the combo stops firing")
    } else if got["W"] == true {
        failures.append("W painted black: read as castable")
    } else {
        print("  W ✗  its border painted black: still a verdict, not a hole")
    }
} else {
    failures.append("cannot read the anchor fixture for the black-border case")
}

print("asserting a one-slot combo does not make the reader drop its located icons")
guard let blanked = load(fixture(anchorName)) else {
    print("FAIL: cannot read the anchor fixture")
    exit(2)
}
blankQ(blanked)
for round in 1...8 {
    Clock.ms += 6000
    let got = hud.read(frame: blanked, champion: champion, icons: iconFiles, slots: ["Q"])
    if hud.statusText.contains("icons lost") {
        failures.append("Q-only combo, round \(round): the reader dropped the located icons (\(hud.statusText)); re-validation has to score all four icons, not only the enabled ones")
        break
    }
    if got["Q"] == nil {
        failures.append("Q-only combo, round \(round): no Q reading (\(hud.statusText))")
        break
    }
    if round == 8 { print("  8 re-validation rounds on a Q whose art no longer matches: icons kept, Q still read") }
}

guard failures.isEmpty else {
    print("FAIL")
    for failure in failures { print("  - \(failure)") }
    exit(1)
}
print("PASS")
