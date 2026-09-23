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

/** One slot's reading in a frame: castable or not, and the gold share of its frame line. */
struct HudReading: Equatable {
    let slot: String
    let ready: Bool
    let gold: Float
}

/** The reader's state for the panel and the log: a message, or the readings of the last frame (formatted only when shown). */
struct HudStatus: Equatable {
    var message = ""
    var readings: [HudReading] = []

    var text: String {
        guard !readings.isEmpty else { return message }
        return "HUD: " + readings.map { "\($0.slot) \($0.ready ? "✓" : "✗") \(String(format: "%.2f", $0.gold))" }.joined(separator: "  ")
    }
}

/** Reads ability availability from the HUD: the icons are located once per game by matching the Data Dragon images, then the golden frame the HUD draws around castable abilities is checked every frame. */
final class AbilityHud: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "voidmac.hud", qos: .background)
    private var refs: [IconRef] = []
    private var size = 0
    private var pitch = 0
    private var champion = ""
    private var frameSize = (width: 0, height: 0)
    private var ready: [String: Bool] = [:]
    private var locating = false
    private var lastLocateMs = -1e9
    /** Until the icons are found once, the search repeats quickly: while it fails the combo has no cooldown reading at all. */
    private var everLocated = false
    private var lastCheckMs = -1e9
    private var checkFailures = 0
    private var state = HudStatus(message: "HUD: icons not located yet")
    /** The D/F summoner icons, found right of R once Q/W/E/R are located; `summonerMatched` is false while they sit where the layout puts them but no icon confirmed it. */
    private var summonerRefs: [IconRef] = []
    private var summonerSize = 0
    private var summonerPitch = 0
    private var summonerFiles: [String: String] = [:]
    private var summonerMatched = false
    private var summonerLocating = false
    private var summonerAttempts = 0
    private var lastSummonerLocateMs = -1e9

    /** The reader's state, taken under the lock its writers use. */
    var status: HudStatus { lock.withLock { state } }

    var statusText: String { status.text }

    /** Availability of the asked-for slots in this frame (Q/W/E/R, and D/F when their icon files are given), empty until the icons are located; requests a background locate when needed. */
    func read(frame: Frame, champion current: String, icons: [String: String], slots: [String]) -> [String: Bool] {
        guard !current.isEmpty, Self.abilitySlots.allSatisfy({ icons[$0] != nil }), !slots.isEmpty else { return [:] }
        let summonerIcons = icons.filter { Self.summonerSlots.contains($0.key) && !$0.value.isEmpty }
        let located: (refs: [IconRef], size: Int, pitch: Int, ready: [String: Bool], summoners: [IconRef], summonerSize: Int, summonerPitch: Int, summonersCurrent: Bool)? = lock.withLock {
            if champion != current || frameSize.width != frame.width || frameSize.height != frame.height {
                refs = []
                summonerRefs = []
            }
            return refs.isEmpty ? nil : (refs, size, pitch, ready, summonerRefs, summonerSize, summonerPitch, summonerFiles == summonerIcons && (summonerMatched || summonerAttempts >= 5))
        }
        guard let located else {
            requestLocate(frame: frame, champion: current, icons: icons)
            return [:]
        }
        if slots.contains(where: { summonerIcons[$0] != nil }), !located.summonersCurrent {
            requestSummonerLocate(frame: frame, icons: summonerIcons)
        }
        var result: [String: Bool] = [:]
        var readings: [HudReading] = []
        for ref in located.refs + located.summoners where slots.contains(ref.slot) {
            let summoner = Self.summonerSlots.contains(ref.slot)
            let gold = Self.frameLine(frame: frame, x: ref.x, y: ref.y, size: summoner ? located.summonerSize : located.size, pitch: summoner ? located.summonerPitch : located.pitch).gold
            let available = gold >= 0.9 ? true : (gold <= 0.85 ? false : (located.ready[ref.slot] ?? false))
            result[ref.slot] = available
            readings.append(HudReading(slot: ref.slot, ready: available, gold: gold))
        }
        let now = nowMs()
        var lost = false
        if now - lastCheckMs > 5000 {
            lastCheckMs = now
            let size = located.size
            let bestMatch = located.refs.map { Self.ncc(Self.resample(frame: frame, x: $0.x, y: $0.y, width: size, height: size, toWidth: size, toHeight: size), $0.gray) }.max() ?? 0
            if bestMatch < 0.3 { checkFailures += 1 } else { checkFailures = 0 }
            lost = checkFailures >= 6
        }
        lock.withLock {
            ready = result
            state.readings = readings
            if lost {
                refs = []
                summonerRefs = []
                checkFailures = 0
                state = HudStatus(message: "HUD: icons lost, locating again")
            }
        }
        return result
    }

    static let abilitySlots = ["Q", "W", "E", "R"]
    static let summonerSlots = ["D", "F"]

    /** Finds the D/F icons right of R on the background queue, once per game; until an icon confirms them they sit where the HUD layout puts them and the search repeats every 4 s, five times at most. */
    private func requestSummonerLocate(frame: Frame, icons: [String: String]) {
        let now = nowMs()
        let anchor: (x: Int, y: Int, size: Int, pitch: Int)? = lock.withLock {
            guard !summonerLocating, now - lastSummonerLocateMs > 4000, let r = refs.first(where: { $0.slot == "R" }) else { return nil }
            summonerLocating = true
            lastSummonerLocateMs = now
            return (r.x, r.y, size, pitch)
        }
        guard let anchor else { return }
        let x0 = min(frame.width - 1, anchor.x + anchor.size / 2), x1 = min(frame.width, anchor.x + anchor.size + 4 * anchor.pitch)
        let y0 = max(0, anchor.y - anchor.size / 2), y1 = min(frame.height, anchor.y + anchor.size * 3 / 2)
        guard x1 - x0 > anchor.size, y1 - y0 > anchor.size else {
            lock.withLock { summonerLocating = false }
            return
        }
        let width = x1 - x0, height = y1 - y0, bytesPerRow = width * 4
        let copy = UnsafeMutableRawPointer.allocate(byteCount: bytesPerRow * height, alignment: 16)
        for row in 0..<height {
            copy.advanced(by: row * bytesPerRow).copyMemory(from: frame.base + (y0 + row) * frame.bytesPerRow + x0 * 4, byteCount: bytesPerRow)
        }
        let region = Frame(base: UnsafeRawPointer(copy), width: width, height: height, bytesPerRow: bytesPerRow)
        let box = StripBox(pointer: copy)
        queue.async {
            defer { _ = box }
            let found = Self.locateSummoners(region: region, origin: (x0, y0), anchor: anchor, icons: icons)
            self.lock.withLock {
                self.summonerLocating = false
                guard self.refs.first(where: { $0.slot == "R" })?.x == anchor.x else { return }
                self.summonerAttempts = self.summonerFiles == icons ? self.summonerAttempts + 1 : 1
                self.summonerRefs = found.refs
                self.summonerSize = found.size
                self.summonerPitch = found.pitch
                self.summonerFiles = icons
                self.summonerMatched = found.matched
            }
            Log.info("HUD summoner icons \(found.matched ? "located" : "placed by the HUD layout"): size \(found.size) px, pitch \(found.pitch) px, \(found.note), rects \(found.refs.map { "\($0.slot)(\($0.x),\($0.y))" }.joined(separator: " "))")
        }
    }

    /** D/F icon rects in frame px, measured on both HUD sizes: D's inner rect starts 1.33-1.35 ability sizes right of R and F's 2.23-2.33, both 0.74-0.78 of its size and level with it, D to F 1.21-1.24 of their own size. Each icon is matched only in its own slot's window (one icon can look like the other), a missing one is placed from the other, both from R when neither matches. */
    private static func locateSummoners(region: Frame, origin: (x: Int, y: Int), anchor: (x: Int, y: Int, size: Int, pitch: Int), icons: [String: String]) -> (refs: [IconRef], size: Int, pitch: Int, matched: Bool, note: String) {
        let plane = GrayPlane(region)
        var found: [String: Anchor] = [:]
        var notes: [String] = []
        let windows = ["D": (120, 150), "F": (205, 255)]
        for slot in summonerSlots {
            guard let file = icons[slot], let window = windows[slot], let art = loadIcon(file) else { continue }
            defer { UnsafeMutableRawPointer(mutating: art.base).deallocate() }
            var best = Anchor(score: -1, x: 0, y: 0, size: 0)
            let smallest = anchor.size * 66 / 100, largest = anchor.size * 86 / 100
            let xs = max(0, anchor.x + anchor.size * window.0 / 100 - origin.x), ys = max(0, anchor.y - origin.y - 10)
            var size = smallest
            while size <= largest {
                let xe = min(region.width - size - 8, anchor.x + anchor.size * window.1 / 100 - origin.x), ye = min(region.height - size - 1, anchor.y - origin.y + 10)
                if xe >= xs, ye >= ys {
                    plane.search(template: resample(icon: art, to: size), xs: xs...xe, ys: ys...ye, best: &best)
                }
                size += max(1, anchor.size / 30)
            }
            notes.append("\(slot) \(file) \(String(format: "%.2f", best.score))")
            if best.score >= 0.5 { found[slot] = best }
        }
        let size = found.isEmpty ? max(8, anchor.size * 76 / 100) : found.values.map(\.size).reduce(0, +) / found.count
        let pitch = max(size + 4, size * 122 / 100)
        var d: (x: Int, y: Int)
        if let hit = found["D"] {
            d = (origin.x + hit.x, origin.y + hit.y)
        } else if let hit = found["F"] {
            d = (origin.x + hit.x - pitch, origin.y + hit.y)
        } else {
            d = (anchor.x + anchor.size * 134 / 100, anchor.y)
        }
        var f = (x: d.x + pitch, y: d.y)
        if let hit = found["F"], found["D"] != nil {
            f = (origin.x + hit.x, origin.y + hit.y)
        }
        let refs = [IconRef(slot: "D", x: d.x, y: d.y, gray: Patch(width: 0, height: 0, values: [])),
                    IconRef(slot: "F", x: f.x, y: f.y, gray: Patch(width: 0, height: 0, values: []))]
        return (refs, size, max(size + 4, f.x - d.x), !found.isEmpty, notes.isEmpty ? "no summoner icon files" : "match " + notes.joined(separator: ", "))
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
                    self.summonerRefs = []
                    self.summonerMatched = false
                    self.summonerAttempts = 0
                    self.lastSummonerLocateMs = -1e9
                    self.size = found.size
                    self.pitch = found.pitch
                    self.champion = current
                    self.frameSize = (frame.width, fullHeight)
                    self.ready = [:]
                    self.state = HudStatus(message: "HUD: icons located (\(found.size) px, match \(String(format: "%.2f", found.score)))")
                    Log.info("HUD icons located: size \(found.size) px, pitch \(found.pitch) px, match \(String(format: "%.2f", found.score)), rects \(found.refs.map { "\($0.slot)(\($0.x),\($0.y))" }.joined(separator: " "))")
                } else {
                    self.state = HudStatus(message: "HUD: icons not found, retrying")
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

    /** Coarse search of every icon over the middle of the strip at 1/6 scale, fine search around each anchor at full scale, then the pitch that fits all four icons best. */
    private static func locate(strip: Frame, stripY: Int, fullHeight: Int, icons: [String: String]) -> (refs: [IconRef], size: Int, pitch: Int, score: Float)? {
        var arts: [Frame] = []
        defer { for art in arts { UnsafeMutableRawPointer(mutating: art.base).deallocate() } }
        for slot in ["Q", "W", "E", "R"] {
            guard let art = loadIcon(icons[slot] ?? "") else { return nil }
            arts.append(art)
        }
        let k = 6
        let x0 = strip.width / 4
        let coarse = resample(frame: strip, x: x0, y: 0, width: strip.width / 2, height: strip.height, toWidth: strip.width / 2 / k, toHeight: strip.height / k)
        var anchors = [Anchor](repeating: Anchor(score: -1, x: 0, y: 0, size: 0), count: 4)
        var candidate = Int(Double(fullHeight) * 0.022)
        var searched = 0
        while candidate <= Int(Double(fullHeight) * 0.064) {
            let templateSize = max(8, candidate / k)
            if templateSize != searched {
                searched = templateSize
                searchCoarse(coarse, templates: arts.map { resample(icon: $0, to: templateSize) }, candidate: candidate, anchors: &anchors)
            }
            candidate += max(2, fullHeight / 900)
        }
        let plane = GrayPlane(strip)
        var best: (total: Float, single: Float, x: Int, y: Int, size: Int, pitch: Int) = (-1, 0, 0, 0, 0, 0)
        for (slot, anchor) in anchors.enumerated() where anchor.score >= 0.5 {
            let ax = x0 + anchor.x * k, ay = anchor.y * k
            var fine = Anchor(score: -1, x: 0, y: 0, size: 0)
            for size in (anchor.size - 6)...(anchor.size + 6) where size >= 12 {
                plane.search(template: resample(icon: arts[slot], to: size), xs: max(0, ax - 8)...(ax + 8), ys: max(0, ay - 8)...(ay + 8), best: &fine)
            }
            guard fine.score >= 0.6 else { continue }
            let size = fine.size
            let templates = arts.map { resample(icon: $0, to: size) }
            let sums = templates.map(templateSums)
            for pitch in (size * 115 / 100)...(size * 135 / 100) {
                let start = fine.x - slot * pitch
                guard start >= 0, start + 3 * pitch + size < strip.width else { continue }
                for y in max(0, fine.y - 8)...(fine.y + 8) where y + size < strip.height {
                    var total: Float = 0
                    var single: Float = 0
                    for i in 0..<4 {
                        let score = plane.ncc(x: start + i * pitch, y: y, template: templates[i], sums: sums[i])
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

    /** Best match so far of one icon: score, top-left and the icon size in frame px. */
    private struct Anchor {
        var score: Float
        var x: Int
        var y: Int
        var size: Int
    }

    /** Scores the four templates at every coarse offset, eight neighbouring offsets per pass with the window sums shared; each lane adds in `ncc`'s order, so the scores match it bit for bit. */
    private static func searchCoarse(_ image: Patch, templates: [Patch], candidate: Int, anchors: inout [Anchor]) {
        let side = templates[0].width
        let columns = max(0, image.width - side), rows = max(0, image.height - side)
        guard columns > 0, rows > 0 else { return }
        let n = Float(side * side)
        let sums = templates.map(templateSums)
        let values = image.values + [Float](repeating: 0, count: 8)
        let weights = templates.flatMap(\.values)
        let plane = side * side
        values.withUnsafeBufferPointer { pixels in
            weights.withUnsafeBufferPointer { weight in
                let base = UnsafeRawPointer(pixels.baseAddress!)
                for y in 0..<rows {
                    var x = 0
                    while x < columns {
                        var sa = SIMD8<Float>(), saa = SIMD8<Float>()
                        var sab0 = SIMD8<Float>(), sab1 = SIMD8<Float>(), sab2 = SIMD8<Float>(), sab3 = SIMD8<Float>()
                        for r in 0..<side {
                            let row = ((y + r) * image.width + x) * MemoryLayout<Float>.stride
                            let t = r * side
                            for c in 0..<side {
                                let a = base.loadUnaligned(fromByteOffset: row + c * MemoryLayout<Float>.stride, as: SIMD8<Float>.self)
                                sa += a
                                saa += a * a
                                sab0 += a * weight[t + c]
                                sab1 += a * weight[plane + t + c]
                                sab2 += a * weight[2 * plane + t + c]
                                sab3 += a * weight[3 * plane + t + c]
                            }
                        }
                        let va = saa - sa * sa / n
                        let lanes = min(8, columns - x)
                        func keep(_ slot: Int, _ sab: SIMD8<Float>) {
                            let cov = sab - sa * sums[slot].sb / n
                            let vb = sums[slot].sbb - sums[slot].sb * sums[slot].sb / n
                            for lane in 0..<lanes {
                                let score = va[lane] > 1 && vb > 1 ? cov[lane] / (va[lane] * vb).squareRoot() : 0
                                if score > anchors[slot].score { anchors[slot] = Anchor(score: score, x: x + lane, y: y, size: candidate) }
                            }
                        }
                        keep(0, sab0)
                        keep(1, sab1)
                        keep(2, sab2)
                        keep(3, sab3)
                        x += 8
                    }
                }
            }
        }
    }

    /** Template sums for `ncc`, accumulated in its order. */
    private static func templateSums(_ template: Patch) -> (sb: Float, sbb: Float) {
        var sb: Float = 0, sbb: Float = 0
        for b in template.values {
            sb += b
            sbb += b * b
        }
        return (sb, sbb)
    }

    /** Full-resolution grayscale of the strip (the values a 1:1 `resample` yields) with spare zeros after the last row for eight-lane loads. */
    private struct GrayPlane {
        let width: Int
        let height: Int
        let values: [Float]

        init(_ frame: Frame) {
            width = frame.width
            height = frame.height
            var values = [Float](repeating: 0, count: frame.width * frame.height + 64)
            values.withUnsafeMutableBufferPointer { plane in
                for y in 0..<frame.height {
                    let row = frame.base + y * frame.bytesPerRow
                    for x in 0..<frame.width {
                        let p = row.load(fromByteOffset: x * 4, as: UInt32.self)
                        plane[y * frame.width + x] = Float((Int((p >> 16) & 0xFF) * 299 + Int((p >> 8) & 0xFF) * 587 + Int(p & 0xFF) * 114) / 1000)
                    }
                }
            }
            self.values = values
        }

        /** `ncc` of the template against the plane at one offset. */
        func ncc(x: Int, y: Int, template: Patch, sums: (sb: Float, sbb: Float)) -> Float {
            var sa: Float = 0, saa: Float = 0, sab: Float = 0
            values.withUnsafeBufferPointer { plane in
                template.values.withUnsafeBufferPointer { weight in
                    for r in 0..<template.height {
                        let row = (y + r) * width + x, t = r * template.width
                        for c in 0..<template.width {
                            let a = plane[row + c], b = weight[t + c]
                            sa += a
                            saa += a * a
                            sab += a * b
                        }
                    }
                }
            }
            let n = Float(template.width * template.height)
            let cov = sab - sa * sums.sb / n, va = saa - sa * sa / n, vb = sums.sbb - sums.sb * sums.sb / n
            return va > 1 && vb > 1 ? cov / (va * vb).squareRoot() : 0
        }

        /** Scores the template at every offset in the ranges that fits the plane, row by row and eight columns per pass, keeping the first best in scan order. */
        func search(template: Patch, xs: ClosedRange<Int>, ys: ClosedRange<Int>, best: inout Anchor) {
            let side = template.width
            let n = Float(side * side)
            let sums = AbilityHud.templateSums(template)
            let vb = sums.sbb - sums.sb * sums.sb / n
            values.withUnsafeBufferPointer { pixels in
                template.values.withUnsafeBufferPointer { weight in
                    let base = UnsafeRawPointer(pixels.baseAddress!)
                    for y in ys where y + side < height {
                        var x = xs.lowerBound
                        while x <= xs.upperBound {
                            var sa = SIMD8<Float>(), saa = SIMD8<Float>(), sab = SIMD8<Float>()
                            for r in 0..<side {
                                let row = ((y + r) * width + x) * MemoryLayout<Float>.stride
                                let t = r * side
                                for c in 0..<side {
                                    let a = base.loadUnaligned(fromByteOffset: row + c * MemoryLayout<Float>.stride, as: SIMD8<Float>.self)
                                    sa += a
                                    saa += a * a
                                    sab += a * weight[t + c]
                                }
                            }
                            let cov = sab - sa * sums.sb / n, va = saa - sa * sa / n
                            for lane in 0..<8 where x + lane <= xs.upperBound && x + lane + side < width {
                                let score = va[lane] > 1 && vb > 1 ? cov[lane] / (va[lane] * vb).squareRoot() : 0
                                if score > best.score { best = Anchor(score: score, x: x + lane, y: y, size: side) }
                            }
                            x += 8
                        }
                    }
                }
            }
        }
    }

    /** The icon's frame line right of the inner rect, searched from −10 px to at most half the gap to the next icon (never past +14) so the locate's pitch error does not matter without ever reading the neighbour's border; only the vertical border is read, because the line under the icon is gold even on an ability that cannot be cast (Ashe's Focus gauge). */
    private static func frameLine(frame: Frame, x: Int, y: Int, size: Int, pitch: Int) -> (frame: Float, gold: Float) {
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
        let reach = min(14, max(0, (pitch - size) / 2))
        for offset in -10...reach {
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
