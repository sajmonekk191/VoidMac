import Foundation

/** One enemy minion bar: `x` is where the health fill starts, `span` the fill of a full bar, `fill` the health in px with the anti-aliased edge as a fraction; `white` is the game's last-hit assist saying one attack kills it now, `large` the super minion's 1.5× wider bar, `mark` the end of the darker one-shot part the assist draws at the start of a red fill (px from `x`). */
struct MinionHit: Equatable {
    var x: Int
    var y: Int
    var span: Int
    var height: Int
    var fill: Double
    var white = false
    var large = false
    var mark: Double?

    var fraction: Double { span > 0 ? min(1, max(0, fill / Double(span))) : 0 }
    var centerX: Double { Double(x) + Double(span) / 2 }
}

/** Size of the minion bar in one frame: the in-world bars scale with min(width / 1920, height / 1080), 122 × 10 px inside the border at 3600 × 2144 and at 3600 × 2338 for melee, caster and cannon (measured on 20 frames), 182 px for the super minion. */
struct MinionBarGeometry: Equatable {
    let scale: Double
    let interiorWidth: Int
    let largeInteriorWidth: Int
    let bandHeight: Int
    let rowStride: Int

    init(frameWidth: Int, frameHeight: Int) {
        scale = max(0.5, min(Double(frameWidth) / 1920, Double(frameHeight) / 1080))
        interiorWidth = max(24, Int((65.07 * scale).rounded()))
        largeInteriorWidth = max(36, Int((97.07 * scale).rounded()))
        bandHeight = max(3, Int((4.27 * scale).rounded()))
        rowStride = max(2, Int(3.2 * scale))
    }

    /** Full-health fill: the interior minus its dark edge column on each side. */
    var span: Int { interiorWidth - 2 }

    var largeSpan: Int { largeInteriorWidth - 2 }

    /** Frame px from the bar top down to the middle of the minion's body; the super minion stands much taller. */
    func bodyBelowBar(large: Bool) -> Double { (large ? 64 : 40) * scale }

    /** Frame px from the bar top down to the minion's feet (casters stand shorter, cannons taller). */
    func feetBelowBar(large: Bool) -> Double { (large ? 120 : 64) * scale }
}

/** One strided pass for enemy minion bars: a red gradient fill of the minion bar's exact height inside a dark border, whose dark empty part ends at the bar's exact width; with the game's last-hit assist the fill starts with a darker one-shot part, and a bar one attack kills turns white where the red one was. */
enum MinionBars {
    private static let rgbMask: UInt32 = 0x00FF_FFFF
    private static let redMask = SIMD16<UInt32>(repeating: 0x0080_8080)
    private static let redValue = SIMD16<UInt32>(repeating: 0x0080_0000)
    private static let brightMask = SIMD16<UInt32>(repeating: 0x0080_8080)

    /** Bars in `rect`; white bars too when `white` (the game's assist is on): seven of their eight rows are whitish, so the stride cannot step over one. */
    static func scan(_ frame: Frame, rect requested: PixelRect, geometry: MinionBarGeometry, white: Bool, limit: Int = 40) -> [MinionHit] {
        let x0 = max(4, requested.x), y0 = max(4, requested.y)
        let x1 = min(frame.width - 4, requested.x + requested.width), y1 = min(frame.height - 4, requested.y + requested.height)
        guard x1 - x0 > geometry.interiorWidth, y1 > y0 else { return [] }
        var hits: [MinionHit] = []
        var y = y0
        while y < y1, hits.count < limit {
            scanRow(frame, y: y, from: x0, to: x1, geometry: geometry, white: white, into: &hits)
            y += geometry.rowStride
        }
        return hits
    }

    /** White bars at the places (fill start, bar top) of bars followed until now: the assist only ever turns a red bar white, and its gradient fades too fast for the strided pass to be sure to cross a bright row. */
    static func whiteBars(_ frame: Frame, at places: [(x: Int, y: Int)], geometry: MinionBarGeometry) -> [MinionHit] {
        let reach = max(4, Int(6 * geometry.scale))
        var hits: [MinionHit] = []
        for place in places {
            var y = max(4, place.y - reach / 2)
            probe: while y <= min(frame.height - 5, place.y + reach / 2) {
                var x = max(6, place.x - reach)
                while x <= min(frame.width - geometry.interiorWidth - 4, place.x + reach) {
                    guard isWhitish(pixel(frame, x, y)) else {
                        x += 1
                        continue
                    }
                    var runEnd = x + 1
                    while runEnd < frame.width - 4, isWhitish(pixel(frame, runEnd, y)) { runEnd += 1 }
                    if let hit = check(frame, y: y, start: x, runEnd: runEnd, white: true, geometry: geometry) {
                        if !hits.contains(where: { $0.x == hit.x && $0.y == hit.y }) { hits.append(hit) }
                        break probe
                    }
                    x = runEnd
                }
                y += 1
            }
        }
        return hits
    }

