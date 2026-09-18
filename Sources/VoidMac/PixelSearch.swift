import Foundation

struct PixelRect {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
}

/** One detected bar: `x`/`y` is the top-left of the fill, `width` the whole bar frame, `fill` the red or green run (0 for an empty bar). */
struct PixelHit: Equatable {
    let x: Int
    let y: Int
    var width = 0
    var height = 0
    var fill = 0

    var fillRatio: Double { width > 0 ? min(1, Double(fill) / Double(width)) : 0 }
}

/** Bar size limits scaled to the captured frame; `barWidth` is the fixed width of a champion bar frame. */
struct DetectionConfig {
    var minHeight: Int
    var maxHeight: Int
    var maxRun: Int
    var barWidth: Int
    var boxWidth: Int
    var minFrameWidth: Int
    var rowStride: Int
}

/** Enemy champion bars and the own bar. */
struct ScanResult {
    var enemies: [PixelHit] = []
    var own: [PixelHit] = []
}

/** One strided pass over the frame: enemy champion bars (red fill with level box and outline, or the level box alone when the fill is empty) and the own green bar. */
enum PixelSearch {
    private static let rgbMask: UInt32 = 0x00FF_FFFF
    private static let redMask = SIMD16<UInt32>(repeating: 0x0080_C0C0)
    private static let redValue = SIMD16<UInt32>(repeating: 0x0080_0000)
    private static let greenMask = SIMD16<UInt32>(repeating: 0x00C0_80C0)
    private static let greenValue = SIMD16<UInt32>(repeating: 0x0000_8000)
    private static let boxMask = SIMD16<UInt32>(repeating: 0x0080_F0F0)
    private static let boxBits = SIMD16<UInt32>(repeating: 0x0060_0000)
    private static let zero = SIMD16<UInt32>(repeating: 0)

    private struct RowHits {
        var fills: [PixelHit] = []
        var boxes: [PixelHit] = []
        var own: [PixelHit] = []
    }

    static func scan(_ frame: Frame, rect requested: PixelRect, config: DetectionConfig, limit: Int = 24) -> ScanResult {
        guard let rect = clamp(requested, to: frame) else { return ScanResult() }
        var rows = RowHits()
        var y = rect.y
        while y < rect.y + rect.height, rows.fills.count < limit * 8 {
            scanRow(frame, rect: rect, y: y, config: config, into: &rows)
            y += config.rowStride
        }
        var result = ScanResult(enemies: deduped(rows.fills, config: config, limit: limit), own: deduped(rows.own, config: config, limit: 4))
        for box in deduped(rows.boxes, config: config, limit: limit) where result.enemies.count < limit && !result.enemies.contains(where: { near($0, box, config) }) {
            result.enemies.append(box)
        }
        return result
    }

    private static func clamp(_ requested: PixelRect, to frame: Frame) -> PixelRect? {
        var rect = requested
        rect.x = max(1, rect.x)
        rect.y = max(1, rect.y)
        rect.width = min(rect.width, frame.width - rect.x - 1)
        rect.height = min(rect.height, frame.height - rect.y - 1)
        guard rect.width > 1, rect.height > 1 else { return nil }
        return rect
    }

    @inline(__always)
    private static func near(_ a: PixelHit, _ b: PixelHit, _ config: DetectionConfig) -> Bool {
        abs(a.x - b.x) <= config.maxRun && abs(a.y - b.y) <= config.maxHeight * 2
    }

    /** Collapses the rows a bar was detected on into one hit (the topmost row). */
    private static func deduped(_ hits: [PixelHit], config: DetectionConfig, limit: Int) -> [PixelHit] {
        var out: [PixelHit] = []
        for hit in hits where !out.contains(where: { near($0, hit, config) }) {
            out.append(hit)
            if out.count >= limit { break }
        }
        return out
    }

    @inline(__always)
    private static func pixel(_ frame: Frame, _ x: Int, _ y: Int) -> UInt32 {
        (frame.base + y * frame.bytesPerRow + x * 4).load(as: UInt32.self) & rgbMask
    }

