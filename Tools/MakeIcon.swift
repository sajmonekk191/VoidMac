import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    let ctx = NSGraphicsContext.current!.cgContext
    let inset = rect.insetBy(dx: size * 0.06, dy: size * 0.06)
    ctx.addPath(CGPath(roundedRect: inset, cornerWidth: size * 0.22, cornerHeight: size * 0.22, transform: nil))
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let bg = CGGradient(colorsSpace: space, colors: [CGColor(red: 0.05, green: 0.11, blue: 0.27, alpha: 1), CGColor(red: 0.015, green: 0.03, blue: 0.07, alpha: 1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])
    let glow = CGGradient(colorsSpace: space, colors: [CGColor(red: 0.24, green: 0.5, blue: 1, alpha: 0.55), CGColor(red: 0.31, green: 0.82, blue: 1, alpha: 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: size * 0.5, y: size * 0.58), startRadius: 0, endCenter: CGPoint(x: size * 0.5, y: size * 0.58), endRadius: size * 0.55, options: [])
    let ring = CGGradient(colorsSpace: space, colors: [CGColor(red: 0.24, green: 0.5, blue: 1, alpha: 1), CGColor(red: 0.31, green: 0.82, blue: 1, alpha: 1)] as CFArray, locations: [0, 1])!
    ctx.saveGState()
    ctx.addArc(center: CGPoint(x: size / 2, y: size * 0.585), radius: size * 0.30, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.setLineWidth(size * 0.028)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(ring, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])
    ctx.restoreGState()
    let mark = NSAttributedString(string: "V#", attributes: [
        .font: NSFont.systemFont(ofSize: size * 0.30, weight: .black),
        .foregroundColor: NSColor.white,
        .shadow: { let s = NSShadow(); s.shadowColor = NSColor(red: 0.31, green: 0.82, blue: 1, alpha: 0.9); s.shadowBlurRadius = size * 0.03; return s }(),
    ])
    let markSize = mark.size()
    mark.draw(at: CGPoint(x: (size - markSize.width) / 2, y: size * 0.585 - markSize.height / 2 + size * 0.01))
    let tag = NSAttributedString(string: "MAC", attributes: [
        .font: NSFont.systemFont(ofSize: size * 0.085, weight: .heavy),
        .foregroundColor: NSColor(red: 0.31, green: 0.82, blue: 1, alpha: 1),
        .kern: size * 0.012,
    ])
    let tagSize = tag.size()
    let pill = CGRect(x: (size - tagSize.width) / 2 - size * 0.04, y: size * 0.125, width: tagSize.width + size * 0.08, height: tagSize.height + size * 0.03)
    ctx.setFillColor(CGColor(red: 0.24, green: 0.5, blue: 1, alpha: 0.18))
    ctx.setStrokeColor(CGColor(red: 0.31, green: 0.82, blue: 1, alpha: 0.85))
    ctx.setLineWidth(size * 0.008)
    ctx.addPath(CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil))
    ctx.drawPath(using: .fillStroke)
    tag.draw(at: CGPoint(x: pill.midX - tagSize.width / 2, y: pill.midY - tagSize.height / 2))
    return true
}
let tiff = image.tiffRepresentation!
let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
