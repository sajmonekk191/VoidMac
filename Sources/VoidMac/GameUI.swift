import AppKit
import SwiftUI

/** The in-game UI: the menu window, one window per popped-out section, the corner badge and the click-through HUD; every window stays inside the game window and remembers where it was. */
@MainActor
final class GameUI {
    let settings: Settings
    let state: AppState
    let uiState = GameUIState()
    private(set) var isVisible = false
    private let menu: KeyablePanel
    private let menuHost: NSHostingView<AnyView>
    private var widgets: [MenuSection: (panel: KeyablePanel, host: NSHostingView<AnyView>)] = [:]
    private let badge: KeyablePanel
    private let badgeHost: NSHostingView<AnyView>
    let strip = HudOverlay()
    let marks = HudOverlay()
    private var restoring = false
    private var lastGameFrame: NSRect?
    var onToggle: () -> Void = {}

    init(settings: Settings, state: AppState) {
        self.settings = settings
        self.state = state
        uiState.popped = Set(settings.layout.popped.keys)
        uiState.collapsed = Set(settings.layout.collapsed)
        menu = Self.makePanel()
        menuHost = NSHostingView(rootView: AnyView(EmptyView()))
        menu.contentView = menuHost
        badge = Self.makePanel()
        badge.hasShadow = false
        badge.isMovableByWindowBackground = false
        badgeHost = NSHostingView(rootView: AnyView(EmptyView()))
        badge.contentView = badgeHost
        let actions = GameMenuActions(pop: { [weak self] in self?.pop($0) }, dock: { [weak self] in self?.dock($0) }, close: { [weak self] in self?.hide() })
        menuHost.rootView = AnyView(GameMenuView(settings: settings, state: state, ui: uiState, actions: actions))
        badgeHost.rootView = AnyView(BadgeView(state: state, open: false) { [weak self] in self?.onToggle() })
        for key in settings.layout.popped.keys {
            if let section = MenuSection(rawValue: key) { makeWidget(section, actions: actions) }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.windowMoved(note.object as? NSWindow) }
        }
    }

    private static func makePanel() -> KeyablePanel {
        let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 400), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func makeWidget(_ section: MenuSection, actions: GameMenuActions) {
        guard widgets[section] == nil else { return }
        let panel = Self.makePanel()
        let host = NSHostingView(rootView: AnyView(GameWidgetView(section: section, settings: settings, state: state, actions: actions)))
        panel.contentView = host
        widgets[section] = (panel, host)
    }

    var windows: [NSWindow] { [menu] + widgets.values.map(\.panel) + [badge] }

    /** True while the cursor is over the menu, a section window or the badge, so the orbwalker leaves the mouse alone. */
    var hovering: Bool {
        let mouse = NSEvent.mouseLocation
        return windows.contains { $0.isVisible && $0.frame.insetBy(dx: -2, dy: -2).contains(mouse) }
    }

    var isAnyKey: Bool { windows.contains { $0.isKeyWindow } }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        guard let game = lastGameFrame else { return }
        isVisible = true
        restoring = true
        place(menu, offset: settings.layout.menu, fallback: CGPoint(x: 56, y: 56), in: game)
        for (section, widget) in widgets {
            place(widget.panel, offset: settings.layout.popped[section.rawValue], fallback: fallbackOffset(for: section), in: game)
        }
        restoring = false
        fit()
        menu.orderFrontRegardless()
        for widget in widgets.values { widget.panel.orderFrontRegardless() }
        badgeHost.rootView = AnyView(BadgeView(state: state, open: true) { [weak self] in self?.onToggle() })
    }

    func hide() {
        isVisible = false
        for window in [menu] + widgets.values.map(\.panel) {
            window.makeFirstResponder(nil)
            window.orderOut(nil)
        }
        badgeHost.rootView = AnyView(BadgeView(state: state, open: false) { [weak self] in self?.onToggle() })
    }

    /** Moves a section into its own window next to the menu. */
    func pop(_ section: MenuSection) {
        let actions = GameMenuActions(pop: { [weak self] in self?.pop($0) }, dock: { [weak self] in self?.dock($0) }, close: { [weak self] in self?.hide() })
        makeWidget(section, actions: actions)
        uiState.popped.insert(section.rawValue)
        guard let game = lastGameFrame, let widget = widgets[section] else { return }
        restoring = true
        place(widget.panel, offset: settings.layout.popped[section.rawValue], fallback: fallbackOffset(for: section), in: game)
        restoring = false
        if settings.layout.popped[section.rawValue] == nil { settings.layout.popped[section.rawValue] = Self.offset(of: widget.panel, in: game) }
        fit()
        if isVisible { widget.panel.orderFrontRegardless() }
    }

    func dock(_ section: MenuSection) {
        uiState.popped.remove(section.rawValue)
        settings.layout.popped.removeValue(forKey: section.rawValue)
        if let widget = widgets.removeValue(forKey: section) {
            widget.panel.makeFirstResponder(nil)
            widget.panel.orderOut(nil)
        }
        fit()
    }

    /** Runs 20× per second: keeps the windows inside the game, sized to their content, the badge in the corner, and mirrors the folded sections into the settings. */
    func tick(gameFrame: NSRect?, level: NSWindow.Level, inMatch: Bool) {
        lastGameFrame = gameFrame
        guard let game = gameFrame, inMatch else {
            if isVisible { hide() }
            if badge.isVisible { badge.orderOut(nil) }
            return
        }
        let folded = Set(settings.layout.collapsed)
        if uiState.collapsed != folded { settings.layout.collapsed = Array(uiState.collapsed).sorted() }
        for window in windows where window.level != level { window.level = level }
        if settings.layout.badge && inMatch {
            let size = badgeHost.fittingSize
            let frame = NSRect(x: game.minX + 10, y: game.maxY - 10 - size.height, width: size.width, height: size.height)
            if badge.frame != frame { badge.setFrame(frame, display: true) }
            if !badge.isVisible { badge.orderFrontRegardless() }
        } else if badge.isVisible {
            badge.orderOut(nil)
        }
        guard isVisible else { return }
        fit()
        restoring = true
        for window in [menu] + widgets.values.map(\.panel) {
            window.allowedFrame = game
            let inside = window.constrainFrameRect(window.frame, to: nil)
            if inside != window.frame { window.setFrame(inside, display: true) }
        }
        restoring = false
    }

    /** Resizes each window to its SwiftUI content, keeping its top-left corner where it is. */
    private func fit() {
        let pairs = [(menu, menuHost)] + widgets.values.map({ ($0.panel, $0.host) })
        for (window, host) in pairs {
            let size = host.fittingSize
            guard size.width > 10, size.height > 10, abs(size.height - window.frame.height) > 0.5 || abs(size.width - window.frame.width) > 0.5 else { continue }
            let frame = NSRect(x: window.frame.minX, y: window.frame.maxY - size.height, width: size.width, height: size.height)
            window.setFrame(window.constrainFrameRect(frame, to: nil), display: true)
        }
    }

    private func place(_ window: KeyablePanel, offset: [Double]?, fallback: CGPoint, in game: NSRect) {
        window.allowedFrame = game
        let dx = offset?.first ?? fallback.x, dy = offset?.last ?? fallback.y
        let frame = NSRect(x: game.minX + dx, y: game.maxY - dy - window.frame.height, width: window.frame.width, height: window.frame.height)
        window.setFrame(window.constrainFrameRect(frame, to: nil), display: true)
    }

    private func fallbackOffset(for section: MenuSection) -> CGPoint {
        let index = Double(MenuSection.allCases.firstIndex(of: section) ?? 0)
        return CGPoint(x: 420 + index * 24, y: 56 + index * 40)
    }

    /** Window offset from the game window's top-left corner, in points. */
    private static func offset(of window: NSWindow, in game: NSRect) -> [Double] {
        [window.frame.minX - game.minX, game.maxY - window.frame.maxY]
    }

    private func windowMoved(_ window: NSWindow?) {
        guard !restoring, let window, let game = lastGameFrame else { return }
        if window === menu {
            settings.layout.menu = Self.offset(of: window, in: game)
        } else if let section = widgets.first(where: { $0.value.panel === window })?.key {
            settings.layout.popped[section.rawValue] = Self.offset(of: window, in: game)
        }
    }
}