    @inline(__always)
    static func isEnemyRed(_ p: UInt32) -> Bool {
        let r = Int((p >> 16) & 0xFF), g = Int((p >> 8) & 0xFF), b = Int(p & 0xFF)
        return r >= 130 && g <= 55 && b <= 55 && r - max(g, b) >= 90
    }

    /** The whole enemy fill including its lighter top band, used for the bar's true top and height. */
    @inline(__always)
    private static func isBarRed(_ p: UInt32) -> Bool {
        let r = Int((p >> 16) & 0xFF), g = Int((p >> 8) & 0xFF), b = Int(p & 0xFF)
        return r >= 0xA0 && g <= 0x70 && b <= 0x70 && r - max(g, b) >= 0x60
    }

    @inline(__always)
    static func isSelfGreen(_ p: UInt32) -> Bool {
        let r = Int((p >> 16) & 0xFF), g = Int((p >> 8) & 0xFF), b = Int(p & 0xFF)
        return g >= 0x80 && r <= 0x3F && b <= 0x3F && g - max(r, b) >= 0x50
    }

    @inline(__always)
    private static func isDark(_ p: UInt32) -> Bool {
        ((p >> 16) & 0xFF) <= 96 && ((p >> 8) & 0xFF) <= 96 && (p & 0xFF) <= 96
    }

    @inline(__always)
    private static func isBarBackground(_ p: UInt32) -> Bool {
        let r = Int((p >> 16) & 0xFF), g = Int((p >> 8) & 0xFF), b = Int(p & 0xFF)
        return max(r, g, b) <= 0x50 && g <= r + 8 && b <= r + 10
    }

    /** Pure dark-red interior of an enemy level box. */
    @inline(__always)
    private static func isBoxInterior(_ p: UInt32) -> Bool {
        let r = Int((p >> 16) & 0xFF), g = Int((p >> 8) & 0xFF), b = Int(p & 0xFF)
        return r >= 0x20 && r <= 0x68 && g <= 0x14 && b <= 0x14
    }

    /** Dark teal interior of the own level box. */
    @inline(__always)
    private static func isSelfBoxPixel(_ p: UInt32) -> Bool {
        let r = Int((p >> 16) & 0xFF), g = Int((p >> 8) & 0xFF), b = Int(p & 0xFF)
        return r <= 0x18 && g <= 0x44 && b <= 0x58 && b >= g && b >= 0x14
    }

    @inline(__always)
    private static func isBright(_ p: UInt32) -> Bool {
        let r = Int((p >> 16) & 0xFF), g = Int((p >> 8) & 0xFF), b = Int(p & 0xFF)
        return min(r, g, b) >= 0x88
    }

    @inline(__always)
    private static func isOutline(_ p: UInt32) -> Bool {
        let r = Int((p >> 16) & 0xFF), g = Int((p >> 8) & 0xFF), b = Int(p & 0xFF)
        return max(r, g, b) <= 0x70 || max(r, g, b) - min(r, g, b) <= 0x20
    }

    /** Anything inside a bar frame: fill, orange or yellow damage ghost, the dark (effect-tinted) background and border, a light shield. */
    @inline(__always)
    private static func isBarFrame(_ p: UInt32) -> Bool {
        if isEnemyRed(p) { return true }
        let r = Int((p >> 16) & 0xFF), g = Int((p >> 8) & 0xFF), b = Int(p & 0xFF)
        let hi = max(r, g, b), lo = min(r, g, b)
        if hi <= 0x60 { return true }
        if r >= 0xD0 && g >= 0x30 && b <= 0x60 && r > g + 0x20 { return true }
        return hi - lo <= 0x18 && lo >= 0xB0
    }

    @inline(__always)
    private static func isSelfBarFrame(_ p: UInt32) -> Bool {
        if isSelfGreen(p) { return true }
        let r = Int((p >> 16) & 0xFF), g = Int((p >> 8) & 0xFF), b = Int(p & 0xFF)
        let hi = max(r, g, b), lo = min(r, g, b)
        return hi <= 0x60 || (hi - lo <= 0x18 && lo >= 0xB0)
    }

