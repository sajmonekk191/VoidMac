import Foundation
import Testing
@testable import VoidMac

@Test func logWritesEveryLineOffTheCallingThreads() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("voidmac-test-\(UUID().uuidString).log").path
    setenv("VOIDMAC_LOG", path, 1)
    try #require(Log.fileURL.path == path)
    DispatchQueue.concurrentPerform(iterations: 8) { thread in
        for line in 0..<50 { Log.info("thread \(thread) line \(line)") }
    }
    Log.flush()
    let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 400)
    #expect(lines.allSatisfy { $0.contains(" [i] thread ") })
    try? FileManager.default.removeItem(atPath: path)
}
