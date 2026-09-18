import AppKit
import SwiftUI

struct PanelActions {
    let close: () -> Void
    let refreshPreview: () -> Void
    let savePNG: () -> Void
    let recheckPermissions: () -> Void
    let openPrivacySettings: (String) -> Void
    let relaunch: () -> Void
    let revealConfig: () -> Void
    let resetSettings: () -> Void
}

final class KeyablePanel: NSPanel {
    var allowedFrame: NSRect?
    override var canBecomeKey: Bool { true }

    /** Keeps the panel inside the game window while it is dragged: it stops at the edges instead of leaving the game. */
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        guard let allowed = allowedFrame else { return super.constrainFrameRect(frameRect, to: screen) }
        var rect = frameRect
        rect.origin.x = min(max(rect.minX, allowed.minX), max(allowed.minX, allowed.maxX - rect.width))
        rect.origin.y = min(max(rect.minY, allowed.minY), max(allowed.minY, allowed.maxY - rect.height))
        return rect
    }
}

/** Owns the in-game settings panel, the status bar item and the hotkey polling. */
@MainActor
final class WindowController {
    let settings: Settings
    let state: AppState
    let live: LiveClient
    let game: GameSession
    let orbwalker: Orbwalker
    let vision: Vision

    private let panel: KeyablePanel
    private let overlay = RangeOverlay()
    private let gameUI: GameUI
    private var statusItem: NSStatusItem?
    private var panelKeyWasDown = false
    private var escWasDown = false
    private var panelAutoOpened = false

    init(settings: Settings, state: AppState, live: LiveClient, game: GameSession, orbwalker: Orbwalker, vision: Vision) {
        self.settings = settings
        self.state = state
        self.live = live
        self.game = game
        self.orbwalker = orbwalker
        self.vision = vision
        gameUI = GameUI(settings: settings, state: state)

        panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 860, height: 560), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false

