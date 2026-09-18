import AppKit
import SwiftUI

/** Offline renders of the in-game UI (`--ui-shot <folder>`): the menu, one popped-out section and the badge as PNGs, with sample state, for checking the look without a game. */
enum UIPreview {
    @MainActor
    static func render(to folder: String, settings: Settings) {
        let state = AppState()
        state.engineStatus = "ready, hold Space"
        state.capturing = true
        state.fps = 113
        state.scanMicros = 2400
        state.pixelSize = CGSize(width: 3600, height: 2338)
        state.windowFrame = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        var snap = PlayerSnapshot()
        snap.connected = true
        snap.championName = "Lucian"
        snap.level = 14
        snap.attackSpeed = 1.234
        snap.attackRange = 500
        snap.enemies = [EnemyPlayer(champion: "chogath", championName: "Cho'Gath", level: 12, names: ["Cho'Gath"]), EnemyPlayer(champion: "annie", championName: "Annie", level: 9, names: ["Annie"])]
        state.snapshot = snap
        state.windup = 15
        state.windupMs = 190
        let ui = GameUIState()
        let actions = GameMenuActions(pop: { _ in }, dock: { _ in }, close: {})
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        shoot(AnyView(GameMenuView(settings: settings, state: state, ui: ui, actions: actions)), folder: folder, name: "menu.png")
        ui.collapsed = Set(MenuSection.allCases.map(\.rawValue).filter { $0 != "orbwalker" })
        shoot(AnyView(GameMenuView(settings: settings, state: state, ui: ui, actions: actions)), folder: folder, name: "menu-folded.png")
        shoot(AnyView(GameWidgetView(section: .combos, settings: settings, state: state, actions: actions)), folder: folder, name: "widget-combos.png")
        shoot(AnyView(GameWidgetView(section: .status, settings: settings, state: state, actions: actions)), folder: folder, name: "widget-status.png")
        shoot(AnyView(BadgeView(state: state, open: false) {}), folder: folder, name: "badge.png")
    }

    @MainActor
    private static func shoot(_ view: AnyView, folder: String, name: String) {
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: size.width, height: size.height), styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
        try? rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:])?.write(to: url)
        window.orderOut(nil)
        print("\(name): \(Int(size.width))×\(Int(size.height)) pt")
    }
}
