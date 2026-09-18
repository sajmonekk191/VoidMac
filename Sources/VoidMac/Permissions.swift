import ApplicationServices
import CoreGraphics
import IOKit.hid

enum Permissions {
    /** Prompts for Accessibility, Screen Recording and Input Monitoring and returns what is granted. */
    static func request() -> PermissionStatus {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        var status = PermissionStatus()
        status.accessibility = AXIsProcessTrustedWithOptions(options)
        status.screenRecording = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
        status.inputMonitoring = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted || IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        report("Accessibility (mouse/keyboard events)", status.accessibility)
        report("Screen Recording (pixel search)", status.screenRecording)
        report("Input Monitoring (activation key)", status.inputMonitoring)
        if !(status.accessibility && status.screenRecording) {
            Log.warn("Grant the missing permissions to Void# in System Settings > Privacy & Security, then restart.")
        }
        return status
    }

    static func current() -> PermissionStatus {
        PermissionStatus(accessibility: AXIsProcessTrusted(),
                         screenRecording: CGPreflightScreenCaptureAccess(),
                         inputMonitoring: IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted)
    }

    private static func report(_ name: String, _ granted: Bool) {
        if granted { Log.info("\(name): granted") } else { Log.error("\(name): MISSING") }
    }
}