        let actions = PanelActions(
            close: { [weak self] in self?.hidePanel() },
            refreshPreview: { [weak self] in self?.refreshPreview() },
            savePNG: { [weak self] in
                guard let self else { return }
                self.state.previewMessage = FrameDump.save(from: self.game.capture, settings: self.settings)
            },
            recheckPermissions: { [weak self] in self?.state.permissions = Permissions.request() },
            openPrivacySettings: { pane in
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
            },
            relaunch: {
                let path = Bundle.main.bundlePath
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", "sleep 0.5; open \"\(path)\""]
                try? process.run()
                AppLifecycle.shutdown?()
            },
            revealConfig: { NSWorkspace.shared.activateFileViewerSelecting([Settings.fileURL]) },
            resetSettings: { [weak self] in self?.settings.reset() }
        )
        panel.contentView = NSHostingView(rootView: SettingsPanel(settings: settings, state: state, actions: actions))
        gameUI.onToggle = { [weak self] in self?.gameUI.toggle() }
        installStatusItem()
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated { self?.releaseTextFocus(unless: event) }
            return event
        }
    }

    /** A click in one of our windows anywhere outside a text field ends its editing, so hotkeys no longer type into it. */
    private func releaseTextFocus(unless event: NSEvent) {
        guard let window = event.window as? KeyablePanel, let content = window.contentView, window.firstResponder is NSText || window.firstResponder is NSTextField else { return }
        var view = content.hitTest(content.convert(event.locationInWindow, from: nil))
        while let current = view {
            if current is NSText || current is NSTextField { return }
            view = current.superview
        }
        window.makeFirstResponder(nil)
    }

    /** Status pills at the top of the game and the attack timer plus target name near the champion, from the same 20 Hz tick as the range overlay. */
    private func updateHud(level: NSWindow.Level) {
        let frame = game.capture.windowFrame
        let snap = live.snapshot
        let layout = settings.layout
        guard snap.connected, game.isFocused, frame.width > 0 else {
            gameUI.strip.update(gameFrame: frame, level: level, items: [])
            gameUI.marks.update(gameFrame: frame, level: level, items: [])
            return
        }
        var pills: [HudOverlay.Item] = []
        if layout.hudStrip {
            let status = orbwalker.statusText
            var texts: [(String, String)] = [("ORBWALK · \(status.uppercased())", status == "ACTIVE" ? "#3DDC97" : (status.hasPrefix("ready") ? "#4FD1FF" : "#F2C744"))]
            texts.append(("AIM " + (settings.aim.enabled ? "ON" : "OFF"), settings.aim.enabled ? "#4FD1FF" : "#8A93A6"))
            texts.append(("COMBO " + (settings.combos.enabled ? "ON" : "OFF"), settings.combos.enabled ? "#4FD1FF" : "#8A93A6"))
            let widths = texts.map { 14 + 6.3 * Double($0.0.count) }
            var x = (frame.width - widths.reduce(0, +) - Double(texts.count - 1) * 6) / 2
            for (index, text) in texts.enumerated() {
                pills.append(.pill(rect: CGRect(x: x, y: 6, width: widths[index], height: 18), text: text.0, fillHex: "#070B16", textHex: text.1))
                x += widths[index] + 6
            }
        }
        gameUI.strip.update(gameFrame: frame, level: level, items: pills)
        var marks: [HudOverlay.Item] = []
        let vis = vision.latest
        if layout.hudTimer, orbwalker.activationHeld, let timer = orbwalker.attackTimer, let feet = vis.selfPoint(cfg: settings.engine), vis.frameWidth > 0 {
            let x = feet.x * frame.width / Double(vis.frameWidth), y = feet.y * frame.height / Double(vis.frameHeight)
            marks.append(.bar(rect: CGRect(x: x - 32, y: y + 12, width: 64, height: 6), progress: timer.elapsedMs / max(1, timer.periodMs), windup: timer.elapsedMs < timer.windupMs))
        }

        if layout.hudTarget, let target = orbwalker.currentTargetInfo, !target.text.isEmpty, target.text != "dummy" {
            let name = String(target.text.split(separator: " via ").first ?? "")
            let width = 12 + 6 * Double(name.count)
            marks.append(.label(rect: CGRect(x: target.point.x - frame.minX - width / 2, y: target.point.y - frame.minY - 28, width: width, height: 15), text: name, hex: "#FFFFFF"))
        }
        gameUI.marks.update(gameFrame: frame, level: level, items: marks)
    }

    /** Reach ellipse (and enabled spell ranges) around the champion in window px while the activation key is held: sampled in ground units through the vision's projection. */
    private func updateOverlay(level: NSWindow.Level) {
        let snap = live.snapshot
        let vis = vision.latest
        let frame = game.capture.windowFrame
        guard settings.drawRange, orbwalker.activationHeld, snap.connected, game.isFocused, let projection = vis.projection, vis.frameWidth > 0, frame.width > 0,
              let feet = vis.selfPoint(cfg: settings.engine) else {
            overlay.update(gameFrame: frame, level: level, colorHex: "", reach: nil, gate: nil, extras: [])
            return
        }
        let scaleX = frame.width / Double(vis.frameWidth), scaleY = frame.height / Double(vis.frameHeight)
        let ground = projection.ground(feet)
        func path(radius: Double) -> CGPath {
            let p = CGMutablePath()
            for i in 0...90 {
                let angle = Double(i) / 90 * 2 * Double.pi
                let s = projection.screen(CGPoint(x: ground.x + radius * cos(angle), y: ground.y + radius * sin(angle)))
                let point = CGPoint(x: s.x * scaleX, y: s.y * scaleY)
                if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
            }
            p.closeSubpath()
            return p
        }
        let reach = GroundProjection.reach(attackRange: snap.attackRange)
        let gate = settings.attackRangeTolerance > 0 ? path(radius: reach * (1 + settings.attackRangeTolerance / 100)) : nil
        let colorHex = settings.rangeRainbow ? HexColor.rainbow(ms: nowMs()) : settings.rangeColorHex
        var extras: [RangeOverlay.Extra] = []
        for slot in ["Q", "W", "E", "R"] {
            guard let style = settings.spellRanges[slot], style.enabled,
                  let spec = Spells.resolve(abilityID: snap.abilities[slot]?.id ?? "", champion: snap.championName, slot: slot),
                  spec.range > 0, spec.range < 3000, !spec.isGlobal else { continue }
            extras.append(RangeOverlay.Extra(path: path(radius: spec.range), colorHex: style.colorHex))
        }
        if let target = orbwalker.currentTarget {
            let marker = CGMutablePath()
            marker.addEllipse(in: CGRect(x: target.x - frame.minX - 7, y: target.y - frame.minY - 7, width: 14, height: 14))
            extras.append(RangeOverlay.Extra(path: marker, colorHex: "#FFFFFF"))
        }
        overlay.update(gameFrame: frame, level: level, colorHex: colorHex, reach: path(radius: reach), gate: gate, extras: extras)
    }

    func startTimers() {
        Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        Timer.scheduledTimer(withTimeInterval: 1.0 / 50, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollHotkeys() }
        }
    }

    private func tick() {
        state.refresh(live: live, game: game, orbwalker: orbwalker, vision: vision, settings: settings, menuVisible: gameUI.isVisible)
        let base = max(Int(CGWindowLevelForKey(.screenSaverWindow)), game.capture.windowLayer)
        let level = NSWindow.Level(rawValue: min(base + 2, Int(CGWindowLevelForKey(.maximumWindow))))
        if panel.level != level { panel.level = level }
        updateOverlay(level: NSWindow.Level(rawValue: level.rawValue - 1))
        updateHud(level: NSWindow.Level(rawValue: level.rawValue - 1))
        gameUI.tick(gameFrame: gameFrame(), level: level, inMatch: live.snapshot.connected && game.isFocused)
        let hovering = gameUI.isVisible && gameUI.hovering
        if !hovering {
            hoverSinceMs = nil
        } else if hoverSinceMs == nil {
            hoverSinceMs = nowMs()
        }
        let pausedNow = state.panelVisible || (hoverSinceMs.map { nowMs() - $0 >= 200 } ?? false)
        if orbwalker.paused != pausedNow {
            orbwalker.paused = pausedNow
            if pausedNow { orbwalker.releaseHeldKeys() }
        }
        if state.panelVisible, let frame = gameFrame() {
            panel.allowedFrame = frame
            let inside = panel.constrainFrameRect(panel.frame, to: nil)
            if inside != panel.frame { panel.setFrame(inside, display: true) }
        }
        if panelAutoOpened && state.panelVisible && game.isFocused && live.snapshot.connected {
            panelAutoOpened = false
            hidePanel()
        }
    }

    /** The menu key opens the in-game menu while the game is captured and in front, the settings window otherwise; Esc closes whichever of ours is key. */
    private func pollHotkeys() {
        let panelDown = Input.isKeyDown(settings.panelKeyCode)
        if panelDown && !panelKeyWasDown {
            if state.panelVisible {
                hidePanel()
            } else if game.isFocused && game.capture.isRunning {
                gameUI.toggle()
            } else {
                showPanel()
            }
        }
        panelKeyWasDown = panelDown
        let escDown = Input.isKeyDown(53)
        if escDown && !escWasDown {
            if state.panelVisible && panel.isKeyWindow { hidePanel() } else if gameUI.isVisible && gameUI.isAnyKey { gameUI.hide() }
        }
        escWasDown = escDown
    }

    /** Menu bar item: the in-game menu when the game is captured and in front, else the settings window. */
    func togglePanel() {
        if state.panelVisible {
            hidePanel()
        } else if !gameUI.isVisible && game.isFocused && game.capture.isRunning {
            gameUI.show()
        } else if gameUI.isVisible {
            gameUI.hide()
        } else {
            showPanel()
        }
    }

    /** Opens the panel shortly after launch only when a permission is missing; otherwise the panel lives inside the game. */
    func showPanelAfterLaunch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, !self.state.panelVisible, self.permissionsMissing else { return }
            self.state.tab = .status
            self.showPanel()
            self.panelAutoOpened = true
        }
    }

    private var permissionsMissing: Bool {
        let permissions = Permissions.current()
        return !(permissions.accessibility && permissions.screenRecording && permissions.inputMonitoring)
    }

    /** The game window in AppKit coordinates, the only place the panel may be. */
    private func gameFrame() -> NSRect? {
        guard game.capture.isRunning, let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
        let f = game.capture.windowFrame
        return NSRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
    }

    /** Opens the settings window: centred over the game window when there is one, else on the screen. */
    func showPanel() {
        let size = panel.frame.size
        let target: NSRect
        if let frame = gameFrame() {
            target = NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height)
            panel.allowedFrame = frame
        } else {
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            target = NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height)
            panel.allowedFrame = nil
        }
        panel.setFrame(panel.constrainFrameRect(target, to: nil), display: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        state.panelVisible = true
        orbwalker.paused = true
        orbwalker.releaseHeldKeys()
        state.permissions = Permissions.current()
    }

    func hidePanel() {
        panel.makeFirstResponder(nil)
        panel.orderOut(nil)
        state.panelVisible = false
        orbwalker.paused = false
    }

    private func refreshPreview() {
        if let preview = FrameDump.preview(from: game.capture, settings: settings) {
            state.preview = preview
            state.previewMessage = ""
        } else {
            state.previewMessage = "No frame yet. The game window must be open and visible."
        }
    }

    /** When the pointer settled on a window of the in-game UI; our own click cursor only passes over it, so it never counts. */
    private var hoverSinceMs: Double?

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "scope", accessibilityDescription: "Void#")
        let menu = NSMenu()
        let open = NSMenuItem(title: "Settings…", action: #selector(menuTogglePanel), keyEquivalent: ",")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Void#", action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    @objc private func menuTogglePanel() { togglePanel() }
    @objc private func menuQuit() { AppLifecycle.shutdown?() }
}

enum AppLifecycle {
    nonisolated(unsafe) static var shutdown: (() -> Void)?
}
