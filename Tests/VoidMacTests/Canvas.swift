import CoreGraphics
@testable import VoidMac

/** A BGRA frame the tests paint pixel by pixel, laid out like a ScreenCaptureKit buffer. */
final class Canvas {
    let width: Int
    let height: Int
    private let pixels: UnsafeMutableRawPointer

    init(width: Int, height: Int, color: UInt32) {
        self.width = width
        self.height = height
        pixels = UnsafeMutableRawPointer.allocate(byteCount: width * height * 4, alignment: 64)
        fill(x: 0, y: 0, width: width, height: height, color: color)
    }

    deinit { pixels.deallocate() }

    var frame: Frame { Frame(base: UnsafeRawPointer(pixels), width: width, height: height, bytesPerRow: width * 4) }

    func set(_ x: Int, _ y: Int, _ color: UInt32) {
        pixels.storeBytes(of: color, toByteOffset: (y * width + x) * 4, as: UInt32.self)
    }

    func fill(x: Int, y: Int, width: Int, height: Int, color: UInt32) {
        for row in y..<(y + height) {
            for column in x..<(x + width) { set(column, row, color) }
        }
    }

    /** A copy with the content moved by (dx, dy) px, edges clamped: a camera pan with a known answer. */
    func translated(dx: Int, dy: Int) -> Canvas {
        let copy = Canvas(width: width, height: height, color: 0)
        for y in 0..<height {
            for x in 0..<width {
                let source = (min(height - 1, max(0, y - dy)) * width + min(width - 1, max(0, x - dx))) * 4
                copy.set(x, y, pixels.load(fromByteOffset: source, as: UInt32.self))
            }
        }
        return copy
    }
}

/** Opaque pixel from 8-bit channels. */
func bgra(_ r: Int, _ g: Int, _ b: Int) -> UInt32 {
    0xFF00_0000 | UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
}

/** SplitMix64, for reproducible random textures and RANSAC samples. */
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
