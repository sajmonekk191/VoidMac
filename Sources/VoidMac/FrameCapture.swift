import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/** What ScreenCaptureKit captures: the game window alone, or the display cropped to it. */
enum CaptureMode: String, SettingChoice {
    case window, display

    static let fallback = CaptureMode.window
}

struct Frame {
    let base: UnsafeRawPointer
    let width: Int
    let height: Int
    let bytesPerRow: Int
}

private final class ErrorBox: @unchecked Sendable {
    var error: Error?
}

/** Streams one window through ScreenCaptureKit and keeps only the newest BGRA frame. */
final class FrameCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let frameCondition = NSCondition()
    private let queue = DispatchQueue(label: "voidmac.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var latest: CVPixelBuffer?
    private var frameCounter = 0
    private var fpsWindowStart = nowMs()
    private var attached = Attachment()
    private var lastFrameStorage = 0.0
    private var configuration: SCStreamConfiguration?
    private var currentRate = 12
    private let rateQueue = DispatchQueue(label: "voidmac.capture.rate")

    /** What the running stream is attached to, written and read under `lock`. */
    private struct Attachment {
        var windowFrame = CGRect.zero
        var windowID: CGWindowID = 0
        var windowLayer = 0
        var mode = CaptureMode.window
        var native = false
        var startedAtMs = 0.0
        var pixelSize = CGSize.zero
        var fps = 0.0
    }

    /** The captured window's rect in points. */
    var windowFrame: CGRect { lock.withLock { attached.windowFrame } }
    var windowID: CGWindowID { lock.withLock { attached.windowID } }
    var windowLayer: Int {
        get { lock.withLock { attached.windowLayer } }
        set { lock.withLock { attached.windowLayer = newValue } }
    }
    var mode: CaptureMode { lock.withLock { attached.mode } }
    var native: Bool { lock.withLock { attached.native } }
    var startedAtMs: Double { lock.withLock { attached.startedAtMs } }
    var pixelSize: CGSize { lock.withLock { attached.pixelSize } }
    var fps: Double { lock.withLock { attached.fps } }
    /** Arrival time of the newest frame, under the condition its waiters sleep on. */
    var lastFrameAtMs: Double { frameCondition.withLock { lastFrameStorage } }

    var isRunning: Bool { lock.withLock { stream != nil } }
    var hasFrame: Bool { lock.withLock { latest != nil } }

    func start(window: SCWindow, display: SCDisplay? = nil, excluding: [SCRunningApplication] = [], mode requested: CaptureMode = .window, native useNative: Bool = false) {
        stop()
        let filter: SCContentFilter
        let usedMode: CaptureMode
        if requested == .display, let display {
            filter = SCContentFilter(display: display, excludingApplications: excluding, exceptingWindows: [])
            usedMode = .display
        } else {
            filter = SCContentFilter(desktopIndependentWindow: window)
            usedMode = .window
        }
        let scale = useNative ? CGFloat(filter.pointPixelScale) : 1
        let config = SCStreamConfiguration()
        config.width = max(2, Int(window.frame.width * scale))
        config.height = max(2, Int(window.frame.height * scale))
        if usedMode == .display, let display {
            config.sourceRect = CGRect(x: window.frame.minX - display.frame.minX, y: window.frame.minY - display.frame.minY,
                                       width: window.frame.width, height: window.frame.height)
        }
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, currentRate)))
        config.queueDepth = 3
        config.shouldBeOpaque = true
        config.ignoreShadowsSingleWindow = true

        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        } catch {
            Log.error("Capture output setup failed: \(error.localizedDescription)")
            return
        }
        let box = ErrorBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do { try await newStream.startCapture() } catch { box.error = error }
            semaphore.signal()
        }
        semaphore.wait()
        if let error = box.error {
            Log.error("Capture start failed: \(error.localizedDescription)")
            return
        }
        lock.withLock {
            stream = newStream
            latest = nil
            attached = Attachment(windowFrame: window.frame, windowID: window.windowID, windowLayer: window.windowLayer, mode: usedMode, native: useNative,
                                  startedAtMs: nowMs(), pixelSize: CGSize(width: config.width, height: config.height), fps: attached.fps)
            configuration = config
            frameCounter = 0
            fpsWindowStart = nowMs()
        }
        Log.info("Capturing game window \(Int(window.frame.width))x\(Int(window.frame.height)) pt @ \(config.width)x\(config.height) px, layer \(window.windowLayer), mode \(usedMode.rawValue)")
    }

    /** Frame-rate cap applied live without restarting the stream; a no-op when unchanged, never blocks the caller. */
    func setRate(_ fps: Int) {
        let target: (SCStream, SCStreamConfiguration)? = lock.withLock {
            guard currentRate != fps else { return nil }
            currentRate = fps
            guard let stream, let configuration else { return nil }
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
            return (stream, configuration)
        }
        guard let target else { return }
        rateQueue.async {
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                try? await target.0.updateConfiguration(target.1)
                semaphore.signal()
            }
            semaphore.wait()
            Log.info("capture rate: \(fps) fps")
        }
    }

    func stop() {
        let old: SCStream? = lock.withLock {
            let s = stream
            stream = nil
            latest = nil
            configuration = nil
            return s
        }
        guard let old else { return }
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            try? await old.stopCapture()
            semaphore.signal()
        }
        semaphore.wait()
        Log.info("Capture stopped")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.withLock {
            latest = buffer
            frameCounter += 1
            let elapsed = nowMs() - fpsWindowStart
            if elapsed >= 1000 {
                attached.fps = Double(frameCounter) * 1000 / elapsed
                frameCounter = 0
                fpsWindowStart = nowMs()
            }
        }
        frameCondition.lock()
        lastFrameStorage = nowMs()
        frameCondition.broadcast()
        frameCondition.unlock()
    }

    /** Blocks until a frame newer than `stamp` arrived (true) or the timeout passed. */
    func waitForFrame(after stamp: Double, timeoutMs: Int) -> Bool {
        let deadline = Date(timeIntervalSinceNow: Double(timeoutMs) / 1000)
        frameCondition.lock()
        defer { frameCondition.unlock() }
        while lastFrameStorage <= stamp, frameCondition.wait(until: deadline) {}
        return lastFrameStorage > stamp
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.withLock {
            self.stream = nil
            latest = nil
        }
        Log.error("Capture stream stopped: \(error.localizedDescription)")
    }

    /** Runs `body` on the newest frame while its memory is locked; nil when no frame exists yet. */
    func withLatestFrame<T>(_ body: (Frame) -> T?) -> T? {
        guard let buffer = lock.withLock({ latest }) else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let frame = Frame(base: UnsafeRawPointer(base),
                          width: CVPixelBufferGetWidth(buffer),
                          height: CVPixelBufferGetHeight(buffer),
                          bytesPerRow: CVPixelBufferGetBytesPerRow(buffer))
        return body(frame)
    }
}