    @inline(__always)
    private static func pixel(_ frame: Frame, _ x: Int, _ y: Int) -> UInt32 {
        (frame.base + y * frame.bytesPerRow + x * 4).load(as: UInt32.self) & rgbMask
    }

    @inline(__always)
    private static func channels(_ p: UInt32) -> (r: Int, g: Int, b: Int) {
        (Int((p >> 16) & 0xFF), Int((p >> 8) & 0xFF), Int(p & 0xFF))
    }

    /** The bright rows of the minion fill (DD5459 down to 8A3437), anti-aliased edges included. */
    @inline(__always)
    static func isRedFill(_ p: UInt32) -> Bool {
        let (r, g, b) = channels(p)
        return r >= 0x78 && g >= 0x20 && b >= 0x20 && g <= 0x70 && b <= 0x74 && r - max(g, b) >= 0x3C && abs(g - b) <= 0x14
    }

    /** The one-shot part of an assisted fill: a darker, deeper red than the fill (9C0400 against DD5459 on the top row, measured in game). */
    @inline(__always)
    static func isShadedFill(_ p: UInt32) -> Bool {
        let (r, g, b) = channels(p)
        return r >= 0x50 && max(g, b) * 2 <= r && r - max(g, b) >= 0x20
    }

    /** The top rows of a white bar, which fades to 5A5A50 at the bottom. */
    @inline(__always)
    static func isWhiteFill(_ p: UInt32) -> Bool {
        let (r, g, b) = channels(p)
        return min(r, g, b) >= 0xB0 && max(r, g, b) - min(r, g, b) <= 0x30
    }

    /** Seven of the eight rows of a white bar (A6ADB2, D6E0E5 … 828B8B; the bottom 616768 is not). */
    @inline(__always)
    private static func isWhitish(_ p: UInt32) -> Bool {
        let (r, g, b) = channels(p)
        return min(r, g, b) >= 0x80 && max(r, g, b) - min(r, g, b) <= 0x30
    }

    /** Any row of the fill gradient, down to its darkest (67292B) or, when white, its greyest. */
    @inline(__always)
    private static func isBand(_ p: UInt32, white: Bool) -> Bool {
        let (r, g, b) = channels(p)
        if white { return min(r, g, b) >= 0x48 && max(r, g, b) - min(r, g, b) <= 0x30 }
        return r >= 0x58 && r - max(g, b) >= 0x18 && abs(g - b) <= 0x18
    }

    @inline(__always)
    private static func isDark(_ p: UInt32, limit: Int = 0x48) -> Bool {
        let (r, g, b) = channels(p)
        return max(r, g, b) <= limit
    }

    /** The bar's empty part: near-black, tinted by whatever shows through it (141313 over stone, 092632 over a blue glow); up to 58201E over a champion's red outline and 004B61 over a bright cyan spell when `lenient`. */
    @inline(__always)
    private static func isEmptyBar(_ p: UInt32, lenient: Bool = false) -> Bool {
        let (r, g, b) = channels(p)
        return max(r, g, b) <= (lenient ? 0x6C : 0x3C)
    }

    private static func scanRow(_ frame: Frame, y: Int, from start: Int, to end: Int, geometry: MinionBarGeometry, white: Bool, into hits: inout [MinionHit]) {
        let row = frame.base + y * frame.bytesPerRow
        var x = start
        var checkedUntil = start
        while x < end {
            if x >= checkedUntil {
                guard x + 16 <= end else { break }
                let block = row.loadUnaligned(fromByteOffset: x * 4, as: SIMD16<UInt32>.self)
                let candidates = white ? ((block & redMask) .== redValue) .| ((block & brightMask) .== brightMask) : (block & redMask) .== redValue
                if !any(candidates) {
                    x += 16
                    continue
                }
                checkedUntil = x + 16
            }
            let p = row.load(fromByteOffset: x * 4, as: UInt32.self) & rgbMask
            let red = isRedFill(p)
            guard red || (white && isWhitish(p)) else {
                x += 1
                continue
            }
            var runEnd = x + 1
            while runEnd < end, red ? isRedFill(pixel(frame, runEnd, y)) : isWhitish(pixel(frame, runEnd, y)) { runEnd += 1 }
            if let hit = check(frame, y: y, start: x, runEnd: runEnd, white: !red, geometry: geometry) {
                if !hits.contains(where: { abs($0.x - hit.x) <= 3 && abs($0.y - hit.y) <= hit.height + 2 }) { hits.append(hit) }
                x = max(runEnd, hit.x + hit.span + 2)
            } else {
                x = runEnd
            }
        }
    }

