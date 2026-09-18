import AppKit

/** Click-through HUD window over the game built from a few CALayers: text pills, a progress bar and labels placed in game-window points; sized to what it shows and touched only when an item changes. */
@MainActor
final class HudOverlay {
    enum Item: Equatable {
        case pill(rect: CGRect, text: String, fillHex: String, textHex: String)
        case bar(rect: CGRect, progress: Double, windup: Bool)
        case label(rect: CGRect, text: String, hex: String)
    }

    private let panel: NSPanel
    private let view = FlippedView()
    private var layers: [CALayer] = []
    private var last: [Item] = []
    private var lastOrigin = CGPoint.zero

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
        panel.contentView = view
    }

    /** Shows the items (game-window points, top-left origin) over the game frame (Quartz coordinates); an empty list hides the window. */
    func update(gameFrame: CGRect, level: NSWindow.Level, items: [Item]) {
        guard !items.isEmpty, gameFrame.width > 0, let primary = NSScreen.screens.first else {
            if panel.isVisible { panel.orderOut(nil) }
            last = []
            return
        }
        if panel.level != level { panel.level = level }
        let origin = CGPoint(x: gameFrame.minX, y: gameFrame.minY)
        guard items != last || origin != lastOrigin || !panel.isVisible else { return }
        last = items
        lastOrigin = origin
        var box = items.map(Self.rect).reduce(CGRect.null) { $0.union($1) }
        box = box.insetBy(dx: -4, dy: -4).integral
        let frame = NSRect(x: gameFrame.minX + box.minX, y: primary.frame.height - (gameFrame.minY + box.maxY), width: box.width, height: box.height)
        let scale = panel.screen?.backingScaleFactor ?? primary.backingScaleFactor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer?.contentsScale = scale
        while layers.count < items.count {
            let layer = CALayer()
            view.layer?.addSublayer(layer)
            layers.append(layer)
        }
        for (index, layer) in layers.enumerated() {
            guard index < items.count else {
                layer.isHidden = true
                continue
            }
            layer.isHidden = false
            layer.contentsScale = scale
            Self.fill(layer, with: items[index], offset: box.origin, scale: scale)
        }
        CATransaction.commit()
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private static func rect(of item: Item) -> CGRect {
        switch item {
        case .pill(let rect, _, _, _), .bar(let rect, _, _), .label(let rect, _, _): return rect
        }
    }

    /** Lays out one item's sublayers (background, fill, text) inside its host layer. */
    private static func fill(_ layer: CALayer, with item: Item, offset: CGPoint, scale: CGFloat) {
        let rect = rect(of: item).offsetBy(dx: -offset.x, dy: -offset.y)
        layer.frame = rect
        let fillLayer = sublayer(layer, index: 0)
        let text = textLayer(layer, index: 1)
        switch item {
        case .pill(_, let string, let fillHex, let textHex):
            layer.backgroundColor = HexColor.cg(fillHex, alpha: 0.82)
            layer.cornerRadius = rect.height / 2
            layer.borderWidth = 1
            layer.borderColor = HexColor.cg(textHex, alpha: 0.35)
            fillLayer.isHidden = true
            text.isHidden = false
            text.frame = CGRect(x: 0, y: (rect.height - 13) / 2, width: rect.width, height: 13)
            text.string = string
            text.foregroundColor = HexColor.cg(textHex, alpha: 1)
            text.fontSize = 10
        case .bar(_, let progress, let windup):
            layer.backgroundColor = CGColor(gray: 0, alpha: 0.55)
            layer.cornerRadius = rect.height / 2
            layer.borderWidth = 1
            layer.borderColor = CGColor(gray: 1, alpha: 0.25)
            fillLayer.isHidden = false
            fillLayer.frame = CGRect(x: 1, y: 1, width: max(0, (rect.width - 2) * min(1, max(0, progress))), height: rect.height - 2)
            fillLayer.cornerRadius = (rect.height - 2) / 2
            fillLayer.backgroundColor = windup ? HexColor.cg("#FFB020", alpha: 1) : (progress >= 1 ? HexColor.cg("#3DDC97", alpha: 1) : HexColor.cg("#4FD1FF", alpha: 1))
            text.isHidden = true
        case .label(_, let string, let hex):
            layer.backgroundColor = CGColor(gray: 0, alpha: 0.45)
            layer.cornerRadius = 4
            layer.borderWidth = 0
            fillLayer.isHidden = true
            text.isHidden = false
            text.frame = CGRect(x: 0, y: (rect.height - 12) / 2, width: rect.width, height: 12)
            text.string = string
            text.foregroundColor = HexColor.cg(hex, alpha: 1)
            text.fontSize = 9.5
        }
        fillLayer.contentsScale = scale
        text.contentsScale = scale
    }

    private static func sublayer(_ host: CALayer, index: Int) -> CALayer {
        if let existing = host.sublayers, existing.count > index { return existing[index] }
        let layer = index == 1 ? makeText() : CALayer()
        host.addSublayer(layer)
        return layer
    }

    private static func textLayer(_ host: CALayer, index: Int) -> CATextLayer {
        (sublayer(host, index: index) as? CATextLayer) ?? makeText()
    }

    private static func makeText() -> CATextLayer {
        let text = CATextLayer()
        text.alignmentMode = .center
        text.truncationMode = .end
        text.isWrapped = false
        text.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        text.shadowColor = CGColor(gray: 0, alpha: 1)
        text.shadowOpacity = 0.9
        text.shadowRadius = 1
        text.shadowOffset = CGSize(width: 0, height: 0)
        return text
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }
}
