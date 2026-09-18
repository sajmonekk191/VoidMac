import AppKit
import CoreGraphics
import Foundation

/** Grayscale patch used for template matching. */
private struct Patch {
    var width: Int
    var height: Int
    var values: [Float]
}

/** Where one ability icon sits in the frame, with the reference icon at that size for re-validation. */
private struct IconRef {
    var slot: String
    var x: Int
    var y: Int
    var gray: Patch
}

/** Reads ability availability from the HUD: the icons are located once per game by matching the Data Dragon images, then the golden frame the HUD draws around castable abilities is checked every frame. */
final class AbilityHud: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "voidmac.hud", qos: .background)
    private var refs: [IconRef] = []
    private var size = 0
    private var champion = ""
    private var frameSize = (width: 0, height: 0)
    private var ready: [String: Bool] = [:]
    private var locating = false
    private var lastLocateMs = -1e9
    /** Until the icons are found once, the search repeats quickly: while it fails the combo has no cooldown reading at all. */
    private var everLocated = false
    private var lastCheckMs = -1e9
    private var checkFailures = 0
    private var statusStorage = "HUD: icons not located yet"

    /** The reader's own words for the panel; taken under the lock its writers use. */
    var statusText: String { lock.withLock { statusStorage } }

    /** Availability of the asked-for slots in this frame, empty until the icons are located; requests a background locate when needed. */
    func read(frame: Frame, champion current: String, icons: [String: String], slots: [String]) -> [String: Bool] {
        guard !current.isEmpty, icons.count == 4, !slots.isEmpty else { return [:] }
        let known: [IconRef]? = lock.withLock {
            if champion != current || frameSize.width != frame.width || frameSize.height != frame.height { refs = [] }
            return refs.isEmpty ? nil : refs
        }
        guard let known else {
            requestLocate(frame: frame, champion: current, icons: icons)
            return [:]
        }
        let checked = known.filter { slots.contains($0.slot) }
        var result: [String: Bool] = [:]
        var parts: [String] = []
        for ref in checked {
            let line = Self.frameLine(frame: frame, x: ref.x, y: ref.y, size: size)
            let previous = lock.withLock { ready[ref.slot] }
            let available = line.gold >= 0.9 ? true : (line.gold <= 0.85 ? false : (previous ?? false))
            result[ref.slot] = available
            parts.append("\(ref.slot) \(available ? "✓" : "✗") \(String(format: "%.2f", line.gold))")
        }
        let now = nowMs()
        var lost = false
        if now - lastCheckMs > 5000 {
            lastCheckMs = now
            let bestMatch = known.map { Self.ncc(Self.resample(frame: frame, x: $0.x, y: $0.y, width: size, height: size, toWidth: size, toHeight: size), $0.gray) }.max() ?? 0
            if bestMatch < 0.3 { checkFailures += 1 } else { checkFailures = 0 }
            lost = checkFailures >= 6
        }
        lock.withLock {
            ready = result
            statusStorage = "HUD: " + parts.joined(separator: "  ")
            if lost {
                refs = []
                checkFailures = 0
                statusStorage = "HUD: icons lost, locating again"
            }
        }
        return result
    }

    private func requestLocate(frame: Frame, champion current: String, icons: [String: String]) {
        let now = nowMs()
        let go: Bool = lock.withLock {
            guard !locating, now - lastLocateMs > (everLocated ? 5000 : 1200) else { return false }
            locating = true
            lastLocateMs = now
            return true
        }
        guard go else { return }
        let stripY = frame.height * 76 / 100
        let stripHeight = frame.height - stripY
        let bytes = stripHeight * frame.bytesPerRow
        let copy = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
        copy.copyMemory(from: frame.base + stripY * frame.bytesPerRow, byteCount: bytes)
        let strip = Frame(base: UnsafeRawPointer(copy), width: frame.width, height: stripHeight, bytesPerRow: frame.bytesPerRow)
        let fullHeight = frame.height
        let box = StripBox(pointer: copy)
        queue.async {
            defer { _ = box }
            let found = Self.locate(strip: strip, stripY: stripY, fullHeight: fullHeight, icons: icons)
            self.lock.withLock {
                self.locating = false
                if let found {
                    self.everLocated = true
                    self.refs = found.refs
                    self.size = found.size
                    self.champion = current
                    self.frameSize = (frame.width, fullHeight)
                    self.ready = [:]
                    self.statusStorage = "HUD: ikony nalezeny (\(found.size) px, shoda \(String(format: "%.2f", found.score)))"
                    Log.info("HUD icons located: size \(found.size) px, pitch \(found.pitch) px, match \(String(format: "%.2f", found.score)), rects \(found.refs.map { "\($0.slot)(\($0.x),\($0.y))" }.joined(separator: " "))")
                } else {
                    self.statusStorage = "HUD: icons not found, retrying"
                }
            }
        }
    }

    /** Keeps the strip copy alive until the locate finishes. */
    private final class StripBox: @unchecked Sendable {
        let pointer: UnsafeMutableRawPointer
        init(pointer: UnsafeMutableRawPointer) { self.pointer = pointer }
        deinit { pointer.deallocate() }
    }

    private static func locate(strip: Frame, stripY: Int, fullHeight: Int, icons: [String: String]) -> (refs: [IconRef], size: Int, pitch: Int, score: Float)? {
        guard let q = loadIcon(icons["Q"] ?? ""), let w = loadIcon(icons["W"] ?? ""), let e = loadIcon(icons["E"] ?? ""), let r = loadIcon(icons["R"] ?? "") else { return nil }
        let arts = [q, w, e, r]
        let k = 6
        let x0 = strip.width / 4
        let coarse = resample(frame: strip, x: x0, y: 0, width: strip.width / 2, height: strip.height, toWidth: strip.width / 2 / k, toHeight: strip.height / k)
        var anchors = [(score: Float, x: Int, y: Int, size: Int)](repeating: (-1, 0, 0, 0), count: 4)
        var candidate = Int(Double(fullHeight) * 0.022)
        while candidate <= Int(Double(fullHeight) * 0.064) {
            let ts = max(8, candidate / k)
            for slot in 0..<4 {
                let template = resample(icon: arts[slot], to: ts)
                for y in 0..<max(0, coarse.height - ts) {
                    for x in 0..<max(0, coarse.width - ts) {
                        let score = ncc(coarse, template, atX: x, atY: y)
                        if score > anchors[slot].score { anchors[slot] = (score, x, y, candidate) }
                    }
                }
            }
            candidate += max(2, fullHeight / 900)
        }
        var best: (total: Float, single: Float, x: Int, y: Int, size: Int, pitch: Int) = (-1, 0, 0, 0, 0, 0)
        for (slot, anchor) in anchors.enumerated() where anchor.score >= 0.5 {
            let ax = x0 + anchor.x * k, ay = anchor.y * k
            var fine: (score: Float, x: Int, y: Int, size: Int) = (-1, 0, 0, 0)
            for size in (anchor.size - 6)...(anchor.size + 6) where size >= 12 {
                let template = resample(icon: arts[slot], to: size)
                for y in max(0, ay - 8)...(ay + 8) {
                    for x in max(0, ax - 8)...(ax + 8) where x + size < strip.width && y + size < strip.height {
                        let score = ncc(resample(frame: strip, x: x, y: y, width: size, height: size, toWidth: size, toHeight: size), template, atX: 0, atY: 0)
                        if score > fine.score { fine = (score, x, y, size) }
                    }
                }
            }
            guard fine.score >= 0.6 else { continue }
            let size = fine.size
            let templates = arts.map { resample(icon: $0, to: size) }
            for pitch in (size * 115 / 100)...(size * 135 / 100) {
                let start = fine.x - slot * pitch
                guard start >= 0, start + 3 * pitch + size < strip.width else { continue }
                for y in max(0, fine.y - 8)...(fine.y + 8) where y + size < strip.height {
                    var total: Float = 0
                    var single: Float = 0
                    for i in 0..<4 {
                        let score = ncc(resample(frame: strip, x: start + i * pitch, y: y, width: size, height: size, toWidth: size, toHeight: size), templates[i], atX: 0, atY: 0)
                        total += score
                        if score > single { single = score }
                    }
                    if total > best.total { best = (total, single, start, y, size, pitch) }
                }
            }
        }
        guard best.total >= 1.8, best.single >= 0.6 else { return nil }
        let templates = arts.map { resample(icon: $0, to: best.size) }
        var refs: [IconRef] = []
        for (i, slot) in ["Q", "W", "E", "R"].enumerated() {
            refs.append(IconRef(slot: slot, x: best.x + i * best.pitch, y: stripY + best.y, gray: templates[i]))
        }
        return (refs, best.size, best.pitch, best.total / 4)
    }

    /** The icon's frame line right of the inner rect, searched within −10…+14 px so the locate's pitch error does not matter; only the vertical border is read, because the line under the icon is gold even on an ability that cannot be cast (Ashe's Focus gauge). */
    private static func frameLine(frame: Frame, x: Int, y: Int, size: Int) -> (frame: Float, gold: Float) {
        let inset = max(6, size / 8)
        @inline(__always) func classify(_ px: Int, _ py: Int) -> (gold: Bool, grey: Bool) {
            guard px >= 0, py >= 0, px < frame.width, py < frame.height else { return (false, false) }
            let p = (frame.base + py * frame.bytesPerRow + px * 4).load(as: UInt32.self)
            let r = Int((p >> 16) & 0xFF), g = Int((p >> 8) & 0xFF), b = Int(p & 0xFF)
            let hi = max(r, g, b), lo = min(r, g, b)
            let gold = r >= 0x55 && g >= 0x34 && g <= r - 0x10 && b <= g - 0x10 && r - b >= 0x38
            let grey = hi >= 0x30 && hi <= 0x90 && hi - lo <= 0x22
            return (gold, grey)
        }
        let length = Float(max(1, size - 2 * inset))
        var best: (frame: Float, gold: Float) = (0, 0)
        for offset in -10...14 {
            var gold = 0, framed = 0
            for t in inset..<(size - inset) {
                let border = classify(x + size - 1 + offset, y + t)
                if border.gold { gold += 1; framed += 1 } else if border.grey { framed += 1 }
            }
            let candidate = (frame: Float(framed) / length, gold: Float(gold) / length)
            if candidate.gold > best.gold || (candidate.gold == best.gold && candidate.frame > best.frame) { best = candidate }
        }
        return best
    }

    private static func loadIcon(_ file: String) -> Frame? {
        guard !file.isEmpty else { return nil }
        let local = Settings.fileURL.deletingLastPathComponent().appendingPathComponent("icons/spell_\(file)")
        var data = try? Data(contentsOf: local)
        if data == nil, let remote = URL(string: "https://ddragon.leagueoflegends.com/cdn/\(SpellData.version)/img/spell/\(file)"), let downloaded = try? Data(contentsOf: remote) {
            data = downloaded
            try? FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? downloaded.write(to: local)
        }
        guard let data, let image = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = image.width, height = image.height, bytesPerRow = width * 4
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bytesPerRow * height, alignment: 16)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let context = CGContext(data: buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info.rawValue) else {
            buffer.deallocate()
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Frame(base: UnsafeRawPointer(buffer), width: width, height: height, bytesPerRow: bytesPerRow)
    }

    private static func resample(icon: Frame, to size: Int) -> Patch {
        resample(frame: icon, x: 0, y: 0, width: icon.width, height: icon.height, toWidth: size, toHeight: size)
    }

    /** Box-filtered grayscale of a frame region scaled to the requested size. */
    private static func resample(frame: Frame, x: Int, y: Int, width: Int, height: Int, toWidth: Int, toHeight: Int) -> Patch {
        var values = [Float](repeating: 0, count: toWidth * toHeight)
        for dy in 0..<toHeight {
            let sy0 = y + dy * height / toHeight
            let sy1 = min(frame.height, max(sy0 + 1, y + (dy + 1) * height / toHeight))
            for dx in 0..<toWidth {
                let sx0 = x + dx * width / toWidth
                let sx1 = min(frame.width, max(sx0 + 1, x + (dx + 1) * width / toWidth))
                var sum = 0, count = 0
                var yy = sy0
                while yy < sy1 {
                    let row = frame.base + yy * frame.bytesPerRow
                    var xx = sx0
                    while xx < sx1 {
                        let p = row.load(fromByteOffset: xx * 4, as: UInt32.self)
                        sum += (Int((p >> 16) & 0xFF) * 299 + Int((p >> 8) & 0xFF) * 587 + Int(p & 0xFF) * 114) / 1000
                        count += 1
                        xx += 1
                    }
                    yy += 1
                }
                values[dy * toWidth + dx] = count > 0 ? Float(sum) / Float(count) : 0
            }
        }
        return Patch(width: toWidth, height: toHeight, values: values)
    }

    /** Normalized cross-correlation of the template against the patch at an offset. */
    private static func ncc(_ patch: Patch, _ template: Patch, atX: Int, atY: Int) -> Float {
        var sa: Float = 0, sb: Float = 0, saa: Float = 0, sbb: Float = 0, sab: Float = 0
        let n = Float(template.width * template.height)
        for y in 0..<template.height {
            let rowA = (atY + y) * patch.width + atX
            let rowB = y * template.width
            for x in 0..<template.width {
                let a = patch.values[rowA + x], b = template.values[rowB + x]
                sa += a
                sb += b
                saa += a * a
                sbb += b * b
                sab += a * b
            }
        }
        let cov = sab - sa * sb / n, va = saa - sa * sa / n, vb = sbb - sb * sb / n
        return va > 1 && vb > 1 ? cov / (va * vb).squareRoot() : 0
    }

    private static func ncc(_ patch: Patch, _ template: Patch) -> Float {
        ncc(patch, template, atX: 0, atY: 0)
    }
}
