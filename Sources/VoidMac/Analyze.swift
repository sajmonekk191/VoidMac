import AppKit
import Foundation

/** Offline analysis of a dumped PNG: which bars the detector finds, how long a scan takes, and the ground shift to a second PNG. */
enum Analyze {
    private static func load(_ path: String) -> (frame: Frame, buffer: UnsafeMutableRawPointer)? {
        guard let image = NSImage(contentsOfFile: path), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("Cannot load \(path)")
            return nil
        }
        let width = cg.width, height = cg.height, bytesPerRow = width * 4
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bytesPerRow * height, alignment: 64)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let ctx = CGContext(data: buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (Frame(base: UnsafeRawPointer(buffer), width: width, height: height, bytesPerRow: bytesPerRow), buffer)
    }

    /** Locates the champion's ability icons in a dumped frame and prints their availability, exactly as the vision does in-game. */
    static func hud(path: String, champion: String, readPath: String? = nil) {
        guard let loaded = load(path) else { return }
        defer { loaded.buffer.deallocate() }
        var files: [String: String] = [:]
        for slot in ["Q", "W", "E", "R"] { files[slot] = Spells.spec(champion: champion, slot: slot)?.image ?? "" }
        let reader = AbilityHud()
        let initial = reader.statusText
        _ = reader.read(frame: loaded.frame, champion: champion, icons: files, slots: ["Q", "W", "E", "R"])
        let started = nowMs()
        while nowMs() - started < 15000, reader.statusText == initial { sleepMs(50) }
        print(reader.statusText)
        let ready = reader.read(frame: loaded.frame, champion: champion, icons: files, slots: ["Q", "W", "E", "R"])
        print("ready: \(["Q", "W", "E", "R"].map { "\($0) \(ready[$0].map { $0 ? "✓" : "✗" } ?? "?")" }.joined(separator: "  "))")
        print(reader.statusText)
        if let readPath, let other = load(readPath) {
            defer { other.buffer.deallocate() }
            _ = reader.read(frame: other.frame, champion: champion, icons: files, slots: ["Q", "W", "E", "R"])
            print("read \(readPath): \(reader.statusText)")
        }
    }

}