    private static func scanRow(_ frame: Frame, rect: PixelRect, y: Int, config: DetectionConfig, into hits: inout RowHits) {
        let row = frame.base + y * frame.bytesPerRow
        let end = rect.x + rect.width
        var x = rect.x
        var checkedUntil = rect.x
        var red = -1, green = -1, box = -1
        while x < end {
            if red < 0, green < 0, box < 0, x >= checkedUntil {
                guard x + 16 <= end else { break }
                let block = row.loadUnaligned(fromByteOffset: x * 4, as: SIMD16<UInt32>.self)
                let anyRed = (block & redMask) .== redValue
                let anyGreen = (block & greenMask) .== greenValue
                let anyBox = ((block & boxMask) .== zero) .& ((block & boxBits) .!= zero)
                if !any(anyRed .| anyGreen .| anyBox) {
                    x += 16
                    continue
                }
                checkedUntil = x + 16
            }
            let p = row.load(fromByteOffset: x * 4, as: UInt32.self) & rgbMask
            if isEnemyRed(p) {
                if red < 0 { red = x }
            } else if red >= 0 {
                checkEnemyRun(frame, y: y, start: red, end: x, config: config, into: &hits.fills)
                red = -1
            }
            if isSelfGreen(p) {
                if green < 0 { green = x }
            } else if green >= 0 {
                checkOwnRun(frame, y: y, start: green, end: x, config: config, into: &hits.own)
                green = -1
            }
            if isBoxInterior(p) {
                if box < 0 { box = x }
            } else if box >= 0 {
                let resume = checkBox(frame, y: y, start: box, end: x, config: config, into: &hits.boxes)
                box = -1
                if resume > x {
                    x = resume
                    continue
                }
            }
            x += 1
        }
        if red >= 0 { checkEnemyRun(frame, y: y, start: red, end: end, config: config, into: &hits.fills) }
        if green >= 0 { checkOwnRun(frame, y: y, start: green, end: end, config: config, into: &hits.own) }
        if box >= 0 { _ = checkBox(frame, y: y, start: box, end: end, config: config, into: &hits.boxes) }
    }

    /** Red run starting at a dark border: fill top and height, outline above and below, level box on the left, bar frame of plausible width. */
    private static func checkEnemyRun(_ frame: Frame, y: Int, start: Int, end: Int, config: DetectionConfig, into hits: inout [PixelHit]) {
        guard start >= 8, y >= 2 else { return }
        guard isDark(pixel(frame, start - 1, y)) || isDark(pixel(frame, start - 2, y)) else { return }
        for k in 2...max(7, config.minHeight) where isEnemyRed(pixel(frame, start - k, y)) { return }
        let runLimit = config.maxRun * 3
        guard extendRun(frame, start: start, end: end, y: y, limit: runLimit + 1, maxGap: max(4, config.minHeight), isFill: isEnemyRed) - start <= runLimit else { return }
        let probeX = min(start + 2, end - 1)
        let heightLimit = config.maxHeight * 2
        let top = min(fillTop(frame, x: start + 1, y: y, limit: heightLimit, isFill: isBarRed),
                      fillTop(frame, x: probeX, y: y, limit: heightLimit, isFill: isBarRed))
        let height = fillHeight(frame, x: probeX, top: top, limit: heightLimit + 1, isFill: isBarRed)
        guard height >= config.minHeight, height <= config.maxHeight else { return }
        guard hasOutline(frame, x: probeX, top: top, height: height, isFill: isBarRed) else { return }
        guard hasLevelBox(frame, fillStart: start, top: top, height: height, boxWidth: config.boxWidth, isBox: { p in
            let r = Int((p >> 16) & 0xFF), g = Int((p >> 8) & 0xFF), b = Int(p & 0xFF)
            return max(r, g, b) <= 0x60 && g <= r + 4 && b <= r + 6
        }, minBox: 50) else { return }
        let middle = top + height / 2
        guard extendRun(frame, start: start, end: start, y: middle, limit: config.minFrameWidth, maxGap: max(4, config.minHeight / 2), isFill: isBarFrame) - start >= config.minFrameWidth else { return }
        let fill = extendRun(frame, start: start, end: start, y: middle, limit: config.maxRun, maxGap: max(4, config.minHeight), isFill: isEnemyRed) - start
        hits.append(PixelHit(x: start, y: top, width: config.barWidth, height: height, fill: fill))
    }

