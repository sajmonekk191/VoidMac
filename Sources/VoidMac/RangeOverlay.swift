import AppKit

/** Click-through window over the game that draws the basic-attack reach around the champion (solid = where a 65-unit target's centre is still hittable, dashed = the orbwalker's gate with its tolerance) and any enabled spell ranges. Sized to the ellipses; geometry and colours are pushed to the layers only when they change. */
@MainActor
final class RangeOverlay {
    struct Extra {
        var path: CGPath
        var colorHex: String
    }

    private let panel: NSPanel
    private let view = FlippedView()
    private let gateLayer = CAShapeLayer()
    private let reachLayer = CAShapeLayer()
    private var extraLayers: [CAShapeLayer] = []
    private var lastKey = ""
    private var lastColor = ""

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        view.wantsLayer = true
        for (layer, width) in [(gateLayer, 1.5), (reachLayer, 2.5)] {
            layer.fillColor = nil
            layer.lineWidth = width
            view.layer?.addSublayer(layer)
        }
        gateLayer.lineDashPattern = [6, 6]
        panel.contentView = view
    }

    /** Places the window over the ellipses (paths in game-window points, top-left origin; the game frame in Quartz coordinates); the reach in the "#RRGGBB" colour, extras in theirs; nil reach hides it. */
    func update(gameFrame: CGRect, level: NSWindow.Level, colorHex: String, reach: CGPath?, gate: CGPath?, extras: [Extra]) {
        guard let reach, gameFrame.width > 0, let primary = NSScreen.screens.first else {
            if panel.isVisible { panel.orderOut(nil) }
            lastKey = ""
            lastColor = ""
            return
        }
        var box = reach.boundingBox
        if let gate { box = box.union(gate.boundingBox) }
        for extra in extras { box = box.union(extra.path.boundingBox) }
        box = box.insetBy(dx: -6, dy: -6).integral
        var key = "\(Int(gameFrame.minX)),\(Int(gameFrame.minY)),\(Int(box.minX)),\(Int(box.minY)),\(Int(box.width)),\(Int(box.height)),\(gate == nil)"
        for extra in extras { key += ";\(Int(extra.path.boundingBox.minX)),\(Int(extra.path.boundingBox.minY)),\(Int(extra.path.boundingBox.width)),\(extra.colorHex)" }
        let scale = panel.screen?.backingScaleFactor ?? primary.backingScaleFactor
        if key != lastKey || !panel.isVisible {
            lastKey = key
            let frame = NSRect(x: gameFrame.minX + box.minX, y: primary.frame.height - (gameFrame.minY + box.maxY), width: box.width, height: box.height)
            var shift = CGAffineTransform(translationX: -box.minX, y: -box.minY)
            while extraLayers.count < extras.count {
                let layer = CAShapeLayer()
                layer.fillColor = nil
                layer.lineWidth = 2
                view.layer?.insertSublayer(layer, at: 0)
                extraLayers.append(layer)
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for layer in [gateLayer, reachLayer] + extraLayers { layer.contentsScale = scale }
            view.layer?.contentsScale = scale
            reachLayer.path = reach.copy(using: &shift)
            gateLayer.path = gate?.copy(using: &shift)
            gateLayer.isHidden = gate == nil
            for (index, layer) in extraLayers.enumerated() {
                if index < extras.count {
                    layer.path = extras[index].path.copy(using: &shift)
                    layer.strokeColor = HexColor.cg(extras[index].colorHex, alpha: 0.85)
                    layer.isHidden = false
                } else {
                    layer.isHidden = true
                }
            }
            CATransaction.commit()
            if panel.frame != frame { panel.setFrame(frame, display: false) }
        }
        if colorHex != lastColor {
            lastColor = colorHex
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            reachLayer.strokeColor = HexColor.cg(colorHex, alpha: 0.9)
            gateLayer.strokeColor = HexColor.cg(colorHex, alpha: 0.55)
            CATransaction.commit()
        }
        if panel.level != level { panel.level = level }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }
}
