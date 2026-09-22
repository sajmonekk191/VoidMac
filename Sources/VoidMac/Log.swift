import Foundation

/** Timestamped lines in ~/Library/Logs/VoidMac.log (or $VOIDMAC_LOG), written on a utility queue so the realtime threads never wait on the disk. */
enum Log {
    static let fileURL: URL = ProcessInfo.processInfo.environment["VOIDMAC_LOG"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/VoidMac.log")
    private static let queue = DispatchQueue(label: "voidmac.log", qos: .utility)
    private static let toTerminal = isatty(1) != 0
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
    private static let handle: FileHandle? = {
        if !FileManager.default.fileExists(atPath: fileURL.path) { FileManager.default.createFile(atPath: fileURL.path, contents: nil) }
        let handle = try? FileHandle(forWritingTo: fileURL)
        _ = try? handle?.seekToEnd()
        return handle
    }()

    static func info(_ message: String) { write("[i]", "\u{1B}[36m[i]\u{1B}[0m", message) }
    static func warn(_ message: String) { write("[!]", "\u{1B}[33m[!]\u{1B}[0m", message) }
    static func error(_ message: String) { write("[x]", "\u{1B}[31m[x]\u{1B}[0m", message) }

    /** Blocks until every line logged so far is on disk; called right before the process exits. */
    static func flush() {
        queue.sync {}
    }

    private static func write(_ plain: String, _ colored: String, _ message: String) {
        let date = Date()
        queue.async {
            if toTerminal { print("\(colored) \(message)") }
            try? handle?.write(contentsOf: Data("\(stamp.string(from: date)) \(plain) \(message)\n".utf8))
        }
    }
}