    /** Green run with the teal level box on its left: the own champion bar. */
    private static func checkOwnRun(_ frame: Frame, y: Int, start: Int, end: Int, config: DetectionConfig, into hits: inout [PixelHit]) {
        guard start >= 8, y >= 2 else { return }
        guard isDark(pixel(frame, start - 1, y)) || isDark(pixel(frame, start - 2, y)) else { return }
        for k in 2...max(7, config.minHeight) where isSelfGreen(pixel(frame, start - k, y)) { return }
        let fullEnd = extendRun(frame, start: start, end: end, y: y, limit: config.maxRun, maxGap: max(4, config.minHeight), isFill: isSelfGreen)
        let width = fullEnd - start
        guard width >= config.minFrameWidth / 3, width <= config.maxRun else { return }
        let probeX = min(start + 2, end - 1)
        let top = min(fillTop(frame, x: start + 1, y: y, limit: config.maxHeight + 2, isFill: isSelfGreen),
                      fillTop(frame, x: probeX, y: y, limit: config.maxHeight + 2, isFill: isSelfGreen))
        let height = fillHeight(frame, x: probeX, top: top, limit: config.maxHeight + 3, isFill: isSelfGreen)
        guard height >= config.minHeight, height <= config.maxHeight + 2 else { return }
        guard hasLevelBox(frame, fillStart: start - 2, top: top, height: height, boxWidth: config.boxWidth, isBox: isSelfBoxPixel, minBox: 40) else { return }
        let middle = top + height / 2
        guard extendRun(frame, start: start, end: start, y: middle, limit: config.minFrameWidth, maxGap: max(4, config.minHeight / 2), isFill: isSelfBarFrame) - start >= config.minFrameWidth else { return }
        let fill = extendRun(frame, start: start, end: start, y: middle, limit: config.maxRun, maxGap: max(4, config.minHeight), isFill: isSelfGreen) - start
        hits.append(PixelHit(x: start, y: top, width: config.barWidth, height: height, fill: fill))
    }

    /** Level box run (digit strokes merged) with a bar frame to its right: an enemy bar whose fill is empty; returns where the row scan resumes. */
    private static func checkBox(_ frame: Frame, y: Int, start: Int, end firstEnd: Int, config: DetectionConfig, into hits: inout [PixelHit]) -> Int {
        let boxMin = config.boxWidth * 6 / 10
        let boxMax = config.boxWidth * 14 / 10
        guard firstEnd - start <= boxMax else { return firstEnd }
        let end = extendRun(frame, start: start, end: firstEnd, y: y, limit: boxMax, maxGap: config.boxWidth / 2, isFill: isBoxInterior)
        let length = end - start
        guard length >= boxMin, length <= boxMax, y >= 1, y < frame.height - 2 else { return end }
        let minBoxHeight = config.minHeight * 14 / 10
        let maxBoxHeight = config.minHeight * 9 / 2
        let top = min(fillTop(frame, x: start + 2, y: y, limit: maxBoxHeight, isFill: isBoxInterior),
                      fillTop(frame, x: end - 3, y: y, limit: maxBoxHeight, isFill: isBoxInterior))
        var bottom = top
        while bottom < frame.height - 2, bottom - top < maxBoxHeight {
            var leftOk = false, rightOk = false
            for k in -2...2 where start + k >= 0 && end + k < frame.width {
                if isBoxInterior(pixel(frame, start + k, bottom + 1)) { leftOk = true }
                if isBoxInterior(pixel(frame, end - 1 + k, bottom + 1)) { rightOk = true }
            }
            guard leftOk && rightOk else { break }
            bottom += 1
        }
        let boxHeight = bottom - top + 1
        guard boxHeight >= minBoxHeight, boxHeight <= maxBoxHeight, bottom - 2 > top + 2, end - 3 > start + 3 else { return end }
        var bright = 0, total = 0
        for yy in (top + 2)...(bottom - 2) {
            for xx in (start + 3)..<(end - 3) {
                total += 1
                if isBright(pixel(frame, xx, yy)) { bright += 1 }
            }
        }
        guard bright >= 3, bright * 100 <= total * 45 else { return end }
        let barRow = top + boxHeight / 2
        var barStart = end
        var skipped = 0
        while skipped < 12, barStart < frame.width - 1 {
            let q = pixel(frame, barStart, barRow)
            if (isEnemyRed(q) || isBarBackground(q)) && !isBoxInterior(q) { break }
            barStart += 1
            skipped += 1
        }
        guard skipped < 12 else { return end }
        guard extendRun(frame, start: barStart, end: barStart, y: barRow, limit: config.minFrameWidth, maxGap: max(4, config.minHeight / 2), isFill: isBarFrame) - barStart >= config.minFrameWidth else { return end }
        hits.append(PixelHit(x: barStart, y: max(0, barRow - config.minHeight / 2), width: config.barWidth, height: config.minHeight, fill: 0))
        return end
    }

