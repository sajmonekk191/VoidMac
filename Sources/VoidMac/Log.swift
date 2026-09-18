import Foundation

enum Log {
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/VoidMac.log")
    private static let lock = NSLock()
    private static let toTerminal = isatty(1) != 0
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    nonisolated(unsafe) private static var handle: FileHandle? = {
        if !FileManager.default.fileExists(atPath: fileURL.path) { FileManager.default.createFile(atPath: fileURL.path, contents: nil) }
        let h = try? FileHandle(forWritingTo: fileURL)
        h?.seekToEndOfFile()
        return h
    }()

    static func info(_ message: String) { write("[i]", "\u{1B}[36m[i]\u{1B}[0m", message) }
    static func warn(_ message: String) { write("[!]", "\u{1B}[33m[!]\u{1B}[0m", message) }
    static func error(_ message: String) { write("[x]", "\u{1B}[31m[x]\u{1B}[0m", message) }

    private static func write(_ plain: String, _ colored: String, _ message: String) {
        if toTerminal { print("\(colored) \(message)") }
        let line = "\(stamp.string(from: Date())) \(plain) \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        handle?.write(Data(line.utf8))
    }
}
