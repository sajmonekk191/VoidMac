import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct FramePreview {
    let image: NSImage
    let summary: String
}

/** Owned copy of a frame that frees itself once the background encoder is done with it. */
private final class FrameCopy: @unchecked Sendable {
    let frame: Frame
    private let data: UnsafeMutableRawPointer

    init(_ source: Frame) {
        let bytes = source.bytesPerRow * source.height
        data = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
        data.copyMemory(from: source.base, byteCount: bytes)
        frame = Frame(base: UnsafeRawPointer(data), width: source.width, height: source.height, bytesPerRow: source.bytesPerRow)
    }

    deinit { data.deallocate() }
}

/** Turns captured frames into images: the panel preview, a Desktop dump, and background PNG records for tuning detection. */
enum FrameDump {
    static let recordFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/VoidMac-frames")
    private static let encoder = DispatchQueue(label: "voidmac.frames", qos: .utility)

    static func cgImage(from frame: Frame) -> CGImage? {
        let data = UnsafeMutableRawPointer.allocate(byteCount: frame.bytesPerRow * frame.height, alignment: 16)
        defer { data.deallocate() }
        data.copyMemory(from: frame.base, byteCount: frame.bytesPerRow * frame.height)
        let context = CGContext(data: data, width: frame.width, height: frame.height, bitsPerComponent: 8,
                                bytesPerRow: frame.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bgra.rawValue)
        return context?.makeImage()
    }