    /** Verifies the fill run [start, runEnd) found on row `y` and measures the bar it belongs to; nil unless every part of a minion bar is where it must be. */
    static func check(_ frame: Frame, y: Int, start found: Int, runEnd: Int, white: Bool, geometry: MinionBarGeometry) -> MinionHit? {
        guard found >= 6, runEnd > found else { return nil }
        let isFill: (UInt32) -> Bool = white ? isWhiteFill : isRedFill
        let twoTone = !white && runEnd - found >= 8 && isDeeper(pixel(frame, found + 1, y), than: pixel(frame, runEnd - 2, y))
        let column = twoTone ? runEnd - 4 : found + min(3, runEnd - found - 1)
        guard isBand(pixel(frame, column, y), white: white) else { return nil }
        let reach = geometry.bandHeight * 2
        var top = y, bottom = y
        while top > 3, y - top < reach, isBand(pixel(frame, column, top - 1), white: white) { top -= 1 }
        while bottom < frame.height - 4, bottom - y < reach, isBand(pixel(frame, column, bottom + 1), white: white) { bottom += 1 }
        let height = bottom - top + 1
        guard abs(height - geometry.bandHeight) <= 1 else { return nil }
        guard isDark(pixel(frame, column, top - 1), limit: 0x50) || isDark(pixel(frame, column, top - 2), limit: 0x50),
              isDark(pixel(frame, column, bottom + 1), limit: 0x50) || isDark(pixel(frame, column, bottom + 2), limit: 0x50) else { return nil }
        var measureRow = top
        var brightest = -1
        for row in top...bottom {
            let r = Int((pixel(frame, column, row) >> 16) & 0xFF)
            if r > brightest {
                brightest = r
                measureRow = row
            }
        }
        let bottomRed = Int((pixel(frame, column, bottom) >> 16) & 0xFF)
        if white {
            guard (measureRow - top) * 4 <= height, bottomRed * 10 <= brightest * 7, brightest < 0xF8 else { return nil }
        } else {
            guard (measureRow - top) * 5 <= height * 2, bottomRed * 5 <= brightest * 4 else { return nil }
        }
        func bordered(_ x: Int) -> Bool { isDark(pixel(frame, x - 1, measureRow)) || isDark(pixel(frame, x - 2, measureRow)) }
        var start = found
        if white, !isFill(pixel(frame, start, measureRow)), isFill(pixel(frame, start + 1, measureRow)) { start += 1 }
        while start > found - 3, isFill(pixel(frame, start - 1, measureRow)) { start -= 1 }
        guard isFill(pixel(frame, start, measureRow)) else { return nil }
        var fillEnd = start
        var shadedEnd: Int?
        if !white, !bordered(start) {
            var left = start
            while start - left < geometry.interiorWidth, isShadedFill(pixel(frame, left - 1, measureRow)), !isRedFill(pixel(frame, left - 1, measureRow)) { left -= 1 }
            guard start - left >= 3 else { return nil }
            shadedEnd = start
            fillEnd = start - 1
            start = left
        }
        guard bordered(start) else { return nil }
        let normalRight = start + geometry.interiorWidth - 2, largeRight = start + geometry.largeInteriorWidth - 2
        guard normalRight + 3 < frame.width else { return nil }
        var probe = fillEnd + 1
        while probe <= normalRight + 1, probe - fillEnd <= 4 {
            if isFill(pixel(frame, probe, measureRow)) { fillEnd = probe }
            probe += 1
        }
        if fillEnd >= normalRight - 1, largeRight + 3 < frame.width, isFill(pixel(frame, normalRight, measureRow)), isFill(pixel(frame, normalRight + 1, measureRow)) {
            probe = normalRight + 2
            while probe <= largeRight + 1, probe - fillEnd <= 4 {
                if isFill(pixel(frame, probe, measureRow)) { fillEnd = probe }
                probe += 1
            }
        }
        var mark: Double?
        let shade = pixel(frame, start + 2, measureRow), lit = pixel(frame, max(start + 2, fillEnd - 1), measureRow)
        if let boundary = shadedEnd {
            guard isDeeper(pixel(frame, (start + boundary) / 2, measureRow), than: pixel(frame, max(boundary, fillEnd - 1), measureRow)),
                  isUniform(frame, row: measureRow, from: start + 1, to: boundary - 2), isUniform(frame, row: measureRow, from: boundary + 1, to: fillEnd - 2) else { return nil }
            mark = Double(boundary - start)
        } else if !white, isShadedFill(shade), isDeeper(shade, than: lit) {
            var boundary = start + 3
            while boundary < fillEnd, distance(pixel(frame, boundary, measureRow), shade) <= distance(pixel(frame, boundary, measureRow), lit) { boundary += 1 }
            guard boundary - start >= 4, isUniform(frame, row: measureRow, from: start + 2, to: boundary - 2),
                  isUniform(frame, row: measureRow, from: boundary + 1, to: fillEnd - 2) else { return nil }
            mark = Double(boundary - start)
        } else {
            guard isFill(pixel(frame, start + min(2, fillEnd - start), measureRow)), isUniform(frame, row: measureRow, from: start + 2, to: fillEnd - 2) else { return nil }
        }
        let lenient = white || mark != nil
        func closes(_ right: Int) -> Bool {
            guard fillEnd <= right + 1 else { return false }
            let emptyFrom = fillEnd + 3
            if emptyFrom < right - 3 {
                var samples = 0, matching = 0
                var x = max(emptyFrom, right - (right - emptyFrom) / 2)
                while x < right - 1 {
                    samples += 1
                    if isEmptyBar(pixel(frame, x, measureRow), lenient: lenient) { matching += 1 }
                    x += 2
                }
                guard matching * 10 >= samples * 8 else { return false }
            }
            return (right...(right + 2)).contains { isDark(pixel(frame, $0, measureRow), limit: 0x50) }
        }
        func brightness(_ x: Int, _ row: Int) -> Int {
            let (r, g, b) = channels(pixel(frame, x, row))
            return max(r, g, b)
        }
        func bordered(after right: Int) -> Bool {
            (top...bottom).filter { brightness(right + 1, $0) + 6 <= brightness(right + 3, $0) && brightness(right + 1, $0) + 3 <= brightness(right - 1, $0) }.count * 2 >= bottom - top + 1
        }
        func framed(from left: Int, to right: Int) -> Bool {
            let step = max(1, (right - left) / 8)
            var samples = 0, matching = 0
            var x = left
            while x <= right {
                samples += 1
                if isEmptyBar(pixel(frame, x, measureRow)), brightness(x, top - 1) + 6 <= brightness(x, top), brightness(x, bottom + 1) + 4 <= brightness(x, bottom) { matching += 1 }
                x += step
            }
            return samples > 0 && matching * 10 >= samples * 8
        }
        let fitsLarge = largeRight + 3 < frame.width && closes(largeRight)
        let large = fillEnd > normalRight + 1 ? fitsLarge : fitsLarge && !bordered(after: normalRight) && framed(from: normalRight + 4, to: largeRight - 4)
        guard large || closes(normalRight) else { return nil }
        let interiorRight = large ? largeRight : normalRight
        let coverage = partialCoverage(edge: pixel(frame, fillEnd + 1, measureRow), full: pixel(frame, max(start, fillEnd - 2), measureRow),
                                       empty: pixel(frame, min(interiorRight - 1, fillEnd + 3), measureRow))
        let span = large ? geometry.largeSpan : geometry.span
        let fill = min(Double(span), Double(fillEnd - start + 1) + coverage)
        return MinionHit(x: start, y: top, span: span, height: height, fill: fill, white: white, large: large, mark: mark.flatMap { $0 < fill - 1 ? $0 : nil })
    }