    /** Enemy bars have a dark level box with a light digit left of the fill; the own bar a teal one. */
    @inline(__always)
    private static func hasLevelBox(_ frame: Frame, fillStart: Int, top: Int, height: Int, boxWidth: Int, isBox: (UInt32) -> Bool, minBox: Int) -> Bool {
        let x0 = max(0, fillStart - 3 - boxWidth)
        let x1 = fillStart - 3
        let y0 = max(0, top - 2)
        let y1 = min(frame.height - 1, top + height + 1)
        guard x1 > x0, y1 > y0 else { return false }
        var total = 0, box = 0, bright = 0
        for yy in y0...y1 {
            for xx in x0...x1 {
                let p = pixel(frame, xx, yy)
                total += 1
                if isBox(p) { box += 1 }
                if isBright(p) { bright += 1 }
            }
        }
        return box * 100 >= total * minBox && bright >= 3 && bright * 100 <= total * 45
    }

    /** A real bar has a dark or grey outline above and below the fill (one darker transition row allowed). */
    @inline(__always)
    private static func hasOutline(_ frame: Frame, x: Int, top: Int, height: Int, isFill: (UInt32) -> Bool) -> Bool {
        guard top >= 2, top + height + 1 < frame.height else { return false }
        for (first, second) in [(top - 1, top - 2), (top + height, top + height + 1)] {
            let p = pixel(frame, x, first)
            if isFill(p) { return false }
            if isOutline(p) { continue }
            let q = pixel(frame, x, second)
            if isFill(q) || !isOutline(q) { return false }
        }
        return true
    }

    /** End of the run continued past `end` over gaps of at most `maxGap` non-matching pixels, capped at `limit` width. */
    @inline(__always)
    private static func extendRun(_ frame: Frame, start: Int, end: Int, y: Int, limit: Int, maxGap: Int, isFill: (UInt32) -> Bool) -> Int {
        var runEnd = end
        var probe = end
        while probe < frame.width - 1, runEnd - start < limit, probe - runEnd <= maxGap {
            if isFill(pixel(frame, probe, y)) { runEnd = probe + 1 }
            probe += 1
        }
        return runEnd
    }

    @inline(__always)
    private static func fillTop(_ frame: Frame, x: Int, y: Int, limit: Int, isFill: (UInt32) -> Bool) -> Int {
        guard x >= 0, x < frame.width else { return y }
        var top = y
        while top > 1, y - top < limit, isFill(pixel(frame, x, top - 1)) { top -= 1 }
        return top
    }

    @inline(__always)
    private static func fillHeight(_ frame: Frame, x: Int, top: Int, limit: Int, isFill: (UInt32) -> Bool) -> Int {
        var height = 1
        while top + height < frame.height - 1, height < limit, isFill(pixel(frame, x, top + height)) { height += 1 }
        return height
    }
}
