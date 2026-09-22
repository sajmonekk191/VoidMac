import AppKit
import ScreenCaptureKit

private final class ContentBox: @unchecked Sendable {
    var content: SCShareableContent?
    var error: Error?
}

struct ContentListing {
    var windows: [SCWindow] = []
    var displays: [SCDisplay] = []
    var applications: [SCRunningApplication] = []
    var error: Error?
}

/** Tracks the League game window, keeps the capture attached to it and answers focus queries. */
final class GameSession: @unchecked Sendable {
    let settings: Settings
    let capture = FrameCapture()
    private var fallbackToDisplay = false
    private var pendingFrame: CGRect?
    private var missedWindow = 0
    private var lastDiagnostic = ""
    private var lastDiagnosticAt = 0.0
    private let focusLock = NSLock()
    private var frontmost: (bundleID: String?, pid: pid_t)
    /** Whether a match is running; outside one the capture drops to 12 fps (the orbwalker sets the rate inside a match). */
    var isMatchActive: () -> Bool = { true }

    /** Call on the main thread: the frontmost app is tracked from the workspace's activation notifications, never polled. */
    init(settings: Settings) {
        self.settings = settings
        let front = NSWorkspace.shared.frontmostApplication
        frontmost = (front?.bundleIdentifier, front?.processIdentifier ?? 0)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.focusLock.withLock { self?.frontmost = (app.bundleIdentifier, app.processIdentifier) }
        }
    }

    var gameBundleID: String { settings.engine.gameBundleID }

    /** Game (or this app over a captured game) in front. */
    var isFocused: Bool {
        let front = focusLock.withLock { frontmost }
        return front.bundleID == gameBundleID || (front.pid == getpid() && capture.isRunning && capture.hasFrame)
    }

    func start() {
        let thread = Thread { self.loop() }
        thread.name = "gamesession"
        thread.start()
    }

    private func loop() {
        var lastListingMs = -1e9
        while true {
            let healthy = capture.isRunning && capture.hasFrame && nowMs() - capture.lastFrameAtMs < 1500
            if !healthy || nowMs() - lastListingMs >= 3000 {
                lastListingMs = nowMs()
                let listing = Self.listContent()
                if let window = pickGameWindow(from: listing.windows) {
                    missedWindow = 0
                    let engine = settings.engine
                    let requested = engine.captureMode
                    let mode: CaptureMode = (requested == .window && fallbackToDisplay) ? .display : requested
                    let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
                    let display = listing.displays.first { $0.frame.contains(center) } ?? listing.displays.first
                    let me = listing.applications.filter { $0.processID == getpid() }
                    let resized = capture.isRunning && capture.windowID == window.windowID && capture.windowFrame != window.frame
                    let changed = !capture.isRunning || capture.windowID != window.windowID || resized
                        || capture.mode != mode || capture.native != !engine.capturePoints
                    if changed {
                        if resized, window.frame != pendingFrame {
                            pendingFrame = window.frame
                            lastListingMs = nowMs() - 2000
                        } else {
                            pendingFrame = nil
                            capture.start(window: window, display: display, excluding: me, mode: mode, native: !engine.capturePoints)
                        }
                    } else if capture.mode == .window && !capture.hasFrame && nowMs() - capture.startedAtMs > 2000 {
                        Log.warn("window capture delivered no frames in 2 s, switching to display capture")
                        fallbackToDisplay = true
                        capture.start(window: window, display: display, excluding: me, mode: .display, native: !engine.capturePoints)
                    } else if capture.hasFrame && nowMs() - capture.lastFrameAtMs > 1500 {
                        Log.warn("capture stalled (no frame for \(Int(nowMs() - capture.lastFrameAtMs)) ms), restarting stream")
                        capture.start(window: window, display: display, excluding: me, mode: mode, native: !engine.capturePoints)
                    } else if capture.mode == .display && !capture.hasFrame && nowMs() - capture.startedAtMs > 3000 {
                        Log.warn("display capture delivered no frames in 3 s, restarting stream")
                        capture.start(window: window, display: display, excluding: me, mode: .display, native: !engine.capturePoints)
                    } else if capture.windowLayer != window.windowLayer {
                        capture.windowLayer = window.windowLayer
                    }
                } else {
                    missedWindow += 1
                    if capture.isRunning, missedWindow >= 3 { capture.stop() }
                    diagnose(listing)
                }
            }
            if capture.isRunning, !isMatchActive() { capture.setRate(12) }
            sleepMs(1000)
        }
    }

    /** The biggest game window, on screen or not: a full-screen League on another Space reports `isOnScreen == false` while it is being played. */
    private func pickGameWindow(from windows: [SCWindow]) -> SCWindow? {
        let bundleID = gameBundleID
        return windows
            .filter { $0.owningApplication?.bundleIdentifier == bundleID && $0.frame.width >= 400 && $0.frame.height >= 300 }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    private func diagnose(_ listing: ContentListing) {
        let front = NSWorkspace.shared.frontmostApplication
        let candidates = listing.windows
            .filter { ($0.owningApplication?.bundleIdentifier ?? "").lowercased().contains("riot") || ($0.owningApplication?.applicationName ?? "").lowercased().contains("league") }
            .map { "\($0.owningApplication?.bundleIdentifier ?? "?") \(Int($0.frame.width))x\(Int($0.frame.height)) layer \($0.windowLayer) onScreen \($0.isOnScreen) \"\($0.title ?? "")\"" }
        var text = "game window \(gameBundleID) not found; SCK windows: \(listing.windows.count)"
        if let error = listing.error { text += ", SCK error: \(error.localizedDescription)" }
        text += "; riot windows: [\(candidates.joined(separator: " | "))]"
        text += "; frontmost: \(front?.bundleIdentifier ?? "nil") (\(front?.localizedName ?? "?"))"
        if text != lastDiagnostic || nowMs() - lastDiagnosticAt > 15000 {
            lastDiagnostic = text
            lastDiagnosticAt = nowMs()
            Log.warn(text)
        }
    }

    static func listContent() -> ContentListing {
        let box = ContentBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            defer { semaphore.signal() }
            do {
                box.content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            } catch {
                box.error = error
            }
        }
        semaphore.wait()
        var listing = ContentListing(error: box.error)
        if let content = box.content {
            listing.windows = content.windows
            listing.displays = content.displays
            listing.applications = content.applications
        }
        return listing
    }

    static func printWindowList() {
        let listing = listContent()
        if let error = listing.error { print("SCShareableContent error: \(error.localizedDescription)") }
        for w in listing.windows where w.frame.width >= 100 {
            let bundle = w.owningApplication?.bundleIdentifier ?? "?"
            print("\(bundle)  \(Int(w.frame.width))x\(Int(w.frame.height)) @ (\(Int(w.frame.minX)), \(Int(w.frame.minY)))  layer \(w.windowLayer)  onScreen \(w.isOnScreen)  \"\(w.title ?? "")\"")
        }
        let front = NSWorkspace.shared.frontmostApplication
        print("frontmost: \(front?.bundleIdentifier ?? "nil") (\(front?.localizedName ?? "?"), pid \(front?.processIdentifier ?? 0))")
    }
}