    /** True when `a` is the assist's one-shot red next to the fill `b`: no brighter, with clearly less green and blue. */
    @inline(__always)
    private static func isDeeper(_ a: UInt32, than b: UInt32) -> Bool {
        let (ar, ag, ab) = channels(a), (br, bg, bb) = channels(b)
        return ar <= br && ag + 0x18 <= bg && ab + 0x18 <= bb
    }

    /** Largest channel difference of two pixels. */
    @inline(__always)
    private static func distance(_ a: UInt32, _ b: UInt32) -> Int {
        let (ar, ag, ab) = channels(a), (br, bg, bb) = channels(b)
        return max(abs(ar - br), abs(ag - bg), abs(ab - bb))
    }

    /** The fill is one flat colour along the row (a bar is drawn per row; text and models are not): of up to eight samples at most one differs from the first by more than 0x18. */
    private static func isUniform(_ frame: Frame, row: Int, from left: Int, to right: Int) -> Bool {
        guard right - left >= 2 else { return true }
        let reference = pixel(frame, left, row)
        let step = max(1, (right - left) / 7)
        var mismatches = 0
        var x = left + step
        while x <= right {
            if distance(pixel(frame, x, row), reference) > 0x18 { mismatches += 1 }
            x += step
        }
        return mismatches <= 1
    }

    /** How much of the first pixel past the fill is still health, from its red channel between the full fill and the empty bar. */
    @inline(__always)
    private static func partialCoverage(edge: UInt32, full: UInt32, empty: UInt32) -> Double {
        let r = Double((edge >> 16) & 0xFF), rFull = Double((full >> 16) & 0xFF), rEmpty = Double((empty >> 16) & 0xFF)
        guard rFull - rEmpty > 16 else { return 0 }
        return max(0, min(1, (r - rEmpty) / (rFull - rEmpty)))
    }
}
