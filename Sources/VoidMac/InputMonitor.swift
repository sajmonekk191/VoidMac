import CoreGraphics
import Foundation

/** One active session tap for keys only (autoaim may swallow spell keys); mouse motion never passes through this process. */
final class InputMonitor: @unchecked Sendable {
    static let shared = InputMonitor()

    private let lock = NSLock()
    private var down = Set<UInt16>()
    private var keyStateFalseSince: [UInt16: Double] = [:]
    private var lastVerifyMs: [UInt16: Double] = [:]
    private var tap: CFMachPort?
    private var lastTapWarningMs = -1e9
    private var tapActive = false
    /** Returns true to swallow a physical key event (key code, is key down, is autorepeat); called on the tap thread. */
    nonisolated(unsafe) var interceptor: ((UInt16, Bool, Bool) -> Bool)?
    /** Every physical, non-repeat key press, swallowed or not; called on the tap thread, must return fast. */
    nonisolated(unsafe) var onKeyDown: ((UInt16) -> Void)?

    func start() {
        let thread = Thread { self.run() }
        thread.name = "inputtap"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /** True while the key is physically held; the HID key state is consulted at most every 100 ms to recover from a missed event. */
    func isHeld(_ code: UInt16) -> Bool {
        guard lock.withLock({ tapActive }) else { return CGEventSource.keyState(.hidSystemState, key: CGKeyCode(code)) }
        let now = nowMs()
        return lock.withLock {
            let tapDown = down.contains(code)
            guard now - (lastVerifyMs[code] ?? -1e9) >= 100 else { return tapDown }
            lastVerifyMs[code] = now
            let raw = CGEventSource.keyState(.hidSystemState, key: CGKeyCode(code))
            if raw {
                keyStateFalseSince[code] = nil
            } else if keyStateFalseSince[code] == nil {
                keyStateFalseSince[code] = now
            }
            if tapDown && !raw, let since = keyStateFalseSince[code], now - since > 300 {
                down.remove(code)
                return false
            }
            return tapDown || raw
        }
    }

    private func run() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon, Unmanaged<InputMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event) {
                return nil
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                          callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            Log.warn("key tap unavailable (Input Monitoring?), falling back to key state polling")
            return
        }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        lock.withLock { tapActive = true }
        Log.info("key tap active")
        CFRunLoopRun()
    }

    /** Handles one tapped event; true means the event is swallowed. */
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            let now = nowMs()
            if now - lastTapWarningMs > 2000 {
                lastTapWarningMs = now
                Log.warn("key tap disabled by \(type == .tapDisabledByTimeout ? "timeout" : "user input"), re-enabled")
            }
            return false
        }
        if event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) { return false }
        let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        switch type {
        case .keyDown:
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if !isRepeat { onKeyDown?(code) }
            if let interceptor, interceptor(code, true, isRepeat) { return true }
            lock.withLock { _ = down.insert(code) }
        case .keyUp:
            if let interceptor, interceptor(code, false, false) { return true }
            lock.withLock { _ = down.remove(code) }
        case .flagsChanged:
            let flags = event.flags
            let held: Bool
            switch code {
            case 54, 55: held = flags.contains(.maskCommand)
            case 56, 60: held = flags.contains(.maskShift)
            case 58, 61: held = flags.contains(.maskAlternate)
            case 59, 62: held = flags.contains(.maskControl)
            case 57: held = flags.contains(.maskAlphaShift)
            case 63: held = flags.contains(.maskSecondaryFn)
            default: held = false
            }
            lock.withLock { if held { down.insert(code) } else { down.remove(code) } }
        default:
            break
        }
        return false
    }
}