    private static let bgra = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)

    /** Copy of a frame region as an image: a row copy, cheap enough for the vision thread. */
    static func crop(_ frame: Frame, x: Int, y: Int, width: Int, height: Int) -> CGImage? {
        let x0 = max(0, x), y0 = max(0, y)
        let w = min(frame.width - x0, width), h = min(frame.height - y0, height)
        guard w > 8, h > 8 else { return nil }
        let bytesPerRow = w * 4
        var data = Data(count: bytesPerRow * h)
        data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            for row in 0..<h { base.advanced(by: row * bytesPerRow).copyMemory(from: frame.base + (y0 + row) * frame.bytesPerRow + x0 * 4, byteCount: bytesPerRow) }
        }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: bgra, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /** The image drawn `scale`× larger with high-quality interpolation, so small HUD text stays readable for the text recogniser. */
    static func enlarged(_ image: CGImage, scale: Int) -> CGImage {
        guard scale > 1, let context = CGContext(data: nil, width: image.width * scale, height: image.height * scale, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bgra.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width * scale, height: image.height * scale))
        return context.makeImage() ?? image
    }

    /** Copies the frame now (a few ms) and writes `<name>.png` into the records folder later, keeping the newest files per kind (name prefix): 12 champion frames, 3 HUD suspects, 8 of anything else. */
    static func saveAsync(_ frame: Frame, name: String) {
        let copy = FrameCopy(frame)
        encoder.async {
            try? FileManager.default.createDirectory(at: recordFolder, withIntermediateDirectories: true)
            let url = recordFolder.appendingPathComponent("\(name).png")
            if let image = cgImage(from: copy.frame), let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, nil)
                if !CGImageDestinationFinalize(destination) { Log.warn("frame NOT saved: \(url.path)") }
            }
            if let files = try? FileManager.default.contentsOfDirectory(at: recordFolder, includingPropertiesForKeys: [.contentModificationDateKey]) {
                func modified(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
                let kinds = Dictionary(grouping: files.filter { $0.pathExtension == "png" }) { String($0.lastPathComponent.split(separator: "-").first ?? "") }
                for (kind, urls) in kinds {
                    let keep = kind == "champion" ? 12 : (kind == "hud" ? 3 : 8)
                    for stale in urls.sorted(by: { modified($0) < modified($1) }).dropLast(keep) { try? FileManager.default.removeItem(at: stale) }
                }
            }
        }
    }

    static func save(from capture: FrameCapture, settings: Settings) -> String {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/VoidMac-frame.png")
        let cfg = settings.engine
        let result: String? = capture.withLatestFrame { frame in
            let config = cfg.detectionConfig(frameWidth: frame.width, frameHeight: frame.height)
            let bars = PixelSearch.scan(frame, rect: PixelRect(x: 0, y: 0, width: frame.width, height: frame.height), config: config).enemies.count
            guard let image = cgImage(from: frame),
                  let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { return "Could not encode the frame" }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return "Could not write \(url.path)" }
            return "Saved \(frame.width)x\(frame.height) px to \(url.lastPathComponent), champion bars found: \(bars)"
        }
        return result ?? "No frame yet (is the game window visible?)"
    }

    /** The newest frame with every enemy bar, the own bar and the bar the orbwalker would pick (nearest to the champion) marked. */
    static func preview(from capture: FrameCapture, settings: Settings) -> FramePreview? {
        let cfg = settings.engine
        return capture.withLatestFrame { frame -> FramePreview? in
            guard let cg = cgImage(from: frame) else { return nil }
            let config = cfg.detectionConfig(frameWidth: frame.width, frameHeight: frame.height)
            let started = DispatchTime.now().uptimeNanoseconds
            let scan = PixelSearch.scan(frame, rect: PixelRect(x: 0, y: 0, width: frame.width, height: frame.height), config: config)
            let micros = Int(Double(DispatchTime.now().uptimeNanoseconds - started) / 1000)
            let center = CGPoint(x: Double(frame.width) / 2, y: Double(frame.height) / 2)
            let own = scan.own.min { hypot(Double($0.x) - center.x, Double($0.y) - center.y) < hypot(Double($1.x) - center.x, Double($1.y) - center.y) }
            let anchor = own.map { CGPoint(x: Double($0.x) + Double($0.width) * 0.4, y: Double($0.y) + cfg.aim.selfFeetOffsetY * Double(frame.height) / 1080) } ?? center
            let hit = scan.enemies.min { hypot(Double($0.x) - anchor.x, Double($0.y) - anchor.y) < hypot(Double($1.x) - anchor.x, Double($1.y) - anchor.y) }
            let scale = min(1, 720 / Double(frame.width))
            let size = NSSize(width: Double(frame.width) * scale, height: Double(frame.height) * scale)
            let image = NSImage(size: size, flipped: true) { bounds in
                guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
                ctx.draw(cg, in: bounds)
                ctx.setStrokeColor(CGColor(red: 1, green: 0.85, blue: 0.2, alpha: 0.9))
                ctx.setLineWidth(1.5)
                for candidate in scan.enemies {
                    ctx.strokeEllipse(in: CGRect(x: Double(candidate.x) * scale - 5, y: Double(candidate.y) * scale - 5, width: 10, height: 10))
                }
                if let own {
                    ctx.setStrokeColor(CGColor(red: 0.3, green: 1, blue: 0.6, alpha: 1))
                    ctx.setLineWidth(2)
                    ctx.strokeEllipse(in: CGRect(x: (Double(own.x) + Double(own.width) / 2) * scale - 8, y: Double(own.y) * scale - 8, width: 16, height: 16))
                }
                if let hit {
                    let x = Double(hit.x) * scale, y = Double(hit.y) * scale
                    ctx.setStrokeColor(CGColor(red: 1, green: 0.2, blue: 0.3, alpha: 1))
                    ctx.setLineWidth(2)
                    ctx.strokeEllipse(in: CGRect(x: x - 10, y: y - 10, width: 20, height: 20))
                    let cx = (Double(hit.x) + Double(hit.width) * 0.4 + cfg.clickOffsetX * Double(frame.width) / 1920) * scale
                    let cy = (Double(hit.y) + cfg.clickOffsetY * Double(frame.height) / 1080) * scale
                    ctx.setStrokeColor(CGColor(red: 1, green: 0.85, blue: 0.2, alpha: 1))
                    ctx.move(to: CGPoint(x: cx - 8, y: cy)); ctx.addLine(to: CGPoint(x: cx + 8, y: cy))
                    ctx.move(to: CGPoint(x: cx, y: cy - 8)); ctx.addLine(to: CGPoint(x: cx, y: cy + 8))
                    ctx.strokePath()
                }
                return true
            }
            let target = hit.map { "nearest target (\($0.x), \($0.y)), fill \($0.fill)/\($0.width) px" } ?? "no enemy bar"
            let ownText = own.map { "own bar (\($0.x), \($0.y))" } ?? "own bar not found"
            return FramePreview(image: image, summary: "\(frame.width)x\(frame.height) px, champion bars: \(scan.enemies.count), \(target), \(ownText), scan \(micros) µs")
        }
    }
}
