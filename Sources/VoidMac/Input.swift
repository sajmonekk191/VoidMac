import CoreGraphics
import Foundation

/** Synthesises mouse and keyboard events at session level (a HID post can stall 20 ms under load, a session post stays under 3 ms). */
enum Input {
    private static let source: CGEventSource? = {
        let s = CGEventSource(stateID: .hidSystemState)
        let permitAll: CGEventFilterMask = [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents]
        s?.localEventsSuppressionInterval = 0
        s?.setLocalEventsFilterDuringSuppressionState(permitAll, state: CGEventSuppressionState(rawValue: 0)!)
        s?.setLocalEventsFilterDuringSuppressionState(permitAll, state: CGEventSuppressionState(rawValue: 1)!)
        return s
    }()

    static func isKeyDown(_ keyCode: UInt16) -> Bool {
        InputMonitor.shared.isHeld(keyCode)
    }

    static func mousePosition() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    static func rightMouse(down: Bool, at point: CGPoint) {
        post(down ? .rightMouseDown : .rightMouseUp, at: point, button: .right)
    }

    static func rightClick(at point: CGPoint) {
        post(.rightMouseDown, at: point, button: .right)
        post(.rightMouseUp, at: point, button: .right)
    }

    static func leftClick(at point: CGPoint) {
        post(.leftMouseDown, at: point, button: .left)
        post(.leftMouseUp, at: point, button: .left)
    }

    static func middleMouse(down: Bool) {
        post(down ? .otherMouseDown : .otherMouseUp, at: mousePosition(), button: .center)
    }

    /** Moves the cursor with a plain move event posted at session level (no HID hop, no position query): the deltas come from the known previous point. Never warps: a warp makes macOS drop real mouse motion for 150-250 ms. */
    static func moveCursor(to destination: CGPoint, from current: CGPoint) {
        let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: destination, mouseButton: .left)
        event?.setIntegerValueField(.mouseEventDeltaX, value: Int64((destination.x - current.x).rounded()))
        event?.setIntegerValueField(.mouseEventDeltaY, value: Int64((destination.y - current.y).rounded()))
        event?.post(tap: .cgSessionEventTap)
    }

    static func key(_ keyCode: UInt16, down: Bool) {
        CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: down)?.post(tap: .cgSessionEventTap)
    }

    private static func post(_ type: CGEventType, at point: CGPoint, button: CGMouseButton) {
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)?.post(tap: .cgSessionEventTap)
    }
}
